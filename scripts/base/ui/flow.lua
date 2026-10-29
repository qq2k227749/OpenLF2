-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local virtual_keys = constants.virtual_keys
-- Session-owned screen routing. Base screens and replacements share this API.
local title = require("base/ui/title")
local speed = require("base/game/speed")
local controls = require("base/ui/controls")
local music = require("base/game/music")
local recording = require("base/game/recording")
local catalog = require("base/game/catalog")
local font = require("base/ui/font")
local i18n = require("base/i18n/i18n")
local network = require("base/game/network")
local unlock = require("base/game/unlock")
local control = require("base/game/control")
local user_options = require("base/game/options")
local touch_gamepad = require("base/ui/touch_gamepad")
local quit_dialog = require("base/ui/quit_dialog")
local flow = {}
local function screen_module(name)
    if name == "characters" then return require("base/ui/character_select") end
    if name == "backgrounds" then return require("base/ui/background_preview") end
    if name == "match" then return require("base/ui/match_screen") end
    if name == "battle" then return require("base/ui/battle_setup") end
    if name == "championship" then return require("base/ui/championship") end
    if name == "ending" then return require("base/ui/ending") end
    if name == "network" then return require("base/ui/network") end
    if name == "launch" then return require("base/ui/launch") end
    return title
end
-- Whether the current screen reads key sets directly (not mouse/touch via base/ui/navigation);
-- the on-screen gamepad only has something to drive there ("full"); while a match is paused or
-- replaying only its pause button shows ("pause"); in a live match it shows too ("match").
local function gamepad_mode(state)
    if state.active == "launch" or state.active == "network" then return nil end
    if state.active == "match" then
        local match = state.match.match
        -- Paused or replaying: only the pause button stays, to resume.
        if match.replay and not match.replay_ended then return "pause" end
        if state.match.view and state.match.view.paused then return "pause" end
        return "match"
    end
    return "full"
end
local function screen_state(state)
    return state[state.active]
end
local function can_drop_replay(state)
    return not state.session and not state.quit_dialog and (state.active == "title"
        or (state.active == "launch" and state.launch.page == "menu"))
end
function flow.create(options)
    local settings = controls.load(options.default_controller)
    -- OpenLF2's own options (base/game/options), e.g. the unlocked characters.
    user_options.start()
    local state = {active = "launch", title = title.create(options), options = options,
        launch = require("base/ui/launch").create({menu_seed = options.menu_seed, problem = settings.problem,
            game_pack = options.game_pack}),
        pointer_x = 0, pointer_y = 0, previous_button = false, volume_frames = 0,
        touch_gamepad = touch_gamepad.create(user_options.current().gamepad, user_options.current().digipad), mouse_touch = false,
        -- Optional mouse input can stand in for touch while testing the on-screen gamepad.
        mouse_touch_enabled = options.mouse_touch == true}
    music.play("bgm/main.wma")
    -- A startup recording is already queued by the host; route consumes it on the first frame.
    if options.start_screen == "replay" then state.active = "title" end
    -- Developer entry points requested by the host; not part of the original flow.
    if options.start_screen == "ending" then
        state.ending = require("base/ui/ending").create(0)
        state.active = "ending"
    end
    if options.start_screen == "backgrounds" then
        state.backgrounds = require("base/ui/background_preview").create()
        state.active = "backgrounds"
    end
    if options.network_role then
        state.network = require("base/ui/network").create(options)
        state.active = "network"
        state.network_cli = options.network_trace
        require("base/ui/network").begin(state.network, options.network_role == "host", options.network_address)
    end
    return state
end
local function with_recording(state, options)
    options.network = state.session ~= nil
    local settings = controls.current()
    if settings.record == 0 then return options end
    local names = {}
    for slot = 0, 7 do names[slot + 1] = controls.name(slot) end
    options.record = {names = names, version = state.options.recording_version or 0, time = engine.local_time(),
        music = music.selected and music.selected:gsub("/", "\\") or "", author = settings.author,
        info = settings.info, email = settings.email}
    return options
end
-- The title's Replay entry: a recording the player chose arrives from the host; after
-- data/version checks, the game starts at once.
local function start_replay(state, block)
    local replay, problem = recording.open(block, state.options.recording_version or 0)
    if not replay then
        recording.status = {kind = constants.recording_statuses.error, text = i18n.clip(i18n.tr(problem), 96), count = 0}
        return
    end
    controls.replace_names(replay.names)
    unlock.begin_replay(replay.unlock_characters, replay.unlock_function_keys)
    if replay.mode ~= constants.modes.stage and replay.music ~= "" then
        music.selected = replay.music:gsub("\\", "/"):lower()
        music.play_selected()
    end
    local options = {mode = replay.mode, difficulty = replay.difficulty, background = replay.background,
        stage_level = replay.stage_level, fighters = catalog.load(), backgrounds = catalog.backgrounds(), slots = {},
        replay = replay, battle = replay.battle}
    state.match = require("base/ui/match_screen").create(options)
    state.active = "match"
    state.wait_release = true
end
local function leave_replay(state)
    controls.replace_names(nil)
    unlock.end_replay()
    music.play("bgm/main.wma")
    speed.fast = false
    state.active = "title"
    state.wait_release = true
end

local function route(state, input, context)
    if can_drop_replay(state) then
        local block, problem = engine.take_recording()
        if block then
            start_replay(state, block)
            return
        elseif problem then
            recording.status = {kind = constants.recording_statuses.error, text = i18n.tr("Loading error!  Recording file may be corrupted!!"), count = 0}
        end
    end
    if state.wait_release then
        if not controls.idle(input) then return end
        state.wait_release = false
    end
    local routed = {}
    for key, value in pairs(context) do routed[key] = value end
    local requested
    function routed.action(name)
        assert(not requested, "multiple screen actions in one update")
        requested = name
    end
    screen_module(state.active).update(screen_state(state), input, routed)
    -- A recording opened from a file manager or the command line owns this window.
    -- F4 and leaving its result screen finish that invocation.
    if state.options.start_screen == "replay" and state.active == "match"
       and state.match.match.replay and (requested == "title" or requested == "round_over") then
        context.action("quit")
        return
    end
    if requested == "network" then
        state.network = require("base/ui/network").create(state.options)
        state.active = "network"
    elseif requested == "network_ready" then
        local before = unlock.reset_session()
        state.session = state.network.session
        -- Hidden characters unlocked here (the option or LF2.NET) are unlocked for the whole room.
        if before.characters == 1 then network.share_unlocked(state.session) end
        controls.replace_names(state.session.names)
        state.title = title.create(state.options)
        if title.set_replay_disabled then title.set_replay_disabled(state.title, true) end
        state.active = "title"
        state.wait_release = true
        -- A new connection starts a new deterministic menu session on both peers.
        state.characters, state.championship, state.championship_options, state.battle_config = nil, nil, nil, nil
        require("base/game/stage").set_random_list({constants.fighter_ids.deep,
            constants.fighter_ids.john, constants.fighter_ids.henry, constants.fighter_ids.rudolf,
            constants.fighter_ids.louis, constants.fighter_ids.davis, constants.fighter_ids.dennis,
            constants.fighter_ids.woody, constants.fighter_ids.freeze, constants.fighter_ids.firen}, -1)
        require("base/ui/demo").reset()
        recording.status = nil
        music.enabled, music.selected = true, nil
        speed.fast = false
        music.play("bgm/main.wma")
    elseif requested == "launch" then
        state.active = "launch"
        state.session = nil
        controls.replace_names(nil)
    elseif requested == "versus" or requested == "stage" or requested == "battle" then
        -- The previous visit's state carries the values the original keeps in globals.
        state.characters = require("base/ui/character_select").create({mode = requested,
            previous = state.characters})
        state.active = "characters"
        state.wait_release = true
    elseif requested == "start_match" then
        local options
        if state.active == "battle" then
            options = require("base/ui/battle_setup").match_options(state.battle)
        elseif state.active == "championship" then
            options = require("base/ui/championship").match_options(state.championship)
        else
            options = require("base/ui/character_select").match_options(state.characters)
        end
        state.match = require("base/ui/match_screen").create(with_recording(state, options))
        state.active = "match"
        state.wait_release = true
    elseif requested == "championship" or requested == "team_championship" then
        state.championship_options = state.championship_options or (state.characters and state.characters.options)
            or {background = constants.background_rows.random, random_background = true, difficulty = 0}
        state.championship = require("base/ui/championship").create(state.championship_options,
            requested == "team_championship")
        state.active = "championship"
        state.wait_release = true
    elseif requested == "battle_setup" then
        local setup = require("base/ui/battle_setup")
        state.battle_config = state.battle_config or setup.create_config()
        state.battle = setup.create(state.characters, state.battle_config)
        state.active = "battle"
        state.wait_release = true
    elseif requested == "characters" then
        -- Reset All / back from the Battle setup: the character menu starts over.
        state.characters = require("base/ui/character_select").reset_all(state.characters)
        state.active = "characters"
        state.wait_release = true
    elseif requested == "replay_error" then
        recording.status = {kind = constants.recording_statuses.error, text = i18n.tr("Recording file error! Replaying canceled!"), count = 0}
        leave_replay(state)
    elseif requested == "round_over" and state.match.match.replay then
        -- After a replay, the game returns to the title.
        leave_replay(state)
    elseif requested == "demo" or (requested == "round_over" and state.match.match.mode == constants.modes.demo) then
        if requested == "round_over" and not state.match.match.random_game then
            speed.fast = false
            music.play("bgm/main.wma")
            state.active = "title"
        else
            music.play_selected()
            state.match = require("base/ui/match_screen").create(require("base/ui/demo").match_options(state.characters))
            state.active = "match"
        end
        state.wait_release = true
    elseif requested == "round_over" then
        local outcome = require("base/ui/match_screen").outcome(state.match)
        local selection = require("base/ui/character_select")
        if state.match.match.mode == constants.modes.championship
           or state.match.match.mode == constants.modes.team_championship then
            require("base/ui/championship").round_over(state.championship, state.match.match)
            state.active = "championship"
        elseif state.characters.mode == constants.modes.battle then
            state.battle = require("base/ui/battle_setup").create(state.characters, state.battle_config)
            state.battle.state = constants.battle_setup_states.options
            state.active = "battle"
        elseif outcome.ending then
            state.ending = require("base/ui/ending").create(state.match.match.difficulty)
            state.active = "ending"
        elseif outcome.auto_start then
            state.characters = selection.resume_options(state.characters, outcome)
            state.match = require("base/ui/match_screen").create(with_recording(state, selection.match_options(state.characters)))
            state.active = "match"
        else
            state.characters = selection.resume_options(state.characters, outcome)
            state.active = "characters"
        end
        state.wait_release = true
    elseif requested == "game_start" then
        music.play("bgm/main.wma")
        state.active = "title"
        if title.latch_input then title.latch_input(state.title, input)
        else state.wait_release = true end
    elseif requested == "title" then
        if not state.session then controls.replace_names(nil) end
        unlock.end_replay()
        music.play("bgm/main.wma")
        state.active = "title"
        -- Do not turn the key returning to the title into a new title action.
        state.wait_release = true
    elseif requested then context.action(requested) end
end
function flow.describe(state)
    local module = screen_module(state.active)
    local detail = module.describe and module.describe(screen_state(state)) or ""
    local status = recording.status_text()
    local unlocked = unlock.describe()
    return (state.session and "network_frames=" .. state.session.frames .. " " or "") .. "screen=" .. state.active .. (detail ~= "" and " " .. detail or "") .. (status and " status=" .. status or "")
        .. (unlocked and " unlock=" .. unlocked or "")
end
function flow.draw(state, context)
    context.replay_drop(can_drop_replay(state))
    local shown_options = user_options.current()
    context.render_filter(shown_options.upscaling_filter)
    -- Fullscreen (OpenLF2 extension): no-op without a real window; reasserted every frame
    -- like the filter above.
    context.fullscreen(shown_options.fullscreen)
    if state.active == "match" and shown_options.battlefield_layout == "expand" then
        screen_module(state.active).draw(screen_state(state), context, state.window_bounds)
    else
        screen_module(state.active).draw(screen_state(state), context)
    end
    -- The on-screen gamepad draws on top of every screen it drives; hidden while paused (it
    -- would sit under the PAUSE picture).
    if gamepad_mode(state) then
        state.touch_gamepad.fast_on = speed.fast
        touch_gamepad.draw(state.touch_gamepad, context)
    end
    local status = recording.status_text()
    if status then font.gdi(context, i18n.clip(status, 128), 3, 0x213, recording.status_color())
    elseif state.volume_text then font.gdi(context, state.volume_text, 3, 0x213, 0x00ff00) end
    -- Show FPS (OpenLF2 extension): centered on the statusbar line so it never overlaps the
    -- left-aligned text.
    if shown_options.show_fps and state.fps then
        local fps_text = "FPS: " .. state.fps
        font.gdi(context, fps_text, math.floor((constants.screen.width - font.gdi_width(fps_text)) / 2), 0x213)
    end
    if state.quit_dialog then quit_dialog.draw(state.quit_dialog, context) end
end
local function disconnect(state, message)
    network.close(state.session)
    state.session = nil
    unlock.end_session()
    controls.replace_names(nil)
    state.active, state.wait_release = "launch", nil
    state.title = title.create(state.options)
    state.characters, state.championship, state.championship_options, state.battle_config = nil, nil, nil, nil
    state.launch.message = message
    speed.fast = false
    music.play("bgm/main.wma")
end
-- Whether Escape (and Android's back button, which the platform reports as Escape) is free to ask about leaving
-- the game: not in a network game, where it disconnects, and not on the launch screen's pages that use it.
local function escape_free(state)
    if state.session then return false end
    if state.active == "launch" then return state.launch.page == "menu" end
    return true
end
-- raw: the host's input; screens get it per player slot, with the last known pointer position
-- and `click`, a fresh press of the left button.
function flow.update(state, raw, context)
    local input = controls.read(controls.current(), raw)
    i18n.host(input.filters and input.filters.text)
    -- Alt+Enter, from any screen: the fullscreen option flips (and is saved like the options page does).
    if input.toggle_fullscreen and input.filters and input.filters.window then
        local values = user_options.current()
        values.fullscreen = not values.fullscreen
        user_options.save(values)
        input.fullscreen_set = values.fullscreen
    end
    local shown_options = user_options.current()
    -- Local presentation data stays outside network and replay inputs.
    if shown_options.battlefield_layout == "expand" then
        state.window_bounds = input.screen or state.window_bounds
    else
        state.window_bounds = nil
    end
    -- The on-screen gamepad drives player 1's slot, merged here before a networked match sends
    -- input[0]. It only reads fingers on screens it drives, releasing/hiding otherwise.
    local mode = gamepad_mode(state)
    local active_screen = mode ~= nil
    -- Mouse-as-touch stays active after release, like a held touch; real input or touch ends it.
    -- The "Show gamepad" option shows the gamepad when a screen first drives it and lets the mouse
    -- press it; keyboard or controller input hides it again until the mouse is used.
    local always_gamepad = shown_options.show_gamepad
    if not always_gamepad then
        state.gamepad_shown = false
    elseif active_screen and not state.gamepad_shown then
        state.gamepad_shown = true
        state.mouse_touch = true
    end
    local mouse_driven = state.mouse_touch_enabled or always_gamepad
    if mouse_driven and not input.touch_active then
        -- Presses are the key-downs since the last frame, so a tap that came and went still counts.
        local keyboard_or_pad = next(input.keys) ~= nil or next(input.gamepad) ~= nil or #(input.presses or {}) > 0
        for _, pad in ipairs(input.pads or {}) do
            if next(pad.dirs) ~= nil or next(pad.buttons) ~= nil then keyboard_or_pad = true end
        end
        if keyboard_or_pad then
            state.mouse_touch = nil
        elseif active_screen and input.button and input.pointer_x and input.pointer_y
               and not (input.pointer_x == -1 and input.pointer_y == -1) then
            state.mouse_touch = true
        end
    end
    if not mouse_driven then state.mouse_touch = nil end
    local gamepad_input = input
    if active_screen and state.mouse_touch and not input.touch_active then
        gamepad_input = {touch_active = true, screen = input.screen,
            touches = input.button and {{id = 0, x = input.pointer_x, y = input.pointer_y}} or {}}
    end
    -- Chord buttons are enabled by what player 1's fighter can do right now.
    local fighter = state.active == "match" and state.match and state.match.match and state.match.match.items[0] or nil
    local available = {}
    for _, chord in ipairs({"da", "dj", "daj"}) do available[chord] = control.chord_available(fighter, chord) end
    touch_gamepad.set_available(state.touch_gamepad, available)
    local touched, pause_held, fast_held = touch_gamepad.update(state.touch_gamepad,
        active_screen and gamepad_input or {touch_active = false, screen = input.screen}, mode)
    -- The pause button is F1; the match toggles on its press.
    if pause_held and state.active == "match" and not input.functions:find("1", 1, true) then
        input.functions = input.functions .. "1"
    end
    -- The fast-forward button is F5.
    if fast_held and state.active == "match" and not input.functions:find("5", 1, true) then
        input.functions = input.functions .. "5"
    end
    for _, letter in ipairs({"u", "d", "l", "r", "c", "b", "f"}) do
        if touched:find(letter, 1, true) and not input[0]:find(letter, 1, true) then input[0] = input[0] .. letter end
    end
    local local_keys = input.keys
    local left_room = false
    if state.session then
        unlock.observe(input)
        if network.takes_unlock_bits(state.session) then input.unlock_bits = unlock.take_pending() end
        if input.keys[virtual_keys.escape] then
            disconnect(state, i18n.tr("Network game disconnected"))
            left_room = true
        else
            local hp = state.active == "match" and recording.hp_sum(state.match.match) or 0
            local combined, problem = network.exchange(state.session, input, hp)
            if problem then
                disconnect(state, problem)
            elseif not combined then return false
            else input = combined end
        end
    end
    local joining_cli = state.network_cli and state.active == "network"
    if input.pointer_x and input.pointer_x >= 0 and input.pointer_y >= 0 then
        state.pointer_x, state.pointer_y = input.pointer_x, input.pointer_y
    end
    input.pointer_x, input.pointer_y = state.pointer_x, state.pointer_y
    -- Renderer capability flags are kept for frames that don't repeat them.
    if input.filters then state.filters = input.filters end
    input.filters = state.filters or {}
    input.click = input.button and not state.previous_button
    state.previous_button = input.button
    -- Unlock words: typed marks are taken before the screen runs, except during a replay
    -- (recorded bits act instead); a recording match stores the frame's bits.
    if not state.session then unlock.observe(input) end
    local current = state.active == "match" and state.match and state.match.match
    if not (current and current.replay and not current.replay_ended) then
        local bits, played
        if input.network then
            bits = input.unlock_bits or 0
            played = unlock.apply_recorded(bits)
        else bits, played = unlock.take_marks() end
        for _, sound in ipairs(played) do context.sound(sound.resource, sound.volume, sound.pan) end
        if current then current.unlock_bits = bits end
    end
    local escape_pressed = false
    for _, code in ipairs(input.presses or {}) do
        if code == virtual_keys.escape then escape_pressed = true end
    end
    if input.keys[virtual_keys.escape] and not state.escape_held then escape_pressed = true end
    state.escape_held = input.keys[virtual_keys.escape] == true
    -- The Escape that left a network game does not also ask to exit on the launch screen.
    if left_room then escape_pressed = false end
    local closed_now = false
    if state.quit_dialog then
        -- While the question is open the screen below is frozen.
        local answer = quit_dialog.update(state.quit_dialog, input, context)
        if answer == "exit" and state.quit_dialog.kind == "leave" then
            -- Leaving the fight is F4, held for two frames after this one so that the match sees it on a frame that
            -- reads the keys (no wait for released keys here: a held F4 would never count as idle).
            state.pending_leave = 3
            state.quit_dialog, state.swallow_pointer, closed_now = nil, true, true
        elseif answer == "exit" then
            context.action("quit")
        elseif answer == "close" then
            -- The press that closed it must not reach the screen below: it skips this frame and then ignores the
            -- pointer button until it is released.
            state.quit_dialog, state.wait_release, state.swallow_pointer, closed_now = nil, true, true, true
        end
    elseif escape_pressed and escape_free(state) then
        state.quit_dialog = quit_dialog.create(state.active == "match" and "leave" or "exit")
    end
    if state.pending_leave and not state.quit_dialog then
        if state.active == "match" and not input.functions:find("4", 1, true) then input.functions = input.functions .. "4" end
        state.pending_leave = state.pending_leave > 1 and state.pending_leave - 1 or nil
    end
    if state.swallow_pointer and not state.quit_dialog then
        if input.button then input.button, input.click = false, false else state.swallow_pointer = nil end
    end
    if not state.quit_dialog and not closed_now then route(state, input, context) end
    if joining_cli then
        if state.network.session.error then error(state.network.session.error) end
        -- CLI traces start at the title; the handshake consumes no trace frames.
        return false
    end
    local step = 0
    if local_keys[virtual_keys.f11] then step = -1 end
    if local_keys[virtual_keys.f12] then step = 1 end
    if step ~= 0 then
        music.change_volume(step)
        state.volume_frames = 100
    end
    state.volume_text = nil
    if state.volume_frames > 0 then
        state.volume_text = i18n.tr("Volume: %d", music.master)
        state.volume_frames = state.volume_frames - 1
    end
    music.flush(context)
    recording.tick_status(state.active == "match" and state.match.match.paused)
    -- A relay room paces its own frames (base/game/room): the host asks for ticks as often as it
    -- can and the session waits for each frame's turn; F5's fast mode cannot speed up a room.
    context.speed(state.session and network.paced(state.session) or speed.fast)
    -- Show FPS (OpenLF2 extension): measured FPS, nil for a trace unless given; drawn in flow.draw.
    state.fps = input.fps
end
return flow
