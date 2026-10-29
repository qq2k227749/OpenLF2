// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/object_data.hpp"
#include "openlf2/resources/data_file.hpp"
#include "openlf2/detail/resources/scan_stream.hpp"
#include <algorithm>

namespace openlf2::object_data {
namespace {
using scanning::ParseFailure;
using scanning::TokenStream;
using scanning::wrapping_add;
using scanning::wrapping_subtract;
constexpr std::size_t token_capacity = 200;
constexpr std::size_t max_diagnostics = 256;
constexpr std::size_t max_input = 4 * 1024 * 1024;

class Parser {
public:
    explicit Parser(std::string_view text) : stream_(text) {}

    ObjectData run() {
        bool first = true;
        while (!stream_.at_end()) {
            // At EOF the previous token is evaluated again, as in the original loop.
            if (!stream_.word(token_, token_capacity) && first) {
                throw ParseFailure{ErrorCode::format, "object data contains no tokens"};
            }
            first = false;
            add_checksum();
            if (token_ == "<bmp_begin>") header();
            else if (token_ == "<weapon_strength_list>") strength_list();
            else if (token_ == "<frame>") frame();
            else if (token_ != "<bmp_end>" && token_ != "<frame_end>" &&
                     token_ != "<weapon_strength_list_end>") {
                note("ignored top-level token `" + token_ + "`");
            }
        }
        for (std::int32_t index = 0; index < frame_count; ++index) {
            const auto& frame = data_.frames[static_cast<std::size_t>(index)];
            if (frame.defined && !find_picture(data_, frame.picture)) {
                note("frame " + std::to_string(index) + " picture " +
                     std::to_string(frame.picture) + " is outside every sprite sheet");
            }
        }
        return std::move(data_);
    }

    [[nodiscard]] std::size_t line() const { return stream_.line(); }

private:
    void add_checksum() { scanning::add_token_checksum(data_.token_checksum, token_); }

    void note(std::string message) {
        if (data_.diagnostics.size() < max_diagnostics) {
            data_.diagnostics.push_back("line " + std::to_string(stream_.line()) + ": " +
                                        std::move(message));
        } else if (data_.diagnostics.size() == max_diagnostics) {
            data_.diagnostics.emplace_back("further diagnostics omitted");
        }
    }

    // Inner loops never test EOF in the original, which would loop forever.
    void next_token(std::string_view section) {
        if (!stream_.word(token_, token_capacity)) unterminated(section);
    }
    [[noreturn]] static void unterminated(std::string_view section) {
        throw ParseFailure{ErrorCode::format, "unterminated " + std::string(section) + " at end of file"};
    }
    std::string read_word(std::string_view section, std::size_t capacity) {
        std::string value;
        if (!stream_.word(value, capacity)) unterminated(section);
        return value;
    }

    bool read_int(std::int32_t& field) {
        const auto result = stream_.integer(field);
        if (result == TokenStream::Scan::mismatch) {
            note("`" + token_ + "` expects an integer; value left unchanged");
        }
        return result == TokenStream::Scan::value;
    }
    void read_int(std::optional<std::int32_t>& field) {
        std::int32_t value = field.value_or(0);
        if (read_int(value)) field = value;
    }
    void read_real(std::optional<double>& field) {
        double value = 0;
        const auto result = stream_.real(value);
        if (result == TokenStream::Scan::value) field = value;
        else if (result == TokenStream::Scan::mismatch) {
            note("`" + token_ + "` expects a number; value left unchanged");
        }
    }

    struct PendingSheet {
        std::optional<std::int32_t> width, height, columns, rows;
    };

    void finish_sheet() {
        auto& sheet = data_.sheets.back();
        // Bounds keep cell arithmetic within 32 bits; they exceed every original sheet.
        const auto require = [&](const std::optional<std::int32_t>& value, std::string_view key) {
            if (!value || *value < 1 || *value > 8192) {
                throw ParseFailure{ErrorCode::unsupported,
                                   "sprite sheet " + sheet.path + " needs " + std::string(key) + " in 1-8192"};
            }
            return *value;
        };
        sheet.cell_width = require(pending_.width, "w:");
        sheet.cell_height = require(pending_.height, "h:");
        sheet.columns = require(pending_.columns, "row:");
        sheet.rows = require(pending_.rows, "col:");
        if (std::int64_t{sheet.columns} * sheet.rows > max_sheet_cells) {
            throw ParseFailure{ErrorCode::unsupported,
                               "sprite sheet " + sheet.path + " exceeds 500 cells"};
        }
        std::int32_t first = 0;
        for (std::size_t index = 0; index + 1 < data_.sheets.size(); ++index) {
            first += data_.sheets[index].columns * data_.sheets[index].rows;
        }
        sheet.first_picture = first;
        pending_ = {};
    }

    void sheet_field(std::optional<std::int32_t> PendingSheet::*field) {
        if (data_.sheets.empty()) {
            note("`" + token_ + "` before the first sprite sheet is ignored");
            std::optional<std::int32_t> ignored;
            read_int(ignored);
            return;
        }
        read_int(pending_.*field);
    }

    void header() {
        constexpr std::string_view section = "<bmp_begin>";
        auto& movement = data_.movement;
        for (;;) {
            next_token(section);
            if (token_ == "<bmp_end>") {
                if (!data_.sheets.empty()) finish_sheet();
                return;
            }
            if (token_.starts_with("file")) {
                if (!data_.sheets.empty()) finish_sheet();
                if (data_.sheets.size() == max_sheets) {
                    throw ParseFailure{ErrorCode::unsupported, "more than ten sprite sheets"};
                }
                SpriteSheet sheet;
                sheet.declared_range = token_.substr(4);
                sheet.path = read_word(section, 40);
                data_.sheets.push_back(std::move(sheet));
            } else if (token_ == "head:") data_.head = read_word(section, 40);
            else if (token_ == "small:") data_.small = read_word(section, 36);
            else if (token_ == "name:") data_.name = read_word(section, 60);
            else if (token_ == "walking_frame_rate") read_int(movement.walking_frame_rate);
            else if (token_ == "walking_speed") read_real(movement.walking_speed);
            else if (token_ == "walking_speedz") read_real(movement.walking_speedz);
            else if (token_ == "running_frame_rate") read_int(movement.running_frame_rate);
            else if (token_ == "running_speed") read_real(movement.running_speed);
            else if (token_ == "running_speedz") read_real(movement.running_speedz);
            else if (token_ == "heavy_walking_speed") read_real(movement.heavy_walking_speed);
            else if (token_ == "heavy_walking_speedz") read_real(movement.heavy_walking_speedz);
            else if (token_ == "heavy_running_speed") read_real(movement.heavy_running_speed);
            else if (token_ == "heavy_running_speedz") read_real(movement.heavy_running_speedz);
            else if (token_ == "jump_height") read_real(movement.jump_height);
            else if (token_ == "jump_distance") read_real(movement.jump_distance);
            else if (token_ == "jump_distancez") read_real(movement.jump_distancez);
            else if (token_ == "dash_height") read_real(movement.dash_height);
            else if (token_ == "dash_distance") read_real(movement.dash_distance);
            else if (token_ == "dash_distancez") read_real(movement.dash_distancez);
            else if (token_ == "rowing_height") read_real(movement.rowing_height);
            else if (token_ == "rowing_distance") read_real(movement.rowing_distance);
            else if (token_ == "w:") sheet_field(&PendingSheet::width);
            else if (token_ == "h:") sheet_field(&PendingSheet::height);
            else if (token_ == "row:") sheet_field(&PendingSheet::columns);
            else if (token_ == "col:") sheet_field(&PendingSheet::rows);
            else if (token_ == "weapon_hp:") read_int(data_.weapon_hp);
            else if (token_ == "weapon_drop_hurt:") read_int(data_.weapon_drop_hurt);
            else if (token_ == "weapon_hit_sound:") data_.weapon_hit_sound = read_word(section, 300);
            else if (token_ == "weapon_drop_sound:") data_.weapon_drop_sound = read_word(section, 300);
            else if (token_ == "weapon_broken_sound:") data_.weapon_broken_sound = read_word(section, 300);
            else note("ignored header token `" + token_ + "`");
        }
    }

    // Returns true when the token named an itr/strength field.
    bool interaction_field(Interaction& target) {
        if (token_ == "kind:") read_int(target.kind);
        else if (token_ == "x:") read_int(target.area.x);
        else if (token_ == "y:") read_int(target.area.y);
        else if (token_ == "w:") read_int(target.area.width);
        else if (token_ == "h:") read_int(target.area.height);
        else if (token_ == "dvx:") read_int(target.dvx);
        else if (token_ == "dvy:") read_int(target.dvy);
        else if (token_ == "fall:") read_int(target.fall);
        else if (token_ == "arest:") read_int(target.arest);
        else if (token_ == "vrest:") read_int(target.vrest);
        else if (token_ == "respond:") read_int(target.respond);
        else if (token_ == "bdefend:") read_int(target.bdefend);
        else if (token_ == "injury:") read_int(target.injury);
        else if (token_ == "zwidth:") read_int(target.zwidth);
        else if (token_ == "effect:") read_int(target.effect);
        else return false;
        return true;
    }

    void strength_list() {
        constexpr std::string_view section = "<weapon_strength_list>";
        std::int32_t entry = 0;
        next_token(section);
        while (token_ != "<weapon_strength_list_end>") {
            if (token_ == "entry:") {
                const auto name_slot = entry;
                if (read_int(entry)) {
                    if (entry < 0 || entry >= static_cast<std::int32_t>(strength_entries)) {
                        throw ParseFailure{ErrorCode::unsupported,
                                           "weapon strength entry outside 0-9: " + std::to_string(entry)};
                    }
                    if (name_slot > 5) {
                        throw ParseFailure{ErrorCode::unsupported,
                                           "weapon strength name slot overlaps sprite paths"};
                    }
                    data_.strengths[static_cast<std::size_t>(name_slot)].name = read_word(section, 30);
                    data_.strengths[static_cast<std::size_t>(entry)].referenced = true;
                }
            } else {
                // The original's only fields here are dvx..zwidth; kind/x/y/w/h are not keys.
                const bool geometry = token_ == "kind:" || token_ == "x:" || token_ == "y:" ||
                                      token_ == "w:" || token_ == "h:";
                if (geometry || !interaction_field(data_.strengths[static_cast<std::size_t>(entry)].values)) {
                    note("ignored weapon strength token `" + token_ + "`");
                }
            }
            next_token(section);
        }
    }

    template <typename Handler> void block(std::string_view end, Handler handler) {
        const std::string section = token_;
        next_token(section);
        while (token_ != end) {
            if (!handler()) note("ignored " + section + " token `" + token_ + "`");
            next_token(section);
        }
    }

    bool object_point(ObjectPoint& point) {
        if (token_ == "kind:") read_int(point.kind);
        else if (token_ == "x:") read_int(point.x);
        else if (token_ == "y:") read_int(point.y);
        else if (token_ == "action:") read_int(point.action);
        else if (token_ == "dvx:") read_int(point.dvx);
        else if (token_ == "dvy:") read_int(point.dvy);
        else if (token_ == "oid:") read_int(point.oid);
        else if (token_ == "facing:") read_int(point.facing);
        else return false;
        return true;
    }

    bool catch_point(CatchPoint& point) {
        if (token_ == "kind:") read_int(point.kind);
        else if (token_ == "x:") read_int(point.x);
        else if (token_ == "y:") read_int(point.y);
        else if (token_ == "injury:" || token_ == "fronthurtact:") read_int(point.injury);
        else if (token_ == "cover:" || token_ == "backhurtact:") read_int(point.cover);
        else if (token_ == "vaction:") read_int(point.vaction);
        else if (token_ == "aaction:") read_int(point.aaction);
        else if (token_ == "jaction:") read_int(point.jaction);
        else if (token_ == "taction:") read_int(point.taction);
        else if (token_ == "daction:") read_int(point.daction);
        else if (token_ == "throwvx:") read_int(point.throwvx);
        else if (token_ == "throwvy:") read_int(point.throwvy);
        else if (token_ == "throwvz:") read_int(point.throwvz);
        else if (token_ == "hurtable:") read_int(point.hurtable);
        else if (token_ == "throwinjury:") read_int(point.throwinjury);
        else if (token_ == "decrease:") read_int(point.decrease);
        else if (token_ == "dircontrol:") read_int(point.dircontrol);
        else return false;
        return true;
    }

    bool weapon_point(WeaponPoint& point) {
        if (token_ == "kind:") read_int(point.kind);
        else if (token_ == "x:") read_int(point.x);
        else if (token_ == "y:") read_int(point.y);
        else if (token_ == "weaponact:") read_int(point.weaponact);
        else if (token_ == "attacking:") read_int(point.attacking);
        else if (token_ == "cover:") read_int(point.cover);
        else if (token_ == "dvx:") read_int(point.dvx);
        else if (token_ == "dvy:") read_int(point.dvy);
        else if (token_ == "dvz:") read_int(point.dvz);
        else return false;
        return true;
    }

    bool interaction_block_field(Interaction& target) {
        if (interaction_field(target)) return true;
        if (token_ == "catchingact:") {
            if (read_int(target.catching_actions[0])) read_int(target.catching_actions[1]);
        } else if (token_ == "caughtact:") {
            if (read_int(target.caught_actions[0])) read_int(target.caught_actions[1]);
        } else if (token_ == "pickingact:") read_int(target.catching_actions[0]);
        else if (token_ == "pickedact:") read_int(target.catching_actions[1]);
        else return false;
        return true;
    }

    template <typename Item> static Rectangle bounds(const std::vector<Item>& items) {
        Rectangle result{items.front().area.x, items.front().area.y,
                         wrapping_add(items.front().area.width, items.front().area.x),
                         wrapping_add(items.front().area.height, items.front().area.y)};
        for (std::size_t index = 1; index < items.size(); ++index) {
            const auto& area = items[index].area;
            result.x = std::min(result.x, area.x);
            result.y = std::min(result.y, area.y);
            result.width = std::max(result.width, wrapping_add(area.width, area.x));
            result.height = std::max(result.height, wrapping_add(area.height, area.y));
        }
        result.width = wrapping_subtract(result.width, result.x);
        result.height = wrapping_subtract(result.height, result.y);
        return result;
    }

    void frame() {
        constexpr std::string_view section = "<frame>";
        std::int32_t index = 0;
        if (stream_.integer(index) != TokenStream::Scan::value) {
            throw ParseFailure{ErrorCode::unsupported, "<frame> without a frame number"};
        }
        if (index < 0 || index >= frame_count) {
            throw ParseFailure{ErrorCode::unsupported, "frame number outside 0-399: " + std::to_string(index)};
        }
        auto& frame = data_.frames[static_cast<std::size_t>(index)];
        if (frame.defined) note("frame " + std::to_string(index) + " redefined; earlier fields kept");
        // The original keeps 19 characters of a frame's name; mods write longer ones, which only
        // label the frame, so the rest is dropped instead of refusing the file.
        frame.name = read_word(section, token_capacity);
        if (frame.name.size() > 19) {
            note("frame " + std::to_string(index) + " name `" + frame.name + "` cut to 19 characters");
            frame.name.resize(19);
        }
        frame.defined = true;
        frame.interactions.clear();
        frame.bodies.clear();
        next_token(section);
        while (token_ != "<frame_end>") {
            if (token_ == "pic:") read_int(frame.picture);
            else if (token_ == "state:") read_int(frame.state);
            else if (token_ == "wait:") read_int(frame.wait);
            else if (token_ == "next:") read_int(frame.next);
            else if (token_ == "dvx:") read_int(frame.dvx);
            else if (token_ == "dvy:") read_int(frame.dvy);
            else if (token_ == "dvz:") read_int(frame.dvz);
            else if (token_ == "centerx:") read_int(frame.center_x);
            else if (token_ == "centery:") read_int(frame.center_y);
            else if (token_ == "hit_a:") read_int(frame.hits[0]);
            else if (token_ == "hit_d:") read_int(frame.hits[1]);
            else if (token_ == "hit_j:") read_int(frame.hits[2]);
            else if (token_ == "hit_Fa:") read_int(frame.hits[3]);
            else if (token_ == "hit_Ua:") read_int(frame.hits[4]);
            else if (token_ == "hit_Da:") read_int(frame.hits[5]);
            else if (token_ == "hit_Fj:") read_int(frame.hits[6]);
            else if (token_ == "hit_Uj:") read_int(frame.hits[7]);
            else if (token_ == "hit_Dj:") read_int(frame.hits[8]);
            else if (token_ == "hit_ja:") read_int(frame.hits[9]);
            else if (token_ == "mp:") read_int(frame.mp);
            else if (token_ == "sound:") frame.sound = read_word(section, 300);
            else if (token_ == "opoint:") block("opoint_end:", [&] { return object_point(frame.opoint); });
            else if (token_ == "bpoint:") {
                block("bpoint_end:", [&] {
                    if (token_ == "x:") read_int(frame.bpoint.x);
                    else if (token_ == "y:") read_int(frame.bpoint.y);
                    else return false;
                    return true;
                });
            } else if (token_ == "cpoint:") block("cpoint_end:", [&] { return catch_point(frame.cpoint); });
            else if (token_ == "wpoint:") block("wpoint_end:", [&] { return weapon_point(frame.wpoint); });
            else if (token_ == "itr:") {
                // The original allocates room for five records on the first block.
                if (frame.interactions.size() == max_frame_blocks) {
                    throw ParseFailure{ErrorCode::unsupported, "more than five itr blocks in a frame"};
                }
                auto& interaction = frame.interactions.emplace_back();
                block("itr_end:", [&] { return interaction_block_field(interaction); });
            } else if (token_ == "bdy:") {
                if (frame.bodies.size() == max_frame_blocks) {
                    throw ParseFailure{ErrorCode::unsupported, "more than five bdy blocks in a frame"};
                }
                auto& body = frame.bodies.emplace_back();
                block("bdy_end:", [&] {
                    if (token_ == "kind:") read_int(body.kind);
                    else if (token_ == "x:") read_int(body.area.x);
                    else if (token_ == "y:") read_int(body.area.y);
                    else if (token_ == "w:") read_int(body.area.width);
                    else if (token_ == "h:") read_int(body.area.height);
                    else return false;
                    return true;
                });
            } else note("ignored frame token `" + token_ + "`");
            next_token(section);
        }
        if (!frame.interactions.empty()) frame.interaction_bounds = bounds(frame.interactions);
        if (!frame.bodies.empty()) frame.body_bounds = bounds(frame.bodies);
    }

    TokenStream stream_;
    ObjectData data_;
    std::string token_;
    PendingSheet pending_;
};

ScriptValue integer(std::int32_t value) { return ScriptValue{value}; }
ScriptValue text(std::string value) { return ScriptValue{std::move(value)}; }
ScriptValue table(ScriptTable fields) { return ScriptValue{std::move(fields)}; }

void set_optional(ScriptTable& target, std::string key, const std::optional<std::int32_t>& value) {
    if (value) set_field(target, std::move(key), integer(*value));
}
void set_optional(ScriptTable& target, std::string key, const std::optional<double>& value) {
    if (value) set_field(target, std::move(key), ScriptValue{*value});
}
void set_optional(ScriptTable& target, std::string key, const std::optional<std::string>& value) {
    if (value) set_field(target, std::move(key), text(*value));
}

ScriptValue rectangle(const Rectangle& area) {
    return table({{"x", integer(area.x)}, {"y", integer(area.y)},
                  {"width", integer(area.width)}, {"height", integer(area.height)}});
}
ScriptValue pair(const std::array<std::int32_t, 2>& values) {
    return table({{1, integer(values[0])}, {2, integer(values[1])}});
}
ScriptTable interaction_fields(const Interaction& value) {
    return {{"kind", integer(value.kind)}, {"x", integer(value.area.x)},
            {"y", integer(value.area.y)}, {"width", integer(value.area.width)},
            {"height", integer(value.area.height)}, {"dvx", integer(value.dvx)},
            {"dvy", integer(value.dvy)}, {"fall", integer(value.fall)},
            {"arest", integer(value.arest)}, {"vrest", integer(value.vrest)},
            {"respond", integer(value.respond)}, {"effect", integer(value.effect)},
            {"catching_actions", pair(value.catching_actions)},
            {"caught_actions", pair(value.caught_actions)}, {"bdefend", integer(value.bdefend)},
            {"injury", integer(value.injury)}, {"zwidth", integer(value.zwidth)}};
}

ScriptValue frame_value(const Frame& frame) {
    static constexpr std::array<std::string_view, 10> hit_names{
        "a", "d", "j", "Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja"};
    ScriptTable hits;
    for (std::size_t index = 0; index < hit_names.size(); ++index) {
        set_field(hits, std::string(hit_names[index]), integer(frame.hits[index]));
    }
    const auto& o = frame.opoint;
    const auto& c = frame.cpoint;
    const auto& w = frame.wpoint;
    ScriptTable catch_point{{"kind", integer(c.kind)}, {"x", integer(c.x)}, {"y", integer(c.y)},
        {"injury", integer(c.injury)}, {"cover", integer(c.cover)},
        {"vaction", integer(c.vaction)}, {"aaction", integer(c.aaction)},
        {"jaction", integer(c.jaction)}, {"daction", integer(c.daction)},
        {"taction", integer(c.taction)}, {"throwvx", integer(c.throwvx)},
        {"throwvy", integer(c.throwvy)}, {"hurtable", integer(c.hurtable)},
        {"decrease", integer(c.decrease)}, {"dircontrol", integer(c.dircontrol)}};
    set_optional(catch_point, "throwinjury", c.throwinjury);
    set_optional(catch_point, "throwvz", c.throwvz);
    ScriptTable interactions;
    for (std::size_t index = 0; index < frame.interactions.size(); ++index) {
        set_field(interactions, static_cast<std::int32_t>(index + 1),
                  table(interaction_fields(frame.interactions[index])));
    }
    ScriptTable bodies;
    for (std::size_t index = 0; index < frame.bodies.size(); ++index) {
        const auto& body = frame.bodies[index];
        set_field(bodies, static_cast<std::int32_t>(index + 1),
                  table({{"kind", integer(body.kind)}, {"x", integer(body.area.x)},
                         {"y", integer(body.area.y)}, {"width", integer(body.area.width)},
                         {"height", integer(body.area.height)}}));
    }
    ScriptTable result{{"name", text(frame.name)}, {"picture", integer(frame.picture)},
        {"state", integer(frame.state)}, {"wait", integer(frame.wait)},
        {"next", integer(frame.next)}, {"dvx", integer(frame.dvx)}, {"dvy", integer(frame.dvy)},
        {"dvz", integer(frame.dvz)}, {"center_x", integer(frame.center_x)},
        {"center_y", integer(frame.center_y)}, {"mp", integer(frame.mp)},
        {"hits", table(std::move(hits))},
        {"opoint", table({{"kind", integer(o.kind)}, {"x", integer(o.x)}, {"y", integer(o.y)},
                          {"action", integer(o.action)}, {"dvx", integer(o.dvx)},
                          {"dvy", integer(o.dvy)}, {"oid", integer(o.oid)},
                          {"facing", integer(o.facing)}})},
        {"bpoint", table({{"x", integer(frame.bpoint.x)}, {"y", integer(frame.bpoint.y)}})},
        {"cpoint", table(std::move(catch_point))},
        {"wpoint", table({{"kind", integer(w.kind)}, {"x", integer(w.x)}, {"y", integer(w.y)},
                          {"weaponact", integer(w.weaponact)}, {"attacking", integer(w.attacking)},
                          {"cover", integer(w.cover)}, {"dvx", integer(w.dvx)},
                          {"dvy", integer(w.dvy)}, {"dvz", integer(w.dvz)}})},
        {"interactions", table(std::move(interactions))}, {"bodies", table(std::move(bodies))},
        {"interaction_bounds", rectangle(frame.interaction_bounds)},
        {"body_bounds", rectangle(frame.body_bounds)}};
    set_optional(result, "sound", frame.sound);
    return table(std::move(result));
}
}

Result<ObjectData> parse(std::string_view text) {
    Parser parser(text);
    try {
        return parser.run();
    } catch (const ParseFailure& failure) {
        return fail(failure.code, "line " + std::to_string(parser.line()) + ": " + failure.message);
    }
}

Result<ObjectData> load(const ResourceSource& resources, std::string_view path) {
    auto bytes = read_data_text(resources, path, max_input);
    if (!bytes) return std::unexpected(bytes.error());
    auto parsed = parse(std::string_view(bytes->data(), bytes->size()));
    if (!parsed) parsed.error().message = std::string(path) + ": " + parsed.error().message;
    return parsed;
}

std::optional<PictureCell> find_picture(const ObjectData& data, std::int32_t picture) {
    for (std::size_t index = 0; index < data.sheets.size(); ++index) {
        const auto& sheet = data.sheets[index];
        const auto cell = std::int64_t{picture} - sheet.first_picture;
        if (cell < 0 || cell >= std::int64_t{sheet.columns} * sheet.rows) continue;
        const auto column = static_cast<std::int32_t>(cell % sheet.columns);
        const auto row = static_cast<std::int32_t>(cell / sheet.columns);
        return PictureCell{index, {column * (sheet.cell_width + 1), row * (sheet.cell_height + 1),
                                   sheet.cell_width, sheet.cell_height}};
    }
    return std::nullopt;
}

ScriptValue to_script_value(const ObjectData& data) {
    ScriptTable movement;
    const auto& m = data.movement;
    set_optional(movement, "walking_frame_rate", m.walking_frame_rate);
    set_optional(movement, "walking_speed", m.walking_speed);
    set_optional(movement, "walking_speedz", m.walking_speedz);
    set_optional(movement, "running_frame_rate", m.running_frame_rate);
    set_optional(movement, "running_speed", m.running_speed);
    set_optional(movement, "running_speedz", m.running_speedz);
    set_optional(movement, "heavy_walking_speed", m.heavy_walking_speed);
    set_optional(movement, "heavy_walking_speedz", m.heavy_walking_speedz);
    set_optional(movement, "heavy_running_speed", m.heavy_running_speed);
    set_optional(movement, "heavy_running_speedz", m.heavy_running_speedz);
    set_optional(movement, "jump_height", m.jump_height);
    set_optional(movement, "jump_distance", m.jump_distance);
    set_optional(movement, "jump_distancez", m.jump_distancez);
    set_optional(movement, "dash_height", m.dash_height);
    set_optional(movement, "dash_distance", m.dash_distance);
    set_optional(movement, "dash_distancez", m.dash_distancez);
    set_optional(movement, "rowing_height", m.rowing_height);
    set_optional(movement, "rowing_distance", m.rowing_distance);

    ScriptTable weapon{{"hp", integer(data.weapon_hp)}, {"drop_hurt", integer(data.weapon_drop_hurt)}};
    set_optional(weapon, "hit_sound", data.weapon_hit_sound);
    set_optional(weapon, "drop_sound", data.weapon_drop_sound);
    set_optional(weapon, "broken_sound", data.weapon_broken_sound);

    ScriptTable sheets;
    for (std::size_t index = 0; index < data.sheets.size(); ++index) {
        const auto& sheet = data.sheets[index];
        set_field(sheets, static_cast<std::int32_t>(index + 1),
                  table({{"path", text(sheet.path)}, {"declared_range", text(sheet.declared_range)},
                         {"first_picture", integer(sheet.first_picture)},
                         {"cell_width", integer(sheet.cell_width)},
                         {"cell_height", integer(sheet.cell_height)},
                         {"columns", integer(sheet.columns)}, {"rows", integer(sheet.rows)}}));
    }

    ScriptTable strengths;
    for (std::size_t index = 0; index < data.strengths.size(); ++index) {
        const auto& strength = data.strengths[index];
        if (!strength.referenced && !strength.name) continue;
        auto fields = interaction_fields(strength.values);
        set_optional(fields, "name", strength.name);
        set_field(strengths, static_cast<std::int32_t>(index), table(std::move(fields)));
    }

    ScriptTable frames;
    for (std::size_t index = 0; index < data.frames.size(); ++index) {
        if (data.frames[index].defined) {
            set_field(frames, static_cast<std::int32_t>(index), frame_value(data.frames[index]));
        }
    }

    ScriptTable diagnostics;
    for (std::size_t index = 0; index < data.diagnostics.size(); ++index) {
        set_field(diagnostics, static_cast<std::int32_t>(index + 1), text(data.diagnostics[index]));
    }

    ScriptTable result{{"name", text(data.name)}, {"head", text(data.head)},
        {"movement", table(std::move(movement))}, {"weapon", table(std::move(weapon))},
        {"sheets", table(std::move(sheets))}, {"strengths", table(std::move(strengths))},
        {"frames", table(std::move(frames))}, {"token_checksum", integer(data.token_checksum)},
        {"diagnostics", table(std::move(diagnostics))}};
    set_optional(result, "small", data.small);
    return table(std::move(result));
}
}
