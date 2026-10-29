// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/ports/music.hpp"
#include "openlf2/ports/resources.hpp"
#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <span>
#include <string_view>
#include <variant>
#include <vector>

namespace openlf2 {
struct Rectangle { int x; int y; int width; int height; };
struct WindowPlacement {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    bool maximized = false;
};
struct Viewport {
    int width = 0;
    int height = 0;
    int red = 0;
    int green = 0;
    int blue = 0;
    // Optional drawing area in viewport coordinates; presentation keeps the original scale.
    std::optional<Rectangle> render_area = std::nullopt;
};
// How the frame is scaled to the window. `xbrz` is an edge-directed pixel-art scaler that runs as
// a shader, so only some renderers offer it (Platform::supports).
// sharp: SDL 3.4's pixel-art scaling, crisp pixels of even size at any zoom (OpenLF2 extension).
enum class RenderFilter { nearest, linear, xbrz, sharp };
// Optional CPU lighting for world sprites. Screen Y grows downward; ground_y is the
// object's floor row, independent of jump height. Angles are in degrees.
struct SpriteLighting {
    int ground_y = 0;
    float azimuth = -50.0f;
    float elevation = 70.0f;
    bool character = false;
    bool casts_shadow = false;
    int shadow_blur = 2; // radius in viewport pixels; zero preserves hard silhouette edges
    float shadow_opacity = 0.275f; // 0..1, applied only to projected shadows
};
struct SpriteCommand {
    std::string resource;
    Rectangle source;
    int x;
    int y;
    bool color_key;
    bool mirrored = false; // horizontal flip of the source rectangle
    bool flipped = false;  // vertical flip of the source rectangle
    int tint = 0xffffff;   // 0xRRGGBB multiplied into the source color (white leaves it unchanged)
    bool overlay = false;  // drawn over the whole window (letterbox bars included), see Viewport
    std::optional<Rectangle> clip = std::nullopt; // defaults to the original viewport
    float scale_x = 1.0f; // horizontal transform; source sampling is unchanged
    int translate_x = 0;
    std::optional<SpriteLighting> lighting = std::nullopt;
};
// Solid rectangle in 8-bit RGBA channels.
struct FillCommand {
    Rectangle area;
    int red;
    int green;
    int blue;
    bool overlay = false; // as SpriteCommand::overlay
    std::optional<Rectangle> clip = std::nullopt; // as SpriteCommand::clip
    int alpha = 255;
};
enum class TextAlign { left, center, right };
// UTF-8 text drawn with a vector font (the translated languages; the original's bitmap font only
// has ASCII). `x` is the left, center or right edge by `align`, `y` the top; `size` is the font
// size in pixels. `outline` (0xRRGGBB) adds a one pixel border, `background` an opaque box behind
// the text. Without `antialias` the glyphs have hard pixel edges.
struct TextCommand {
    std::string text;
    int x = 0;
    int y = 0;
    TextAlign align = TextAlign::left;
    int size = 13;
    int color = 0xffffff;
    std::optional<int> outline = std::nullopt;
    std::optional<int> background = std::nullopt;
    bool antialias = true;
    bool overlay = false; // as SpriteCommand::overlay
    std::optional<Rectangle> clip = std::nullopt; // as SpriteCommand::clip
};
using DrawCommand = std::variant<SpriteCommand, FillCommand, TextCommand>;
// Restarts a sound from the beginning, one voice per resource. Volume/pan in hundredths of a
// decibel: volume -10000..0 attenuates; pan > 0 attenuates the left channel, pan < 0 the right.
struct SoundCommand {
    std::string resource;
    int volume = 0;
    int pan = 0;
};
// Music control, applied in order: `play` starts/resumes a resource, `stop` stops and rewinds,
// `resume` continues, `volume` is hundredths of a decibel (-10000 silent .. 0). Tracks loop.
struct MusicCommand {
    enum class Kind { play, stop, resume, volume };
    Kind kind = Kind::stop;
    std::string resource;
    int volume = 0;
};
// Haptic feedback (OpenLF2 extension). `gamepad` rumbles `pad_index` (see InputSnapshot::pads);
// `phone` uses the device's own vibration motor where one exists. `strength` is 0..100.
// Best-effort: an unavailable target is silently ignored, never an error.
struct RumbleCommand {
    enum class Target { gamepad, phone };
    Target target = Target::gamepad;
    int pad_index = 0;
    int strength = 0;
};
// Held keyboard keys, indexed by Windows virtual-key code. Scripts map them to players via
// data/control.txt.
// Connected controllers' buttons, merged, in SDL's standard layout: left stick counts as the
// d-pad, `south` is the bottom face button (A on Xbox).
struct GamepadButtons {
    bool up = false;
    bool down = false;
    bool left = false;
    bool right = false;
    bool south = false;
    bool east = false;
    bool west = false;
    bool north = false;
    bool start = false;
    bool back = false;
};
// One controller's directions and buttons (bit n = button n: 0 south, 1 east, 2 west, 3 north,
// 4/5 shoulders, 6 back, 7 start, 8/9 stick clicks), for a player's own joystick set.
struct PadState {
    bool up = false;
    bool down = false;
    bool left = false;
    bool right = false;
    std::uint32_t buttons = 0;
};
inline constexpr std::size_t max_pads = 4;
// One held finger: viewport position and a platform-assigned id, stable while it stays down.
struct TouchPoint { int id; int x; int y; };
// The window's edges in viewport coordinates: beyond 0..width / 0..height when the picture is
// letterboxed. Overlay draw commands use the same coordinates.
struct ScreenExtent { int left = 0; int top = 0; int right = 0; int bottom = 0; };
// Viewport-coordinate pointer (-1 when unknown); follows the mouse or the last finger touched.
struct InputSnapshot {
    std::array<bool, 256> keys{};
    int pointer_x = -1;
    int pointer_y = -1;
    bool button = false;
    // The button or a finger went down since the previous poll (a short tap may be up again
    // by the time a script frame runs).
    bool pressed = false;
    GamepadButtons gamepad;
    // Controllers in connection order (`gamepad` above is the merged view for menus). At most max_pads.
    std::vector<PadState> pads;
    // The window's edges in viewport coordinates; all zero when there is no window.
    ScreenExtent screen;
    // Every finger held down this poll, in viewport coordinates (letterbox bars included, so
    // coordinates can be negative or past the viewport size).
    std::vector<TouchPoint> touches;
    // True from the first touch until the mouse/keyboard is used again; drives touch-only UI.
    bool touch_active = false;
    // Printable ASCII typed since the previous poll that no key-down event accounted for: the
    // text of soft keyboards and system text dialogs. Hardware keys arrive in `key_downs`.
    std::string text;
    bool quit = false;
    // The file picked in the dialog opened by choose_file, once (UTF-8 path).
    std::optional<std::string> chosen_file;
    // The first file dropped onto this window during this poll (UTF-8 path).
    std::optional<std::string> dropped_file;
    // Ordered key-down events (auto-repeat included); `keys` alone loses ordering.
    std::vector<int> key_downs;
    // Alt+Enter was pressed: the host consumed both keys (Enter is not in `keys` or `key_downs`); the scripts
    // switch between fullscreen and window.
    bool toggle_fullscreen = false;
};
// Setup screens shown before any game data exists, drawn with SDL's built-in 8x8 font (ASCII only).
class SetupDialog {
public:
    virtual ~SetupDialog() = default;
    // Shows `text` with one button per answer; returns the chosen index, or nothing if canceled.
    virtual Result<std::optional<std::size_t>> choose(std::string_view text, std::span<const std::string> answers) = 0;
    // Draws progress (`fraction` 0..1) once, non-blocking; call repeatedly. False once canceled.
    virtual Result<bool> progress(std::string_view text, double fraction, std::string_view cancel) = 0;
};
// The texts of the open-file dialog (see Platform::choose_file).
struct FileDialogText {
    std::string title, filter, accept;
};
class Platform {
public:
    virtual ~Platform() = default;
    virtual InputSnapshot poll() = 0;
    // Commands are drawn in order over the viewport's clear color.
    virtual Result<void> present(std::span<const DrawCommand> commands, const Viewport& viewport) = 0;
    // Shows or hides the on-screen keyboard where the system has one; `text` of the snapshot
    // only carries typing while it is active.
    virtual void set_text_input(bool active) = 0;
    // Applies the scaling mode without recreating the window. A mode the renderer cannot do
    // (`supports` is false) is replaced by `nearest`.
    virtual Result<void> set_render_filter(RenderFilter filter) = 0;
    // Whether the renderer can scale with `filter`: nearest and linear always, xbrz only on the
    // renderers that can run its shader.
    [[nodiscard]] virtual bool supports(RenderFilter filter) const = 0;
    // Whether TextCommand can be drawn (needs the TrueType text renderer); scripts only use it when it can.
    [[nodiscard]] virtual bool supports_text() const { return false; }
    // The renderer in use, e.g. "gpu" or "opengl" (for the log).
    [[nodiscard]] virtual std::string renderer_name() const = 0;
    // False where the window already fills a fixed screen (mobile, console, browser).
    [[nodiscard]] virtual bool supports_fullscreen() const = 0;
    // Enters or leaves borderless (desktop) fullscreen. A no-op where supports_fullscreen() is
    // false, so it is safe to call unconditionally every frame like set_render_filter.
    virtual Result<void> set_fullscreen(bool enabled) = 0;
    // Desktop placement in window coordinates; unsupported platforms return nothing.
    // The rectangle is the normal window's, even while maximized or fullscreen.
    virtual std::optional<WindowPlacement> window_placement() { return std::nullopt; }
    virtual Result<void> restore_window(const WindowPlacement&) { return {}; }
    // Plays the sounds requested by one frame. Without an audio device this does nothing.
    virtual Result<void> play(std::span<const SoundCommand> sounds) = 0;
    // Triggers the haptic feedback requested by one frame. Best-effort: never fails for an
    // unavailable target (see RumbleCommand), only for a malformed request.
    virtual Result<void> rumble(std::span<const RumbleCommand> commands) = 0;
    // Opens the system's open-file dialog for recordings (*.lfr), starting in `directory`, with the
    // given texts (the dialog's title, the filter's name, the confirm button; an empty one is the
    // system's default); the result arrives later through poll(). Returns an error when no dialog
    // can be shown.
    virtual Result<void> choose_file(const std::optional<std::filesystem::path>& directory,
                                     const FileDialogText& text) = 0;
    // Applies one frame's music commands and keeps the current track's audio queued; called
    // every frame. A track that cannot be decoded is reported once and stays silent.
    virtual Result<void> music(std::span<const MusicCommand> commands) = 0;
    // Shows `directory` in the system's file manager (the recording page's "open folder"); creates it
    // first. An error where the platform cannot (browsers, phones).
    virtual Result<void> open_folder(const std::filesystem::path& directory) = 0;
    // Opens `url` (an http:// or https:// URL) in the system browser, or the platform's own
    // handler for it (the launch menu's "official website"). An error where the platform cannot.
    virtual Result<void> open_url(const std::string& url) = 0;
    // The setup screens, drawn in this window at its initial viewport; used before any game
    // frame is presented.
    virtual SetupDialog& setup_dialog() = 0;
};
// `resources` and `decoder` must outlive the platform. `renderer` picks one by name for testing;
// empty lets the platform choose.
Result<std::unique_ptr<Platform>> make_platform(const ResourceSource& resources, const Viewport& viewport,
                                                const MusicDecoder& decoder, std::string_view renderer = {},
                                                const std::optional<WindowPlacement>& placement = std::nullopt);
// The per-user directory for the configuration, created if needed (SDL_GetPrefPath).
Result<std::filesystem::path> settings_directory();
}
