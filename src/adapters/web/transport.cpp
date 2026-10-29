// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

// Network play in the browser. Browsers cannot open TCP sockets, so this transport hands the byte
// stream to dist/web/online.js (globalThis.OpenLF2Online), which carries it over a WebSocket to a
// relay server that pairs two players by room code. The stream, and the game protocol on top of
// it, are the same as with the TCP transport: Host waits in the page's room, and Connect takes a
// room code where the TCP transport takes an IPv4 address (an empty address means the page's room).

#include "openlf2/ports/network.hpp"
#include <algorithm>
#include <cstddef>
#include <emscripten.h>
#include <string>
#include <utility>
#include <vector>

namespace openlf2 {
namespace {
constexpr int receive_limit = 8192;       // bytes per poll, as the TCP transport's receive buffer
constexpr std::size_t send_limit = 65536; // as the TCP transport's send queue

// Every call is guarded: a script error must reach the game as a network error, never abort it.
// online_start_js returns 1 when started, 0 when online.js refused (online_error_* says why) and
// -1 when online.js is not on the page.
EM_JS(int, online_start_js, (int host, const char* address), {
    const online = globalThis.OpenLF2Online;
    if (!online) return -1;
    try {
        return online.start(host !== 0, UTF8ToString(address)) ? 1 : 0;
    } catch (error) {
        return 0;
    }
});
EM_JS(int, online_send_js, (const char* bytes, int length), {
    try {
        return globalThis.OpenLF2Online.send(HEAPU8.slice(bytes, bytes + length)) ? 1 : 0;
    } catch (error) {
        return 0;
    }
});
// Received bytes waiting, or -1 once the connection failed and nothing is left to read.
EM_JS(int, online_available_js, (), {
    try {
        return globalThis.OpenLF2Online.available();
    } catch (error) {
        return -1;
    }
});
EM_JS(int, online_take_js, (char* buffer, int capacity), {
    try {
        return globalThis.OpenLF2Online.takeInto(HEAPU8, buffer, capacity);
    } catch (error) {
        return 0;
    }
});
EM_JS(int, online_status_js, (), {
    try {
        return globalThis.OpenLF2Online.status();
    } catch (error) {
        return 0;
    }
});
// The error is read as a length probe then a copy into a caller-owned buffer, as in settings.cpp,
// to avoid depending on _malloc being exported to JS.
EM_JS(int, online_error_length_js, (), {
    try {
        return lengthBytesUTF8(String(globalThis.OpenLF2Online.error() || ""));
    } catch (error) {
        return 0;
    }
});
EM_JS(void, online_error_copy_js, (char* buffer, int capacity), {
    try {
        stringToUTF8(String(globalThis.OpenLF2Online.error() || ""), buffer, capacity);
    } catch (error) {
    }
});
EM_JS(void, online_close_js, (), {
    try {
        if (globalThis.OpenLF2Online) globalThis.OpenLF2Online.close();
    } catch (error) {
    }
});

std::string online_error(std::string fallback) {
    const int length = online_error_length_js();
    if (length <= 0) return fallback;
    std::vector<char> buffer(static_cast<std::size_t>(length) + 1);
    online_error_copy_js(buffer.data(), static_cast<int>(buffer.size()));
    return std::string(buffer.data(), static_cast<std::size_t>(length));
}

class BrowserTransport final : public NetworkTransport {
public:
    // The address of Host is the bind address and does not apply; the page's room is used.
    Result<void> listen(std::string_view, std::uint16_t) override { return start(true, {}); }
    Result<void> connect(std::string_view address, std::uint16_t) override { return start(false, address); }
    Result<void> send(std::span<const char> bytes) override {
        if (status() != NetworkStatus::connected) return fail(ErrorCode::io, "Network peer is not connected");
        if (bytes.size() > send_limit) return fail(ErrorCode::limit, "Network send queue exceeds 64 KiB");
        if (bytes.empty()) return {};
        if (online_send_js(bytes.data(), static_cast<int>(bytes.size())) != 1) {
            return fail(ErrorCode::io, online_error("Network send failed"));
        }
        return {};
    }
    Result<Bytes> poll() override {
        const int available = online_available_js();
        if (available < 0) {
            auto message = online_error("Network peer disconnected");
            close();
            return fail(ErrorCode::io, std::move(message));
        }
        if (available == 0) return Bytes{};
        Bytes bytes(static_cast<std::size_t>(std::min(available, receive_limit)));
        const int taken = online_take_js(bytes.data(), static_cast<int>(bytes.size()));
        bytes.resize(static_cast<std::size_t>(std::clamp(taken, 0, static_cast<int>(bytes.size()))));
        return bytes;
    }
    void close() noexcept override { online_close_js(); }
    NetworkStatus status() const noexcept override {
        switch (online_status_js()) {
        case 1: return NetworkStatus::listening;
        case 2: return NetworkStatus::connecting;
        case 3: return NetworkStatus::connected;
        default: return NetworkStatus::idle;
        }
    }
    std::uint16_t local_port() const noexcept override { return 0; }
private:
    static Result<void> start(bool host, std::string_view address) {
        const std::string terminated(address); // EM_JS needs a null-terminated string
        const int started = online_start_js(host ? 1 : 0, terminated.c_str());
        if (started < 0) return fail(ErrorCode::platform, "Network play needs online.js on the game page");
        if (started == 0) return fail(ErrorCode::io, online_error("Network could not start"));
        return {};
    }
};
}
Result<std::unique_ptr<NetworkTransport>> make_network_transport() {
    return std::unique_ptr<NetworkTransport>(std::make_unique<BrowserTransport>());
}
}
