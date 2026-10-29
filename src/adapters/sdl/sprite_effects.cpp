// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/detail/sdl/sprite_effects.hpp"
#include <SDL3/SDL.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <numbers>
#include <vector>

namespace openlf2 {
namespace {
struct DestroyTexture { void operator()(SDL_Texture* p) const { SDL_DestroyTexture(p); } };
struct DestroySurface { void operator()(SDL_Surface* p) const { SDL_DestroySurface(p); } };
struct CloseStream { void operator()(SDL_IOStream* p) const { SDL_CloseIO(p); } };
using Texture = std::unique_ptr<SDL_Texture, DestroyTexture>;
using Surface = std::unique_ptr<SDL_Surface, DestroySurface>;
auto error() { return fail(ErrorCode::platform, SDL_GetError()); }
constexpr std::size_t cache_budget = 64 * 1024 * 1024;
constexpr std::size_t sheet_budget = 128 * 1024 * 1024;
constexpr std::size_t max_pixels = cache_budget / 4;
// Coordinates and strides are nonnegative after clipping/bounds validation.
// Convert each operand before arithmetic, including on 32-bit targets.
std::size_t buffer_index(int x, int y, int stride) {
    return static_cast<std::size_t>(y) * static_cast<std::size_t>(stride) + static_cast<std::size_t>(x);
}
struct Key {
    std::string resource;
    std::array<int, 4> source;
    int ground_gap;
    float azimuth, elevation, scale_x;
    int blur;
    bool keyed, mirrored, flipped, character, shadow;
    auto operator<=>(const Key&) const = default;
};
struct Entry {
    Texture shaded;
    Rectangle shadow_bounds{}; // relative to the sprite's top left
    std::vector<std::uint8_t> shadow;
    std::size_t bytes = 0;
    std::uint64_t used = 0;
};
struct Light {
    float x, y, z;
    explicit Light(const SpriteLighting& settings) {
        const float az = settings.azimuth * std::numbers::pi_v<float> / 180.0f;
        const float el = settings.elevation * std::numbers::pi_v<float> / 180.0f;
        x = std::cos(el) * std::sin(az); y = std::sin(el); z = std::cos(el) * std::cos(az);
    }
};
// A separable box blur with zero padding. Running sums keep work linear in mask
// size; this runs only when creating a cached silhouette, never on cache hits.
Result<void> soften(Entry& entry, int radius) {
    if (radius == 0 || entry.shadow.empty()) return {};
    const auto old = entry.shadow_bounds;
    const int width = old.width + radius * 2, height = old.height + radius * 2;
    const auto size = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    if (size > max_pixels) return fail(ErrorCode::limit, "blurred shadow exceeds memory budget");
    std::vector<std::uint8_t> padded(size), horizontal(size);
    for (int y = 0; y < old.height; ++y)
        std::memcpy(padded.data() + buffer_index(radius, y + radius, width),
            entry.shadow.data() + buffer_index(0, y, old.width), static_cast<std::size_t>(old.width));
    const int diameter = radius * 2 + 1;
    for (int y = 0; y < height; ++y) {
        int sum = 0;
        for (int x = 0; x < radius; ++x) sum += padded[buffer_index(x, y, width)];
        for (int x = 0; x < width; ++x) {
            if (x + radius < width) sum += padded[buffer_index(x + radius, y, width)];
            horizontal[buffer_index(x, y, width)] = static_cast<std::uint8_t>((sum + diameter / 2) / diameter);
            if (x >= radius) sum -= padded[buffer_index(x - radius, y, width)];
        }
    }
    for (int x = 0; x < width; ++x) {
        int sum = 0;
        for (int y = 0; y < radius; ++y) sum += horizontal[buffer_index(x, y, width)];
        for (int y = 0; y < height; ++y) {
            if (y + radius < height) sum += horizontal[buffer_index(x, y + radius, width)];
            padded[buffer_index(x, y, width)] = static_cast<std::uint8_t>((sum + diameter / 2) / diameter);
            if (y >= radius) sum -= horizontal[buffer_index(x, y - radius, width)];
        }
    }
    entry.shadow = std::move(padded);
    entry.shadow_bounds = {old.x - radius, old.y - radius, width, height};
    return {};
}
Result<Texture> texture(SDL_Renderer& renderer, int width, int height, const void* pixels) {
    Texture result(SDL_CreateTexture(&renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, width, height));
    if (!result || !SDL_UpdateTexture(result.get(), nullptr, pixels, width * 4)
        || !SDL_SetTextureBlendMode(result.get(), SDL_BLENDMODE_BLEND)
        || !SDL_SetTextureScaleMode(result.get(), SDL_SCALEMODE_NEAREST)) return error();
    return result;
}
}

struct SpriteEffects::Impl {
    std::map<Key, Entry> entries;
    std::map<std::string, Surface, std::less<>> sheets;
    std::size_t bytes = 0, sheet_bytes = 0;
    std::uint64_t clock = 0;
    Texture shadow_texture;
    std::vector<std::uint8_t> mask;
    Rectangle area{};
    bool has_shadow = false;

    Result<SDL_Surface*> sheet(const ResourceSource& resources, const std::string& name) {
        if (const auto found = sheets.find(name); found != sheets.end()) return found->second.get();
        auto data = resources.read(name);
        if (!data) return std::unexpected(data.error());
        std::unique_ptr<SDL_IOStream, CloseStream> stream(SDL_IOFromConstMem(data->data(), data->size()));
        if (!stream) return error();
        const bool png = name.ends_with(".png");
#if SDL_VERSION_ATLEAST(3, 4, 0)
        Surface loaded(png ? SDL_LoadPNG_IO(stream.get(), false) : SDL_LoadBMP_IO(stream.get(), false));
#else
        if (png) return fail(ErrorCode::unsupported, "PNG sprites require SDL 3.4: " + name);
        Surface loaded(SDL_LoadBMP_IO(stream.get(), false));
#endif
        if (!loaded) return error();
        if (loaded->w <= 0 || loaded->h <= 0 || loaded->w > 8192 || loaded->h > 8192)
            return fail(ErrorCode::limit, "image dimensions exceed limits");
        const auto size = static_cast<std::size_t>(loaded->w) * static_cast<std::size_t>(loaded->h) * 4;
        if (size > sheet_budget) return fail(ErrorCode::limit, "lighting source memory budget exceeded");
        Surface converted(SDL_ConvertSurface(loaded.get(), SDL_PIXELFORMAT_RGBA32));
        if (!converted) return error();
        // LF2 BMPs use black color keys, not their file's unused alpha byte.
        if (!png) {
            auto* pixels = static_cast<std::uint8_t*>(converted->pixels);
            for (int y = 0; y < converted->h; ++y)
                for (int x = 0; x < converted->w; ++x) pixels[buffer_index(x * 4 + 3, y, converted->pitch)] = 255;
        }
        if (sheets.size() >= 32 || size > sheet_budget - sheet_bytes) { sheets.clear(); sheet_bytes = 0; }
        auto* result = converted.get();
        sheets.emplace(name, std::move(converted)); sheet_bytes += size;
        return result;
    }

    Result<Entry*> get(SDL_Renderer& renderer, const ResourceSource& resources, const SpriteCommand& sprite) {
        const auto& settings = *sprite.lighting;
        if (!std::isfinite(settings.azimuth) || !std::isfinite(settings.elevation)
            || settings.azimuth < -180 || settings.azimuth > 180 || settings.elevation < 12 || settings.elevation > 89
            || settings.shadow_blur < 0 || settings.shadow_blur > 8
            || !std::isfinite(settings.shadow_opacity) || settings.shadow_opacity < 0 || settings.shadow_opacity > 1
            || !std::isfinite(sprite.scale_x) || sprite.scale_x <= 0 || sprite.scale_x > 32)
            return fail(ErrorCode::format, "invalid sprite lighting");
        const Key key{sprite.resource, {sprite.source.x, sprite.source.y, sprite.source.width, sprite.source.height},
            settings.ground_y - sprite.y, settings.azimuth, settings.elevation, sprite.scale_x, settings.shadow_blur,
            sprite.color_key, sprite.mirrored, sprite.flipped, settings.character, settings.casts_shadow};
        if (auto found = entries.find(key); found != entries.end()) { found->second.used = ++clock; return &found->second; }
        auto image = sheet(resources, sprite.resource);
        if (!image) return std::unexpected(image.error());
        const auto& region = sprite.source;
        const int w = region.width, h = region.height;
        if (region.x < 0 || region.y < 0 || w <= 0 || h <= 0 || w > (*image)->w || h > (*image)->h
            || region.x > (*image)->w - w || region.y > (*image)->h - h)
            return fail(ErrorCode::format, "lit sprite rectangle outside texture: " + sprite.resource);
        const auto pixels = static_cast<std::size_t>(w) * static_cast<std::size_t>(h);
        if (pixels > max_pixels) return fail(ErrorCode::limit, "lit sprite exceeds memory budget");
        std::vector<std::uint8_t> rgba(pixels * 4);
        const auto* source = static_cast<const std::uint8_t*>((*image)->pixels);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            const int sx = region.x + (sprite.mirrored ? w - 1 - x : x);
            const int sy = region.y + (sprite.flipped ? h - 1 - y : y);
            auto* pixel = rgba.data() + buffer_index(x, y, w) * 4;
            std::memcpy(pixel, source + buffer_index(sx * 4, sy, (*image)->pitch), 4);
            if (sprite.color_key && pixel[0] == 0 && pixel[1] == 0 && pixel[2] == 0) pixel[3] = 0;
        }
        const auto alpha = [&](int x, int y) -> float {
            return x >= 0 && x < w && y >= 0 && y < h && rgba[buffer_index(x, y, w) * 4 + 3] >= 128 ? 1.0f : 0.0f;
        };
        Entry entry;
        const Light light(settings);
        if (settings.casts_shadow && std::abs(light.z) > 0.0001f) {
            const float across = -light.x / light.y, up = light.z / light.y;
            const float ground = static_cast<float>(key.ground_gap);
            const float top_x = ground * across, bottom_x = (ground - static_cast<float>(h)) * across;
            const float top_y = ground - ground * up, bottom_y = ground - (ground - static_cast<float>(h)) * up;
            const float width = static_cast<float>(w) * sprite.scale_x;
            const int left = static_cast<int>(std::floor(std::min(top_x, bottom_x)));
            const int right = static_cast<int>(std::ceil(std::max(top_x, bottom_x) + width));
            const int top = static_cast<int>(std::floor(std::min(top_y, bottom_y)));
            const int bottom = static_cast<int>(std::ceil(std::max(top_y, bottom_y)));
            entry.shadow_bounds = {left, top, right - left, bottom - top};
            const auto size = static_cast<std::size_t>(right - left) * static_cast<std::size_t>(bottom - top);
            if (size > max_pixels) return fail(ErrorCode::limit, "projected shadow exceeds memory budget");
            entry.shadow.resize(size);
            // Invert the affine projection once per destination pixel, then soften the
            // coverage before caching it. The shared frame mask takes maximum coverage.
            for (int y = top; y < bottom; ++y) for (int x = left; x < right; ++x) {
                const float height = (ground - (static_cast<float>(y) + 0.5f)) / up;
                const int sy = static_cast<int>(std::floor(ground - height));
                const int sx = static_cast<int>(std::floor((static_cast<float>(x) + 0.5f - height * across) / sprite.scale_x));
                if (alpha(sx, sy) != 0) entry.shadow[buffer_index(x - left, y - top, right - left)] = 255;
            }
            if (auto blurred = soften(entry, settings.shadow_blur); !blurred) return std::unexpected(blurred.error());
            entry.bytes += entry.shadow.size();
        }
        if (settings.character) {
            auto lit = rgba;
            for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
                auto* pixel = lit.data() + buffer_index(x, y, w) * 4;
                if (pixel[3] == 0) continue;
                float gx = 0, gy = 0;
                for (const int r : {1, 2}) {
                    gx += (alpha(x + r, y - r) + 2 * alpha(x + r, y) + alpha(x + r, y + r)
                        - alpha(x - r, y - r) - 2 * alpha(x - r, y) - alpha(x - r, y + r)) * 0.25f;
                    gy += (alpha(x - r, y + r) + 2 * alpha(x, y + r) + alpha(x + r, y + r)
                        - alpha(x - r, y - r) - 2 * alpha(x, y - r) - alpha(x + r, y - r)) * 0.25f;
                }
                const float nx = -gx * 0.9f, ny = gy * 0.9f;
                const float length = std::sqrt(nx * nx + ny * ny + 1.0f);
                const float wrap = std::clamp((nx * light.x + ny * light.y + light.z) / length * 0.5f + 0.5f, 0.0f, 1.0f);
                const float height = std::clamp(static_cast<float>(key.ground_gap - y) / 550.0f, 0.0f, 1.0f);
                const float sky = std::clamp(ny / length * 0.5f + 0.5f + height * 0.9f, 0.0f, 1.0f);
                constexpr std::array<float, 3> sun{1.10f, 1.02f, 0.90f}, upper{0.62f, 0.68f, 0.80f}, lower{0.55f, 0.52f, 0.50f};
                for (std::size_t channel = 0; channel < 3; ++channel) {
                    const float ambient = (lower[channel] + (upper[channel] - lower[channel]) * sky) * 0.66f;
                    pixel[channel] = static_cast<std::uint8_t>(std::clamp(std::lround(static_cast<float>(pixel[channel])
                        * (ambient + sun[channel] * 1.48f * wrap * wrap)), 0L, 255L));
                }
            }
            auto made = texture(renderer, w, h, lit.data());
            if (!made) return std::unexpected(made.error());
            entry.shaded = std::move(*made); entry.bytes += pixels * 4;
        }
        if (entry.bytes > cache_budget) return fail(ErrorCode::limit, "sprite effects exceed memory budget");
        while (!entries.empty() && (entries.size() >= 512 || entry.bytes > cache_budget - bytes)) {
            auto oldest = std::ranges::min_element(entries, {}, [](const auto& pair) { return pair.second.used; });
            bytes -= oldest->second.bytes; entries.erase(oldest);
        }
        entry.used = ++clock; bytes += entry.bytes;
        return &entries.emplace(key, std::move(entry)).first->second;
    }
};

SpriteEffects::SpriteEffects() : impl_(std::make_unique<Impl>()) {}
SpriteEffects::~SpriteEffects() = default;
void SpriteEffects::clear() { impl_ = std::make_unique<Impl>(); }
Result<SDL_Texture*> SpriteEffects::shaded(SDL_Renderer& renderer, const ResourceSource& resources, const SpriteCommand& sprite) {
    auto entry = impl_->get(renderer, resources, sprite);
    if (!entry) return std::unexpected(entry.error());
    return (*entry)->shaded.get();
}
Result<void> SpriteEffects::prepare(SDL_Renderer& renderer, const ResourceSource& resources,
                                    std::span<const DrawCommand> commands, Rectangle area) {
    auto& state = *impl_;
    state.has_shadow = false;
    bool active = false, shadows = false;
    for (const auto& command : commands) {
        const auto* sprite = std::get_if<SpriteCommand>(&command);
        if (!sprite || sprite->overlay || !sprite->lighting) continue;
        active = true;
        shadows |= sprite->lighting->casts_shadow && sprite->lighting->shadow_opacity > 0;
    }
    if (!active) {
        if (!state.entries.empty() || state.shadow_texture) clear();
        return {};
    }
    if (!shadows) return {}; // Shading alone needs no per-frame floor mask or upload.
    if (area.width <= 0 || area.height <= 0 || static_cast<std::size_t>(area.width) * static_cast<std::size_t>(area.height) > max_pixels)
        return fail(ErrorCode::limit, "shadow mask exceeds memory budget");
    state.area = area;
    state.mask.assign(static_cast<std::size_t>(area.width) * static_cast<std::size_t>(area.height) * 4, 0);
    for (const auto& command : commands) {
        const auto* sprite = std::get_if<SpriteCommand>(&command);
        if (!sprite || sprite->overlay || !sprite->lighting || !sprite->lighting->casts_shadow
            || sprite->lighting->shadow_opacity == 0) continue;
        // A sprite whose silhouette cannot be made (a rectangle past its picture, a budget) casts no shadow;
        // it is still drawn, unshaded if need be.
        auto cached = state.get(renderer, resources, *sprite);
        if (!cached) continue;
        const auto& entry = **cached;
        const auto bounds = entry.shadow_bounds;
        const int x0 = static_cast<int>(std::floor(static_cast<float>(sprite->x) * sprite->scale_x)) + sprite->translate_x + bounds.x;
        const int y0 = sprite->y + bounds.y;
        const auto clip = sprite->clip.value_or(area);
        const int left = std::max({x0, area.x, clip.x}), top = std::max({y0, area.y, clip.y});
        const int right = std::min({x0 + bounds.width, area.x + area.width, clip.x + clip.width});
        const int bottom = std::min({y0 + bounds.height, area.y + area.height, clip.y + clip.height});
        // Opacity is applied after the cached blur, so changing it reuses the same
        // silhouette and never affects character shading or legacy stage shadows.
        const auto opacity = static_cast<unsigned>(std::lround(sprite->lighting->shadow_opacity * 255.0f));
        for (int y = top; y < bottom; ++y) for (int x = left; x < right; ++x) {
            const auto coverage = static_cast<std::uint8_t>((static_cast<unsigned>(
                entry.shadow[buffer_index(x - x0, y - y0, bounds.width)]) * opacity + 127) / 255);
            if (!coverage) continue;
            auto& alpha = state.mask[buffer_index(x - area.x, y - area.y, area.width) * 4 + 3];
            alpha = std::max(alpha, coverage);
            state.has_shadow = true;
        }
    }
    if (state.has_shadow) {
        if (!state.shadow_texture || state.shadow_texture->w != area.width || state.shadow_texture->h != area.height) {
            auto made = texture(renderer, area.width, area.height, state.mask.data());
            if (!made) return std::unexpected(made.error());
            state.shadow_texture = std::move(*made);
        } else if (!SDL_UpdateTexture(state.shadow_texture.get(), nullptr, state.mask.data(), area.width * 4)) return error();
    }
    return {};
}
Result<void> SpriteEffects::draw_shadows(SDL_Renderer& renderer, float offset_x, float offset_y) {
    const auto& state = *impl_;
    if (!state.has_shadow) return {};
    const SDL_FRect destination{static_cast<float>(state.area.x) + offset_x, static_cast<float>(state.area.y) + offset_y,
        static_cast<float>(state.area.width), static_cast<float>(state.area.height)};
    if (!SDL_RenderTexture(&renderer, state.shadow_texture.get(), nullptr, &destination)) return error();
    return {};
}
}
