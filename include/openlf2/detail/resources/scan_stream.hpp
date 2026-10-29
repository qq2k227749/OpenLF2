// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
// Private to openlf2_resources: fscanf behavior shared by original text formats.
#include "openlf2/core/result.hpp"
#include <cmath>
#include <cstdint>
#include <limits>
#include <locale>
#include <sstream>
#include <string>
#include <string_view>

namespace openlf2::scanning {
struct ParseFailure {
    ErrorCode code;
    std::string message;
};

inline bool is_space(char character) {
    return character == ' ' || character == '\t' || character == '\n' || character == '\v' ||
           character == '\f' || character == '\r';
}
inline bool is_digit(char character) { return character >= '0' && character <= '9'; }

inline std::int32_t wrapping_add(std::int32_t left, std::int32_t right) {
    return static_cast<std::int32_t>(static_cast<std::uint32_t>(left) +
                                     static_cast<std::uint32_t>(right));
}
inline std::int32_t wrapping_subtract(std::int32_t left, std::int32_t right) {
    return static_cast<std::int32_t>(static_cast<std::uint32_t>(left) -
                                     static_cast<std::uint32_t>(right));
}

// The end-of-file flag is set only when a read reaches the end, matching the original's fscanf loop.
class TokenStream {
public:
    enum class Scan { value, mismatch, end };
    explicit TokenStream(std::string_view text) : text_(text) {}
    [[nodiscard]] bool at_end() const { return end_reached_; }
    [[nodiscard]] std::size_t line() const { return line_; }

    // %s. Returns false at end of input and leaves the target unchanged.
    bool word(std::string& target, std::size_t capacity) {
        if (!skip_space()) return false;
        const auto start = position_;
        while (position_ < text_.size() && !is_space(text_[position_])) ++position_;
        if (position_ == text_.size()) end_reached_ = true;
        if (position_ - start >= capacity) {
            throw ParseFailure{ErrorCode::unsupported,
                               "token longer than the original " + std::to_string(capacity - 1) +
                                   "-character buffer"};
        }
        target.assign(text_.substr(start, position_ - start));
        return true;
    }

    // %d. A mismatch consumes only whitespace, so the text becomes the next token. Like the
    // original's C library, digits accumulate in 32 bits and wrap around, then the sign applies:
    // mods write values such as "y: 100000000000000000000" that the original reads that way.
    Scan integer(std::int32_t& target) {
        if (!skip_space()) return Scan::end;
        auto cursor = position_;
        const bool negative = text_[cursor] == '-';
        if (negative || text_[cursor] == '+') ++cursor;
        if (cursor == text_.size() || !is_digit(text_[cursor])) {
            if (cursor != position_) unsupported("sign without digits");
            return Scan::mismatch;
        }
        std::uint32_t value = 0;
        while (cursor < text_.size() && is_digit(text_[cursor])) {
            value = value * 10U + static_cast<std::uint32_t>(text_[cursor++] - '0');
        }
        if (negative) value = 0U - value;
        finish(cursor);
        target = static_cast<std::int32_t>(value);
        return Scan::value;
    }

    // %lf: sign, digits, optional fraction and exponent.
    Scan real(double& target) {
        if (!skip_space()) return Scan::end;
        auto cursor = position_;
        if (text_[cursor] == '-' || text_[cursor] == '+') ++cursor;
        const auto digits = [&] {
            const auto start = cursor;
            while (cursor < text_.size() && is_digit(text_[cursor])) ++cursor;
            return cursor - start;
        };
        auto mantissa_digits = digits();
        if (cursor < text_.size() && text_[cursor] == '.') {
            ++cursor;
            mantissa_digits += digits();
        }
        if (mantissa_digits == 0) {
            if (cursor != position_) unsupported("number without digits");
            return Scan::mismatch;
        }
        if (cursor < text_.size() && (text_[cursor] == 'e' || text_[cursor] == 'E')) {
            ++cursor;
            if (cursor < text_.size() && (text_[cursor] == '-' || text_[cursor] == '+')) ++cursor;
            if (digits() == 0) unsupported("exponent without digits");
        }
        const auto number = text_.substr(position_, cursor - position_);
        double value = 0;
        // NDK libc++ has no floating-point from_chars. The grammar above fixes the
        // consumed token; the classic locale makes decimal conversion independent of the host.
        std::istringstream input{std::string(number)};
        input.imbue(std::locale::classic());
        input >> std::noskipws >> value;
        if (!input || input.rdbuf()->sgetc() != std::char_traits<char>::eof() ||
            !std::isfinite(value)) {
            unsupported("floating-point value outside supported range");
        }
        finish(cursor);
        target = value;
        return Scan::value;
    }

private:
    [[noreturn]] static void unsupported(const std::string& message) {
        throw ParseFailure{ErrorCode::unsupported, message};
    }
    bool skip_space() {
        while (position_ < text_.size() && is_space(text_[position_])) {
            if (text_[position_] == '\n') ++line_;
            ++position_;
        }
        if (position_ == text_.size()) end_reached_ = true;
        return position_ < text_.size();
    }
    void finish(std::size_t cursor) {
        position_ = cursor;
        if (position_ == text_.size()) end_reached_ = true;
    }
    std::string_view text_;
    std::size_t position_ = 0;
    std::size_t line_ = 1;
    bool end_reached_ = false;
};

inline void add_token_checksum(std::int32_t& checksum, std::string_view word) {
    auto sum = static_cast<std::uint32_t>(checksum);
    for (std::size_t index = 0; index < word.size(); ++index) {
        const auto character = static_cast<std::int32_t>(static_cast<signed char>(word[index]));
        sum += static_cast<std::uint32_t>(character) * static_cast<std::uint32_t>(index);
    }
    checksum = static_cast<std::int32_t>(sum);
}
}
