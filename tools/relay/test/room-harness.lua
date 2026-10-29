-- SPDX-License-Identifier: MIT
--
-- Runs scripts/base/game/room.lua for room-game.test.js, one game per process. The test answers
-- the engine's network calls with dist/web/online.js, as src/adapters/web/transport.cpp does in
-- the browser, so the game's real protocol code meets the real relay.
--
-- stdout: "E <operation> <hex value>" asks the test for an engine call, answered on stdin by
-- "ok <hex>" or "err <hex>"; "R <words>" answers a command. Commands (stdin), one per line:
--   start host|join [address]   poll   lobby   begin   names   slots   backlog   tick
--   share (room.share_unlocked)   characters 0|1 (the unlock flag, as the game sets it)
--   exchange <keys of players 1-4, comma separated, "-" for none> <function keys or -> <unlock bits> <hp> [display age]
local root = assert(arg[1], "usage: lua room-harness.lua <repository root>")
package.path = root .. "/scripts/?.lua;" .. package.path

local function hex(bytes) return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(text) return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)) end
local function call(operation, value)
    io.write("E ", operation, " ", hex(value or ""), "\n")
    io.flush()
    local kind, payload = io.read("*l"):match("^(%S+) ?(%x*)$")
    if kind == "ok" then return unhex(payload) end
    return nil, unhex(payload)
end

local applied_random
engine = {}
function engine.network(operation, value) return call(operation, value) end
function engine.network_time() return tonumber((call("time"))) end
-- A random table without NUL bytes, different per process so that the host's is recognisable.
local random_table = {}
local seed = tonumber(os.getenv("ROOM_SEED") or "1")
for index = 1, 3000 do random_table[index] = string.char((index * 7 + seed) % 255 + 1) end
random_table = table.concat(random_table)
function engine.random_state() return random_table end
function engine.set_random_state(bytes) applied_random = bytes end
function engine.reset_random_sequence() end

local names = {}
package.preload["base/ui/controls"] = function()
    return {current = function() return {names = names} end}
end
package.preload["base/i18n/i18n"] = function()
    return {tr = function(text, ...)
        if select("#", ...) > 0 then return string.format(text, ...) end
        return text
    end}
end
package.preload["base/game/recording"] = function()
    -- recording.lua's key packing, and a fixed game data checksum.
    local key_bits = {{"u", 0x80}, {"d", 0x40}, {"l", 0x20}, {"r", 0x10}, {"c", 8}, {"b", 4}, {"f", 2}}
    local recording = {}
    function recording.pack_keys(letters)
        local value = 0
        for _, bit in ipairs(key_bits) do
            if letters:find(bit[1], 1, true) then value = value + bit[2] end
        end
        return value
    end
    function recording.unpack_keys(value)
        local letters = {}
        for _, bit in ipairs(key_bits) do
            if math.floor(value / bit[2]) % 2 == 1 then letters[#letters + 1] = bit[1] end
        end
        return table.concat(letters)
    end
    function recording.data_checksum() return tonumber(os.getenv("ROOM_DATA_CHECKSUM") or "123456789") end
    return recording
end
local room = require("base/game/room")
local recording = require("base/game/recording")

local state = room.create({network_profile = string.rep("ab", 32), recording_version = 1})
local function answer(...) io.write("R ", table.concat({...}, " "), "\n"); io.flush() end
local function words(text) local list = {} for word in text:gmatch("%S+") do list[#list + 1] = word end return list end

for line in io.lines() do
    local command = words(line)
    local name = command[1]
    if name == "names" then
        for index = 1, 4 do names[index] = command[index + 1] or "" end
        answer("ok")
    elseif name == "start" then
        local ok, problem = room.start(state, command[2] == "host", command[3] or "")
        answer(ok and "ok" or "err " .. hex(problem or "?"))
    elseif name == "poll" then
        local ready, problem = room.poll(state)
        if ready then answer("ready", hex(applied_random == random_table and "own" or "other"))
        elseif problem then answer("err", hex(problem))
        else answer("wait") end
    elseif name == "lobby" then
        local lobby = room.lobby(state)
        local list = {}
        for index, player in ipairs(lobby.players) do list[index] = hex(player.name) .. (player.host and ":h" or "") end
        answer(lobby.joined and "1" or "0", lobby.host and "1" or "0", lobby.can_start and "1" or "0",
            lobby.code or "-", #list > 0 and table.concat(list, ",") or "-")
    elseif name == "begin" then
        answer(room.begin(state) and "ok" or "no")
    elseif name == "share" then
        room.share_unlocked(state)
        answer("ok")
    elseif name == "characters" then
        require("base/game/unlock").flags.characters = tonumber(command[2])
        answer("ok")
    elseif name == "slots" then
        local list = {}
        for index = 1, 8 do list[index] = hex(state.names[index] or "") end
        local own = state.order[state.own]
        answer(own.offset, own.count, table.concat(list, ","))
    elseif name == "backlog" then
        answer(room.backlog(state))
    elseif name == "tick" then
        answer(string.format("%.4f", state.tick))
    elseif name == "exchange" then
        local input = {functions = command[3] ~= "-" and command[3] or "", unlock_bits = tonumber(command[4]),
            display_age = tonumber(command[6])}
        local index = 0
        for keys in (command[2] .. ","):gmatch("([^,]*),") do
            input[index] = keys ~= "-" and keys or ""
            index = index + 1
        end
        local combined, problem = room.exchange(state, input, tonumber(command[5]))
        if problem then answer("err", hex(problem))
        elseif not combined then answer("wait")
        else
            local slots, sources = {}, {}
            for slot = 0, 7 do slots[slot + 1] = combined[slot] ~= "" and combined[slot] or "-" end
            for side, source in ipairs(combined.function_sources) do sources[side] = source ~= "" and source or "-" end
            answer("frame", state.next_run - 1, table.concat(slots, ","), combined.functions ~= "" and combined.functions or "-",
                table.concat(sources, ","), combined.unlock_bits, hex(recording.status and recording.status.text or ""))
            recording.status = nil
        end
    elseif name == "quit" then
        room.close(state)
        answer("bye")
        break
    else
        answer("err", hex("unknown command " .. tostring(name)))
    end
end
