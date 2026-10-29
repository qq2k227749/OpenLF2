// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/ports/compression.hpp"
#include "openlf2/ports/resources.hpp"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>

namespace openlf2 {
// A game pack (OpenLF2 extension): a ZIP file holding a whole LF2 game folder, such as a mod
// distributed with its own executable, data, sprite, bgm and bg folders. It stands in for the
// original installer. Paths match like the installer's (case-insensitive, either slash) from the
// game folder: the one holding data/data.txt nearest the top of the ZIP file. The game's executable
// is its lf2.exe, or else its only .exe (the largest when there are several: mods keep their
// pictures in it). Entries are read from the file on demand.
class PackArchive final : public ResourceSource {
public:
    static Result<std::unique_ptr<PackArchive>> open(const std::filesystem::path& path,
                                                     const Decompressor& decompressor);
    Result<Bytes> read(std::string_view path) const override;
    [[nodiscard]] std::size_t file_count() const { return entries_.size(); }
    // The pack's own name for lf2.exe (for messages).
    [[nodiscard]] const std::string& executable_name() const { return executable_; }
private:
    struct Entry {
        std::uint32_t header_offset;
        std::uint32_t compressed_size;
        std::uint32_t size;
        Compression method;
    };
    PackArchive(const std::filesystem::path& path, const Decompressor& decompressor);
    Result<void> index();
    const Decompressor& decompressor_;
    std::map<std::string, Entry, std::less<>> entries_;
    std::string executable_;
    std::uintmax_t file_size_ = 0;
    mutable std::mutex mutex_;
    mutable std::ifstream file_;
};
}
