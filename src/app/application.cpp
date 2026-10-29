// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/engine/application.hpp"
#include "openlf2/core/files.hpp"
#include "openlf2/core/json.hpp"
#include "openlf2/engine/compatibility_random.hpp"
#include "openlf2/ports/digest.hpp"
#include "openlf2/engine/frame_clock.hpp"
#include "openlf2/engine/packages.hpp"
#include "openlf2/resources/recording.hpp"
#include <cstdio>
#include <ctime>
#include "openlf2/ports/download.hpp"
#include "openlf2/ports/platform.hpp"
#include "openlf2/ports/scripts.hpp"
#include "openlf2/resources/background_data.hpp"
#include "openlf2/resources/stage_data.hpp"
#include "openlf2/resources/bitmap.hpp"
#include "openlf2/resources/installer.hpp"
#include "openlf2/resources/pack.hpp"
#include "openlf2/resources/object_data.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <exception>
#ifdef OPENLF2_SIMULATION_THREADS
#include <condition_variable>
#include <mutex>
#endif
#include <charconv>
#include <chrono>
#include <cmath>
#include <optional>
#include <cstdint>
#include <functional>
#include <iomanip>
#include <iostream>
#include <locale>
#include <map>
#include <set>
#include <sstream>
#include <thread>
#include <system_error>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

namespace openlf2 {
namespace {
void wait_milliseconds(std::uint32_t milliseconds) {
#ifdef __EMSCRIPTEN__
    emscripten_sleep(static_cast<unsigned int>(milliseconds));
#else
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
#endif
}
#ifdef __EMSCRIPTEN__
// Browsers put the canvas on screen at their display refresh. A requestAnimationFrame loop notes when the page
// last refreshed, so that frames can start just after a refresh: then each frame stays up for the same whole
// number of refreshes (two at 60 Hz), where frames started by a timer near a refresh show up once or three times.
EM_JS(void, openlf2_watch_display, (), {
    if (globalThis.OpenLF2Display) return;
    const display = globalThis.OpenLF2Display = {time: -1, count: 0};
    const refresh = (time) => { display.time = time; display.count += 1; requestAnimationFrame(refresh); };
    requestAnimationFrame(refresh);
});
// Milliseconds since the latest display refresh; -1 before the first.
EM_JS(double, openlf2_display_age, (), {
    const display = globalThis.OpenLF2Display;
    return display && display.time >= 0 ? performance.now() - display.time : -1;
});
// Waits for the next display refresh, at most `limit` milliseconds (a hidden page has no refreshes).
EM_ASYNC_JS(void, openlf2_wait_display, (int limit), {
    await new Promise((resolve) => {
        let done = false;
        const finish = () => { if (!done) { done = true; resolve(); } };
        requestAnimationFrame(finish);
        setTimeout(finish, limit);
    });
});
// Frames at normal speed on the web: started on display refreshes, 33 1/3 ms apart (30 per second, two
// refreshes at 60 Hz and four at 120 Hz; the original's 33 ms would slip a refresh every 50 frames). A frame
// due within `slack` after a refresh starts at it, which keeps the frames' place among the refreshes.
class DisplayPacer {
public:
    void restart(double now) { next_ = now; }
    [[nodiscard]] bool due(double now) {
        if (now + slack < next_) return false;
        if (now - next_ > max_lag) next_ = now - max_lag;
        next_ += step;
        return true;
    }
private:
    static constexpr double step = 100.0 / 3.0, slack = 4.0, max_lag = 100.0;
    double next_ = 0;
};
#endif
double elapsed_ms(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}
// Prefer current-input frames; sustained overload enables one frame of overlap. Fast-forward always overlaps, whatever
// the draw time: its frames come as fast as they can be made.
class FramePipeline {
public:
    bool active() const { return active_; }
    void observe(double serial_ms, bool fast) {
        constexpr std::size_t overload_frames = 8;
        constexpr double headroom_fraction = 0.8;
        if (fast != fast_) {
            reset_history();
            fast_ = fast;
            if (fast) active_ = true;
        }
        if (fast) return;
        const double budget = FrameClock::normal_step;
        const auto window = active_ ? frame_costs_.size() : overload_frames;
        cost_sum_ += serial_ms - frame_costs_[next_sample_];
        frame_costs_[next_sample_] = serial_ms;
        next_sample_ = (next_sample_ + 1) % window;
        if (sample_count_ < window) ++sample_count_;
        if (sample_count_ < window) return;
        const double average = cost_sum_ / static_cast<double>(window);
        const bool switch_mode = active_ ? average < budget * headroom_fraction : average > budget;
        if (switch_mode) {
            active_ = !active_;
            reset_history();
        }
    }
private:
    void reset_history() {
        sample_count_ = 0;
        frame_costs_ = {};
        next_sample_ = 0;
        cost_sum_ = 0;
    }
    bool active_ = false, fast_ = false;
    std::array<double, 60> frame_costs_{};
    std::size_t sample_count_ = 0, next_sample_ = 0;
    double cost_sum_ = 0;
};

struct Configuration {
    std::filesystem::path installer;
    std::optional<std::filesystem::path> pack; // --pack: a game folder as a ZIP file instead of the installer
    std::filesystem::path scripts;
    std::vector<std::filesystem::path> mods;
    std::optional<std::filesystem::path> config_directory; // --config-dir
    std::string renderer; // --renderer: the SDL renderer to use (testing); empty = the platform's choice
    std::optional<std::filesystem::path> replay; // A recording to open directly at startup.
    std::string network_role;
    std::string network_address;
    std::uint16_t network_port = 12345;
    bool headless = false;
    bool jit = OPENLF2_DEFAULT_JIT != 0;
    bool help = false;
    bool preview_backgrounds = false;
    bool preview_ending = false;
    // Lets a held mouse button stand in for touch when testing the on-screen gamepad.
    bool mouse_touch = false;
    // --default-controller: until controls are saved, player 1 starts on the first controller (the
    // consoles do this by default; PortMaster handhelds pass it).
    bool default_controller = false;
    std::vector<std::string> input_trace; // held action letters per frame, headless
    std::optional<std::uint32_t> seed;
};
// Headless input trace mini-language: udlrcbf (player 1 actions), '/' next player, digits F1-F9,
// "@X_Y" pointer, "#N" raw key, "$Nx"/"%x" controller, "^x" typed char, "&N_X_Y" touch.
Result<void> valid_trace_frame(std::string_view frame) {
    int players = 0;
    bool pointer = false;
    const auto number = [&](std::size_t& position, std::size_t most) {
        const auto first = position;
        while (position < frame.size() && frame[position] >= '0' && frame[position] <= '9') ++position;
        return position > first && position - first <= most;
    };
    for (std::size_t position = 0; position < frame.size();) {
        const char c = frame[position];
        if (c == '@') {
            ++position;
            if (pointer || !number(position, 3) || position == frame.size() || frame[position] != '_') {
                return fail(ErrorCode::format, "input trace pointer must be one @X_Y");
            }
            ++position;
            if (!number(position, 3)) return fail(ErrorCode::format, "input trace pointer must be one @X_Y");
            pointer = true;
        } else if (c == '#') {
            ++position;
            const auto first = position;
            if (!number(position, 3) || std::stoi(std::string(frame.substr(first, position - first))) > 255) {
                return fail(ErrorCode::format, "input trace raw keys must be #0-#255");
            }
        } else if (c == '%' || c == '^') {
            const auto allowed = c == '%' ? std::string_view("udlrabxysk")
                                          : std::string_view("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.");
            if (position + 1 >= frame.size() || allowed.find(frame[position + 1]) == std::string_view::npos) {
                return fail(ErrorCode::format, c == '%' ? "input trace controller buttons are %u %d %l %r %a %b %x %y %s %k"
                                                        : "input trace typed characters are ^ and a letter, digit or '.'");
            }
            position += 2;
        } else if (c == '$') {
            // "$1u": controller 1 holds a direction (u d l r); "$1b3": its button 3 (0-9).
            const bool direction = position + 2 < frame.size() && std::string_view("udlr").find(frame[position + 2]) != std::string_view::npos;
            const bool button = position + 2 < frame.size() && frame[position + 2] >= '0' && frame[position + 2] <= '9';
            if (position + 2 >= frame.size() || frame[position + 1] < '1' || frame[position + 1] > '4' || !(direction || button)) {
                return fail(ErrorCode::format, "input trace controller state is $Nu, $Nd, $Nl, $Nr or $N0-$N9 (N = 1-4)");
            }
            position += 3;
        } else if (c == '&') {
            // "&3_120_430": finger 3 held at (120, 430).
            ++position;
            if (!number(position, 3) || position == frame.size() || frame[position] != '_') {
                return fail(ErrorCode::format, "input trace touches must be &N_X_Y");
            }
            ++position;
            if (!number(position, 3) || position == frame.size() || frame[position] != '_') {
                return fail(ErrorCode::format, "input trace touches must be &N_X_Y");
            }
            ++position;
            if (!number(position, 3)) return fail(ErrorCode::format, "input trace touches must be &N_X_Y");
        } else if (c == '?') {
            // "?x": the renderer offers xBRZ; "?w": a real window (the host's " fx"/" fw" in live frames).
            if (position + 1 >= frame.size() || (frame[position + 1] != 'x' && frame[position + 1] != 'w')) {
                return fail(ErrorCode::format, "input trace renderer features are ?x and ?w");
            }
            position += 2;
        } else if (c == '~') {
            // "~60": a fixed measured FPS value (the host's " s60" in live frames).
            ++position;
            if (!number(position, 3)) return fail(ErrorCode::format, "input trace fps must be ~0-~999");
        } else if (c == '/') {
            if (++players > 7) return fail(ErrorCode::format, "input trace frames have at most eight players");
            ++position;
        } else if (std::string_view("udlrcbf123456789!").find(c) != std::string_view::npos) {
            ++position;
        } else {
            return fail(ErrorCode::format, "input trace frames use udlrcbf, 1-9, '/', @X_Y, '!', #N, %x, ^x, &N_X_Y, ?x, ?w and ~N");
        }
    }
    return {};
}
// "c*3,,r" = three frames of player 1 holding attack, one idle frame, one frame holding right.
Result<std::vector<std::string>> parse_input_trace(std::string_view specification) {
    std::vector<std::string> frames;
    std::size_t start = 0;
    while (start <= specification.size()) {
        const auto end = std::min(specification.find(',', start), specification.size());
        const auto item = specification.substr(start, end - start);
        const auto star = item.find('*');
        const auto keys = std::string(item.substr(0, star));
        std::size_t repeat = 1;
        if (star != std::string_view::npos) {
            const auto count = item.substr(star + 1);
            if (count.empty() || count.size() > 5 || count.find_first_not_of("0123456789") != std::string_view::npos) {
                return fail(ErrorCode::format, "invalid input trace repeat: " + std::string(item));
            }
            repeat = std::stoul(std::string(count));
        }
        auto valid = valid_trace_frame(keys);
        if (!valid) return fail(ErrorCode::format, valid.error().message + ": " + std::string(item));
        if (frames.size() + repeat > 100000) return fail(ErrorCode::limit, "input trace too long");
        frames.insert(frames.end(), repeat, keys);
        start = end + 1;
    }
    return frames;
}
// Case-insensitive filename match in the configuration directory; identity is confirmed by digest.
Result<std::optional<std::filesystem::path>> find_installer(const std::filesystem::path& directory) {
    std::error_code error;
    if (!std::filesystem::is_directory(directory, error)) return std::optional<std::filesystem::path>{};
    std::filesystem::directory_iterator entries(directory, error);
    if (error) return fail(ErrorCode::io, "cannot list " + directory.string() + ": " + error.message());
    std::vector<std::filesystem::path> matches;
    for (const auto& entry : entries) {
        const auto name = entry.path().filename().string();
        const bool same_name = std::ranges::any_of(installer_names, [&](std::string_view candidate) {
            return std::ranges::equal(name, candidate, [](char left, char right) {
                const auto lower = [](char c) { return c >= 'A' && c <= 'Z' ? static_cast<char>(c + ('a' - 'A')) : c; };
                return lower(left) == lower(right);
            });
        });
        if (same_name && entry.is_regular_file(error)) matches.push_back(entry.path());
    }
    if (matches.size() > 1) {
        return fail(ErrorCode::io, "several supported LF2 installers in " + directory.string() +
                                       "; keep one or pass --installer PATH");
    }
    if (matches.empty()) return std::optional<std::filesystem::path>{};
    return std::optional{matches.front()};
}
#ifndef __SWITCH__
// Candidate installer sources; identify_installer verifies content before saving.
struct InstallerSource {
    std::string_view name;
    std::string_view url;
};
constexpr std::array installer_sources{
    InstallerSource{"archive.org", "https://archive.org/download/little-fighter-2_202404/Little%20Fighter%202.rar/Little%20Fighter%202%2FLF2Setup.exe"},
    InstallerSource{"web.archive.org", "https://web.archive.org/web/20260921121026id_/https://lf2.net/LF2_v2.0a.exe"},
    InstallerSource{"lf2.net", "https://lf2.net/LF2_v2.0a.exe"},
};
std::string megabytes(std::uint64_t bytes) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << std::fixed << std::setprecision(1) << static_cast<double>(bytes) / 1'000'000.0;
    return output.str();
}
// Downloads one source on a worker thread while the dialog shows its progress. Nothing when
// the user cancels.
Result<std::optional<Bytes>> download_with_progress(SetupDialog& dialog, const Downloader& downloader,
                                                    const InstallerSource& source) {
    std::atomic<std::uint64_t> received = 0;
    std::atomic<bool> done = false;
    std::atomic<bool> stop_requested = false;
    std::optional<Result<Bytes>> result;
    std::thread worker([&] {
        try {
            result = downloader.fetch(source.url, installer_size, [&](std::uint64_t bytes, std::uint64_t) {
                received.store(bytes, std::memory_order_relaxed);
                return !stop_requested.load(std::memory_order_relaxed);
            });
        } catch (const std::exception& error) {
            result = fail(ErrorCode::io, std::string("download: ") + error.what());
        }
        done.store(true, std::memory_order_release);
    });
    struct JoinWorker {
        std::thread& thread;
        std::atomic<bool>& stop;
        ~JoinWorker() {
            stop.store(true, std::memory_order_relaxed);
            if (thread.joinable()) thread.join();
        }
    } join_worker{worker, stop_requested};
    const std::string label = "Downloading LF2_v2.0a.exe from " + std::string(source.name) + " ...\n\n";
    while (!done.load(std::memory_order_acquire)) {
        const auto bytes = received.load(std::memory_order_relaxed);
        const auto text = label + megabytes(bytes) + " of " + megabytes(installer_size) + " MB";
        auto going = dialog.progress(text, static_cast<double>(bytes) / static_cast<double>(installer_size), "Cancel");
        if (!going || !*going) {
            if (!going) return std::unexpected(going.error());
            return std::optional<Bytes>{};
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
    }
    worker.join();
    if (!*result) return std::unexpected(result->error());
    return std::optional{std::move(**result)};
}
#endif
// Handles a missing installer. Switch shows a copy-location screen; other builds offer
// a download, verify its identity and save it. Nothing when the user closes or declines.
Result<std::optional<std::filesystem::path>> offer_installer_download(const std::filesystem::path& directory,
                                                                      SetupDialog& dialog) {
    const auto location = directory.string();
#ifdef __SWITCH__
    const std::array close{std::string("Close")};
    auto shown = dialog.choose("A supported Little Fighter 2 v2.0a installer was not found.\n\n"
                               "Copy LF2_v2.0a.exe or lf2_v20a_Setup.exe to\n" + location + "\n\nand start OpenLF2 again.", close);
    if (!shown) return std::unexpected(shown.error());
    return std::optional<std::filesystem::path>{};
#else
    const std::array quit{std::string("Quit")};
    auto downloader = make_downloader();
    if (!downloader) {
        auto shown = dialog.choose("A supported Little Fighter 2 v2.0a installer was not found in\n" + location
                                           + "\n\nThis build cannot download it: put LF2_v2.0a.exe or lf2_v20a_Setup.exe there and start OpenLF2 again.", quit);
        if (!shown) return std::unexpected(shown.error());
        return std::unexpected(downloader.error());
    }
    const std::array yes_no{std::string("Yes"), std::string("No")};
    auto answer = dialog.choose("LF2_v2.0a.exe or lf2_v20a_Setup.exe was not found in\n" + location
                                        + "\n\nOpenLF2 needs its game data. Download it from archive.org now ("
                                        + megabytes(installer_size) + " MB)?", yes_no);
    if (!answer) return std::unexpected(answer.error());
    if (*answer != 0) return std::optional<std::filesystem::path>{};
    std::string failures;
    for (const auto& source : installer_sources) {
        auto bytes = download_with_progress(dialog, **downloader, source);
        if (bytes && !*bytes) return std::optional<std::filesystem::path>{};
        auto checked = bytes ? identify_installer(**bytes) : Result<void>(std::unexpected(bytes.error()));
        if (checked) {
            auto written = replace_file(directory, installer_name, **bytes);
            if (written) return std::optional{directory / installer_name};
            checked = std::unexpected(written.error());
        }
        std::cerr << source.name << ": " << checked.error().message << '\n';
        failures += std::string(source.name) + ": " + checked.error().message + "\n";
    }
    auto shown = dialog.choose("The download failed.\n" + failures + "\nPut LF2_v2.0a.exe or lf2_v20a_Setup.exe into\n" + location
                                       + "\nand start OpenLF2 again.", quit);
    if (!shown) return std::unexpected(shown.error());
    return fail(ErrorCode::io, "LF2_v2.0a.exe could not be downloaded");
#endif
}
// --installer, else the configuration directory, offering a download if missing (not headless).
Result<std::optional<std::filesystem::path>> locate_installer(const Configuration& config,
                                                              std::optional<std::reference_wrapper<SetupDialog>> dialog) {
    if (!config.installer.empty()) return std::optional{config.installer};
    std::filesystem::path directory;
    if (config.config_directory) {
        directory = *config.config_directory;
    } else if (config.headless) {
        return fail(ErrorCode::io, "headless runs need --installer PATH or --config-dir DIR holding LF2_v2.0a.exe or lf2_v20a_Setup.exe");
    } else {
        auto settings = settings_directory();
        if (!settings) return std::unexpected(settings.error());
        directory = std::move(*settings);
    }
    auto found = find_installer(directory);
    if (!found || *found) return found;
    if (!dialog) {
        return fail(ErrorCode::io, "LF2_v2.0a.exe or lf2_v20a_Setup.exe not found in " + directory.string() + "; put one there or pass --installer PATH");
    }
    return offer_installer_download(directory, *dialog);
}
Result<Configuration> configuration(std::span<const std::string> arguments,
                                    const std::filesystem::path& directory) {
    Configuration config;
    config.scripts = directory / "scripts";
    bool files_only = false;
    for (std::size_t index = 0; index < arguments.size(); ++index) {
        const auto& argument = arguments[index];
        if (argument == "--" && !files_only) {
            files_only = true;
            continue;
        }
        if (files_only || (!argument.empty() && argument.front() != '-')) {
            if (argument.empty()) return fail(ErrorCode::format, "recording path must not be empty");
            if (config.replay) return fail(ErrorCode::format, "open one recording at a time");
            config.replay = std::filesystem::path(argument);
            continue;
        }
        if (argument == "--help") config.help = true;
        else if (argument == "--headless") config.headless = true;
        else if (argument == "--jit") config.jit = true;
        else if (argument == "--no-jit") config.jit = false;
        else if (argument == "--preview-backgrounds") config.preview_backgrounds = true;
        else if (argument == "--preview-ending") config.preview_ending = true;
        else if (argument == "--mouse-touch") config.mouse_touch = true;
        else if (argument == "--default-controller") config.default_controller = true;
        else if (argument == "--host" || argument == "--join" || argument == "--port") {
            if (++index == arguments.size()) return fail(ErrorCode::format, argument + " needs a value");
            const auto& value = arguments[index];
            if (argument == "--port") {
                unsigned port = 0;
                const auto parsed = std::from_chars(value.data(), value.data() + value.size(), port);
                if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || port == 0 || port > 65535) {
                    return fail(ErrorCode::format, "--port needs a number in 1..65535");
                }
                config.network_port = static_cast<std::uint16_t>(port);
            } else {
                if (!config.network_role.empty()) return fail(ErrorCode::format, "choose either --host or --join once");
                if (value.empty() || value.size() > 15 || value.find_first_not_of("0123456789.") != std::string::npos) {
                    return fail(ErrorCode::format, argument + " needs a numeric IPv4 address");
                }
                config.network_role = argument == "--host" ? "host" : "join";
                config.network_address = value;
            }
        }
        else if (argument == "--seed") {
            if (++index == arguments.size()) return fail(ErrorCode::format, "--seed needs milliseconds");
            const auto& value = arguments[index];
            std::uint32_t seed = 0;
            const auto parsed = std::from_chars(value.data(), value.data() + value.size(), seed);
            if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) {
                return fail(ErrorCode::format, "--seed needs an unsigned 32-bit number");
            }
            config.seed = seed;
        } else if (argument == "--input-trace") {
            if (++index == arguments.size()) return fail(ErrorCode::format, "--input-trace needs frames");
            auto trace = parse_input_trace(arguments[index]);
            if (!trace) return std::unexpected(trace.error());
            config.input_trace = std::move(*trace);
            config.headless = true;
        }
        else if (argument == "--renderer") {
            if (++index == arguments.size()) return fail(ErrorCode::format, "--renderer needs a renderer name");
            config.renderer = arguments[index];
        }
        else if (argument == "--installer" || argument == "--scripts" || argument == "--mod"
                 || argument == "--config-dir" || argument == "--replay" || argument == "--pack") {
            if (++index == arguments.size()) return fail(ErrorCode::format, argument + " needs a path");
            const auto& value = arguments[index];
            if (argument == "--installer") config.installer = value;
            else if (argument == "--pack") config.pack = std::filesystem::path(value);
            else if (argument == "--scripts") config.scripts = value;
            else if (argument == "--config-dir") config.config_directory = std::filesystem::path(value);
            else if (argument == "--replay") {
                if (value.empty()) return fail(ErrorCode::format, "recording path must not be empty");
                if (config.replay) return fail(ErrorCode::format, "open one recording at a time");
                config.replay = std::filesystem::path(value);
            }
            else config.mods.emplace_back(value);
        } else return fail(ErrorCode::format, "unrecognized argument: " + argument);
    }
    if (config.replay && (!config.network_role.empty() || config.preview_backgrounds || config.preview_ending)) {
        return fail(ErrorCode::format, "a recording cannot be combined with network or preview startup");
    }
    return config;
}
class GameResources final : public ResourceSource {
public:
    GameResources(const ResourceSource& archive, Bytes executable, std::span<const PackageAsset> assets)
        : archive_(archive), executable_(std::move(executable)) {
        for (const auto& asset : assets) assets_.emplace(asset.resource, asset);
    }
    Result<Bytes> read(std::string_view path) const override {
        auto normalized = virtual_path(path);
        if (!normalized) return std::unexpected(normalized.error());
        if (const auto found = assets_.find(*normalized); found != assets_.end()) {
            auto file = package_file(found->second.root, found->second.file);
            if (!file) return std::unexpected(file.error());
            return read_file(*file, 16 * 1024 * 1024);
        }
        if (normalized->starts_with("pe/")) {
            auto name = normalized->substr(3);
            for (auto& character : name) {
                if (character >= 'a' && character <= 'z') character = static_cast<char>(character - ('a' - 'A'));
            }
            return bitmap_resource(executable_, name);
        }
        auto bytes = archive_.read(*normalized);
        // Original bitmaps are RLE8; consumers receive uncompressed BMP data.
        if (!bytes || !normalized->ends_with(".bmp")) return bytes;
        auto converted = bitmap::from_file(*bytes);
        if (!converted) converted.error().message = *normalized + ": " + converted.error().message;
        return converted;
    }
private:
    const ResourceSource& archive_;
    Bytes executable_;
    std::map<std::string, PackageAsset, std::less<>> assets_;
};
// The game data once the installer is loaded; reads fail before that, while the window
// already exists for the setup screens.
class LoadedResources final : public ResourceSource {
public:
    const ResourceSource& attach(std::unique_ptr<ResourceSource> source) {
        source_ = std::move(source);
        return *source_;
    }
    Result<Bytes> read(std::string_view path) const override {
        if (!source_) return fail(ErrorCode::io, "game data not loaded yet: " + std::string(path));
        return source_->read(path);
    }
private:
    std::unique_ptr<ResourceSource> source_;
};
// Parses original data files on request; scripts own caching and interpretation.
class OriginalDataSource final : public ScriptDataSource {
public:
    explicit OriginalDataSource(const ResourceSource& resources) : resources_(resources) {}
    Result<ScriptValue> read(ScriptData kind, std::string_view path) const override {
        if (kind == ScriptData::background) {
            auto parsed = background_data::load(resources_, path);
            if (!parsed) return std::unexpected(parsed.error());
            return background_data::to_script_value(*parsed);
        }
        if (kind == ScriptData::stage) {
            auto parsed = stage_data::load(resources_, path);
            if (!parsed) return std::unexpected(parsed.error());
            return stage_data::to_script_value(*parsed);
        }
        auto parsed = object_data::load(resources_, path);
        if (!parsed) return std::unexpected(parsed.error());
        return object_data::to_script_value(*parsed);
    }
private:
    const ResourceSource& resources_;
};
class GameRandom final : public ScriptRandom {
public:
    explicit GameRandom(std::uint32_t seed) : generator_(seed) {
        // Interim: the original fills the table when "Game Start" is chosen on the launch
        // screen, which is not implemented; here it happens once at startup.
        generator_.fill_table();
    }
    std::int32_t next(std::int32_t range) noexcept override { return generator_.next(range); }
    std::int32_t crt() noexcept override { return generator_.crt(); }
    [[nodiscard]] RandomState state() const noexcept override {
        return RandomState{generator_.table(), generator_.index()};
    }
    void restore(const RandomState& state) noexcept override { generator_.restore(state.table, state.index); }
    void reset_sequence() noexcept override { generator_.reset_sequence(); }
private:
    CompatibilityRandom generator_;
};
// Decodes one second of a music track, rewinds and decodes it again (headless checks).
Result<void> check_music(const ResourceSource& resources, const MusicDecoder& decoder, const std::string& resource) {
    auto bytes = resources.read(resource);
    if (!bytes) return std::unexpected(bytes.error());
    auto stream = decoder.open(std::move(*bytes));
    if (!stream) return std::unexpected(stream.error());
    std::vector<std::int16_t> samples(static_cast<std::size_t>(music_rate) * 2);
    for (int pass = 0; pass < 2; ++pass) {
        auto count = (*stream)->read(samples);
        if (!count) return std::unexpected(count.error());
        if (*count != samples.size()) return fail(ErrorCode::format, "music " + resource + " is shorter than a second");
        if (pass == 0) {
            auto rewound = (*stream)->rewind();
            if (!rewound) return std::unexpected(rewound.error());
        }
    }
    return {};
}
// The letters of a frame's " g" field: u d l r, a b x y for south east west north, s start, k back.
std::string gamepad_letters(const GamepadButtons& buttons) {
    std::string letters;
    const std::array<std::pair<bool, char>, 10> all{{
        {buttons.up, 'u'}, {buttons.down, 'd'}, {buttons.left, 'l'}, {buttons.right, 'r'},
        {buttons.south, 'a'}, {buttons.east, 'b'}, {buttons.west, 'x'}, {buttons.north, 'y'},
        {buttons.start, 's'}, {buttons.back, 'k'}}};
    for (const auto& [down, letter] : all) {
        if (down) letters += letter;
    }
    return letters;
}
// Recordings for the scripts: files go through the .lfr codec (key digits from lf2.exe) into the
// recording directory; a file chosen for replay is decoded and handed over once.
class HostRecordings final : public ScriptRecordings {
public:
    HostRecordings(FileDirectory& directory, std::string key, const Decompressor& decompressor, bool fixed_time)
        : directory_(directory), key_(std::move(key)), decompressor_(decompressor),
          compressor_(make_compressor()), fixed_time_(fixed_time) {}
    Result<void> save(std::string_view name, std::span<const char> block) override {
        auto file = recording::encode(block, key_, *compressor_);
        if (!file) return std::unexpected(file.error());
        return directory_.write(name, *file);
    }
    std::optional<Result<Bytes>> take() override { return std::exchange(pending_, std::nullopt); }
    [[nodiscard]] std::string local_time() const override {
        // Headless runs use a fixed time so recording names are reproducible.
        if (fixed_time_) return "20000101_000000";
        const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
        std::tm local{};
#if defined(_WIN32)
        localtime_s(&local, &now);
#else
        localtime_r(&now, &local);
#endif
        char text[32] = {};
        std::snprintf(text, sizeof(text), "%04d%02d%02d_%02d%02d%02d", local.tm_year + 1900, local.tm_mon + 1,
                      local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec);
        return text;
    }
    // A file the player chose (or --replay): decoded now, taken by the scripts later.
    void offer(const std::filesystem::path& path) {
        auto bytes = read_file(path, 16 * 1024 * 1024);
        if (!bytes) {
            std::cerr << "Replay: cannot read " << path.string() << ": " << bytes.error().message << '\n';
            pending_ = std::unexpected(bytes.error());
            return;
        }
        pending_ = recording::decode(*bytes, key_, decompressor_);
        if (!*pending_) std::cerr << "Replay: cannot decode " << path.string() << ": " << pending_->error().message << '\n';
    }
private:
    FileDirectory& directory_;
    std::string key_;
    const Decompressor& decompressor_;
    std::unique_ptr<Compressor> compressor_;
    bool fixed_time_;
    std::optional<Result<Bytes>> pending_;
};
// lf2.exe's recording key digits and version (initialized data, read at startup).
Result<std::pair<std::string, std::int32_t>> recording_constants(std::span<const char> executable) {
    auto key = executable_data(executable, recording::key_address, recording::key_capacity);
    if (!key) return std::unexpected(key.error());
    auto version = executable_data(executable, recording::version_address, 4);
    if (!version) return std::unexpected(version.error());
    std::string digits(key->begin(), std::find(key->begin(), key->end(), '\0'));
    std::int32_t number = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        number |= static_cast<std::int32_t>(static_cast<std::uint32_t>(static_cast<unsigned char>((*version)[index])) << (8 * index));
    }
    return std::pair{std::move(digits), number};
}
const ScriptValue* settings_field(const ScriptValue& value, std::string_view name) {
    const auto* table = std::get_if<ScriptTable>(&value.value);
    if (!table) return nullptr;
    for (const auto& field : *table) {
        const auto* key = std::get_if<std::string>(&field.key);
        if (key && *key == name) return &field.value;
    }
    return nullptr;
}
Result<ScriptValue> load_settings_document(const SettingsStore& settings) {
    auto text = settings.load();
    if (!text) return std::unexpected(text.error());
    if (!*text) return ScriptValue{ScriptTable{}};
    return parse_json(**text);
}
Result<std::optional<WindowPlacement>> load_window_placement(const SettingsStore& settings) {
    auto document = load_settings_document(settings);
    if (!document) return std::unexpected(document.error());
    const auto* window = settings_field(*document, "window");
    if (!window) return std::nullopt;
    WindowPlacement placement;
    for (const auto& [name, target] : std::array<std::pair<std::string_view, int*>, 4>{{
             {"x", &placement.x}, {"y", &placement.y},
             {"width", &placement.width}, {"height", &placement.height}}}) {
        const auto* field = settings_field(*window, name);
        const auto* number = field ? std::get_if<std::int32_t>(&field->value) : nullptr;
        if (!number || *number < -1000000 || *number > 1000000) return std::nullopt;
        *target = *number;
    }
    if (placement.width < 1 || placement.width > 16384 ||
        placement.height < 1 || placement.height > 16384) return std::nullopt;
    if (const auto* field = settings_field(*window, "maximized")) {
        const auto* maximized = std::get_if<bool>(&field->value);
        if (!maximized) return std::nullopt;
        placement.maximized = *maximized;
    }
    return placement;
}
Result<void> save_window_placement(SettingsStore& settings, const WindowPlacement& placement) {
    auto document = load_settings_document(settings);
    if (!document) return std::unexpected(document.error());
    auto* table = std::get_if<ScriptTable>(&document->value);
    if (!table) return fail(ErrorCode::format, "configuration must be an object");
    ScriptTable window{{"x", ScriptValue{static_cast<std::int32_t>(placement.x)}},
                       {"y", ScriptValue{static_cast<std::int32_t>(placement.y)}},
                       {"width", ScriptValue{static_cast<std::int32_t>(placement.width)}},
                       {"height", ScriptValue{static_cast<std::int32_t>(placement.height)}},
                       {"maximized", ScriptValue{placement.maximized}}};
    std::erase_if(*table, [](const ScriptField& field) {
        const auto* key = std::get_if<std::string>(&field.key);
        return key && *key == "window";
    });
    table->emplace_back(std::string("window"), ScriptValue{std::move(window)});
    auto encoded = write_json(*document);
    if (!encoded) return std::unexpected(encoded.error());
    return settings.save(*encoded);
}
// Live Lua work has one owner and one outstanding request. The main thread
// consumes owned frame commands while the worker builds the next frame. Host
// callbacks outside presentation run only after the preceding request finishes.
class Simulation {
public:
    Simulation(std::unique_ptr<ScriptRuntime> runtime, bool threaded) : runtime_(std::move(runtime)) {
#ifdef OPENLF2_SIMULATION_THREADS
        if (threaded) {
            try { worker_ = std::thread([this] { work(); }); }
            catch (const std::system_error& error) {
                std::cerr << "Simulation worker: " << error.what() << "; using synchronous execution.\n";
            }
        }
#else
        (void)threaded;
#endif
    }
    ~Simulation() {
#ifdef OPENLF2_SIMULATION_THREADS
        if (worker_.joinable()) {
            {
                const std::lock_guard lock(mutex_);
                stopping_ = true;
            }
            changed_.notify_one();
            worker_.join();
        }
#endif
    }
    bool threaded() const {
#ifdef OPENLF2_SIMULATION_THREADS
        return worker_.joinable();
#else
        return false;
#endif
    }
    Result<void> load(std::string_view bundle) {
        if (!threaded()) return runtime_->load(bundle);
        submit(std::string(bundle), true);
        auto result = finish();
        if (!result) return std::unexpected(result.error());
        return {};
    }
    Result<ScriptFrame> frame(std::string_view input) {
        if (!threaded()) {
            const auto started = std::chrono::steady_clock::now();
            auto result = runtime_->frame(input);
            frame_ms_ = elapsed_ms(started);
            return result;
        }
        start(std::string(input));
        return finish();
    }
    double last_frame_ms() const { return frame_ms_; }
    // Descriptions are used only by synchronous headless runs.
    Result<std::string> describe() { assert(!threaded()); return runtime_->describe(); }
    void start(std::string input) { submit(std::move(input), false); }
    Result<ScriptFrame> finish() {
#ifdef OPENLF2_SIMULATION_THREADS
        std::unique_lock lock(mutex_);
        assert(pending_);
        changed_.wait(lock, [this] { return finished_; });
        pending_ = finished_ = false;
        if (auto failure = std::exchange(failure_, nullptr)) std::rethrow_exception(failure);
        return std::move(result_);
#else
        return fail(ErrorCode::unsupported, "simulation worker is unavailable");
#endif
    }
private:
    void submit(std::string input, bool loading) {
#ifdef OPENLF2_SIMULATION_THREADS
        {
            const std::lock_guard lock(mutex_);
            assert(threaded() && !pending_);
            input_ = std::move(input);
            loading_ = loading;
            pending_ = requested_ = true;
        }
        changed_.notify_one();
#else
        (void)input;
        (void)loading;
#endif
    }
#ifdef OPENLF2_SIMULATION_THREADS
    void work() {
        while (true) {
            std::unique_lock lock(mutex_);
            changed_.wait(lock, [this] { return stopping_ || requested_; });
            if (stopping_) break;
            requested_ = false;
            lock.unlock();
            Result<ScriptFrame> result;
            std::exception_ptr failure;
            const auto started = std::chrono::steady_clock::now();
            try {
                if (loading_) {
                    auto loaded = runtime_->load(input_);
                    if (!loaded) result = std::unexpected(loaded.error());
                } else {
                    result = runtime_->frame(input_);
                }
            } catch (...) { failure = std::current_exception(); }
            lock.lock();
            frame_ms_ = loading_ ? 0.0 : elapsed_ms(started);
            result_ = std::move(result);
            failure_ = std::move(failure);
            finished_ = true;
            lock.unlock();
            changed_.notify_one();
        }
        // LuaJIT sampling and Lua destruction stay on the thread that loaded it.
        runtime_.reset();
    }
#endif
    std::unique_ptr<ScriptRuntime> runtime_;
    double frame_ms_ = 0.0;
#ifdef OPENLF2_SIMULATION_THREADS
    std::mutex mutex_;
    std::condition_variable changed_;
    std::string input_;
    Result<ScriptFrame> result_;
    std::exception_ptr failure_;
    bool loading_ = false, pending_ = false, requested_ = false, finished_ = false, stopping_ = false;
    std::thread worker_;
#endif
};

Result<void> run(const Configuration& config) {
    std::vector<std::filesystem::path> packages{config.scripts / "base"};
    packages.insert(packages.end(), config.mods.begin(), config.mods.end());
    auto scripts = load_packages(packages);
    if (!scripts) return std::unexpected(scripts.error());
    const auto music_decoder = make_music_decoder();
    // Declared in lifetime order: the window reads resources, which read the archive, which
    // uses the decompressor.
    auto decompressor = make_decompressor();
    // The original installer, or a game pack (--pack) in its place.
    std::unique_ptr<ResourceSource> archive;
    std::size_t archive_files = 0;
    LoadedResources game_data;
    // The user configuration: --config-dir, otherwise SDL's per-user directory; headless runs
    // without --config-dir keep it in memory so traces never touch the user's file. On the web,
    // the browser's filesystem (--config-dir /data, an Emscripten MEMFS directory) is temporary,
    // so interactive runs use the browser's own localStorage instead, which survives a reload;
    // --config-dir there still locates the uploaded installer and (still temporary) recordings.
    std::unique_ptr<SettingsStore> settings;
#ifdef __EMSCRIPTEN__
    settings = config.headless ? make_memory_settings() : make_browser_settings();
#else
    if (config.config_directory) {
        settings = make_file_settings(*config.config_directory);
    } else if (config.headless) {
        settings = make_memory_settings();
    } else {
        auto directory = settings_directory();
        if (!directory) return std::unexpected(directory.error());
        settings = make_file_settings(std::move(*directory));
    }
#endif
    // Open the window before installer setup, restoring saved desktop placement if present.
    std::unique_ptr<Platform> platform;
    if (!config.headless) {
        const Viewport window{scripts->window.width, scripts->window.height, 0, 0, 0};
        auto placement = load_window_placement(*settings);
        if (!placement) std::cerr << "Window settings: " << placement.error().message << '\n';
        auto made = make_platform(game_data, window, *music_decoder, config.renderer,
                                  placement ? *placement : std::nullopt);
        if (!made) return std::unexpected(made.error());
        platform = std::move(*made);
        std::cout << "Renderer: " << platform->renderer_name()
                  << (platform->supports(RenderFilter::xbrz) ? " (xBRZ upscaling available)\n" : "\n");
        if (!platform->supports_text()) std::cout << "Translated languages unavailable: this build has no SDL3_ttf\n";
    }
    if (config.pack) {
        auto opened = PackArchive::open(*config.pack, *decompressor);
        if (!opened) return std::unexpected(opened.error());
        std::cout << "Game pack " << config.pack->filename().string() << ": " << (*opened)->file_count()
                  << " files, executable " << (*opened)->executable_name() << '\n';
        archive_files = (*opened)->file_count();
        archive = std::move(*opened);
    } else {
        auto installer = locate_installer(config, platform ? std::optional{std::ref(platform->setup_dialog())} : std::nullopt);
        if (!installer) return std::unexpected(installer.error());
        if (!*installer) {
            std::cerr << "OpenLF2 needs LF2_v2.0a.exe or lf2_v20a_Setup.exe; stopping.\n";
            return {};
        }
        auto opened = InstallerArchive::open(**installer, *decompressor);
        if (!opened) return std::unexpected(opened.error());
        archive_files = (*opened)->file_count();
        archive = std::move(*opened);
    }
    auto executable = archive->read("lf2.exe");
    if (!executable) return std::unexpected(executable.error());
    auto constants = recording_constants(*executable);
    if (!constants) return std::unexpected(constants.error());
    const auto& resources = game_data.attach(std::make_unique<GameResources>(*archive, std::move(*executable), scripts->assets));
    auto bootstrap = read_file(config.scripts / "runtime/bootstrap.lua", 1024 * 1024);
    if (!bootstrap) return std::unexpected(bootstrap.error());
    const auto menu_seed = config.seed.value_or(static_cast<std::uint32_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count()));
    OriginalDataSource original_data(resources);
    GameRandom random(menu_seed);
    // Recordings go to recording/ beside config.json (headless without --config-dir: memory).
    std::unique_ptr<FileDirectory> recording_directory;
    if (config.config_directory) {
        recording_directory = make_file_directory(*config.config_directory / "recording");
    } else if (config.headless) {
        recording_directory = make_memory_directory();
    } else {
        auto directory = settings_directory();
        if (!directory) return std::unexpected(directory.error());
        recording_directory = make_file_directory(*directory / "recording");
    }
    HostRecordings recordings(*recording_directory, constants->first, *decompressor, config.headless);
    if (config.replay) recordings.offer(*config.replay);
    auto network = make_network_transport();
    if (!network) return std::unexpected(network.error());
    auto runtime = make_script_runtime(config.jit, resources, original_data, random, *settings, recordings, **network);
    if (!runtime) return std::unexpected(runtime.error());
    // Settings are host-generated literals; screens decide what an entry point means.
    const auto sources = bundle_source(scripts->modules) + std::string(bootstrap->begin(), bootstrap->end());
    // Content identity excludes local paths/settings and seeds, includes the resolved mod sources.
    const auto identity = sources + (config.jit ? "\nJIT=1" : "\nJIT=0");
    auto profile = sha256(std::span<const char>(identity.data(), identity.size()));
    if (!profile) return std::unexpected(profile.error());
    auto network_options = std::string(config.headless ? ", network_trace=true" : "") + ", network_port=" + std::to_string(config.network_port) +
        (config.network_role.empty() ? std::string{} : ", network_role=\"" + config.network_role +
            "\", network_address=\"" + config.network_address + "\"");
#if defined(__EMSCRIPTEN__)
    // The browser's transport (dist/web/online.js) reaches a relay room of up to 8 players
    // (base/game/room), not another computer.
    network_options += ", network_relay=true";
#endif
    const auto bundle = "local runtime_settings = {menu_seed=" + std::to_string(menu_seed) +
        ", network_profile=\"" + *profile + "\", recording_version=" + std::to_string(constants->second) + network_options +
#if defined(__SWITCH__) || defined(__vita__)
        ", default_controller=true" +
#else
        (config.default_controller ? ", default_controller=true" : "") +
#endif
        (config.preview_backgrounds ? ", start_screen=\"backgrounds\"" : "") +
        (config.preview_ending ? ", start_screen=\"ending\"" : "") +
        (config.replay ? ", start_screen=\"replay\"" : "") +
        (config.mouse_touch ? ", mouse_touch=true" : "") +
        // A game pack (--pack) brings its own menu pictures: screens drop what they cut from the original's.
        (config.pack ? ", game_pack=true" : "") + "}\n" + sources;
    Simulation simulation(std::move(*runtime), !config.headless);
    auto loaded = simulation.load(bundle);
    if (!loaded) return std::unexpected(loaded.error());
    if ((*network)->status() == NetworkStatus::listening) {
        std::cout << "Network listening on " << config.network_address << ':' << (*network)->local_port() << std::endl;
    }
    if (config.headless) {
        // Runs each traced frame (or one idle frame) and loads every drawn resource once.
        const auto frames = config.input_trace.empty() ? std::vector<std::string>{""} : config.input_trace;
        std::set<std::string, std::less<>> loaded_resources;
        std::set<std::string, std::less<>> played_sounds;
        std::size_t sound_count = 0;
        // Music: each requested track is decoded for one second (and again after a rewind); the
        // commands are followed to report what would be playing at the end.
        std::set<std::string, std::less<>> decoded_music;
        std::string music_track;
        bool music_running = false;
        bool music_available = true;
        for (std::size_t index = 0; index < frames.size(); ++index) {
            auto frame = simulation.frame(frames[index]);
            if (!frame) return std::unexpected(frame.error());
            // A trace frame denotes a committed script tick, not a socket polling attempt.
            while (frame->waiting) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                frame = simulation.frame(frames[index]);
                if (!frame) return std::unexpected(frame.error());
            }
            for (const auto& command : frame->commands) {
                const auto* sprite = std::get_if<SpriteCommand>(&command);
                if (sprite == nullptr || loaded_resources.contains(sprite->resource)) continue;
                auto bytes = resources.read(sprite->resource);
                if (!bytes) return std::unexpected(bytes.error());
                loaded_resources.insert(sprite->resource);
            }
            for (const auto& sound : frame->sounds) {
                ++sound_count;
                if (played_sounds.contains(sound.resource)) continue;
                auto bytes = resources.read(sound.resource);
                if (!bytes) return std::unexpected(bytes.error());
                played_sounds.insert(sound.resource);
            }
            for (const auto& music : frame->music) {
                if (music.kind == MusicCommand::Kind::play) {
                    music_track = music.resource;
                    music_running = true;
                } else if (music.kind == MusicCommand::Kind::stop) {
                    music_running = false;
                } else if (music.kind == MusicCommand::Kind::resume) {
                    music_running = !music_track.empty();
                }
                if (music.kind != MusicCommand::Kind::play || !music_available || decoded_music.contains(music.resource)) continue;
                auto checked = check_music(resources, *music_decoder, music.resource);
                if (!checked && checked.error().code == ErrorCode::dependency) {
                    music_available = false;
                    continue;
                }
                if (!checked) return std::unexpected(checked.error());
                decoded_music.insert(music.resource);
            }
            for (const auto& action : frame->actions) {
                std::cout << "frame " << index << ": action " << action << '\n';
            }
        }
        if (!config.input_trace.empty()) {
            auto description = simulation.describe();
            if (!description) return std::unexpected(description.error());
            std::cout << *description << '\n';
        }
        std::cout << "Indexed " << archive_files << " files; " << frames.size()
                  << " Lua frame(s), " << loaded_resources.size() << " distinct bitmap resources loaded, "
                  << sound_count << " sound(s) requested from " << played_sounds.size() << " file(s); "
                  << (music_available ? std::to_string(decoded_music.size()) + " music track(s) decoded"
                                      : std::string("music not built"))
                  << "; music=" << (music_track.empty() ? "none" : music_track) << ' '
                  << (music_running ? "playing" : "stopped") << ".\n";
        for (const auto& name : recording_directory->written()) std::cout << "Recording saved: " << name << '\n';
        return {};
    }
    // Preserve the startup frame used by live runs.
    auto initial_frame = simulation.frame("");
    if (!initial_frame) return std::unexpected(initial_frame.error());
    std::optional<ScriptFrame> ready_frame;
    FramePipeline pipeline;
    std::cout << "Keys come from the Control Settings (" << settings->location()
              << ", else data/control.txt); F1-F9 are the original's function keys.\n"
                 "Close the window to exit.\n";
    // Script frames (logic and drawing) follow the original 33 ms schedule, independent of
    // the display refresh rate (the web build: 33 1/3 ms on display refreshes, see DisplayPacer);
    // events are still pumped on every loop iteration.
    const auto origin = std::chrono::steady_clock::now();
    const auto milliseconds = [origin] {
        return static_cast<std::uint32_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - origin).count());
    };
    FrameClock clock(milliseconds());
#ifdef __EMSCRIPTEN__
    openlf2_watch_display();
    DisplayPacer pacer;
    bool display_paced = false; // the previous frame started on a display refresh (DisplayPacer)
#endif
    bool fast = false;
    bool waiting_network = false;
    // "Show FPS" (OpenLF2 extension): an exponential moving average of the real time between
    // script frames actually run, smoothing single-frame jitter while still reflecting when the
    // host cannot keep up with the 33/3 ms schedule. 0 until the second frame has a real delta.
    double measured_fps = 0.0;
    std::optional<std::uint32_t> last_frame_time_ms;
    // Key-down events gathered across polls until the next script frame (bounded).
    std::vector<int> key_downs;
    // The dialog answers on a poll between two script frames; keep the file until a frame runs.
    std::optional<std::string> chosen_file;
    std::optional<std::filesystem::path> dropped_file;
    bool accept_replay_drop = initial_frame->replay_drop.value_or(false);
    // Taps, typed text and controller buttons that came and went between two script frames.
    bool pressed = false;
    bool toggle_fullscreen = false; // Alt+Enter
    std::string typed;
    GamepadButtons gamepad;
    std::vector<PadState> pads; // the same, per controller
    const auto save_window = [&] {
        const auto placement = platform->window_placement();
        if (!placement) return;
        auto saved = save_window_placement(*settings, *placement);
        if (!saved) std::cerr << "Window settings: " << saved.error().message << '\n';
    };
    while (true) {
        const auto input = platform->poll();
        if (input.chosen_file) chosen_file = input.chosen_file;
        if (input.dropped_file && accept_replay_drop && !dropped_file) {
            const auto& name = *input.dropped_file;
            auto path = std::filesystem::path(std::u8string(name.begin(), name.end()));
            auto extension = path.extension().string();
            for (auto& character : extension) {
                if (character >= 'A' && character <= 'Z') character = static_cast<char>(character + ('a' - 'A'));
            }
            if (extension == ".lfr") dropped_file = std::move(path);
        }
        for (const int code : input.key_downs) {
            if (key_downs.size() < 256) key_downs.push_back(code);
        }
        pressed = pressed || input.pressed;
        toggle_fullscreen = toggle_fullscreen || input.toggle_fullscreen;
        if (typed.size() + input.text.size() <= 256) typed += input.text;
        gamepad.up = gamepad.up || input.gamepad.up;
        gamepad.down = gamepad.down || input.gamepad.down;
        gamepad.left = gamepad.left || input.gamepad.left;
        gamepad.right = gamepad.right || input.gamepad.right;
        gamepad.south = gamepad.south || input.gamepad.south;
        gamepad.east = gamepad.east || input.gamepad.east;
        gamepad.west = gamepad.west || input.gamepad.west;
        gamepad.north = gamepad.north || input.gamepad.north;
        gamepad.start = gamepad.start || input.gamepad.start;
        gamepad.back = gamepad.back || input.gamepad.back;
        if (pads.size() < input.pads.size()) pads.resize(input.pads.size());
        for (std::size_t index = 0; index < input.pads.size(); ++index) {
            pads[index].up = pads[index].up || input.pads[index].up;
            pads[index].down = pads[index].down || input.pads[index].down;
            pads[index].left = pads[index].left || input.pads[index].left;
            pads[index].right = pads[index].right || input.pads[index].right;
            pads[index].buttons |= input.pads[index].buttons;
        }
        if (input.quit) break;
        // Drain a queued frame immediately when returning to current-frame
        // rendering. Its input tick was already scheduled and simulated.
        const bool draining = ready_frame && !ready_frame->waiting && !pipeline.active();
#ifdef __EMSCRIPTEN__
        // At normal speed, frames start on display refreshes. F5's fast mode and network rooms keep the timer:
        // a room polls the network every few milliseconds and starts its frames after a refresh itself (" v").
        const bool display_frame = !draining && !waiting_network && !fast;
        if (display_frame) {
            const double now = emscripten_get_now();
            if (!display_paced) pacer.restart(now);
            display_paced = true;
            if (!pacer.due(now)) {
                openlf2_wait_display(100);
                continue;
            }
        } else {
            display_paced = false;
        }
        if (!display_frame && !draining && !waiting_network && !clock.due(milliseconds(), fast)) {
#else
        if (!draining && !waiting_network && !clock.due(milliseconds(), fast)) {
#endif
            const auto wait = clock.sleep_ms(milliseconds(), fast);
            if (wait > 0) wait_milliseconds(wait);
            continue;
        }
        const auto frame_started = std::chrono::steady_clock::now();
        if (!waiting_network && !draining) {
            const auto now_ms = milliseconds();
            if (last_frame_time_ms && now_ms > *last_frame_time_ms) {
                const double instant_fps = 1000.0 / static_cast<double>(now_ms - *last_frame_time_ms);
                measured_fps = measured_fps <= 0.0 ? instant_fps : measured_fps * 0.9 + instant_fps * 0.1;
            }
            last_frame_time_ms = now_ms;
        }
        // Held keys as "k" and comma-separated virtual-key codes, then " m" with the pointer
        // position and left button; scripts map them to players and screens.
        std::string held = "k";
        // A key that went down and up between two frames still counts as held for this one (a soft keyboard's
        // Backspace and Enter are over in an instant), like a key the original latched on its key-down message.
        auto down = input.keys;
        for (const int code : key_downs) {
            if (code > 0 && static_cast<std::size_t>(code) < down.size()) down[static_cast<std::size_t>(code)] = true;
        }
        for (std::size_t code = 0; code < down.size(); ++code) {
            if (!down[code]) continue;
            if (held.size() > 1) held += ',';
            held += std::to_string(code);
        }
        held += " m" + std::to_string(input.pointer_x) + ',' + std::to_string(input.pointer_y) + ','
            + (input.button || pressed ? '1' : '0');
        if (!draining) pressed = false;
        // Then " p" and the key-down codes since the last script frame, in order.
        if (!key_downs.empty()) {
            held += " p";
            for (std::size_t index = 0; index < key_downs.size(); ++index) {
                if (index > 0) held += ',';
                held += std::to_string(key_downs[index]);
            }
            if (!draining) key_downs.clear();
        }
        // Then " w" when Alt+Enter asked to switch between fullscreen and window.
        if (toggle_fullscreen) {
            held += " w";
            if (!draining) toggle_fullscreen = false;
        }
        // Then " t" and the typed text as character codes, and " g" and the controller buttons.
        if (!typed.empty()) {
            held += " t";
            for (std::size_t index = 0; index < typed.size(); ++index) {
                if (index > 0) held += ',';
                held += std::to_string(static_cast<unsigned char>(typed[index]));
            }
            if (!draining) typed.clear();
        }
        if (const auto buttons = gamepad_letters(gamepad); !buttons.empty()) held += " g" + buttons;
        if (!draining) gamepad = {};
        // Then " j" and each controller as its directions (u d l r), ':' and its buttons in hex, comma separated.
        if (!pads.empty()) {
            held += " j";
            for (std::size_t index = 0; index < pads.size(); ++index) {
                const auto& pad = pads[index];
                if (index > 0) held += ',';
                if (pad.up) held += 'u';
                if (pad.down) held += 'd';
                if (pad.left) held += 'l';
                if (pad.right) held += 'r';
                std::array<char, 16> hex{};
                std::snprintf(hex.data(), hex.size(), ":%x", static_cast<unsigned>(pad.buttons));
                held += hex.data();
            }
            if (!draining) pads.clear();
        }
        // Then " h" for a touch-driven UI (an on-screen gamepad): '1' or '0' for whether the
        // pointer above last moved by touch, then each held finger as its id, x and y, comma
        // separated (not accumulated across polls, like the pointer above: a finger lifted
        // between two script frames never reaches a script frame as held).
        if (input.touch_active || !input.touches.empty()) {
            held += input.touch_active ? " h1" : " h0";
            for (const auto& touch : input.touches) {
                held += ',' + std::to_string(touch.id) + ':' + std::to_string(touch.x) + ':' + std::to_string(touch.y);
            }
        }
        // Then " e" and the window edges in viewport coordinates (left,top,right,bottom), beyond the
        // viewport when the picture is letterboxed.
        if (input.screen.right > input.screen.left && input.screen.bottom > input.screen.top) {
            held += " e" + std::to_string(input.screen.left) + ',' + std::to_string(input.screen.top) + ','
                + std::to_string(input.screen.right) + ',' + std::to_string(input.screen.bottom);
        }
        // Then " f" and capability letters: x = xBRZ upscaling, p = pixel-art ("sharp") scaling, w = a real window whose
        // fullscreen state means something to toggle, t = TrueType text for the translated
        // languages. The options page uses these to decide what to offer.
        std::string capabilities;
        if (platform->supports(RenderFilter::xbrz)) capabilities += 'x';
        if (platform->supports(RenderFilter::sharp)) capabilities += 'p';
        if (platform->supports_fullscreen()) capabilities += 'w';
        if (platform->supports_text()) capabilities += 't';
        if (!capabilities.empty()) held += " f" + capabilities;
        // Then " s" and the measured frames per second (an exponential moving average of the
        // real time between script frames actually run, not the nominal 33/3 ms tick), for the
        // "Show FPS" option (OpenLF2 extension; the original has no such display).
        held += " s" + std::to_string(static_cast<long long>(std::lround(measured_fps)));
#ifdef __EMSCRIPTEN__
        // Then " v" and how many milliseconds ago the display last refreshed: a network room starts its frames
        // just after a refresh (base/game/room.lua), as DisplayPacer does at normal speed.
        if (const double age = openlf2_display_age(); age >= 0) {
            held += " v" + std::to_string(static_cast<long long>(std::lround(std::min(age, 600000.0))));
        }
#endif
        if (pipeline.active() && !ready_frame) {
            // Introduce the bounded queue by retaining one completed frame. The
            // previous image stays on screen; its actions/audio are not repeated.
            auto next = simulation.frame(held);
            if (!next) return std::unexpected(next.error());
            ready_frame = std::move(*next);
            waiting_network = ready_frame->waiting;
            auto music = platform->music({});
            if (!music) return std::unexpected(music.error());
            continue;
        }
        const bool queued = ready_frame.has_value();
        const auto call_started = std::chrono::steady_clock::now();
        auto frame = queued ? Result<ScriptFrame>{std::move(*ready_frame)} : simulation.frame(held);
        const double blocking_simulation_ms = queued ? 0.0 : elapsed_ms(call_started);
        ready_frame.reset();
        if (!frame) return std::unexpected(frame.error());
        waiting_network = frame->waiting;
        if (waiting_network) {
            // Keep streamed audio supplied while retaining the last presented image.
            auto music = platform->music({});
            if (!music) return std::unexpected(music.error());
            if (queued) {
                auto next = simulation.frame(held);
                if (!next) return std::unexpected(next.error());
                ready_frame = std::move(*next);
                waiting_network = ready_frame->waiting;
            }
            wait_milliseconds(1);
            continue;
        }
        if (frame->render_filter) {
            auto applied = platform->set_render_filter(*frame->render_filter);
            if (!applied) return std::unexpected(applied.error());
        }
        if (frame->text_input) platform->set_text_input(*frame->text_input);
        accept_replay_drop = frame->replay_drop.value_or(false);
        if (dropped_file) {
            if (accept_replay_drop) recordings.offer(*dropped_file);
            dropped_file.reset();
        }
        if (frame->fullscreen) {
            auto applied = platform->set_fullscreen(*frame->fullscreen);
            if (!applied) return std::unexpected(applied.error());
        }
        if (chosen_file) {
            recordings.offer(std::filesystem::path(std::u8string(chosen_file->begin(), chosen_file->end())));
            chosen_file.reset();
        }
        for (const auto& action : frame->actions) {
            if (action == "quit") {
                save_window();
                return {};
            }
            if (action == "open_recordings") {
                if (const auto folder = recording_directory->path()) {
                    auto shown = platform->open_folder(*folder);
                    if (!shown) std::cerr << "Recording folder: " << shown.error().message << '\n';
                } else {
                    std::cerr << "Recording folder: recordings are kept in memory in this run\n";
                }
                continue;
            }
            if (action == "replay") {
                auto shown = platform->choose_file(recording_directory->path(), frame->file_dialog.value_or(FileDialogText{}));
                if (!shown) std::cerr << "Replay: " << shown.error().message << '\n';
                continue;
            }
            if (action == "open_website" || action == "open_original_website"
                || action == "open_recording_help" || action == "open_special_moves"
                || action == "open_marti_website" || action == "open_starsky_website") {
                const auto url = action == "open_recording_help" ? "https://lf2.net/record/record.html"
                    : action == "open_special_moves" ? "https://lf2.net/control.html"
                    : action == "open_marti_website" ? "http://martiwong.com"
                    : action == "open_starsky_website" ? "https://lf2.net/starsky"
                    : action == "open_original_website" ? "https://lf2.net/"
                    : "https://openlf2.github.io/OpenLF2/";
                auto shown = platform->open_url(url);
                if (!shown) std::cerr << "Website: " << shown.error().message << '\n';
                continue;
            }
            std::cout << "Requested screen: " << action << " (not implemented yet)\n";
        }
        // All settings, replay offers and window actions above happen while Lua
        // is idle. Resource reads during presentation use immutable archive data
        // and independent decompression streams.
        const bool overlapping = pipeline.active() && !draining;
        if (overlapping) simulation.start(std::move(held));
        auto presented = platform->present(frame->commands, frame->viewport);
        if (!presented) return std::unexpected(presented.error());
#if defined(__EMSCRIPTEN__)
        // A page (or a test) that sets globalThis.OpenLF2FrameTimes to an array learns when each frame is shown.
        EM_ASM({
            const times = globalThis.OpenLF2FrameTimes;
            if (Array.isArray(times)) {
                times.push(performance.now());
                if (times.length > 2000) times.splice(0, times.length - 1000);
            }
        });
#endif
        auto music = platform->music(frame->music);
        if (!music) return std::unexpected(music.error());
        auto played = platform->play(frame->sounds);
        if (!played) return std::unexpected(played.error());
        auto rumbled = platform->rumble(frame->rumbles);
        if (!rumbled) return std::unexpected(rumbled.error());
        if (frame->fast) fast = *frame->fast;
        // Estimate serial cost even while requests overlap. Exclude blocking
        // simulation time already included in the main-thread elapsed time.
        const double main_ms = elapsed_ms(frame_started) - blocking_simulation_ms;
        if (overlapping) {
            auto next = simulation.finish();
            if (!next) return std::unexpected(next.error());
            waiting_network = next->waiting;
            ready_frame = std::move(*next);
        }
        if (!draining && !waiting_network) {
            const double serial_ms = main_ms + simulation.last_frame_ms();
            if (simulation.threaded()) pipeline.observe(serial_ms, fast);
        }
    }
    save_window();
    return {};
}
}
int run_application(std::span<const std::string> arguments, const std::filesystem::path& directory) {
    try {
        auto config = configuration(arguments, directory);
        if (!config) { std::cerr << config.error().message << '\n'; return 1; }
        if (config->help) {
            std::cout << "openlf2 [--installer PATH | --pack FILE.zip] [--scripts DIR] [--mod DIR] [--headless] [--jit|--no-jit]\n"
                         "        [--preview-backgrounds] [--preview-ending] [--input-trace FRAMES] [--seed MS]\n"
                         "        [--config-dir DIR] [--replay FILE] [--renderer NAME] [--mouse-touch] [--default-controller] [FILE.lfr]\n"
                         "--mouse-touch (off by default): a held mouse button stands in for one finger on the\n"
                         "        on-screen gamepad, to try it without a touch screen.\n"
                         "--default-controller (off by default; always on for consoles): until controls are saved, player 1 uses the\n"
                         "        first controller instead of the keyboard.\n"
                         "JIT is enabled by default on desktop and Android builds; --no-jit uses the interpreter.\n"
                         "--jit opts in on builds where JIT is available but disabled by default.\n"
                         "--renderer picks the SDL renderer for testing, e.g. opengl, opengles2, gpu or software; without it the GPU\n"
                         "        renderer is tried first (SDL_RENDER_DRIVER overrides).\n"
                         "--host IPv4 / --join IPv4 starts an OpenLF2 network game; --port N defaults to 12345.\n"
                         "FILE.lfr or --replay FILE opens a recording immediately, without navigating the menus.\n"
                         "        Use -- before a file name beginning with '-'; open one recording per process.\n"
                         "--config-dir keeps config.json there instead of the per-user directory (headless: in memory).\n"
                         "--input-trace runs headless frames, e.g. \"c*2,,r\" (letters udlrcbf, 1-9 for F1-F9, '/' before the next player's letters,\n"
                         "        @X_Y moves the pointer, ! holds the left button, #N holds virtual key N, %a holds controller button A\n"
                         "        (u d l r a b x y s k), ^x types the character x).\n"
                         "Without --installer, LF2_v2.0a.exe or lf2_v20a_Setup.exe is looked up in the configuration directory; when it is\n"
                         "        missing, a window offers to download it there (headless runs need --installer or --config-dir).\n"
                         "--pack plays a game folder packed as a ZIP file (an LF2 mod with its own executable, data and pictures)\n"
                         "        instead of the original installer.\n"
                         "Only explicitly selected, trusted local mod packages are supported.\n";
            return 0;
        }
        auto result = run(*config);
        if (!result) { std::cerr << result.error().message << '\n'; return 1; }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Application failure: " << error.what() << '\n';
        return 1;
    }
}
}
