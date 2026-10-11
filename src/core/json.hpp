// Minimal JSON DOM for small documents (API responses, credentials, config).
// Session logs are scanned with a dedicated zero-copy parser in costs.cpp.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace tt::json {

struct Value {
    enum class Type : uint8_t { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<Value> items;                            // Array
    std::vector<std::pair<std::string, Value>> members;  // Object

    bool isNull() const { return type == Type::Null; }
    bool isObject() const { return type == Type::Object; }
    bool isArray() const { return type == Type::Array; }
    bool isNumber() const { return type == Type::Number; }
    bool isString() const { return type == Type::String; }

    // Object member lookup. Returns a shared null value when absent.
    const Value& operator[](std::string_view key) const;

    double num(double fallback = 0) const { return type == Type::Number ? number : fallback; }
    std::string_view str(std::string_view fallback = {}) const {
        return type == Type::String ? std::string_view(string) : fallback;
    }
};

// Parses a complete document; trailing non-whitespace is an error.
bool parse(std::string_view text, Value& out);

// Parses the first value in `text` and ignores whatever follows it.
bool parsePrefix(std::string_view text, Value& out);

// Overwrites every string in the tree before it is freed (used for credentials).
void wipe(Value& v);

// Appends `s` as a quoted, escaped JSON string literal.
void appendQuoted(std::string& out, std::string_view s);

}  // namespace tt::json
