// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/scripts.hpp"
#include "openlf2/core/json.hpp"
#include "openlf2/core/files.hpp"
#include "openlf2_build_info.hpp"
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <limits>
#include <optional>
#include <stdexcept>
#include <utility>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#ifndef __EMSCRIPTEN__
#include <luajit.h>
#endif
}

namespace openlf2 {
namespace {
struct CloseState { void operator()(lua_State* state) const noexcept { lua_close(state); } };
using State = std::unique_ptr<lua_State, CloseState>;
int protected_call(lua_State* state, lua_CFunction function) {
#ifdef __EMSCRIPTEN__
    lua_pushcfunction(state, function);
    return lua_pcall(state, 0, 0, 0);
#else
    return lua_cpcall(state, function, nullptr);
#endif
}
// lua_cpcall's opaque argument becomes light userdata, which ARM64 LuaJIT can reject for host
// addresses; keep the borrowed C++ pointers in a Lua-owned slot instead.
constexpr int bridge_registry_key = 0x4f4c4632;
struct ResourceBridge;
struct Invocation;
struct FrameInvocation;
struct BridgeSlot {
    ResourceBridge* bridge = nullptr;
    Invocation* invocation = nullptr;
    FrameInvocation* frame = nullptr;
};
// The resource and data sources outlive the Lua runtime. Pending data lives here so a Lua
// allocation failure cannot skip a C++ destructor in the native callback's frame.
struct ResourceBridge {
    ResourceBridge(const ResourceSource& source, const ScriptDataSource& data_source, ScriptRandom& generator,
                   SettingsStore& settings_store, ScriptRecordings& recording_service, NetworkTransport& transport)
        : resources(source), data(data_source), random(generator), settings(settings_store),
          recordings(recording_service), network(transport) {}
    const ResourceSource& resources;
    const ScriptDataSource& data;
    ScriptRandom& random;
    SettingsStore& settings;
    ScriptRecordings& recordings;
    NetworkTransport& network;
    std::optional<Result<std::string>> pending_network;
    bool network_operation(std::string_view operation, std::string_view value, std::uint16_t port) noexcept {
        try {
            pending_network = std::string{};
            if (operation == "host" || operation == "join") {
                auto started = operation == "host" ? network.listen(value, port) : network.connect(value, port);
                if (!started) pending_network = std::unexpected(started.error());
            } else if (operation == "send") {
                auto sent = network.send(std::span<const char>(value.data(), value.size()));
                if (!sent) pending_network = std::unexpected(sent.error());
            } else if (operation == "poll") {
                auto received = network.poll();
                if (received) pending_network = std::string(received->begin(), received->end());
                else pending_network = std::unexpected(received.error());
            } else if (operation == "status") {
                switch (network.status()) {
                case NetworkStatus::idle: pending_network = "idle"; break;
                case NetworkStatus::listening: pending_network = "listening"; break;
                case NetworkStatus::connecting: pending_network = "connecting"; break;
                case NetworkStatus::connected: pending_network = "connected"; break;
                }
            } else if (operation == "close") network.close();
            else pending_network = fail(ErrorCode::script, "Unknown network operation");
            return true;
        } catch (...) { pending_network.reset(); return false; }
    }
    std::optional<Result<Bytes>> pending;
    std::string pending_text;

    bool save_recording(std::string_view name, std::string_view block) noexcept {
        try {
            pending_save = recordings.save(name, std::span<const char>(block.data(), block.size()));
            return true;
        } catch (...) {
            pending_save.reset();
            return false;
        }
    }
    bool take_recording() noexcept {
        try {
            auto taken = recordings.take();
            if (taken) pending = std::move(*taken);
            else pending.reset();
            return true;
        } catch (...) {
            pending.reset();
            return false;
        }
    }
    bool local_time() noexcept {
        try {
            pending_text = recordings.local_time();
            return true;
        } catch (...) {
            return false;
        }
    }
    std::optional<Result<ScriptValue>> pending_value;
    std::optional<Result<void>> pending_save;

    // The stored configuration parsed from JSON; an empty value when none was saved.
    bool load_settings() noexcept {
        try {
            auto text = settings.load();
            if (!text) pending_value = std::unexpected(text.error());
            else if (!text->has_value()) pending_value = ScriptValue{};
            else pending_value = parse_json(**text);
            return true;
        } catch (...) {
            pending_value.reset();
            return false;
        }
    }
    // Writes pending_value (converted from a script table) as JSON.
    bool save_settings() noexcept {
        try {
            if (!pending_value || !pending_value->has_value()) {
                pending_save = std::unexpected(pending_value ? pending_value->error() : Error{ErrorCode::script, "no value"});
                return true;
            }
            auto text = write_json(pending_value->value());
            if (!text) pending_save = std::unexpected(text.error());
            else pending_save = settings.save(*text);
            return true;
        } catch (...) {
            pending_save.reset();
            return false;
        }
    }

    bool read(std::string_view path) noexcept {
        try {
            pending = resources.read(path);
            if (*pending && pending->value().size() > 4 * 1024 * 1024) {
                pending = fail(ErrorCode::limit, "script resource exceeds 4 MiB");
            }
            return true;
        } catch (...) {
            pending.reset();
            return false;
        }
    }
    bool read_data(ScriptData kind, std::string_view path) noexcept {
        try {
            pending_value = data.read(kind, path);
            return true;
        } catch (...) {
            pending_value.reset();
            return false;
        }
    }
};
ResourceBridge* resource_bridge(lua_State* state) {
    return static_cast<BridgeSlot*>(lua_touserdata(state, lua_upvalueindex(1)))->bridge;
}
int create_bridge_slot(lua_State* state) {
    std::construct_at(static_cast<BridgeSlot*>(lua_newuserdata(state, sizeof(BridgeSlot))));
    lua_rawseti(state, LUA_REGISTRYINDEX, bridge_registry_key);
    return 0;
}
// Private protocol, matching the fixed-size opcodes in runtime/bootstrap.lua.
enum class FrameOpcode {
    viewport = 1, sprite, fill, overlay, render_area, clip, sound, rumble,
    music, speed, render_filter, text_input, replay_drop, fullscreen, action, text, file_dialog, world_sprite
};
class FrameReader {
public:
    FrameReader(lua_State* state, int table, int count) : state_(state), table_(table), count_(count) {}
    bool remaining() const { return next_ <= count_; }
    double number(double low, double high, bool integral = true) {
        take();
        const bool numeric = lua_type(state_, -1) == LUA_TNUMBER;
        const double value = numeric ? lua_tonumber(state_, -1) : 0;
        lua_pop(state_, 1);
        if (!numeric || !std::isfinite(value) || value < low || value > high
            || (integral && value != std::floor(value))) throw std::runtime_error("invalid numeric frame field");
        return value;
    }
    int integer(int low = -8192, int high = 8192) { return static_cast<int>(number(low, high)); }
    // A drawing position or size. Objects of a mod can fly far off the stage (thousands of pixels) and a script
    // can compute a fraction: a fraction is rounded, and a number outside -8192..8192 (never on screen) leaves
    // the command out (see `dropped`) instead of stopping the game. A value that is no number stays an error.
    int coordinate(const char* field) {
        take();
        const bool numeric = lua_type(state_, -1) == LUA_TNUMBER;
        const double value = numeric ? lua_tonumber(state_, -1) : 0;
        lua_pop(state_, 1);
        if (!numeric) throw std::runtime_error(std::string("invalid numeric frame field: ") + field);
        if (!std::isfinite(value) || value < -8192 || value > 8192) {
            if (!dropped_) dropped_field_ = field, dropped_value_ = value;
            dropped_ = true;
            return 0;
        }
        return static_cast<int>(std::floor(value + 0.5));
    }
    Rectangle area(const char* field) {
        return Rectangle{coordinate(field), coordinate(field), coordinate(field), coordinate(field)};
    }
    // True once per command whose positions could not be drawn (and forgets it); reports each kind once.
    bool dropped(const char* command) {
        if (!dropped_) return false;
        dropped_ = false;
        static std::mutex mutex;
        static std::set<std::string> reported;
        const std::lock_guard lock(mutex);
        if (reported.size() < 64 && reported.insert(std::string(command) + "." + dropped_field_).second) {
            std::cerr << "Frame: a " << command << " with " << dropped_field_ << " " << dropped_value_
                      << " (outside -8192..8192) is left out\n";
        }
        return true;
    }
    bool flag() {
        take();
        const bool valid = lua_type(state_, -1) == LUA_TBOOLEAN;
        const bool value = lua_toboolean(state_, -1) != 0;
        lua_pop(state_, 1);
        if (!valid) throw std::runtime_error("frame flag must be boolean");
        return value;
    }
    std::string_view text() {
        take();
        if (lua_type(state_, -1) != LUA_TSTRING) {
            lua_pop(state_, 1);
            throw std::runtime_error("frame text must be a string");
        }
        std::size_t size = 0;
        const auto* value = lua_tolstring(state_, -1, &size);
        lua_pop(state_, 1);
        text_bytes_ += size;
        if (size > 1024 || text_bytes_ > 512 * 1024) throw std::runtime_error("frame text limit exceeded");
        return {value, size}; // The input table roots the string throughout decoding.
    }
    std::string resource() {
        auto path = virtual_path(text());
        if (!path) throw std::runtime_error(path.error().message);
        return std::move(*path);
    }
    Rectangle rectangle(bool positive = false) {
        Rectangle value{integer(), integer(), integer(), integer()};
        if (positive && (value.width < 1 || value.height < 1)) throw std::runtime_error("invalid frame rectangle");
        return value;
    }
private:
    void take() {
        if (!remaining()) throw std::runtime_error("truncated frame batch");
        lua_rawgeti(state_, table_, next_++);
    }
    lua_State* state_;
    int table_, count_, next_ = 1;
    std::size_t text_bytes_ = 0;
    bool dropped_ = false;
    const char* dropped_field_ = "";
    double dropped_value_ = 0;
};
Result<ScriptFrame> decode_frame(lua_State* state, int table, int count) {
    try {
        ScriptFrame frame;
        frame.commands.reserve(static_cast<std::size_t>(count) / 14);
        FrameReader reader(state, table, count);
        bool overlay = false;
        std::optional<Rectangle> clip;
        const auto set_flag = [&](std::optional<bool>& target) {
            if (target) throw std::runtime_error("duplicate frame flag");
            target = reader.flag();
        };
        int commands = 0;
        while (reader.remaining()) {
            if (++commands > 4096) throw std::runtime_error("too many frame commands");
            const auto opcode = static_cast<FrameOpcode>(reader.integer(1, 18));
            switch (opcode) {
            case FrameOpcode::viewport:
                if (frame.viewport.width) throw std::runtime_error("duplicate viewport");
                frame.viewport.width = reader.integer(1, 8192); frame.viewport.height = reader.integer(1, 8192);
                frame.viewport.red = reader.integer(0, 255); frame.viewport.green = reader.integer(0, 255);
                frame.viewport.blue = reader.integer(0, 255);
                break;
            case FrameOpcode::sprite:
            case FrameOpcode::world_sprite: {
                SpriteCommand sprite{};
                sprite.resource = reader.resource(); sprite.source = reader.area("source");
                sprite.x = reader.coordinate("x"); sprite.y = reader.coordinate("y");
                sprite.color_key = reader.flag(); sprite.mirrored = reader.flag(); sprite.flipped = reader.flag();
                sprite.tint = reader.integer(0, 0xffffff);
                sprite.scale_x = static_cast<float>(reader.number(0, 32, false));
                if (sprite.scale_x <= 0) throw std::runtime_error("invalid sprite scale");
                sprite.translate_x = reader.coordinate("translate_x"); sprite.overlay = overlay; sprite.clip = clip;
                if (opcode == FrameOpcode::world_sprite) {
                    SpriteLighting lighting;
                    lighting.ground_y = reader.coordinate("ground_y");
                    lighting.azimuth = static_cast<float>(reader.number(-180, 180, false));
                    lighting.elevation = static_cast<float>(reader.number(12, 89, false));
                    lighting.character = reader.flag(); lighting.casts_shadow = reader.flag();
                    lighting.shadow_blur = reader.integer(0, 8);
                    lighting.shadow_opacity = static_cast<float>(reader.number(0, 1, false));
                    sprite.lighting = lighting;
                }
                if (reader.dropped("sprite")) break;
                frame.commands.emplace_back(std::move(sprite));
                break;
            }
            case FrameOpcode::fill: {
                FillCommand fill{};
                fill.area = reader.area("area"); fill.red = reader.integer(0, 255); fill.green = reader.integer(0, 255);
                fill.blue = reader.integer(0, 255); fill.alpha = reader.integer(0, 255);
                fill.overlay = overlay; fill.clip = clip;
                if (!reader.dropped("fill")) frame.commands.emplace_back(fill);
                break;
            }
            case FrameOpcode::overlay: overlay = reader.flag(); break;
            case FrameOpcode::render_area:
                if (frame.viewport.render_area) throw std::runtime_error("duplicate render area");
                frame.viewport.render_area = reader.rectangle(true);
                break;
            case FrameOpcode::clip: {
                const bool enabled = reader.flag();
                const auto area = reader.rectangle(enabled);
                clip = enabled ? std::optional<Rectangle>(area) : std::nullopt;
                break;
            }
            case FrameOpcode::sound: {
                SoundCommand sound;
                sound.resource = reader.resource(); sound.volume = reader.integer(-10000, 0); sound.pan = reader.integer(-10000, 10000);
                frame.sounds.push_back(std::move(sound));
                break;
            }
            case FrameOpcode::rumble: {
                RumbleCommand rumble;
                rumble.target = static_cast<RumbleCommand::Target>(reader.integer(0, 1));
                rumble.pad_index = reader.integer(0, std::numeric_limits<int>::max()); rumble.strength = reader.integer(0, 100);
                frame.rumbles.push_back(rumble);
                break;
            }
            case FrameOpcode::music: {
                MusicCommand music;
                music.kind = static_cast<MusicCommand::Kind>(reader.integer(0, 3));
                if (music.kind == MusicCommand::Kind::play) music.resource = reader.resource();
                else if (music.kind == MusicCommand::Kind::volume) music.volume = reader.integer(-10000, 0);
                else if (reader.flag()) throw std::runtime_error("unexpected music payload");
                frame.music.push_back(std::move(music));
                break;
            }
            case FrameOpcode::speed: set_flag(frame.fast); break;
            case FrameOpcode::render_filter:
                if (frame.render_filter) throw std::runtime_error("duplicate render filter");
                frame.render_filter = static_cast<RenderFilter>(reader.integer(0, 3));
                break;
            case FrameOpcode::text_input: set_flag(frame.text_input); break;
            case FrameOpcode::replay_drop: set_flag(frame.replay_drop); break;
            case FrameOpcode::fullscreen: set_flag(frame.fullscreen); break;
            case FrameOpcode::text: {
                TextCommand text{};
                text.text = std::string(reader.text());
                text.x = reader.coordinate("x"); text.y = reader.coordinate("y");
                text.align = static_cast<TextAlign>(reader.integer(0, 2));
                text.size = reader.integer(6, 64); text.color = reader.integer(0, 0xffffff);
                // -1: none.
                if (const int outline = reader.integer(-1, 0xffffff); outline >= 0) text.outline = outline;
                if (const int background = reader.integer(-1, 0xffffff); background >= 0) text.background = background;
                text.antialias = reader.flag(); text.overlay = overlay; text.clip = clip;
                if (!reader.dropped("text")) frame.commands.emplace_back(std::move(text));
                break;
            }
            case FrameOpcode::file_dialog:
                frame.file_dialog = FileDialogText{std::string(reader.text()), std::string(reader.text()),
                                                   std::string(reader.text())};
                break;
            case FrameOpcode::action: {
                const auto name = reader.text();
                if (name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyz_") != std::string_view::npos)
                    throw std::runtime_error("invalid frame action");
                frame.actions.emplace_back(name);
                break;
            }
            }
        }
        if (!frame.viewport.width) throw std::runtime_error("screen must declare a viewport");
        return frame;
    } catch (const std::exception& error) { return fail(ErrorCode::script, error.what()); }
}

// Binary transport only; the base Lua session owns packet schemas, handshake and lockstep.
int network_operation(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TSTRING) return luaL_error(state, "network operation must be a string");
    std::size_t operation_size = 0, size = 0;
    const auto* operation = lua_tolstring(state, 1, &operation_size);
    if (lua_gettop(state) >= 2 && lua_type(state, 2) != LUA_TSTRING) return luaL_error(state, "network value must be a string");
    const auto* value = lua_gettop(state) >= 2 ? lua_tolstring(state, 2, &size) : "";
    if (operation_size > 16 || size > 65536) return luaL_error(state, "network argument exceeds limit");
    const auto port = lua_gettop(state) >= 3 ? lua_tonumber(state, 3) : 12345;
    if (!std::isfinite(port) || port < 1 || port > 65535 || port != std::floor(port)) return luaL_error(state, "network port must be 1..65535");
    if (!bridge->network_operation(std::string_view(operation, operation_size), std::string_view(value, size),
                                   static_cast<std::uint16_t>(port))) return luaL_error(state, "network allocation failed");
    if (!bridge->pending_network->has_value()) {
        lua_pushnil(state);
        lua_pushlstring(state, bridge->pending_network->error().message.data(), bridge->pending_network->error().message.size());
        return 2;
    }
    lua_pushlstring(state, bridge->pending_network->value().data(), bridge->pending_network->value().size());
    return 1;
}
int network_time(lua_State* state) {
    lua_pushnumber(state, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count());
    return 1;
}
int read_resource(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TSTRING) return luaL_error(state, "resource path must be a string");
    std::size_t size = 0;
    const auto* path = lua_tolstring(state, 1, &size);
    if (size == 0 || size > 512) return luaL_error(state, "invalid resource path length");
    if (!bridge->read(std::string_view(path, size))) return luaL_error(state, "resource allocation failed");
    if (!bridge->pending->has_value()) {
        lua_pushlstring(state, bridge->pending->error().message.data(), bridge->pending->error().message.size());
        bridge->pending.reset();
        return lua_error(state);
    }
    lua_pushlstring(state, bridge->pending->value().data(), bridge->pending->value().size());
    bridge->pending.reset();
    return 1;
}
constexpr int max_value_depth = 32;
// Only trivially destructible locals: Lua may raise an allocation error at any push.
void push_value(lua_State* state, const ScriptValue& value, int depth) {
    if (depth > max_value_depth) luaL_error(state, "script data nested too deeply");
    luaL_checkstack(state, 3, "script data nested too deeply");
    const auto& content = value.value;
    if (const auto* flag = std::get_if<bool>(&content)) {
        lua_pushboolean(state, *flag ? 1 : 0);
    } else if (const auto* integer = std::get_if<std::int32_t>(&content)) {
        lua_pushnumber(state, static_cast<lua_Number>(*integer));
    } else if (const auto* number = std::get_if<double>(&content)) {
        lua_pushnumber(state, *number);
    } else if (const auto* text = std::get_if<std::string>(&content)) {
        lua_pushlstring(state, text->data(), text->size());
    } else if (const auto* table = std::get_if<ScriptTable>(&content)) {
        lua_createtable(state, 0, static_cast<int>(std::min<std::size_t>(table->size(), 1 << 16)));
        for (const auto& field : *table) {
            if (const auto* index = std::get_if<std::int32_t>(&field.key)) {
                lua_pushnumber(state, static_cast<lua_Number>(*index));
            } else {
                const auto& name = *std::get_if<std::string>(&field.key);
                lua_pushlstring(state, name.data(), name.size());
            }
            push_value(state, field.value, depth + 1);
            lua_rawset(state, -3);
        }
    } else {
        lua_pushnil(state);
    }
}
// Converts the table at `index` without raising Lua errors, so the C++ values it builds are
// always destroyed normally. String keys are sorted so the saved JSON is deterministic.
Result<ScriptValue> table_value(lua_State* state, int index, int depth) noexcept {
    try {
        if (depth > max_value_depth) return fail(ErrorCode::script, "settings nested too deeply");
        if (!lua_checkstack(state, 4)) return fail(ErrorCode::script, "settings nested too deeply");
        const auto type = lua_type(state, index);
        if (type == LUA_TBOOLEAN) return ScriptValue{lua_toboolean(state, index) != 0};
        if (type == LUA_TSTRING) {
            std::size_t size = 0;
            const auto* text = lua_tolstring(state, index, &size);
            return ScriptValue{std::string(text, size)};
        }
        if (type == LUA_TNUMBER) {
            const auto number = lua_tonumber(state, index);
            if (!std::isfinite(number)) return fail(ErrorCode::script, "settings numbers must be finite");
            if (number == std::floor(number) && number >= -2147483648.0 && number <= 2147483647.0) {
                return ScriptValue{static_cast<std::int32_t>(number)};
            }
            return ScriptValue{number};
        }
        if (type != LUA_TTABLE) return fail(ErrorCode::script, "settings hold only tables, strings, numbers and booleans");
        const int table = index < 0 ? lua_gettop(state) + index + 1 : index;
        std::vector<std::pair<ScriptKey, ScriptValue>> fields;
        lua_pushnil(state);
        while (lua_next(state, table) != 0) {
            ScriptKey key;
            if (lua_type(state, -2) == LUA_TSTRING) {
                std::size_t size = 0;
                const auto* text = lua_tolstring(state, -2, &size);
                key = std::string(text, size);
            } else if (lua_type(state, -2) == LUA_TNUMBER) {
                const auto number = lua_tonumber(state, -2);
                if (number != std::floor(number) || number < 1.0 || number > 2147483647.0) {
                    lua_pop(state, 2);
                    return fail(ErrorCode::script, "settings table keys must be strings or positive integers");
                }
                key = static_cast<std::int32_t>(number);
            } else {
                lua_pop(state, 2);
                return fail(ErrorCode::script, "settings table keys must be strings or positive integers");
            }
            auto value = table_value(state, -1, depth + 1);
            if (!value) {
                lua_pop(state, 2);
                return value;
            }
            fields.emplace_back(std::move(key), std::move(*value));
            lua_pop(state, 1);
        }
        std::ranges::sort(fields, [](const auto& left, const auto& right) { return left.first < right.first; });
        ScriptTable result;
        for (auto& [key, value] : fields) set_field(result, std::move(key), std::move(value));
        return ScriptValue{std::move(result)};
    } catch (...) {
        return fail(ErrorCode::script, "settings conversion failed");
    }
}
// engine.random_state(): the table (3000 bytes) and its index, as a recording stores them.
int random_state(lua_State* state) {
    auto* bridge = resource_bridge(state);
    const auto current = bridge->random.state();
    lua_pushlstring(state, reinterpret_cast<const char*>(current.table.data()), current.table.size());
    lua_pushnumber(state, static_cast<lua_Number>(current.index));
    return 2;
}
// engine.set_random_state(table, index)
int set_random_state(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TSTRING || lua_type(state, 2) != LUA_TNUMBER) {
        return luaL_error(state, "random state needs a table string and an index");
    }
    std::size_t size = 0;
    const auto* table = lua_tolstring(state, 1, &size);
    const auto index = lua_tonumber(state, 2);
    RandomState restored;
    if (size != restored.table.size() || index < 0 || index >= 3000 || index != std::floor(index)) {
        return luaL_error(state, "invalid random state");
    }
    std::memcpy(restored.table.data(), table, size);
    restored.index = static_cast<std::int32_t>(index);
    bridge->random.restore(restored);
    return 0;
}
int reset_random_sequence(lua_State* state) {
    auto* bridge = resource_bridge(state);
    bridge->random.reset_sequence();
    return 0;
}
// engine.save_recording(name, block): true, or nil and a message.
int save_recording(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TSTRING || lua_type(state, 2) != LUA_TSTRING) {
        return luaL_error(state, "save_recording needs a name and a block");
    }
    std::size_t name_size = 0;
    std::size_t block_size = 0;
    const auto* name = lua_tolstring(state, 1, &name_size);
    const auto* block = lua_tolstring(state, 2, &block_size);
    if (!bridge->save_recording(std::string_view(name, name_size), std::string_view(block, block_size))) {
        return luaL_error(state, "recording allocation failed");
    }
    if (!bridge->pending_save->has_value()) {
        const auto& message = bridge->pending_save->error().message;
        lua_pushnil(state);
        lua_pushlstring(state, message.data(), message.size());
        bridge->pending_save.reset();
        return 2;
    }
    bridge->pending_save.reset();
    lua_pushboolean(state, 1);
    return 1;
}
// engine.take_recording(): the block of a recording chosen for replay; nil when there is none, or
// nil and a message when it could not be loaded.
int take_recording(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (!bridge->take_recording()) return luaL_error(state, "recording allocation failed");
    if (!bridge->pending) return 0;
    if (!bridge->pending->has_value()) {
        const auto& message = bridge->pending->error().message;
        lua_pushnil(state);
        lua_pushlstring(state, message.data(), message.size());
        bridge->pending.reset();
        return 2;
    }
    lua_pushlstring(state, bridge->pending->value().data(), bridge->pending->value().size());
    bridge->pending.reset();
    return 1;
}
int local_time(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (!bridge->local_time()) return luaL_error(state, "time allocation failed");
    lua_pushlstring(state, bridge->pending_text.data(), bridge->pending_text.size());
    return 1;
}
// Returns the configuration table, or nil and a message when none is stored or it is unreadable.
int read_settings(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (!bridge->load_settings()) return luaL_error(state, "settings allocation failed");
    if (!bridge->pending_value->has_value()) {
        const auto& message = bridge->pending_value->error().message;
        lua_pushnil(state);
        lua_pushlstring(state, message.data(), message.size());
        bridge->pending_value.reset();
        return 2;
    }
    push_value(state, bridge->pending_value->value(), 0);
    bridge->pending_value.reset();
    return 1;
}
// Saves a table as the configuration; returns true, or nil and a message.
int write_settings(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TTABLE) return luaL_error(state, "settings must be a table");
    lua_settop(state, 1);
    bridge->pending_value = table_value(state, 1, 0);
    const bool saved = bridge->save_settings();
    bridge->pending_value.reset();
    if (!saved) return luaL_error(state, "settings allocation failed");
    if (!bridge->pending_save->has_value()) {
        const auto& message = bridge->pending_save->error().message;
        lua_pushnil(state);
        lua_pushlstring(state, message.data(), message.size());
        bridge->pending_save.reset();
        return 2;
    }
    bridge->pending_save.reset();
    lua_pushboolean(state, 1);
    return 1;
}
// Upvalues: the bridge and the ScriptData kind as a number.
int read_data(lua_State* state) {
    auto* bridge = resource_bridge(state);
    const auto code = lua_tointeger(state, lua_upvalueindex(2));
    const auto kind = code == 0 ? ScriptData::object : code == 1 ? ScriptData::background : ScriptData::stage;
    if (lua_type(state, 1) != LUA_TSTRING) return luaL_error(state, "data path must be a string");
    std::size_t size = 0;
    const auto* path = lua_tolstring(state, 1, &size);
    if (size == 0 || size > 512) return luaL_error(state, "invalid data path length");
    if (!bridge->read_data(kind, std::string_view(path, size))) {
        return luaL_error(state, "data allocation failed");
    }
    if (!bridge->pending_value->has_value()) {
        const auto& message = bridge->pending_value->error().message;
        lua_pushlstring(state, message.data(), message.size());
        bridge->pending_value.reset();
        return lua_error(state);
    }
    push_value(state, bridge->pending_value->value(), 0);
    bridge->pending_value.reset();
    return 1;
}
int random_number(lua_State* state) {
    auto* bridge = resource_bridge(state);
    if (lua_type(state, 1) != LUA_TNUMBER) return luaL_error(state, "random range must be a number");
    const auto range = lua_tonumber(state, 1);
    if (range != static_cast<lua_Number>(static_cast<std::int32_t>(range))) {
        return luaL_error(state, "random range must be a 32-bit integer");
    }
    lua_pushnumber(state, static_cast<lua_Number>(bridge->random.next(static_cast<std::int32_t>(range))));
    return 1;
}
int crt_random_number(lua_State* state) {
    auto* bridge = resource_bridge(state);
    lua_pushnumber(state, static_cast<lua_Number>(bridge->random.crt()));
    return 1;
}
int open_libraries(lua_State* state) {
    luaL_openlibs(state);
#ifndef __EMSCRIPTEN__
    lua_getglobal(state, "jit");
    lua_getfield(state, -1, "opt");
    if (lua_istable(state, -1)) {
        lua_getfield(state, -1, "start");
        lua_pushliteral(state, "maxmcode=16384");
        lua_pushliteral(state, "maxtrace=8192");
        lua_call(state, 2, 0);
    }
    lua_pop(state, 2);
#endif
    lua_pushliteral(state, OPENLF2_BUILD_LABEL);
    lua_setglobal(state, "openlf2_build_label");
    lua_rawgeti(state, LUA_REGISTRYINDEX, bridge_registry_key);
    lua_pushvalue(state, -1);
    lua_pushcclosure(state, read_resource, 1);
    lua_setglobal(state, "openlf2_read_resource");
    lua_pushvalue(state, -1);
    lua_pushinteger(state, 0);
    lua_pushcclosure(state, read_data, 2);
    lua_setglobal(state, "openlf2_read_object_data");
    lua_pushvalue(state, -1);
    lua_pushinteger(state, 1);
    lua_pushcclosure(state, read_data, 2);
    lua_setglobal(state, "openlf2_read_background_data");
    lua_pushvalue(state, -1);
    lua_pushinteger(state, 2);
    lua_pushcclosure(state, read_data, 2);
    lua_setglobal(state, "openlf2_read_stage_data");
    lua_pushvalue(state, -1);
    lua_pushcclosure(state, random_number, 1);
    lua_setglobal(state, "openlf2_random");
    lua_pushvalue(state, -1);
    lua_pushcclosure(state, crt_random_number, 1);
    lua_setglobal(state, "openlf2_crt_random");
    lua_pushvalue(state, -1);
    lua_pushcclosure(state, read_settings, 1);
    lua_setglobal(state, "openlf2_read_settings");
    lua_pushvalue(state, -1);
    lua_pushcclosure(state, write_settings, 1);
    lua_setglobal(state, "openlf2_write_settings");
    const std::pair<const char*, lua_CFunction> recording_functions[] = {
        {"openlf2_network", network_operation}, {"openlf2_network_time", network_time},
        {"openlf2_random_state", random_state}, {"openlf2_set_random_state", set_random_state},
        {"openlf2_reset_random_sequence", reset_random_sequence}, {"openlf2_save_recording", save_recording},
        {"openlf2_take_recording", take_recording}, {"openlf2_local_time", local_time}};
    for (const auto& [name, function] : recording_functions) {
        lua_pushvalue(state, -1);
        lua_pushcclosure(state, function, 1);
        lua_setglobal(state, name);
    }
    lua_pop(state, 1);
    return 0;
}
// This C trampoline has no C++ objects requiring destruction. All Lua allocations
// during compilation, global lookup and execution are below a protected Lua call.
struct Invocation {
    const char* source;
    std::size_t size;
    const char* name;
    const char* result = nullptr;
    std::size_t result_size = 0;
};
int invoke(lua_State* state) {
    lua_rawgeti(state, LUA_REGISTRYINDEX, bridge_registry_key);
    auto* invocation = static_cast<BridgeSlot*>(lua_touserdata(state, -1))->invocation;
    lua_pop(state, 1);
    const int loaded = luaL_loadbufferx(state, invocation->source, invocation->size, invocation->name, "t");
    if (loaded != 0) {
        return lua_error(state);
    }
    lua_call(state, 0, 1);
    if (lua_type(state, -1) != LUA_TSTRING) {
        lua_pushliteral(state, "script operation must return a string");
        return lua_error(state);
    }
    invocation->result = lua_tolstring(state, -1, &invocation->result_size);
    lua_setglobal(state, "openlf2_result");
    return 0;
}
struct FrameInvocation {
    std::string_view input;
    Result<ScriptFrame> result;
};
int invoke_frame(lua_State* state) {
    lua_rawgeti(state, LUA_REGISTRYINDEX, bridge_registry_key);
    auto* invocation = static_cast<BridgeSlot*>(lua_touserdata(state, -1))->frame;
    lua_pop(state, 1);
    lua_getglobal(state, "openlf2_frame");
    lua_pushlstring(state, invocation->input.data(), invocation->input.size());
    lua_call(state, 1, 2);
    if (lua_type(state, -2) == LUA_TBOOLEAN && !lua_toboolean(state, -2)) {
        invocation->result = ScriptFrame{};
        invocation->result->waiting = true;
        return 0;
    }
    luaL_checktype(state, -2, LUA_TTABLE);
    luaL_checktype(state, -1, LUA_TNUMBER);
    const double count = lua_tonumber(state, -1);
    if (!std::isfinite(count) || count < 0 || count > 4096 * 14 || count != std::floor(count))
        return luaL_error(state, "invalid frame batch size");
    luaL_checkstack(state, 4, "frame decoding stack limit");
    invocation->result = decode_frame(state, lua_gettop(state) - 1, static_cast<int>(count));
    return 0;
}
class LuaRuntime final : public ScriptRuntime {
public:
    LuaRuntime(State state, std::unique_ptr<ResourceBridge> bridge)
        : bridge_(std::move(bridge)), state_(std::move(state)) {}
    Result<void> load(std::string_view bundle) override {
        auto result = execute(bundle, "@runtime/bootstrap");
        if (!result) return std::unexpected(result.error());
        return {};
    }
    Result<ScriptFrame> frame(std::string_view input) override {
        // Input is host-generated, not Lua source: trace letters ('/' between players, "@x_y"
        // pointer, '!' button, "#n" raw key, "%x" controller button, "^x" typed character,
        // "&n_x_y" a held finger, "?x"/"?w" a renderer/window capability, "~n" a measured fps)
        // or "k", comma-separated virtual-key codes, " m" x,y,button and
        // optionally " p" with the key-down codes, " t" with typed character codes, " g" with
        // controller button letters, " h" with the touch state, " f" with the scaling modes
        // the renderer offers and " v" with the age of the display refresh (web). The bound covers
        // 256 held keys and 256 key-downs.
        const bool keys = input.starts_with('k');
        const auto allowed = keys ? std::string_view("0123456789,mptgfjhudlrabcexyswkv -:")
                                  : std::string_view("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/@_!#%^.?$&~");
        if (input.size() > 4096 || input.substr(keys ? 1 : 0).find_first_not_of(allowed) != std::string_view::npos) {
            return fail(ErrorCode::script, "invalid input action");
        }
        FrameInvocation invocation{input, ScriptFrame{}};
        lua_rawgeti(state_.get(), LUA_REGISTRYINDEX, bridge_registry_key);
        auto* slot = static_cast<BridgeSlot*>(lua_touserdata(state_.get(), -1));
        lua_pop(state_.get(), 1);
        slot->frame = &invocation;
        const auto status = protected_call(state_.get(), invoke_frame);
        slot->frame = nullptr;
        if (status != 0) return std::unexpected(script_error().error());
        lua_settop(state_.get(), 0);
        return std::move(invocation.result);
    }
    Result<std::string> describe() override {
        return execute("return openlf2_describe()", "@runtime/describe");
    }
private:
    Result<std::string> execute(std::string_view source, const char* name) {
        Invocation invocation{source.data(), source.size(), name};
        lua_rawgeti(state_.get(), LUA_REGISTRYINDEX, bridge_registry_key);
        auto* slot = static_cast<BridgeSlot*>(lua_touserdata(state_.get(), -1));
        slot->invocation = &invocation;
        lua_pop(state_.get(), 1);
        const auto status = protected_call(state_.get(), invoke);
        slot->invocation = nullptr;
        if (status != 0) return script_error();
        // The trusted global roots the borrowed result until the next invocation.
        if (invocation.result == nullptr || invocation.result_size > 512 * 1024) {
            lua_settop(state_.get(), 0);
            return fail(ErrorCode::limit, "invalid or oversized script frame");
        }
        std::string output(invocation.result, invocation.result_size);
        lua_settop(state_.get(), 0);
        return output;
    }
    Result<std::string> script_error() {
        const auto* message = lua_type(state_.get(), -1) == LUA_TSTRING ? lua_tostring(state_.get(), -1) : nullptr;
        auto error = fail(ErrorCode::script, message ? std::string(message) : "Lua runtime failure");
        lua_settop(state_.get(), 0);
        return error;
    }
    std::unique_ptr<ResourceBridge> bridge_;
    State state_;
};
}
Result<std::unique_ptr<ScriptRuntime>> make_script_runtime(bool enable_jit, const ResourceSource& resources,
                                                           const ScriptDataSource& data, ScriptRandom& random,
                                                           SettingsStore& settings, ScriptRecordings& recordings,
                                                           NetworkTransport& network) {
    auto bridge = std::make_unique<ResourceBridge>(resources, data, random, settings, recordings, network);
    State state(luaL_newstate());
    if (!state) return fail(ErrorCode::script, "cannot allocate Lua state");
#ifdef __EMSCRIPTEN__
    if (enable_jit) return fail(ErrorCode::script, "JIT is unavailable in the WebAssembly build");
#else
    // Apply the selected mode before opening LuaJIT's standard libraries, which
    // may execute Lua during initialization.
    if (luaJIT_setmode(state.get(), 0, LUAJIT_MODE_ENGINE |
            (enable_jit ? LUAJIT_MODE_ON : LUAJIT_MODE_OFF)) == 0) {
        return fail(ErrorCode::script, "cannot set LuaJIT engine mode");
    }
#endif
    if (protected_call(state.get(), create_bridge_slot) != 0) {
        return fail(ErrorCode::script, "cannot allocate LuaJIT bridge slot");
    }
    lua_rawgeti(state.get(), LUA_REGISTRYINDEX, bridge_registry_key);
    static_cast<BridgeSlot*>(lua_touserdata(state.get(), -1))->bridge = bridge.get();
    lua_pop(state.get(), 1);
    if (protected_call(state.get(), open_libraries) != 0) {
        const auto* detail = lua_type(state.get(), -1) == LUA_TSTRING
            ? lua_tostring(state.get(), -1) : nullptr;
        return fail(ErrorCode::script, std::string("cannot initialize LuaJIT libraries: ") +
            (detail == nullptr ? "unknown Lua error" : detail));
    }
    return std::unique_ptr<ScriptRuntime>(std::make_unique<LuaRuntime>(std::move(state), std::move(bridge)));
}
}
