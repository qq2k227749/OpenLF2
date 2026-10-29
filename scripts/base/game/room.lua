-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Network play in a relay room (OpenLF2 extension; the web build): protocol 2 of
-- tools/relay/server.js. 2 to 8 computers play one game and the relay keeps the beat: every 33 1/3 ms
-- it sends each computer a frame holding the input of every computer, and each computer runs
-- exactly the frames it receives, in order, so all stay in step without waiting for each other.
-- A computer far from the relay sees the game a little later and its own keys take a little
-- longer to act, but nobody else is slowed down.
--
-- The 8 player slots are shared out in the order of the relay's list (the host first): with 2
-- computers each gets 4 (players 1-4 and 5-8, as in the original), with 3 they get 3, 3 and 2,
-- with 4 two each, ... and with 8 one each. A computer's slots take its players 1, 2, ... in turn.
--
-- An input, at most 16 bytes: byte 1 one-shot events (bits 0 and 1: the unlock words typed; bit 2:
-- this computer came with the hidden characters unlocked), bytes 2 and 3 the function keys F1-F8
-- and F9 held, then one byte per slot of the computer (recording.pack_keys). Inputs are bit sets:
-- the relay merges those of one beat by OR.
local constants = require("base/game/constants")
local controls = require("base/ui/controls")
local recording = require("base/game/recording")
local i18n = require("base/i18n/i18n")
local unlock = require("base/game/unlock")
local room = {}

local kinds = {hello = 0x01, start = 0x02, input = 0x03, ready = 0x04, check = 0x05,
    welcome = 0x81, lobby = 0x82, started = 0x83, frame = 0x84, checked = 0x85, left = 0x86}
local slot_count = 8
local most_players = 8
local connect_timeout, frame_timeout = 30000, 30000 -- ms
local display_slack, display_catch_up = 4, 50 -- ms (see room.exchange)
local check_interval = 8 -- frames between two desync checks sent
local history_size = 1024 -- frames whose own checks are kept for comparison
local max_backlog = 9000 -- frames (5 minutes) received and not run yet
local heartbeat = 25 -- ms: while frames run, an input goes to the relay at least this often
local playout_window = 90 -- frames whose arrival times set the pacing
local powers = {1, 2, 4, 8, 16, 32, 64, 128}

local function has(value, index) return math.floor(value / powers[index]) % 2 == 1 end
local function bit_or(a, b)
    local result = 0
    for index = 1, 8 do
        if has(a, index) or has(b, index) then result = result + powers[index] end
    end
    return result
end
local function u16(value) return string.char(value % 256, math.floor(value / 256) % 256) end
local function u32(value)
    return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256)
end
local function read_u16(bytes, at)
    local low, high = bytes:byte(at, at + 1)
    return low + high * 256
end
local function read_u32(bytes, at)
    local a, b, c, d = bytes:byte(at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function message(kind, payload) return string.char(kind) .. u16(#payload) .. payload end

local function failed(state, problem)
    engine.network("close")
    state.phase, state.error = "failed", problem
    return nil, problem
end
local function send(state, bytes)
    local sent, problem = engine.network("send", bytes)
    if not sent then return failed(state, problem) end
    return true
end

-- What every computer in a room must share: engine, scripts and mods, recording version, game data.
local function profile(state)
    return "OpenLF2 Room 1\n" .. state.engine_profile .. "\n" .. string.format("%.0f", state.version) .. "\n"
        .. string.format("%.0f", recording.data_checksum() % 4294967296)
end
-- This computer's player names (its key sets 1-4), NUL separated.
local function own_names()
    local names = {}
    for index = 1, 4 do
        local name = controls.current().names[index] or ""
        names[index] = name:match("^[^_%z]*"):sub(1, constants.text_limits.player_name_bytes)
    end
    return table.concat(names, "\0")
end
local function split_names(info)
    local names, at = {}, 1
    while true do
        local stop = info:find("\0", at, true)
        names[#names + 1] = info:sub(at, (stop or #info + 1) - 1)
        if not stop then return names end
        at = stop + 1
    end
end
-- The player list of LOBBY and STARTED, from `at`; returns the players and the position after them.
local function read_players(payload, at)
    local count = payload:byte(at)
    if not count or count > most_players then return nil end
    local players = {}
    at = at + 1
    for index = 1, count do
        local id, flags, length = payload:byte(at, at + 2)
        if not length or at + 2 + length > #payload then return nil end
        players[index] = {id = id, host = flags % 2 == 1, names = split_names(payload:sub(at + 3, at + 2 + length))}
        at = at + 3 + length
    end
    return players, at
end
local function player_name(player, fallback)
    local name = player.names[1]
    if name and name ~= "" then return name end
    return fallback
end

function room.create(options)
    assert(type(options.network_profile) == "string" and #options.network_profile == 64, "missing network profile")
    return {relay = true, phase = "idle", received = "", read_at = 1, frames = 0, members = {},
        engine_profile = options.network_profile, version = options.recording_version or 0,
        port = options.network_port or constants.network.default_port}
end
function room.close(state)
    engine.network("close")
    state.phase, state.received, state.read_at = "idle", "", 1
end
function room.start(state, host, address)
    room.close(state)
    state.host, state.error = host, nil
    state.id, state.code, state.tick, state.most = nil, nil, 33, most_players
    state.members, state.order, state.own, state.names, state.start_sent = {}, nil, nil, nil, false
    state.queue, state.queue_first, state.queue_last = {}, 1, 0
    state.next_frame, state.next_run, state.frames = 0, 0, 0
    state.history, state.checks = {}, {}
    state.sent, state.sent_at, state.events = nil, 0, 0
    state.offsets, state.offset_next, state.offset_count, state.target = {}, 1, 0, nil
    local started, problem = engine.network(host and "host" or "join", address, state.port)
    if not started then return failed(state, problem) end
    state.phase = "connecting"
    state.deadline = engine.network_time() + connect_timeout
    return true
end

-- The host's random table goes to everyone; each computer's slots follow from the list.
local function apply_start(state, players, setup)
    if #setup ~= constants.random_table_size or setup:find("\0", 1, true) then
        return nil, "Invalid network random table"
    end
    local own
    for index, player in ipairs(players) do
        if player.id == state.id then own = index end
    end
    if not own or #players < 2 then return nil, "Invalid network player assignment" end
    local share, extra = math.floor(slot_count / #players), slot_count % #players
    local offset = 0
    state.names = {}
    for index, player in ipairs(players) do
        player.offset, player.count = offset, math.min(4, share + (index <= extra and 1 or 0))
        for slot = 1, player.count do state.names[offset + slot] = player.names[slot] or "" end
        offset = offset + player.count
    end
    state.order, state.own, state.members = players, own, players
    engine.set_random_state(setup, 0)
    engine.reset_random_sequence()
    state.phase = "ready"
    state.deadline = engine.network_time() + frame_timeout
    return send(state, message(kinds.ready, ""))
end

-- Pacing: a frame runs at (its number x the beat) + target, the target following the earliest
-- arrival of the recent frames plus most of their spread, so that frames that come a little early
-- or late still run evenly. The target rises at once and sinks slowly.
local function note_arrival(state, number, now)
    state.offsets[state.offset_next] = now - state.tick * number
    state.offset_next = state.offset_next % playout_window + 1
    state.offset_count = math.min(state.offset_count + 1, playout_window)
end
local function update_target(state)
    local values = {}
    for index = 1, state.offset_count do values[index] = state.offsets[index] end
    table.sort(values)
    local base = values[1]
    local spread = values[math.max(1, math.ceil(#values * 0.9))] - base
    local wanted = base + math.min(math.max(spread + 2, 2), 100)
    if not state.target or wanted > state.target then state.target = wanted
    else state.target = math.max(wanted, state.target - 0.5) end
end

local function compare(state, number, hash)
    local own = state.history[number % history_size]
    if own and own.number == number and own.hash ~= hash then return nil, "Network HP synchronization mismatch" end
    return true
end

local function handle(state, kind, payload)
    if kind == kinds.welcome then
        local id, flags, most, tick, length = payload:byte(1, 5)
        if not length or #payload ~= 5 + length then return nil, "Invalid network welcome" end
        state.id, state.host, state.most = id, flags % 2 == 1, math.min(most, most_players)
        -- The beat: whole milliseconds, plus thirds of one in flags bits 1-2 (33 1/3 ms: 30 per second).
        state.tick = (tick > 0 and tick or 33) + (math.floor(flags / 2) % 4 % 3) / 3
        state.code = payload:sub(6)
    elseif kind == kinds.lobby then
        if state.phase == "ready" then return true end
        local players, at = read_players(payload, 1)
        if not players or at ~= #payload + 1 then return nil, "Invalid network player list" end
        state.members, state.start_sent = players, false
    elseif kind == kinds.started then
        if state.phase ~= "lobby" then return nil, "Invalid network start" end
        local players, at = read_players(payload, 1)
        if not players or at + 1 > #payload or at + 1 + read_u16(payload, at) ~= #payload then
            return nil, "Invalid network start"
        end
        return apply_start(state, players, payload:sub(at + 2))
    elseif kind == kinds.frame then
        if state.phase ~= "ready" or #payload < 7 then return nil, "Invalid network frame" end
        local number, count = read_u32(payload, 1), payload:byte(5)
        if number ~= state.next_frame then return nil, "Network frames out of order" end
        if count ~= #state.order then return nil, "Invalid network frame" end
        local inputs, at = {}, 8
        for index = 1, count do
            local length = payload:byte(at)
            if not length or at + length > #payload then return nil, "Invalid network frame" end
            inputs[index] = payload:sub(at + 1, at + length)
            at = at + 1 + length
        end
        if at ~= #payload + 1 then return nil, "Invalid network frame" end
        state.next_frame = number + 1
        state.queue_last = state.queue_last + 1
        state.queue[state.queue_last] = {number = number, inputs = inputs, present = payload:byte(7)}
        if state.queue_last - state.queue_first + 1 > max_backlog then
            return nil, "Network: this computer fell too far behind the game"
        end
        note_arrival(state, number, engine.network_time())
    elseif kind == kinds.checked then
        if state.phase ~= "ready" or #payload ~= 7 then return nil, "Invalid network check" end
        local number, hash = read_u32(payload, 2), read_u16(payload, 6)
        if number < state.next_run then return compare(state, number, hash) end
        if number > state.next_run + max_backlog * 2 then return nil, "Invalid network check" end
        local waiting = state.checks[number] or {}
        waiting[#waiting + 1] = hash
        state.checks[number] = waiting
    elseif kind == kinds.left then
        local player = state.order and state.order[(payload:byte(1) or 255) + 1]
        if not player then return nil, "Invalid network message" end
        player.left = true
        recording.status = {kind = constants.recording_statuses.error, count = 0,
            text = i18n.tr("%s left the game", player_name(player, i18n.tr("Player %d", player.offset + 1)))}
    end
    -- Other kinds: from a newer relay, not needed here.
    return true
end

-- Takes the complete messages received so far.
local function read_messages(state)
    local bytes, problem = engine.network("poll")
    if not bytes then return failed(state, problem) end
    if bytes ~= "" then
        state.received = state.received:sub(state.read_at) .. bytes
        state.read_at = 1
    end
    local buffer, at = state.received, state.read_at
    while #buffer - at >= 2 do
        local length = read_u16(buffer, at + 1)
        if #buffer - at + 1 < 3 + length then break end
        local ok, why = handle(state, buffer:byte(at), buffer:sub(at + 3, at + 2 + length))
        at = at + 3 + length
        if not ok then
            state.read_at = at
            if state.phase == "failed" then return nil, state.error end
            return failed(state, why)
        end
    end
    state.read_at = at
    return true
end

-- From the lobby: true once the game started here, false while waiting, nil and a message on failure.
function room.poll(state)
    if state.phase == "failed" then return nil, state.error end
    local ok, problem = read_messages(state)
    if not ok then return nil, problem end
    if state.phase == "connecting" then
        if engine.network_time() > state.deadline then return failed(state, "Network connection timed out") end
        if engine.network("status") == "connected" then
            local identity = profile(state)
            if not send(state, message(kinds.hello, string.char(#identity) .. identity .. own_names())) then
                return nil, state.error
            end
            state.phase = "lobby"
        end
    end
    return state.phase == "ready"
end

-- The lobby as the network screen shows it.
function room.lobby(state)
    local players = {}
    for index, player in ipairs(state.members or {}) do
        players[index] = {name = player_name(player, i18n.tr("Player %d", index)), host = player.host}
    end
    return {code = state.code, host = state.host == true, players = players, most = state.most or most_players,
        joined = state.phase == "lobby" or state.phase == "ready",
        can_start = state.host == true and state.phase == "lobby" and #players >= 2 and not state.start_sent}
end
-- The host's Start: the relay starts the game for everyone with this computer's random table.
function room.begin(state)
    if not room.lobby(state).can_start then return false end
    state.start_sent = true
    return send(state, message(kinds.start, engine.random_state()))
end

-- The hidden characters were unlocked on this computer before the room (its option or LF2.NET): its
-- first input says so, and the frame carrying it unlocks them for everyone (see combine).
function room.share_unlocked(state) state.events = bit_or(state.events, 4) end

-- This computer's input: the function keys held, then its slots' keys (without the events byte).
local function local_input(state, input)
    local low, high = 0, 0
    for key = 1, 8 do
        if input.functions:find(tostring(key), 1, true) then low = low + powers[key] end
    end
    if input.functions:find("9", 1, true) then high = 1 end
    local bytes = {string.char(low, high)}
    for slot = 0, state.order[state.own].count - 1 do
        bytes[#bytes + 1] = string.char(recording.pack_keys(input[slot] or ""))
    end
    return table.concat(bytes)
end
-- Sends the input when it changed, has events, or (while frames run) when the heartbeat is due:
-- the relay keeps using the newest input, and lets keys go after a moment without news.
local function send_input(state, input, now, running)
    local keys = local_input(state, input)
    state.events = bit_or(state.events, input.unlock_bits or 0)
    if keys == state.sent and state.events == 0 and not (running and now - state.sent_at >= heartbeat) then
        return true
    end
    if not send(state, message(kinds.input, string.char(state.events) .. keys)) then return nil, state.error end
    state.sent, state.sent_at, state.events = keys, now, 0
    return true
end

-- The input of every player for one frame, as a match reads it.
local function combine(state, frame)
    local combined = {functions = "", keys = {}, pointer_x = 0, pointer_y = 0, button = false, network = true,
        function_sources = {}, unlock_bits = 0}
    for slot = 0, slot_count - 1 do combined[slot] = "" end
    local held, shared = {}, false
    for index, player in ipairs(state.order) do
        local input = frame.inputs[index]
        local events, low, high = input:byte(1) or 0, input:byte(2) or 0, input:byte(3) or 0
        local source = {}
        for key = 1, 9 do
            if (key <= 8 and has(low, key)) or (key == 9 and has(high, 1)) then
                source[#source + 1] = tostring(key)
                held[key] = true
            end
        end
        combined.function_sources[index] = table.concat(source)
        for slot = 0, player.count - 1 do
            combined[player.offset + slot] = recording.unpack_keys(input:byte(4 + slot) or 0)
        end
        combined.unlock_bits = bit_or(combined.unlock_bits, events % 4)
        shared = shared or has(events, 3)
    end
    -- Hidden characters some computer came with: off until now on every computer alike, they turn on
    -- here as if LF2.NET was typed (so that a recording of the match replays the same).
    if shared and unlock.flags.characters == 0 and not has(combined.unlock_bits, 1) then
        combined.unlock_bits = combined.unlock_bits + 1
    end
    for key = 1, 9 do
        if held[key] then combined.functions = combined.functions .. key end
    end
    return combined
end

-- Once per attempted tick of a running game: the next frame's input when it is time to run it,
-- nil while waiting, nil and a message on failure. `hp` is the state the frame starts from, for
-- the desync check.
function room.exchange(state, input, hp)
    if state.phase == "failed" then return nil, state.error end
    local ok, problem = read_messages(state)
    if not ok then return nil, problem end
    local now = engine.network_time()
    ok, problem = send_input(state, input, now, false)
    if not ok then return nil, problem end
    local frame = state.queue[state.queue_first]
    if not frame then
        if now > state.deadline then return failed(state, "Network input timed out") end
        return nil
    end
    if state.target then
        local due = state.tick * frame.number + state.target
        local age = input.display_age
        if age then
            -- In a browser the frame starts just after the first display refresh at (or a little before) its
            -- time, so that frames reach the screen a steady number of refreshes apart (two at 60 Hz) instead
            -- of wherever the timer was; a frame far behind runs at once.
            if now - age < due - display_slack and now < due + display_catch_up then return nil end
        elseif now < due then return nil end
    end
    state.queue[state.queue_first] = nil
    state.queue_first = state.queue_first + 1
    -- Desync check: this computer's state at the start of the frame, against the others'. Its own
    -- goes out first, so that the others notice too when this computer is the one to stop.
    local hash = math.floor(hp) % 65536
    state.history[frame.number % history_size] = {number = frame.number, hash = hash}
    if frame.number % check_interval == 0 and not send(state, message(kinds.check, u32(frame.number) .. u16(hash))) then
        return nil, state.error
    end
    for _, other in ipairs(state.checks[frame.number] or {}) do
        if other ~= hash then return failed(state, "Network HP synchronization mismatch") end
    end
    state.checks[frame.number] = nil
    state.next_run, state.frames, state.deadline = frame.number + 1, state.frames + 1, now + frame_timeout
    update_target(state)
    ok, problem = send_input(state, input, now, true)
    if not ok then return nil, problem end
    return combine(state, frame)
end

-- Frames received and not run yet.
function room.backlog(state) return state.queue_last - state.queue_first + 1 end
return room
