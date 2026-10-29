// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/core/binary.hpp"
#include "openlf2/ports/compression.hpp"
#include <array>
#include <algorithm>
#include <cstddef>
#include <limits>
#include <bzlib.h>
#include <zlib.h>

namespace openlf2 {
namespace {
// NSIS's DEFLATE variant omits NLEN from stored blocks. Keep it separate
// from zlib streams, whose integrity/size checks must not be relaxed.
class NsisBits {
public:
    explicit NsisBits(std::span<const char> input) : input_(input) {}
    std::uint32_t read(unsigned count) {
        while (bits_ < count) {
            if (cursor_ == input_.size()) throw FormatError("truncated NSIS DEFLATE stream");
            buffer_ |= std::uint32_t{static_cast<unsigned char>(input_[cursor_++])} << bits_;
            bits_ += 8;
        }
        const auto value = buffer_ & ((std::uint32_t{1} << count) - 1);
        buffer_ >>= count;
        bits_ -= count;
        return value;
    }
    void align() { buffer_ = 0; bits_ = 0; }
    std::span<const char> stored(std::size_t size) {
        if (size > input_.size() - cursor_) throw FormatError("truncated NSIS stored block");
        const auto result = input_.subspan(cursor_, size);
        cursor_ += size;
        return result;
    }
    bool finished() const { return cursor_ == input_.size(); }
private:
    std::span<const char> input_;
    std::size_t cursor_ = 0;
    std::uint32_t buffer_ = 0;
    unsigned bits_ = 0;
};
class NsisHuffman {
public:
    explicit NsisHuffman(std::span<const unsigned> lengths) {
        for (const auto length : lengths) {
            if (length > 15) throw FormatError("invalid NSIS Huffman length");
            ++counts_[length];
        }
        counts_[0] = 0;
        int remaining = 1;
        std::array<unsigned, 16> offsets{};
        for (unsigned length = 1; length <= 15; ++length) {
            remaining = remaining * 2 - static_cast<int>(counts_[length]);
            if (remaining < 0) throw FormatError("oversubscribed NSIS Huffman tree");
            if (length < 15) offsets[length + 1] = offsets[length] + counts_[length];
        }
        for (unsigned symbol = 0; symbol < lengths.size(); ++symbol) {
            if (lengths[symbol]) symbols_[offsets[lengths[symbol]]++] = symbol;
        }
    }
    unsigned decode(NsisBits& bits) const {
        unsigned code = 0, first = 0, index = 0;
        for (unsigned length = 1; length <= 15; ++length) {
            code |= bits.read(1);
            if (code >= first && code - first < counts_[length]) return symbols_[index + code - first];
            index += counts_[length];
            first = (first + counts_[length]) << 1;
            code <<= 1;
        }
        throw FormatError("invalid NSIS Huffman code");
    }
private:
    std::array<unsigned, 16> counts_{};
    std::array<unsigned, 288> symbols_{};
};
Result<Bytes> decode_nsis(std::span<const char> input, std::size_t expected_size) {
    constexpr std::size_t maximum = 64 * 1024 * 1024;
    constexpr std::array<unsigned, 29> length_base{
        3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
    constexpr std::array<unsigned, 29> length_extra{
        0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
    constexpr std::array<unsigned, 30> distance_base{
        1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
    constexpr std::array<unsigned, 30> distance_extra{
        0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
    try {
        NsisBits bits(input);
        Bytes output;
        const auto limit = expected_size ? expected_size : maximum;
        output.reserve(expected_size ? expected_size : 65536);
        bool last = false;
        while (!last) {
            last = bits.read(1) != 0;
            const auto kind = bits.read(2);
            if (kind == 0) {
                bits.align();
                const auto size = bits.read(16);
                if (size > limit - output.size()) throw FormatError("NSIS decoded size exceeds limit");
                const auto stored = bits.stored(size);
                output.insert(output.end(), stored.begin(), stored.end());
                continue;
            }
            std::array<unsigned, 288> literals{};
            std::array<unsigned, 32> distances{};
            if (kind == 1) {
                for (unsigned i = 0; i < literals.size(); ++i) literals[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
                distances.fill(5);
            } else if (kind == 2) {
                const auto literal_count = bits.read(5) + 257;
                const auto distance_count = bits.read(5) + 1;
                const auto code_count = bits.read(4) + 4;
                if (literal_count > 286) throw FormatError("invalid NSIS literal count");
                constexpr std::array<unsigned, 19> order{16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
                std::array<unsigned, 19> code_lengths{};
                for (unsigned i = 0; i < code_count; ++i) code_lengths[order[i]] = bits.read(3);
                const NsisHuffman codes(code_lengths);
                std::array<unsigned, 320> lengths{};
                unsigned count = 0;
                while (count < literal_count + distance_count) {
                    const auto code = codes.decode(bits);
                    unsigned repeat = 1, value = code;
                    if (code == 16) {
                        if (count == 0) throw FormatError("NSIS repeat without previous length");
                        value = lengths[count - 1]; repeat = bits.read(2) + 3;
                    } else if (code == 17) { value = 0; repeat = bits.read(3) + 3; }
                    else if (code == 18) { value = 0; repeat = bits.read(7) + 11; }
                    if (repeat > literal_count + distance_count - count) throw FormatError("excessive NSIS code lengths");
                    while (repeat--) lengths[count++] = value;
                }
                std::copy_n(lengths.begin(), literal_count, literals.begin());
                std::copy_n(lengths.begin() + static_cast<std::ptrdiff_t>(literal_count), distance_count, distances.begin());
            } else throw FormatError("invalid NSIS block type");
            if (!literals[256]) throw FormatError("missing NSIS end-of-block code");
            const NsisHuffman literal_codes(literals), distance_codes(distances);
            while (true) {
                const auto symbol = literal_codes.decode(bits);
                if (symbol == 256) break;
                if (symbol < 256) {
                    if (output.size() == limit) throw FormatError("NSIS decoded size exceeds limit");
                    output.push_back(static_cast<char>(symbol));
                } else {
                    if (symbol > 285) throw FormatError("invalid NSIS length code");
                    const auto length = length_base[symbol - 257] + bits.read(length_extra[symbol - 257]);
                    const auto distance_symbol = distance_codes.decode(bits);
                    if (distance_symbol >= distance_base.size()) throw FormatError("invalid NSIS distance code");
                    const auto distance = distance_base[distance_symbol] + bits.read(distance_extra[distance_symbol]);
                    if (distance > output.size() || length > limit - output.size()) throw FormatError("invalid NSIS back-reference");
                    for (unsigned i = 0; i < length; ++i) output.push_back(output[output.size() - distance]);
                }
            }
        }
        if (!bits.finished() || (expected_size && output.size() != expected_size)) throw FormatError("NSIS stream size mismatch");
        return output;
    } catch (const FormatError& error) { return fail(ErrorCode::format, error.what()); }
}
class ZlibStream {
public:
    z_stream state{};
    bool initialized = false;
    ~ZlibStream() { if (initialized) inflateEnd(&state); }
};
class BzipStream {
public:
    bz_stream state{};
    bool initialized = false;
    ~BzipStream() { if (initialized) BZ2_bzDecompressEnd(&state); }
};
class StreamDecompressor final : public Decompressor {
public:
    Result<Bytes> decode(Compression method, std::span<const char> input,
                         std::size_t expected_size) const override {
        constexpr std::size_t maximum = 64 * 1024 * 1024;
        if (expected_size > maximum || input.size() > maximum) {
            return fail(ErrorCode::limit, "compressed entry exceeds 64 MiB limit");
        }
        if (method == Compression::nsis_deflate) return decode_nsis(input, expected_size);
        if (method == Compression::stored) {
            if (input.size() != expected_size) return fail(ErrorCode::format, "stored size mismatch");
            return Bytes(input.begin(), input.end());
        }
        // One extra output byte detects expansion beyond the declared size.
        Bytes output(expected_size + 1);
        if (method == Compression::zlib || method == Compression::deflate) {
            ZlibStream stream;
            const int window = method == Compression::deflate ? -MAX_WBITS : MAX_WBITS;
            if (inflateInit2(&stream.state, window) != Z_OK) return fail(ErrorCode::dependency, "zlib init failed");
            stream.initialized = true;
            stream.state.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(input.data()));
            stream.state.avail_in = static_cast<uInt>(input.size());
            stream.state.next_out = reinterpret_cast<Bytef*>(output.data());
            stream.state.avail_out = static_cast<uInt>(output.size());
            const auto status = inflate(&stream.state, Z_FINISH);
            if (status != Z_STREAM_END || stream.state.avail_in != 0 ||
                stream.state.total_out != expected_size) {
                return fail(ErrorCode::format, method == Compression::deflate ? "invalid DEFLATE stream or decoded size"
                                                                             : "invalid zlib stream or decoded size");
            }
        } else if (method == Compression::bzip2) {
            BzipStream stream;
            if (BZ2_bzDecompressInit(&stream.state, 0, 0) != BZ_OK) {
                return fail(ErrorCode::dependency, "bzip2 init failed");
            }
            stream.initialized = true;
            stream.state.next_in = const_cast<char*>(input.data());
            stream.state.avail_in = static_cast<unsigned int>(input.size());
            stream.state.next_out = output.data();
            stream.state.avail_out = static_cast<unsigned int>(output.size());
            int status = BZ_OK;
            do {
                const auto before_input = stream.state.avail_in;
                const auto before_output = stream.state.avail_out;
                status = BZ2_bzDecompress(&stream.state);
                if (status == BZ_OK && before_input == stream.state.avail_in &&
                    before_output == stream.state.avail_out) break;
            } while (status == BZ_OK && stream.state.avail_out != 0);
            if (status != BZ_STREAM_END || stream.state.avail_in != 0 ||
                stream.state.total_out_hi32 != 0 || stream.state.total_out_lo32 != expected_size) {
                return fail(ErrorCode::format, "invalid bzip2 stream or decoded size");
            }
        } else return fail(ErrorCode::unsupported, "unsupported compression method");
        output.resize(expected_size);
        return output;
    }
};
class ZlibCompressor final : public Compressor {
public:
    Result<Bytes> encode(std::span<const char> input) const override {
        if (input.size() > 64 * 1024 * 1024) return fail(ErrorCode::limit, "compression input exceeds 64 MiB limit");
        uLongf size = compressBound(static_cast<uLong>(input.size()));
        Bytes output(size);
        const auto status = compress(reinterpret_cast<Bytef*>(output.data()), &size,
                                     reinterpret_cast<const Bytef*>(input.data()), static_cast<uLong>(input.size()));
        if (status != Z_OK) return fail(ErrorCode::dependency, "zlib compress failed");
        output.resize(size);
        return output;
    }
};
}
std::unique_ptr<Decompressor> make_decompressor() { return std::make_unique<StreamDecompressor>(); }
std::unique_ptr<Compressor> make_compressor() { return std::make_unique<ZlibCompressor>(); }
}
