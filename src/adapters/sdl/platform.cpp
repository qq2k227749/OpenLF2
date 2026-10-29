// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/platform.hpp"
#include "openlf2/detail/sdl/frame_upscaler.hpp"
#include "openlf2/detail/sdl/haptics.hpp"
#include "openlf2/detail/sdl/setup_screen.hpp"
#include "openlf2/detail/sdl/text_renderer.hpp"
#include "openlf2/detail/sdl/sprite_effects.hpp"
#ifdef OPENLF2_HAS_WINDOW_ICON
#include "window_icon.hpp" // generated from the SVG icon by tools/icons/make_icons.py
#endif
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <list>
#include <mutex>
#include <utility>
#include <map>
#include <set>
#include <vector>
#include <SDL3/SDL.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

namespace openlf2 {
namespace {
// The open-file dialog's result. SDL may call back on another thread and after the platform is
// gone, so the slot lives for the whole process.
struct DialogSlot {
    std::mutex mutex;
    std::optional<std::string> chosen;
};
DialogSlot& dialog_slot() {
    static DialogSlot slot;
    return slot;
}
#ifndef __EMSCRIPTEN__
void SDLCALL dialog_finished(void*, const char* const* files, int) {
    if (files == nullptr) {
        std::cerr << "Replay: the file dialog failed: " << SDL_GetError() << '\n';
        return;
    }
    if (files[0] == nullptr) return; // cancelled
    auto& slot = dialog_slot();
    const std::scoped_lock lock(slot.mutex);
    slot.chosen = std::string(files[0]);
}
#endif
// Windows virtual-key code of a held key (0 when it has none). Letters and digits follow the
// active layout like Windows' own codes; the other keys use their US positions.
int virtual_key(SDL_Scancode scancode) {
    const SDL_Keycode key = SDL_GetKeyFromScancode(scancode, SDL_KMOD_NONE, false);
    if (key >= 'a' && key <= 'z') return static_cast<int>(key - 'a') + 0x41;
    if (key >= '0' && key <= '9' && (scancode < SDL_SCANCODE_KP_1 || scancode > SDL_SCANCODE_KP_0)) {
        return static_cast<int>(key - '0') + 0x30;
    }
    if (scancode >= SDL_SCANCODE_F1 && scancode <= SDL_SCANCODE_F12) return 0x70 + (scancode - SDL_SCANCODE_F1);
    if (scancode >= SDL_SCANCODE_KP_1 && scancode <= SDL_SCANCODE_KP_9) return 0x61 + (scancode - SDL_SCANCODE_KP_1);
    switch (scancode) {
    case SDL_SCANCODE_KP_0: return 0x60;
    case SDL_SCANCODE_KP_MULTIPLY: return 0x6a;
    case SDL_SCANCODE_KP_PLUS: return 0x6b;
    case SDL_SCANCODE_KP_MINUS: return 0x6d;
    case SDL_SCANCODE_KP_PERIOD: return 0x6e;
    case SDL_SCANCODE_KP_DIVIDE: return 0x6f;
    case SDL_SCANCODE_KP_ENTER: case SDL_SCANCODE_RETURN: return 0x0d;
    case SDL_SCANCODE_BACKSPACE: return 0x08;
    case SDL_SCANCODE_TAB: return 0x09;
    case SDL_SCANCODE_LSHIFT: case SDL_SCANCODE_RSHIFT: return 0x10;
    case SDL_SCANCODE_LCTRL: case SDL_SCANCODE_RCTRL: return 0x11;
    case SDL_SCANCODE_LALT: case SDL_SCANCODE_RALT: return 0x12;
    case SDL_SCANCODE_PAUSE: return 0x13;
    case SDL_SCANCODE_CAPSLOCK: return 0x14;
    // Android's back button is Escape: the scripts ask before leaving the game.
    case SDL_SCANCODE_ESCAPE: case SDL_SCANCODE_AC_BACK: return 0x1b;
    case SDL_SCANCODE_SPACE: return 0x20;
    case SDL_SCANCODE_PAGEUP: return 0x21;
    case SDL_SCANCODE_PAGEDOWN: return 0x22;
    case SDL_SCANCODE_END: return 0x23;
    case SDL_SCANCODE_HOME: return 0x24;
    case SDL_SCANCODE_LEFT: return 0x25;
    case SDL_SCANCODE_UP: return 0x26;
    case SDL_SCANCODE_RIGHT: return 0x27;
    case SDL_SCANCODE_DOWN: return 0x28;
    case SDL_SCANCODE_INSERT: return 0x2d;
    case SDL_SCANCODE_DELETE: return 0x2e;
    case SDL_SCANCODE_NUMLOCKCLEAR: return 0x90;
    case SDL_SCANCODE_SCROLLLOCK: return 0x91;
    case SDL_SCANCODE_SEMICOLON: return 0xba;
    case SDL_SCANCODE_EQUALS: return 0xbb;
    case SDL_SCANCODE_COMMA: return 0xbc;
    case SDL_SCANCODE_MINUS: return 0xbd;
    case SDL_SCANCODE_PERIOD: return 0xbe;
    case SDL_SCANCODE_SLASH: return 0xbf;
    case SDL_SCANCODE_GRAVE: return 0xc0;
    case SDL_SCANCODE_LEFTBRACKET: return 0xdb;
    case SDL_SCANCODE_BACKSLASH: return 0xdc;
    case SDL_SCANCODE_RIGHTBRACKET: return 0xdd;
    case SDL_SCANCODE_APOSTROPHE: return 0xde;
    case SDL_SCANCODE_NONUSBACKSLASH: return 0xe2;
    default: return 0;
    }
}
// True for keys that produce a character in a text field, which SDL also reports as text.
bool types_text(int code) {
    return code == 0x20 || (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) ||
           (code >= 0x60 && code <= 0x6f && code != 0x6c) || (code >= 0xba && code <= 0xc0) ||
           (code >= 0xdb && code <= 0xde) || code == 0xe2;
}
// Prefers SDL's GPU renderer; SDL_RENDER_DRIVER and `--renderer` (testing) override this.
struct QuitSdl { ~QuitSdl() { SDL_Quit(); } };
struct CloseGamepad { void operator()(SDL_Gamepad* handle) const noexcept { SDL_CloseGamepad(handle); } };
struct DestroyWindow { void operator()(SDL_Window* handle) const noexcept { SDL_DestroyWindow(handle); } };
struct DestroyRenderer { void operator()(SDL_Renderer* handle) const noexcept { SDL_DestroyRenderer(handle); } };
struct DestroyTexture { void operator()(SDL_Texture* handle) const noexcept { SDL_DestroyTexture(handle); } };
struct DestroySurface { void operator()(SDL_Surface* handle) const noexcept { SDL_DestroySurface(handle); } };
struct CloseStream { void operator()(SDL_IOStream* handle) const noexcept { SDL_CloseIO(handle); } };
struct DestroyAudioStream { void operator()(SDL_AudioStream* handle) const noexcept { SDL_DestroyAudioStream(handle); } };
struct FreeSdlMemory { void operator()(Uint8* data) const noexcept { SDL_free(data); } };
struct CloseAudioDevice {
    SDL_AudioDeviceID device = 0;
    ~CloseAudioDevice() { if (device != 0) SDL_CloseAudioDevice(device); }
};
// One voice per sound resource: interleaved 16-bit stereo samples and a stream bound to the
// device, cleared on every new play.
struct Voice {
    std::vector<std::int16_t> samples;
    std::unique_ptr<SDL_AudioStream, DestroyAudioStream> stream;
};
struct ScaledVoice {
    const Voice* voice;
    double left;
    double right;
    std::vector<std::int16_t> samples;
};
// Gains are in [0, 1], so a scaled int16 sample remains representable. This
// rounds the same product as std::round, including negative half-way values,
// without a rounding-library call or an unnecessary saturation per sample.
std::int16_t scaled_sample(std::int16_t sample, double factor) {
    if (factor == 1.0) return sample;
    const double value = static_cast<double>(sample) * factor;
    const int whole = static_cast<int>(value);
    const double fraction = value - static_cast<double>(whole);
    return static_cast<std::int16_t>(whole + (fraction >= 0.5 ? 1 : fraction <= -0.5 ? -1 : 0));
}
// DirectSound hundredths of a decibel to a linear gain.
double gain(int hundredths) {
    if (hundredths <= -10000) return 0.0;
    return std::pow(10.0, static_cast<double>(hundredths) / 2000.0);
}
using Texture = std::unique_ptr<SDL_Texture, DestroyTexture>;
#if defined(__EMSCRIPTEN__) || defined(__ANDROID__) || defined(__SWITCH__) || defined(__vita__) || TARGET_OS_IPHONE
constexpr bool desktop_window = false;
#else
constexpr bool desktop_window = true;
#endif
class SdlPlatform final : public Platform {
public:
    SdlPlatform(const ResourceSource& resources, const MusicDecoder& decoder)
        : resources_(resources), decoder_(decoder), text_(resources) {}
    Result<void> initialize(const Viewport& viewport, const std::string& renderer,
                            const std::optional<WindowPlacement>& placement) {
#ifdef __vita__
        // The rear touchpad has no screen position, and SDL's synthetic mouse
        // motion from touch fights focus navigation on Vita menus.
        SDL_SetHint(SDL_HINT_VITA_ENABLE_BACK_TOUCH, "0");
        SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");
#endif
#ifdef __ANDROID__
        // Without this the back button finishes the activity; with it the app receives it as a key.
        SDL_SetHint(SDL_HINT_ANDROID_TRAP_BACK_BUTTON, "1");
#endif
        if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) return error();
        session_ = std::make_unique<QuitSdl>();
#if TARGET_OS_IPHONE
        // UIKit uses RESIZABLE to allow both portrait and landscape orientations.
        constexpr auto window_flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_BORDERLESS;
#elif defined(__ANDROID__)
        constexpr auto window_flags = SDL_WINDOW_FULLSCREEN;
#else
        constexpr auto window_flags = SDL_WINDOW_RESIZABLE;
#endif
        // Scale directly to the display's backing pixels on high-density screens.
        const bool restore = desktop_window && placement.has_value();
        window_.reset(SDL_CreateWindow("OpenLF2", viewport.width, viewport.height,
                                      window_flags | SDL_WINDOW_HIGH_PIXEL_DENSITY |
                                      (restore ? SDL_WINDOW_HIDDEN : 0)));
        if (!window_) return error();
        window_placement();
        if (restore) {
            auto restored = restore_window(*placement);
            if (!restored) std::cerr << "Window settings: " << restored.error().message << '\n';
        }
#if defined(OPENLF2_HAS_WINDOW_ICON) && SDL_VERSION_ATLEAST(3, 4, 0)
        // Purely cosmetic, so a failure is ignored. SDL_LoadPNG_IO is only available
        // since SDL 3.4.0; older SDL3 (e.g. Debian 13's system package) leaves the
        // window icon unset rather than pulling in a separate PNG decoder.
        {
            const std::unique_ptr<SDL_IOStream, CloseStream> stream(
                SDL_IOFromConstMem(icon::window_png.data(), icon::window_png.size()));
            const std::unique_ptr<SDL_Surface, DestroySurface> surface(stream ? SDL_LoadPNG_IO(stream.get(), false) : nullptr);
            if (surface) SDL_SetWindowIcon(window_.get(), surface.get());
        }
#endif
        viewport_ = viewport;
        original_size_ = {viewport.width, viewport.height};
        requested_renderer_ = renderer;
        if (!choose_renderer(renderer)) return error();
        // Avoids tearing only; the application's frame clock decides when frames run.
        SDL_SetRenderVSync(renderer_.get(), 1);
        make_setup_screen();
        // Controllers are optional too. Ones plugged in before the start are opened here, later
        // ones when SDL reports them.
        if (SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
            int count = 0;
            const std::unique_ptr<SDL_JoystickID, decltype(&SDL_free)> ids(SDL_GetGamepads(&count), &SDL_free);
            for (int index = 0; ids && index < count; ++index) open_gamepad(ids.get()[index]);
        }
        // Sound is optional: without an audio device the game runs silently.
        if (SDL_InitSubSystem(SDL_INIT_AUDIO)) {
            audio_ = std::make_unique<CloseAudioDevice>();
            audio_->device = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &voice_spec);
            if (audio_->device == 0) audio_.reset();
        }
        if (audio_) {
            music_stream_.reset(SDL_CreateAudioStream(&voice_spec, &voice_spec));
            if (!music_stream_ || !SDL_BindAudioStream(audio_->device, music_stream_.get())) return error();
        }
        if (restore && !SDL_ShowWindow(window_.get())) return error();
        return {};
    }
    Result<void> choose_file(const std::optional<std::filesystem::path>& directory, const FileDialogText& labels) override {
#ifdef __EMSCRIPTEN__
        (void)directory;
        (void)labels;
        return fail(ErrorCode::platform, "Browser file dialog for replays is unavailable");
#else
        // SDL uses the filter and its name until the dialog closes.
        dialog_filter_name_ = labels.filter.empty() ? "LF2 recording files (*.lfr)" : labels.filter;
        dialog_filter_ = {dialog_filter_name_.c_str(), "lfr"};
        std::string location;
        if (directory) {
            std::error_code error;
            std::filesystem::create_directories(*directory, error);
            const auto text = directory->u8string();
            location.assign(text.begin(), text.end());
        }
        const SDL_PropertiesID properties = SDL_CreateProperties();
        SDL_SetPointerProperty(properties, SDL_PROP_FILE_DIALOG_FILTERS_POINTER, &dialog_filter_);
        SDL_SetNumberProperty(properties, SDL_PROP_FILE_DIALOG_NFILTERS_NUMBER, 1);
        SDL_SetPointerProperty(properties, SDL_PROP_FILE_DIALOG_WINDOW_POINTER, window_.get());
        if (!location.empty()) SDL_SetStringProperty(properties, SDL_PROP_FILE_DIALOG_LOCATION_STRING, location.c_str());
        if (!labels.title.empty()) SDL_SetStringProperty(properties, SDL_PROP_FILE_DIALOG_TITLE_STRING, labels.title.c_str());
        if (!labels.accept.empty()) SDL_SetStringProperty(properties, SDL_PROP_FILE_DIALOG_ACCEPT_STRING, labels.accept.c_str());
        SDL_ShowFileDialogWithProperties(SDL_FILEDIALOG_OPENFILE, dialog_finished, nullptr, properties);
        SDL_DestroyProperties(properties);
        return {};
#endif
    }
    Result<void> open_folder(const std::filesystem::path& directory) override {
#if defined(__EMSCRIPTEN__) || defined(__ANDROID__) || defined(__SWITCH__) || defined(__vita__) || TARGET_OS_IPHONE
        (void)directory;
        return fail(ErrorCode::platform, "Opening a folder is not available on this platform");
#else
        std::error_code error_code;
        std::filesystem::create_directories(directory, error_code);
        // A file:// URL for the folder: forward slashes, a leading slash before a Windows drive, and
        // everything but unreserved characters percent-encoded.
        const auto absolute = std::filesystem::absolute(directory, error_code).generic_u8string();
        std::string url = "file://";
        if (!absolute.empty() && absolute.front() != u8'/') url += '/';
        for (const char8_t unit : absolute) {
            const auto c = static_cast<unsigned char>(unit);
            const bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                               c == '/' || c == '-' || c == '_' || c == '.' || c == '~' || c == ':';
            if (plain) {
                url += static_cast<char>(c);
            } else {
                constexpr std::string_view hex = "0123456789ABCDEF";
                url += '%';
                url += hex[c >> 4];
                url += hex[c & 15];
            }
        }
        if (!SDL_OpenURL(url.c_str())) return fail(ErrorCode::platform, std::string("cannot open the folder: ") + SDL_GetError());
        return {};
#endif
    }
    Result<void> open_url(const std::string& url) override {
        if (!SDL_OpenURL(url.c_str())) return fail(ErrorCode::platform, std::string("cannot open the URL: ") + SDL_GetError());
        return {};
    }
    Result<void> music(std::span<const MusicCommand> commands) override {
        if (!audio_) return {};
        for (const auto& command : commands) {
            switch (command.kind) {
            case MusicCommand::Kind::play:
                if (command.resource == music_resource_ && track_) {
                    music_running_ = true;
                    break;
                }
                if (!SDL_ClearAudioStream(music_stream_.get())) return error();
                track_.reset();
                music_resource_ = command.resource;
                music_running_ = true;
                if (auto opened = open_track(command.resource)) {
                    track_ = std::move(*opened);
                } else if (reported_.insert(command.resource).second) {
                    std::cerr << "Music " << command.resource << " cannot play: " << opened.error().message << '\n';
                }
                break;
            case MusicCommand::Kind::stop:
                music_running_ = false;
                if (!SDL_ClearAudioStream(music_stream_.get())) return error();
                if (track_) {
                    auto rewound = track_->rewind();
                    if (!rewound) return std::unexpected(rewound.error());
                }
                break;
            case MusicCommand::Kind::resume:
                if (track_) music_running_ = true;
                break;
            case MusicCommand::Kind::volume:
                if (!SDL_SetAudioStreamGain(music_stream_.get(), static_cast<float>(gain(command.volume)))) return error();
                break;
            }
        }
        return feed_music();
    }
    Result<void> play(std::span<const SoundCommand> sounds) override {
        if (!audio_) return {};
        for (const auto& sound : sounds) {
            auto voice = voices_.find(sound.resource);
            if (voice == voices_.end()) {
                if (silent_.contains(sound.resource)) continue;
                auto loaded = load_voice(sound.resource);
                if (!loaded) {
                    // A sound the data names but cannot be played (a mod's missing or non-WAV file)
                    // stays silent, like the original, instead of stopping the game.
                    silent_.insert(sound.resource);
                    std::cerr << "Sound " << sound.resource << " cannot play: " << loaded.error().message << '\n';
                    continue;
                }
                voice = voices_.emplace(sound.resource, std::move(*loaded)).first;
            }
            const double volume_gain = gain(sound.volume);
            const double left = volume_gain * (sound.pan > 0 ? gain(-sound.pan) : 1.0);
            const double right = volume_gain * (sound.pan < 0 ? gain(sound.pan) : 1.0);
            auto& cached = voice->second;
            const auto samples = scaled_voice(cached, left, right);
            auto* stream = voice->second.stream.get();
            if (!SDL_ClearAudioStream(stream) ||
                !SDL_PutAudioStreamData(stream, samples.data(), static_cast<int>(samples.size_bytes()))) {
                return error();
            }
        }
        return {};
    }
    Result<void> rumble(std::span<const RumbleCommand> commands) override {
        constexpr Uint32 duration_ms = 150;
        for (const auto& command : commands) {
            if (command.target == RumbleCommand::Target::phone) {
                trigger_phone_haptics(command.strength);
                continue;
            }
            // Best-effort: an out-of-range or rumble-incapable controller is silently skipped,
            // never an error (see RumbleCommand's own documentation).
            if (command.pad_index < 0 || static_cast<std::size_t>(command.pad_index) >= gamepads_.size()) continue;
            auto entry = gamepads_.begin();
            std::advance(entry, command.pad_index);
            const auto strength = static_cast<Uint16>(std::clamp(command.strength, 0, 100) * 65535 / 100);
            SDL_RumbleGamepad(entry->second.get(), strength, strength, duration_ms);
        }
        return {};
    }
    InputSnapshot poll() override {
        InputSnapshot input;
        SDL_Event event{};
        int typed_keys = 0; // key-downs of this poll that the text events below repeat
        bool back_to_original = false;
        while (SDL_PollEvent(&event)) {
            observe(event);
            switch (event.type) {
            case SDL_EVENT_RENDER_TARGETS_RESET:
                frame_target_.reset();
                break;
            case SDL_EVENT_RENDER_DEVICE_RESET:
#ifdef __ANDROID__
            case SDL_EVENT_DID_ENTER_FOREGROUND:
#endif
                rebuild_pending_ = true;
                break;
            case SDL_EVENT_WINDOW_MAXIMIZED:
                if (event.window.windowID == SDL_GetWindowID(window_.get())) was_maximized_ = true;
                break;
            case SDL_EVENT_WINDOW_RESTORED:
                // Leaving the maximized state (a restore from minimizing does not count).
                if (event.window.windowID == SDL_GetWindowID(window_.get()) && was_maximized_) back_to_original = true;
                break;
            case SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
                if (event.window.windowID == SDL_GetWindowID(window_.get())) back_to_original = true;
                break;
            case SDL_EVENT_QUIT:
                input.quit = true;
                break;
            case SDL_EVENT_DROP_FILE:
                if (event.drop.windowID == SDL_GetWindowID(window_.get()) && event.drop.data && !input.dropped_file) {
                    input.dropped_file = event.drop.data;
                }
                break;
            case SDL_EVENT_KEY_DOWN: {
                // Alt+Enter only asks the scripts to switch fullscreen: the Enter key stays out of the input (also
                // its repeats) until it is released.
                if (enter_consumed_ || alt_enter(event)) {
                    if (is_enter(event.key.scancode)) {
                        if (!event.key.repeat && !enter_consumed_) input.toggle_fullscreen = true;
                        enter_consumed_ = true;
                        break;
                    }
                }
                const int code = virtual_key(event.key.scancode);
                // On phones and tablets the text events carry the typed characters (with their case); the keys
                // behind them stay out of the input while a text field is open.
                if (code > 0 && text_from_events() && types_text(code)) break;
                if (code > 0) input.key_downs.push_back(code);
                if (types_text(code)) ++typed_keys;
                pointer_from_touch_ = false;
                break;
            }
            case SDL_EVENT_KEY_UP:
                if (is_enter(event.key.scancode)) enter_consumed_ = false;
                break;
            case SDL_EVENT_WINDOW_FOCUS_LOST:
                enter_consumed_ = false;
                break;
            case SDL_EVENT_TEXT_INPUT:
                for (const char* character = event.text.text; character != nullptr && *character != '\0'; ++character) {
                    const auto byte = static_cast<unsigned char>(*character);
                    if (byte < 0x20 || byte > 0x7e) continue;
                    if (typed_keys > 0) --typed_keys;
                    else input.text.push_back(*character);
                }
                break;
            case SDL_EVENT_MOUSE_MOTION:
                if (event.motion.which != SDL_TOUCH_MOUSEID) pointer_from_touch_ = false;
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
                // Fingers are read from their own events; SDL's copies as a mouse are ignored.
                if (event.button.which == SDL_TOUCH_MOUSEID) break;
                pointer_from_touch_ = false;
                if (event.button.button == SDL_BUTTON_LEFT) input.pressed = true;
                break;
            case SDL_EVENT_FINGER_DOWN:
            case SDL_EVENT_FINGER_MOTION:
            case SDL_EVENT_FINGER_UP:
            case SDL_EVENT_FINGER_CANCELED:
                touch(event.tfinger, event.type, input);
                break;
            default:
                break;
            }
        }
        if (back_to_original) return_to_original_size();
        if (rebuild_pending_ && SDL_GetTicks() >= rebuild_after_ && window_surface_ready()) {
            rebuild_pending_ = !rebuild_renderer();
            rebuild_after_ = SDL_GetTicks() + 500; // a failed attempt is repeated later, not on every poll
        }
        int key_count = 0;
        const auto* key_data = SDL_GetKeyboardState(&key_count);
        const std::span<const bool> keys(key_data, static_cast<std::size_t>(key_count));
        for (int scancode = 0; scancode < key_count; ++scancode) {
            if (!keys[static_cast<std::size_t>(scancode)]) continue;
            const int code = virtual_key(static_cast<SDL_Scancode>(scancode));
            if (code > 0) input.keys[static_cast<std::size_t>(code)] = true;
        }
        if (enter_consumed_) input.keys[0x0d] = false; // the held Enter of an Alt+Enter
        if (text_from_events()) {
            for (int code = 0; code < 256; ++code) {
                if (types_text(code)) input.keys[static_cast<std::size_t>(code)] = false;
            }
        }
        // A tap of Escape (or Android's back button) can be over before this poll reads the keyboard; it still counts.
        for (const int code : input.key_downs) {
            if (code == 0x1b) input.keys[0x1b] = true;
        }
        {
            auto& slot = dialog_slot();
            const std::scoped_lock lock(slot.mutex);
            input.chosen_file = std::exchange(slot.chosen, std::nullopt);
        }
        float window_x = 0.0f;
        float window_y = 0.0f;
        const auto buttons = SDL_GetMouseState(&window_x, &window_y);
        input.button = (buttons & SDL_BUTTON_LMASK) != 0;
        float x = 0.0f;
        float y = 0.0f;
        if (pointer_from_touch_ && touch_pointer_) {
            input.pointer_x = touch_pointer_->first;
            input.pointer_y = touch_pointer_->second;
            input.button = touching_;
        } else if (SDL_GetMouseFocus() == window_.get()
                   && SDL_RenderCoordinatesFromWindow(renderer_.get(), window_x, window_y, &x, &y)) {
            input.pointer_x = static_cast<int>(std::floor(x));
            input.pointer_y = static_cast<int>(std::floor(y));
        }
        input.button = input.button || touching_;
        input.gamepad = read_gamepads();
        input.pads = read_pads();
        // A fresh controller press also hands the pointer back from touch (state read by polling,
        // not events, so it is compared against the previous poll instead).
        if (gamepad_pressed(previous_gamepad_, input.gamepad) || pads_pressed(previous_pads_, input.pads)) {
            pointer_from_touch_ = false;
        }
        previous_gamepad_ = input.gamepad;
        previous_pads_ = input.pads;
        input.touch_active = pointer_from_touch_;
        input.screen = screen_extent();
        input.touches.reserve(touches_.size());
        for (const auto& [finger, point] : touches_) input.touches.push_back(point);
        window_placement();
        return input;
    }
    // Opens the renderer `name` (nullptr: SDL's default) on the window, with the frame's xBRZ program when it can.
    bool open_renderer(const char* name) {
        upscaler_.reset();
        renderer_.reset(SDL_CreateRenderer(window_.get(), name));
        if (!renderer_) return false;
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), viewport_.width, viewport_.height,
                                              SDL_LOGICAL_PRESENTATION_LETTERBOX)) return false;
        upscaler_ = make_frame_upscaler(*renderer_);
        return true;
    }
    // A named renderer (--renderer) or SDL's hint is taken as it is. Otherwise: SDL_GPU, then OpenGL, then the
    // system's default; the first that can also run the xBRZ shader wins (the GPU renderer fails at that on some
    // drivers, and the default renderer of Windows, Direct3D 11, never can), else the first that opens at all.
    bool choose_renderer(const std::string& requested) {
        bool opened = false;
        if (!requested.empty()) {
            opened = open_renderer(requested.c_str());
        } else if (SDL_GetHint(SDL_HINT_RENDER_DRIVER) != nullptr) {
            opened = open_renderer(nullptr);
        } else {
            const char* first_opened = nullptr;
            for (const char* name : {"gpu", "opengl"}) {
                if (open_renderer(name) && upscaler_) break;
                if (renderer_ && first_opened == nullptr) first_opened = name;
                renderer_.reset();
            }
            // Nothing offered xBRZ: the first renderer that opened, else the default.
            opened = renderer_ || (first_opened != nullptr && open_renderer(first_opened)) || open_renderer(nullptr);
        }
        if (opened) {
            const char* name = SDL_GetRendererName(renderer_.get());
            renderer_name_ = name != nullptr ? name : "";
        }
        return opened;
    }
    void make_setup_screen() {
        setup_ = std::make_unique<SdlSetupScreen>(*renderer_, viewport_, [this](const SDL_Event& event) {
            observe(event);
            // Alt+Enter switches fullscreen in the setup dialogs too, and does nothing else there.
            if (!alt_enter(event)) return false;
            if (!event.key.repeat) (void)set_fullscreen((SDL_GetWindowFlags(window_.get()) & SDL_WINDOW_FULLSCREEN) == 0);
            return true;
        });
    }
    // Whether the window has what a renderer needs: on Android its surface, which exists again only some time after
    // the app is back in the foreground.
    bool window_surface_ready() const {
#ifdef __ANDROID__
        return SDL_GetPointerProperty(SDL_GetWindowProperties(window_.get()), SDL_PROP_WINDOW_ANDROID_WINDOW_POINTER,
                                      nullptr) != nullptr;
#else
        return true;
#endif
    }
    // The renderer's graphics context or surface is gone (an Android app coming back from the background, a lost
    // Direct3D device): everything that belongs to it is dropped and the same kind of renderer is opened anew.
    bool rebuild_renderer() {
        setup_.reset();
        textures_.clear();
        unusable_.clear();
        sprite_effects_.clear();
        texture_bytes_ = 0;
        frame_target_.reset();
        text_.forget_textures();
        upscaler_.reset();
        renderer_.reset();
        if (!open_renderer(renderer_name_.c_str()) && !choose_renderer(requested_renderer_)) return false;
        SDL_SetRenderVSync(renderer_.get(), 1);
        make_setup_screen();
        return true;
    }
    // Soft keyboards (Android, iOS) type through text events; their key events only duplicate it.
    bool text_from_events() const {
#if defined(__ANDROID__) || TARGET_OS_IPHONE
        return text_input_;
#else
        return false;
#endif
    }
    static bool is_enter(SDL_Scancode scancode) { return scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER; }
    // Alt+Enter, where a window can be switched between fullscreen and window.
    bool alt_enter(const SDL_Event& event) const {
        return event.type == SDL_EVENT_KEY_DOWN && is_enter(event.key.scancode) && (event.key.mod & SDL_KMOD_ALT) != 0
            && supports_fullscreen();
    }
    // A window that is no longer maximized or fullscreen gets the original resolution (the first viewport's size,
    // where it was), not the size it had before.
    void return_to_original_size() {
        was_maximized_ = false;
        if (!supports_fullscreen() || original_size_.first <= 0 || original_size_.second <= 0) return;
        if ((SDL_GetWindowFlags(window_.get()) & (SDL_WINDOW_MAXIMIZED | SDL_WINDOW_FULLSCREEN)) != 0) {
            // Leaving fullscreen can hand the window back maximized.
            if ((SDL_GetWindowFlags(window_.get()) & SDL_WINDOW_FULLSCREEN) != 0 ||
                !SDL_RestoreWindow(window_.get()) || !SDL_SyncWindow(window_.get())) return;
        }
        WindowPlacement placement;
        placement.width = original_size_.first;
        placement.height = original_size_.second;
        if (!SDL_GetWindowPosition(window_.get(), &placement.x, &placement.y)) return;
        auto restored = restore_window(placement);
        if (!restored) std::cerr << "Window size: " << restored.error().message << '\n';
    }
    // The window corners in viewport coordinates (rounded outward).
    ScreenExtent screen_extent() const {
        int width = 0;
        int height = 0;
        float left = 0.0f;
        float top = 0.0f;
        float right = 0.0f;
        float bottom = 0.0f;
        if (!window_ || !SDL_GetWindowSize(window_.get(), &width, &height)
            || !SDL_RenderCoordinatesFromWindow(renderer_.get(), 0.0f, 0.0f, &left, &top)
            || !SDL_RenderCoordinatesFromWindow(renderer_.get(), static_cast<float>(width), static_cast<float>(height),
                                                &right, &bottom)) {
            return {};
        }
        return {static_cast<int>(std::floor(left)), static_cast<int>(std::floor(top)),
                static_cast<int>(std::ceil(right)), static_cast<int>(std::ceil(bottom))};
    }
    void set_text_input(bool active) override {
        if (active == text_input_ || !window_) return;
        text_input_ = active;
        if (active) SDL_StartTextInput(window_.get());
        else SDL_StopTextInput(window_.get());
    }
    SetupDialog& setup_dialog() override { return *setup_; }
    bool supports(RenderFilter filter) const override {
#if !SDL_VERSION_ATLEAST(3, 4, 0)
        if (filter == RenderFilter::sharp) return false;
#endif
        return filter != RenderFilter::xbrz || upscaler_ != nullptr;
    }
    bool supports_text() const override { return TextRenderer::available(); }
    std::string renderer_name() const override {
        const char* name = renderer_ ? SDL_GetRendererName(renderer_.get()) : nullptr;
        return name != nullptr ? name : "none";
    }
    bool supports_fullscreen() const override {
        return desktop_window && window_ != nullptr;
    }
    Result<void> set_fullscreen(bool enabled) override {
        // A no-op where unsupported, even if asked: Android forces SDL_WINDOW_FULLSCREEN at
        // creation, and toggling it off there would fight the platform's own fixed layout.
        if (!supports_fullscreen()) return {};
        const bool fullscreen = (SDL_GetWindowFlags(window_.get()) & SDL_WINDOW_FULLSCREEN) != 0;
        if (fullscreen == enabled) return {};
        if (!SDL_SetWindowFullscreen(window_.get(), enabled)) return error();
        return {};
    }
    std::optional<WindowPlacement> window_placement() override {
        if (!supports_fullscreen()) return std::nullopt;
        const auto flags = SDL_GetWindowFlags(window_.get());
        if (!(flags & (SDL_WINDOW_FULLSCREEN | SDL_WINDOW_MINIMIZED))) {
            normal_window_.maximized = (flags & SDL_WINDOW_MAXIMIZED) != 0;
            if (!normal_window_.maximized) {
                WindowPlacement placement;
                if (SDL_GetWindowPosition(window_.get(), &placement.x, &placement.y) &&
                    SDL_GetWindowSize(window_.get(), &placement.width, &placement.height)) {
                    normal_window_ = placement;
                }
            }
        }
        if (normal_window_.width <= 0 || normal_window_.height <= 0) return std::nullopt;
        return normal_window_;
    }
    Result<void> restore_window(const WindowPlacement& saved) override {
        if (!supports_fullscreen()) return {};
        WindowPlacement placement = saved;
        // Wayland leaves toplevel window placement to the compositor.
        const bool can_position = std::string_view(SDL_GetCurrentVideoDriver()) != "wayland";
        const SDL_Rect requested{saved.x, saved.y, saved.width, saved.height};
        SDL_DisplayID display = can_position ? SDL_GetDisplayForRect(&requested)
                                            : SDL_GetDisplayForWindow(window_.get());
        if (display == 0) display = SDL_GetPrimaryDisplay();
        SDL_Rect bounds;
        if (SDL_GetDisplayUsableBounds(display, &bounds) && bounds.w > 0 && bounds.h > 0) {
            int top = 0, left = 0, bottom = 0, right = 0;
            if (SDL_GetWindowBordersSize(window_.get(), &top, &left, &bottom, &right) &&
                left + right < bounds.w && top + bottom < bounds.h) {
                bounds.x += left;
                bounds.y += top;
                bounds.w -= left + right;
                bounds.h -= top + bottom;
            }
            placement.width = std::min(placement.width, bounds.w);
            placement.height = std::min(placement.height, bounds.h);
            placement.x = std::clamp(placement.x, bounds.x, bounds.x + bounds.w - placement.width);
            placement.y = std::clamp(placement.y, bounds.y, bounds.y + bounds.h - placement.height);
        }
        if (!SDL_SetWindowSize(window_.get(), placement.width, placement.height) ||
            (can_position && !SDL_SetWindowPosition(window_.get(), placement.x, placement.y)) ||
            !SDL_SyncWindow(window_.get())) return error();
        normal_window_ = placement;
        if (placement.maximized &&
            (!SDL_MaximizeWindow(window_.get()) || !SDL_SyncWindow(window_.get()))) return error();
        return {};
    }
    Result<void> set_render_filter(RenderFilter filter) override {
        // The default, "sharp", needs SDL 3.4; before it, the previous default.
        if (filter == RenderFilter::sharp && !supports(filter)) filter = RenderFilter::linear;
        if (!supports(filter)) filter = RenderFilter::nearest;
        if (filter == render_filter_) return {};
        render_filter_ = filter;
        return {};
    }
    Result<void> present(std::span<const DrawCommand> commands, const Viewport& viewport) override {
        viewport_ = viewport;
        if (!renderer_) return {}; // no renderer while one is being rebuilt
        // The menus draw the original's own cursor sprite (LF2_CURSOR); setup screens show the
        // system cursor until the first game frame.
        if (!cursor_hidden_) cursor_hidden_ = SDL_HideCursor();
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), viewport.width, viewport.height,
                                              SDL_LOGICAL_PRESENTATION_LETTERBOX)) return error();
        const auto clear = [&]() -> bool {
            return SDL_SetRenderDrawColor(renderer_.get(), static_cast<Uint8>(viewport.red), static_cast<Uint8>(viewport.green),
                                          static_cast<Uint8>(viewport.blue), 255) && SDL_RenderClear(renderer_.get());
        };
        const auto area = viewport.render_area.value_or(
            Rectangle{0, 0, viewport.width, viewport.height});
        if (auto prepared = sprite_effects_.prepare(*renderer_, resources_, commands, area); !prepared) return prepared;
        SDL_FRect destination{};
        if (viewport.render_area) {
            SDL_FRect picture{};
            if (!SDL_GetRenderLogicalPresentationRect(renderer_.get(), &picture)) return error();
            const float scale_x = picture.w / static_cast<float>(viewport.width);
            const float scale_y = picture.h / static_cast<float>(viewport.height);
            destination = {picture.x + static_cast<float>(area.x) * scale_x,
                           picture.y + static_cast<float>(area.y) * scale_y,
                           picture.w + static_cast<float>(area.width - viewport.width) * scale_x,
                           picture.h + static_cast<float>(area.height - viewport.height) * scale_y};
        }
        const bool xbrz = render_filter_ == RenderFilter::xbrz && upscaler_;
        if (viewport.render_area || xbrz || render_filter_ == RenderFilter::linear || render_filter_ == RenderFilter::sharp) {
            // The frame is drawn 1:1 into a texture, which is then scaled to the window by the shader or,
            // for linear, by the renderer. Scaling the sprites themselves would sample the pixels around
            // each sprite's rectangle in its sheet and show them as a frame around the sprite.
            auto* frame = frame_target(area.width, area.height);
            if (frame == nullptr || !SDL_SetRenderTarget(renderer_.get(), frame) || !clear()) return error();
            if (viewport.render_area
                && !SDL_SetRenderLogicalPresentation(renderer_.get(), 0, 0,
                                                 SDL_LOGICAL_PRESENTATION_DISABLED)) return error();
            auto drawn = draw_commands(commands, false, static_cast<float>(-area.x),
                                       static_cast<float>(-area.y));
            if (!drawn) {
                SDL_SetRenderTarget(renderer_.get(), nullptr);
                return drawn;
            }
            if (!SDL_SetRenderTarget(renderer_.get(), nullptr) || !clear()) return error();
            if (viewport.render_area
                && !SDL_SetRenderLogicalPresentation(renderer_.get(), 0, 0,
                                                 SDL_LOGICAL_PRESENTATION_DISABLED)) return error();
            const auto* target = viewport.render_area ? &destination : nullptr;
            if (xbrz) {
                if (!SDL_SetTextureScaleMode(frame, SDL_SCALEMODE_NEAREST)
                    || !upscaler_->draw(*renderer_, *frame, target)) return error();
            } else if (!SDL_SetTextureScaleMode(frame, scale_mode(render_filter_))
                       || !SDL_RenderTexture(renderer_.get(), frame, nullptr, target)) {
                return error();
            }
        } else {
            if (!clear()) return error();
            auto drawn = draw_commands(commands, false);
            if (!drawn) return drawn;
        }
        if (viewport.render_area
            && !SDL_SetRenderLogicalPresentation(renderer_.get(), viewport.width, viewport.height,
                                             SDL_LOGICAL_PRESENTATION_LETTERBOX)) return error();
        if (auto overlaid = draw_overlay(commands, viewport); !overlaid) return overlaid;
        // Before SDL 3.4 (Emscripten bundles 3.2) presenting under letterbox presentation paints black bars over the
        // finished frame, erasing the viewport colour and the overlay drawn in the bars. Present without it, then
        // restore it: input coordinates are converted with it between frames.
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED)) return error();
        if (!SDL_RenderPresent(renderer_.get())) return error();
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), viewport.width, viewport.height,
                                              SDL_LOGICAL_PRESENTATION_LETTERBOX)) return error();
        return {};
    }
private:
    // How the finished frame is scaled to the window by the renderer (xBRZ has its own shader).
    static SDL_ScaleMode scale_mode(RenderFilter filter) {
        if (filter == RenderFilter::linear) return SDL_SCALEMODE_LINEAR;
#if SDL_VERSION_ATLEAST(3, 4, 0)
        if (filter == RenderFilter::sharp) return SDL_SCALEMODE_PIXELART;
#endif
        return SDL_SCALEMODE_NEAREST;
    }
    // Draws the overlay commands over the whole window, still in viewport coordinates but not
    // clipped to the letterboxed picture: logical presentation is switched off for this pass
    // and replaced by the same scale and centring.
    Result<void> draw_overlay(std::span<const DrawCommand> commands, const Viewport& viewport) {
        const bool any = std::ranges::any_of(commands, [](const DrawCommand& command) {
            return std::visit([](const auto& item) { return item.overlay; }, command);
        });
        if (!any) return {};
        int width = 0;
        int height = 0;
        // The window's pixels (SDL_GetCurrentRenderOutputSize would give only the letterboxed picture's).
        if (!SDL_GetRenderOutputSize(renderer_.get(), &width, &height)) return error();
        const float scale = std::min(static_cast<float>(width) / static_cast<float>(viewport.width),
                                     static_cast<float>(height) / static_cast<float>(viewport.height));
        const float offset_x = (static_cast<float>(width) - static_cast<float>(viewport.width) * scale) / 2.0f / scale;
        const float offset_y = (static_cast<float>(height) - static_cast<float>(viewport.height) * scale) / 2.0f / scale;
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED)
            || !SDL_SetRenderScale(renderer_.get(), scale, scale)) return error();
        auto drawn = draw_commands(commands, true, offset_x, offset_y);
        SDL_SetRenderScale(renderer_.get(), 1.0f, 1.0f);
        if (!SDL_SetRenderLogicalPresentation(renderer_.get(), viewport.width, viewport.height,
                                              SDL_LOGICAL_PRESENTATION_LETTERBOX)) return error();
        return drawn;
    }
    // Draws the commands whose overlay flag equals `overlay` into the current render target, in
    // viewport coordinates moved by the offset.
    Result<void> draw_commands(std::span<const DrawCommand> commands, bool overlay, float offset_x = 0.0f,
                               float offset_y = 0.0f) {
        bool shadows_drawn = false;
        const bool clipped = viewport_.render_area || std::ranges::any_of(commands,
            [](const DrawCommand& command) {
                return std::visit([](const auto& item) { return item.clip.has_value(); }, command);
            });
        for (const auto& command : commands) {
            if (std::visit([](const auto& item) { return item.overlay; }, command) != overlay) continue;
            if (clipped && !overlay) {
                const auto clip = std::visit([](const auto& item) { return item.clip; }, command);
                const auto bounds =
                    clip.value_or(Rectangle{0, 0, viewport_.width, viewport_.height});
                const SDL_Rect rect{bounds.x + static_cast<int>(offset_x),
                                    bounds.y + static_cast<int>(offset_y),
                                    bounds.width, bounds.height};
                if (!SDL_SetRenderClipRect(renderer_.get(), &rect)) return error();
            }
            if (const auto* fill = std::get_if<FillCommand>(&command)) {
                const SDL_FRect area{static_cast<float>(fill->area.x) + offset_x, static_cast<float>(fill->area.y) + offset_y,
                                     static_cast<float>(fill->area.width), static_cast<float>(fill->area.height)};
                if (!SDL_SetRenderDrawBlendMode(renderer_.get(), fill->alpha == 255 ? SDL_BLENDMODE_NONE : SDL_BLENDMODE_BLEND) ||
                    !SDL_SetRenderDrawColor(renderer_.get(), static_cast<Uint8>(fill->red),
                                            static_cast<Uint8>(fill->green), static_cast<Uint8>(fill->blue),
                                            static_cast<Uint8>(fill->alpha)) ||
                    !SDL_RenderFillRect(renderer_.get(), &area)) return error();
                if (fill->alpha != 255 && !SDL_SetRenderDrawBlendMode(renderer_.get(), SDL_BLENDMODE_NONE)) return error();
                continue;
            }
            if (const auto* text = std::get_if<TextCommand>(&command)) {
                if (auto drawn = draw_text(*text, offset_x, offset_y); !drawn) return drawn;
                continue;
            }
            const auto& sprite = std::get<SpriteCommand>(command);
            if (!overlay && sprite.lighting && !shadows_drawn) {
                // All world sprites stand above the shared floor mask. Clip was applied
                // separately to every silhouette while composing it on the CPU.
                if (!SDL_SetRenderClipRect(renderer_.get(), nullptr)) return error();
                if (auto drawn = sprite_effects_.draw_shadows(*renderer_, offset_x, offset_y); !drawn) return drawn;
                if (clipped) {
                    const auto bounds = sprite.clip.value_or(Rectangle{0, 0, viewport_.width, viewport_.height});
                    const SDL_Rect rect{bounds.x + static_cast<int>(offset_x), bounds.y + static_cast<int>(offset_y), bounds.width, bounds.height};
                    if (!SDL_SetRenderClipRect(renderer_.get(), &rect)) return error();
                }
                shadows_drawn = true;
            }
            // A picture that cannot be read, decoded or uploaded is left out (reported once): one bad picture
            // in a mod must not stop the game.
            SDL_Texture* texture = sprite_texture(sprite);
            if (!texture) continue;
            auto region = sprite.source;
            // A zero rectangle requests the complete image at its natural size.
            if (region.x == 0 && region.y == 0 && region.width == 0 && region.height == 0) {
                region.width = texture->w;
                region.height = texture->h;
            }
            // Only the part of the rectangle inside the picture is drawn. Mods' sheets can be smaller than their
            // declared cells (rows x columns of w+1 by h+1), and an HP bar for more than 600 HP is wider than its
            // picture; the original's blit stopped at the edge or drew nothing, it never stopped the game.
            const int visible_width = std::min(region.width, texture->w - region.x);
            const int visible_height = std::min(region.height, texture->h - region.y);
            if (region.x < 0 || region.y < 0 || visible_width <= 0 || visible_height <= 0) {
                report_once("outside " + sprite.resource, "Picture " + sprite.resource + ": rectangle " + describe(region)
                            + " is outside the " + std::to_string(texture->w) + "x" + std::to_string(texture->h) + " picture; left out");
                continue;
            }
            const bool cut = visible_width < region.width || visible_height < region.height;
            if (cut) {
                report_once("past " + sprite.resource, "Picture " + sprite.resource + ": rectangle " + describe(region)
                            + " reaches past the " + std::to_string(texture->w) + "x" + std::to_string(texture->h)
                            + " picture; drawn up to its edge");
            }
            // A mirrored (or flipped) picture keeps its far edge in place: the cut-off part was on that side.
            const float shift_x = sprite.mirrored ? static_cast<float>(region.width - visible_width) * sprite.scale_x : 0.0f;
            const float shift_y = sprite.flipped ? static_cast<float>(region.height - visible_height) : 0.0f;
            if (sprite.lighting && sprite.lighting->character && !cut) {
                // Shading works on the picture's own pixels; when it cannot (a budget, a bad picture), the
                // sprite is drawn unshaded below.
                auto lit = sprite_effects_.shaded(*renderer_, resources_, sprite);
                if (lit) {
                    if (!SDL_SetTextureColorMod(*lit, static_cast<Uint8>(sprite.tint >> 16),
                        static_cast<Uint8>(sprite.tint >> 8), static_cast<Uint8>(sprite.tint))) return error();
                    const SDL_FRect destination{static_cast<float>(sprite.x) * sprite.scale_x
                        + static_cast<float>(sprite.translate_x) + offset_x, static_cast<float>(sprite.y) + offset_y,
                        static_cast<float>(sprite.source.width) * sprite.scale_x, static_cast<float>(sprite.source.height)};
                    if (!SDL_RenderTexture(renderer_.get(), *lit, nullptr, &destination)) return error();
                    continue;
                }
                report_once("shading " + sprite.resource, "Shading " + sprite.resource + ": " + lit.error().message + "; drawn unshaded");
            }
            const SDL_FRect source{static_cast<float>(region.x), static_cast<float>(region.y),
                                   static_cast<float>(visible_width), static_cast<float>(visible_height)};
            const SDL_FRect destination{static_cast<float>(sprite.x) * sprite.scale_x
                                            + static_cast<float>(sprite.translate_x) + offset_x + shift_x,
                                        static_cast<float>(sprite.y) + offset_y + shift_y,
                                        source.w * sprite.scale_x, source.h};
            // The tint multiplies the texture's colors (SDL keeps it on the texture, so set it every draw).
            if (!SDL_SetTextureColorMod(texture, static_cast<Uint8>((sprite.tint >> 16) & 0xff),
                                        static_cast<Uint8>((sprite.tint >> 8) & 0xff), static_cast<Uint8>(sprite.tint & 0xff))) {
                return error();
            }
            const auto flip = static_cast<SDL_FlipMode>((sprite.mirrored ? SDL_FLIP_HORIZONTAL : SDL_FLIP_NONE)
                                                        | (sprite.flipped ? SDL_FLIP_VERTICAL : SDL_FLIP_NONE));
            if (!SDL_RenderTextureRotated(renderer_.get(), texture, &source, &destination, 0.0, nullptr, flip)) {
                return error();
            }
        }
        if (clipped && !SDL_SetRenderClipRect(renderer_.get(), nullptr)) return error();
        return {};
    }
    // Reports a problem once per `key` (a picture and what is wrong with it), whatever the numbers in the message.
    void report_once(const std::string& key, const std::string& message) {
        if (reported_.size() < 256 && reported_.insert(key).second) std::cerr << message << '\n';
    }
    static std::string describe(const Rectangle& area) {
        return std::to_string(area.x) + "," + std::to_string(area.y) + " " + std::to_string(area.width) + "x"
            + std::to_string(area.height);
    }
    // The sprite's picture as a texture, from the bounded cache or loaded now; null when it cannot be read,
    // decoded or uploaded (reported once, then not tried again).
    SDL_Texture* sprite_texture(const SpriteCommand& sprite) {
        const auto key = sprite.resource + (sprite.color_key ? ":key" : ":opaque");
        if (const auto found = textures_.find(key); found != textures_.end()) return found->second.get();
        if (unusable_.contains(key)) return nullptr;
        const auto failed = [&](const std::string& why) -> SDL_Texture* {
            if (unusable_.size() < 4096) unusable_.insert(key);
            report_once("load " + sprite.resource, "Picture " + sprite.resource + ": " + why + "; left out");
            return nullptr;
        };
        auto bytes = resources_.read(sprite.resource);
        if (!bytes) return failed(bytes.error().message);
        std::unique_ptr<SDL_IOStream, CloseStream> stream(SDL_IOFromConstMem(bytes->data(), bytes->size()));
        if (!stream) return failed(SDL_GetError());
        const bool png = sprite.resource.ends_with(".png");
#if SDL_VERSION_ATLEAST(3, 4, 0)
        std::unique_ptr<SDL_Surface, DestroySurface> loaded(
            png ? SDL_LoadPNG_IO(stream.get(), false) : SDL_LoadBMP_IO(stream.get(), false));
#else
        if (png) return failed("PNG sprites require SDL 3.4");
        std::unique_ptr<SDL_Surface, DestroySurface> loaded(SDL_LoadBMP_IO(stream.get(), false));
#endif
        if (!loaded) return failed(SDL_GetError());
        std::unique_ptr<SDL_Surface, DestroySurface> surface(
            SDL_ConvertSurface(loaded.get(), png ? SDL_PIXELFORMAT_ARGB8888 : SDL_PIXELFORMAT_XRGB8888));
        if (!surface) return failed(SDL_GetError());
        if (surface->w <= 0 || surface->h <= 0 || surface->w > 8192 || surface->h > 8192) {
            return failed("image dimensions exceed limits");
        }
        const auto texture_bytes = static_cast<std::size_t>(surface->w) * static_cast<std::size_t>(surface->h) * 4;
        if (texture_bytes > max_texture_bytes) return failed("texture memory budget exceeded");
        // Bounded cache: drop every retained texture when a limit would be exceeded.
        // SDL flushes pending draws that use a texture before destroying it.
        if (textures_.size() >= max_textures || texture_bytes > max_texture_bytes - texture_bytes_) {
            textures_.clear();
            texture_bytes_ = 0;
        }
        if (sprite.color_key && !SDL_SetSurfaceColorKey(surface.get(), true, SDL_MapSurfaceRGB(surface.get(), 0, 0, 0))) {
            return failed(SDL_GetError());
        }
        Texture texture(SDL_CreateTextureFromSurface(renderer_.get(), surface.get()));
        // Sprites are always sampled without filtering; linear scaling happens on the finished frame.
        if (!texture || !SDL_SetTextureScaleMode(texture.get(), SDL_SCALEMODE_NEAREST)) return failed(SDL_GetError());
        texture_bytes_ += texture_bytes;
        return textures_.emplace(key, std::move(texture)).first->second.get();
    }
    // The text's cached texture, placed by its alignment; a background box is the text's width plus a pixel.
    Result<void> draw_text(const TextCommand& command, float offset_x, float offset_y) {
        if (command.text.empty()) return {};
        auto texture = text_.texture(*renderer_, command);
        if (!texture) {
            // A text that cannot be rendered is reported once and left out; it must not stop the game.
            if (reported_.insert(texture.error().message).second) std::cerr << "Text: " << texture.error().message << '\n';
            return {};
        }
        const auto width = static_cast<float>((*texture)->w);
        const auto height = static_cast<float>((*texture)->h);
        const float shift = command.align == TextAlign::center ? width / 2.0f : command.align == TextAlign::right ? width : 0.0f;
        // An outline adds a pixel on every side; the glyphs themselves stay where the plain text would be.
        const float margin = command.outline ? 1.0f : 0.0f;
        const SDL_FRect area{std::floor(static_cast<float>(command.x) - shift + offset_x) - margin,
                             static_cast<float>(command.y) + offset_y - margin, width, height};
        if (command.background) {
            const auto color = *command.background;
            const SDL_FRect box{area.x + margin, area.y + margin, width + 1.0f, std::max(height, 16.0f)};
            if (!SDL_SetRenderDrawColor(renderer_.get(), static_cast<Uint8>(color >> 16), static_cast<Uint8>(color >> 8),
                                        static_cast<Uint8>(color), 255)
                || !SDL_RenderFillRect(renderer_.get(), &box)) return error();
        }
        if (!SDL_RenderTexture(renderer_.get(), *texture, nullptr, &area)) return error();
        return {};
    }
    SDL_Texture* frame_target(int width, int height) {
        if (!frame_target_ || frame_target_->w != width || frame_target_->h != height) {
            // RGBA32 (bytes R, G, B, A): the shader reads the texture's own channels, and SDL's OpenGL ES
            // renderer keeps ARGB8888 textures with red and blue swapped.
            frame_target_.reset(SDL_CreateTexture(renderer_.get(), SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_TARGET,
                                                  width, height));
            // The frame is opaque, but SDL's GLES2 renderer copies the unused X byte of the XRGB sprites
            // (0) into the target's alpha, so the frame is copied to the screen without blending.
            if (frame_target_ && (!SDL_SetTextureScaleMode(frame_target_.get(), SDL_SCALEMODE_NEAREST) ||
                                  !SDL_SetTextureBlendMode(frame_target_.get(), SDL_BLENDMODE_NONE))) frame_target_.reset();
        }
        return frame_target_.get();
    }
    static std::unexpected<Error> error() { return fail(ErrorCode::platform, SDL_GetError()); }
    void open_gamepad(SDL_JoystickID id) {
        if (gamepads_.contains(id)) return;
        if (std::unique_ptr<SDL_Gamepad, CloseGamepad> handle(SDL_OpenGamepad(id)); handle) {
            gamepads_.emplace(id, std::move(handle));
        }
    }
    // Keeps the controllers open while events pass, whichever loop reads them.
    void observe(const SDL_Event& event) {
        if (event.type == SDL_EVENT_GAMEPAD_ADDED) open_gamepad(event.gdevice.which);
        else if (event.type == SDL_EVENT_GAMEPAD_REMOVED) gamepads_.erase(event.gdevice.which);
    }
    std::vector<PadState> read_pads() const {
        constexpr Sint16 threshold = 16000;
        constexpr std::array<SDL_GamepadButton, 10> numbered{
            SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
            SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, SDL_GAMEPAD_BUTTON_BACK,
            SDL_GAMEPAD_BUTTON_START, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK};
        std::vector<PadState> pads;
        for (const auto& entry : gamepads_) {
            if (pads.size() == max_pads) break;
            auto* pad = entry.second.get();
            PadState state;
            state.up = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_UP) || SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY) < -threshold;
            state.down = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_DOWN) || SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY) > threshold;
            state.left = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_LEFT) || SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) < -threshold;
            state.right = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX) > threshold;
            for (std::size_t index = 0; index < numbered.size(); ++index) {
                if (SDL_GetGamepadButton(pad, numbered[index])) state.buttons |= std::uint32_t{1} << index;
            }
            pads.push_back(state);
        }
        return pads;
    }
    GamepadButtons read_gamepads() const {
        constexpr Sint16 threshold = 16000; // of 32767: a deliberate stick push
        GamepadButtons state;
        for (const auto& entry : gamepads_) {
            auto* pad = entry.second.get();
            const auto held = [pad](SDL_GamepadButton button) { return SDL_GetGamepadButton(pad, button); };
            const auto axis = [pad](SDL_GamepadAxis which) { return SDL_GetGamepadAxis(pad, which); };
            state.up = state.up || held(SDL_GAMEPAD_BUTTON_DPAD_UP) || axis(SDL_GAMEPAD_AXIS_LEFTY) < -threshold;
            state.down = state.down || held(SDL_GAMEPAD_BUTTON_DPAD_DOWN) || axis(SDL_GAMEPAD_AXIS_LEFTY) > threshold;
            state.left = state.left || held(SDL_GAMEPAD_BUTTON_DPAD_LEFT) || axis(SDL_GAMEPAD_AXIS_LEFTX) < -threshold;
            state.right = state.right || held(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || axis(SDL_GAMEPAD_AXIS_LEFTX) > threshold;
            state.south = state.south || held(SDL_GAMEPAD_BUTTON_SOUTH);
            state.east = state.east || held(SDL_GAMEPAD_BUTTON_EAST);
            state.west = state.west || held(SDL_GAMEPAD_BUTTON_WEST);
            state.north = state.north || held(SDL_GAMEPAD_BUTTON_NORTH);
            state.start = state.start || held(SDL_GAMEPAD_BUTTON_START);
            state.back = state.back || held(SDL_GAMEPAD_BUTTON_BACK);
        }
        return state;
    }
    // Whether any button or direction in `now` is held that was not in `before` (a poll sees only
    // the current state, not a down event, so a fresh press is found by comparing polls).
    static bool gamepad_pressed(const GamepadButtons& before, const GamepadButtons& now) {
        return (now.up && !before.up) || (now.down && !before.down) || (now.left && !before.left)
            || (now.right && !before.right) || (now.south && !before.south) || (now.east && !before.east)
            || (now.west && !before.west) || (now.north && !before.north) || (now.start && !before.start)
            || (now.back && !before.back);
    }
    static bool pads_pressed(const std::vector<PadState>& before, const std::vector<PadState>& now) {
        for (std::size_t index = 0; index < now.size(); ++index) {
            static constexpr PadState empty{};
            const PadState& prior = index < before.size() ? before[index] : empty;
            if ((now[index].up && !prior.up) || (now[index].down && !prior.down) || (now[index].left && !prior.left)
                || (now[index].right && !prior.right) || (now[index].buttons & ~prior.buttons) != 0) {
                return true;
            }
        }
        return false;
    }
    // The first finger is the pointer, for menu clicks and dragging (unchanged below). Every
    // finger is also kept in `touches_` regardless, in viewport coordinates, for scripts that
    // compose their own multi-touch UI (an on-screen gamepad), letterbox bars included. A touch
    // on a black bar never becomes the pointer, so it never clicks where a finger was before.
    void touch(const SDL_TouchFingerEvent& finger, Uint32 type, InputSnapshot& input) {
        if (finger.touchID == SDL_MOUSE_TOUCHID) return;
        int width = 0;
        int height = 0;
        float x = 0.0f;
        float y = 0.0f;
        const bool converted = SDL_GetWindowSize(window_.get(), &width, &height)
            && SDL_RenderCoordinatesFromWindow(renderer_.get(), finger.x * static_cast<float>(width),
                                               finger.y * static_cast<float>(height), &x, &y);
        const bool inside = converted && x >= 0.0f && y >= 0.0f && x < static_cast<float>(viewport_.width)
            && y < static_cast<float>(viewport_.height);
        if (type == SDL_EVENT_FINGER_UP || type == SDL_EVENT_FINGER_CANCELED || !converted) {
            touches_.erase(finger.fingerID);
        } else {
            auto entry = touches_.find(finger.fingerID);
            const int id = entry != touches_.end() ? entry->second.id : next_touch_id_++;
            touches_[finger.fingerID] = TouchPoint{id, static_cast<int>(std::floor(x)), static_cast<int>(std::floor(y))};
            pointer_from_touch_ = true;
        }
        if (inside) {
            touch_pointer_ = std::pair{static_cast<int>(std::floor(x)), static_cast<int>(std::floor(y))};
            pointer_from_touch_ = true;
        }
        if (type == SDL_EVENT_FINGER_DOWN && finger_) return;
        if (type != SDL_EVENT_FINGER_DOWN && (!finger_ || *finger_ != finger.fingerID)) return;
        if (type == SDL_EVENT_FINGER_DOWN) {
            if (!inside) return;
            finger_ = finger.fingerID;
            touching_ = true;
            input.pressed = true;
        } else if (type != SDL_EVENT_FINGER_MOTION) {
            finger_.reset();
            touching_ = false;
        }
    }
    std::span<const std::int16_t> scaled_voice(const Voice& voice, double left, double right) {
        if (left == 1.0 && right == 1.0) {
            return voice.samples;
        }
        const auto found = std::find_if(scaled_voices_.begin(), scaled_voices_.end(), [&](const ScaledVoice& entry) {
            return entry.voice == &voice && entry.left == left && entry.right == right;
        });
        if (found != scaled_voices_.end()) {
            scaled_voices_.splice(scaled_voices_.begin(), scaled_voices_, found);
            return scaled_voices_.front().samples;
        }
        std::vector<std::int16_t> buffer;
        if (voice.samples.size() * sizeof(std::int16_t) > max_scaled_voice_bytes) buffer = std::move(scaled_scratch_);
        buffer.resize(voice.samples.size());
        for (std::size_t index = 0; index < buffer.size(); index += 2) {
            buffer[index] = scaled_sample(voice.samples[index], left);
            buffer[index + 1] = scaled_sample(voice.samples[index + 1], right);
        }
        const auto bytes = buffer.capacity() * sizeof(std::int16_t);
        if (bytes > max_scaled_voice_bytes) {
            scaled_scratch_ = std::move(buffer);
            return scaled_scratch_;
        }
        while (!scaled_voices_.empty()
               && (scaled_voices_.size() >= max_scaled_voices || bytes > max_scaled_voice_bytes - scaled_voice_bytes_)) {
            scaled_voice_bytes_ -= scaled_voices_.back().samples.capacity() * sizeof(std::int16_t);
            scaled_voices_.pop_back();
        }
        scaled_voice_bytes_ += bytes;
        scaled_voices_.push_front(ScaledVoice{&voice, left, right, std::move(buffer)});
        return scaled_voices_.front().samples;
    }
    static constexpr SDL_AudioSpec voice_spec{SDL_AUDIO_S16, 2, 44100};
    // Decodes a RIFF/PCM file with SDL and converts it to the voice format.
    Result<Voice> load_voice(const std::string& resource) {
        auto bytes = resources_.read(resource);
        if (!bytes) return std::unexpected(bytes.error());
        if (bytes->size() > 16 * 1024 * 1024) return fail(ErrorCode::limit, "sound exceeds 16 MiB: " + resource);
        std::unique_ptr<SDL_IOStream, CloseStream> input(SDL_IOFromConstMem(bytes->data(), bytes->size()));
        if (!input) return error();
        SDL_AudioSpec spec{};
        Uint8* decoded_data = nullptr;
        Uint32 decoded_length = 0;
        if (!SDL_LoadWAV_IO(input.get(), false, &spec, &decoded_data, &decoded_length)) {
            return fail(ErrorCode::format, "cannot decode sound " + resource + ": " + SDL_GetError());
        }
        std::unique_ptr<Uint8, FreeSdlMemory> decoded(decoded_data);
        Uint8* converted_data = nullptr;
        int converted_length = 0;
        if (!SDL_ConvertAudioSamples(&spec, decoded.get(), static_cast<int>(decoded_length), &voice_spec,
                                     &converted_data, &converted_length)) {
            return error();
        }
        std::unique_ptr<Uint8, FreeSdlMemory> converted(converted_data);
        if (converted_length < 0 || converted_length % (2 * static_cast<int>(sizeof(std::int16_t))) != 0) {
            return fail(ErrorCode::format, "invalid stereo sample count: " + resource);
        }
        Voice voice;
        voice.samples.resize(static_cast<std::size_t>(converted_length) / sizeof(std::int16_t));
        std::memcpy(voice.samples.data(), converted.get(), voice.samples.size() * sizeof(std::int16_t));
        voice.stream.reset(SDL_CreateAudioStream(&voice_spec, &voice_spec));
        if (!voice.stream || !SDL_BindAudioStream(audio_->device, voice.stream.get())) return error();
        return voice;
    }
    Result<std::unique_ptr<MusicStream>> open_track(const std::string& resource) {
        auto bytes = resources_.read(resource);
        if (!bytes) return std::unexpected(bytes.error());
        return decoder_.open(std::move(*bytes));
    }
    // Keeps about a third of a second queued; at the end the track starts again (the original
    // rewinds on EC_COMPLETE).
    Result<void> feed_music() {
        if (!music_running_ || !track_) return {};
        constexpr int target_bytes = music_rate * 4 / 3;
        std::vector<std::int16_t> samples(4096);
        int empty_reads = 0;
        while (SDL_GetAudioStreamQueued(music_stream_.get()) < target_bytes) {
            auto count = track_->read(samples);
            if (!count) {
                if (reported_.insert(music_resource_).second) {
                    std::cerr << "Music " << music_resource_ << " stopped: " << count.error().message << '\n';
                }
                track_.reset();
                return {};
            }
            if (*count == 0) {
                // An empty track would loop forever.
                if (++empty_reads > 1) return {};
                auto rewound = track_->rewind();
                if (!rewound) return std::unexpected(rewound.error());
                continue;
            }
            empty_reads = 0;
            if (!SDL_PutAudioStreamData(music_stream_.get(), samples.data(), static_cast<int>(*count * sizeof(std::int16_t)))) {
                return error();
            }
        }
        return {};
    }
    const ResourceSource& resources_;
    const MusicDecoder& decoder_;
    std::unique_ptr<QuitSdl> session_;
    std::unique_ptr<SDL_Window, DestroyWindow> window_;
    std::unique_ptr<SDL_Renderer, DestroyRenderer> renderer_;
    std::unique_ptr<SdlSetupScreen> setup_; // borrows renderer_
    std::unique_ptr<FrameUpscaler> upscaler_; // borrows renderer_; null when the renderer cannot run the shader
    Texture frame_target_;
#ifndef __EMSCRIPTEN__
    std::string dialog_filter_name_; // the dialog filter and its name are kept while the dialog is open
    SDL_DialogFileFilter dialog_filter_{};
#endif
    TextRenderer text_; // its textures belong to renderer_, so it is declared after it
    SpriteEffects sprite_effects_;
    bool cursor_hidden_ = false;
    Viewport viewport_;
    WindowPlacement normal_window_;
    std::pair<int, int> original_size_{0, 0}; // the window's size at the start, in window units
    bool was_maximized_ = false;
    std::string requested_renderer_; // --renderer, or empty
    std::string renderer_name_;      // the renderer that opened, to open it again
    bool rebuild_pending_ = false;
    Uint64 rebuild_after_ = 0;
    bool enter_consumed_ = false; // Enter belongs to an Alt+Enter until it is released
    bool text_input_ = false;
    // Touch: the finger that acts as the pointer, its last position in viewport coordinates,
    // and whether the pointer last moved by touch rather than by the mouse or a key.
    std::optional<SDL_FingerID> finger_;
    std::optional<std::pair<int, int>> touch_pointer_;
    bool touching_ = false;
    bool pointer_from_touch_ = false;
    // Every held finger, keyed by SDL's own id; `TouchPoint::id` is a small id this adapter
    // assigns instead, stable while that finger stays down.
    std::map<SDL_FingerID, TouchPoint> touches_;
    int next_touch_id_ = 1;
    // The previous poll's controller state, to tell a fresh press from one already held (see
    // gamepad_pressed/pads_pressed).
    GamepadButtons previous_gamepad_;
    std::vector<PadState> previous_pads_;
    std::map<SDL_JoystickID, std::unique_ptr<SDL_Gamepad, CloseGamepad>> gamepads_;
    RenderFilter render_filter_ = RenderFilter::nearest;
    static constexpr std::size_t max_textures = 256;
    static constexpr std::size_t max_texture_bytes = 128 * 1024 * 1024;
    std::map<std::string, Texture, std::less<>> textures_;
    std::set<std::string, std::less<>> unusable_; // texture keys whose picture could not be loaded
    std::size_t texture_bytes_ = 0;
    // Voices are destroyed before the device closes (members are destroyed in reverse order).
    std::unique_ptr<CloseAudioDevice> audio_;
    std::map<std::string, Voice, std::less<>> voices_;
    static constexpr std::size_t max_scaled_voice_bytes = 16 * 1024 * 1024;
    static constexpr std::size_t max_scaled_voices = 64;
    // A map entry's address is stable, so cached variants can identify their
    // immutable source without copying the resource name or PCM buffer.
    std::list<ScaledVoice> scaled_voices_;
    std::size_t scaled_voice_bytes_ = 0;
    std::vector<std::int16_t> scaled_scratch_;
    std::unique_ptr<SDL_AudioStream, DestroyAudioStream> music_stream_;
    std::unique_ptr<MusicStream> track_;
    std::string music_resource_;
    bool music_running_ = false;
    std::set<std::string, std::less<>> reported_;
    std::set<std::string, std::less<>> silent_; // sounds that cannot be loaded
};
}
Result<std::filesystem::path> settings_directory() {
#ifdef __SWITCH__
    return std::filesystem::path("sdmc:/switch/openlf2");
#else
    // Use the application name without an organization subdirectory.
    std::unique_ptr<char, decltype(&SDL_free)> path(SDL_GetPrefPath("", "OpenLF2"), &SDL_free);
    if (!path) return fail(ErrorCode::platform, std::string("no configuration directory: ") + SDL_GetError());
    return std::filesystem::path(reinterpret_cast<const char8_t*>(path.get()));
#endif
}
Result<std::unique_ptr<Platform>> make_platform(const ResourceSource& resources, const Viewport& viewport,
                                                const MusicDecoder& decoder, std::string_view renderer,
                                                const std::optional<WindowPlacement>& placement) {
    auto platform = std::make_unique<SdlPlatform>(resources, decoder);
    auto initialized = platform->initialize(viewport, std::string(renderer), placement);
    if (!initialized) return std::unexpected(initialized.error());
    return std::unique_ptr<Platform>(std::move(platform));
}
}
