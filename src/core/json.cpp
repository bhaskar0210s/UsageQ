#include "json.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <xlocale.h>

namespace uq::json {
namespace {

const Value kNull;
constexpr int kMaxDepth = 128;

void zero(std::string& s) {
    volatile char* v = s.data();
    for (size_t i = 0; i < s.size(); ++i) v[i] = 0;
}

struct Parser {
    const char* p;
    const char* end;
    int depth = 0;

    void ws() {
        while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) ++p;
    }

    bool literal(const char* s, size_t n) {
        if (size_t(end - p) < n || memcmp(p, s, n) != 0) return false;
        p += n;
        return true;
    }

    static int hexDigit(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    bool hex4(uint32_t& cp) {
        if (end - p < 4) return false;
        cp = 0;
        for (int i = 0; i < 4; ++i) {
            int d = hexDigit(p[i]);
            if (d < 0) return false;
            cp = (cp << 4) | uint32_t(d);
        }
        p += 4;
        return true;
    }

    static void utf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out += char(cp);
        } else if (cp < 0x800) {
            out += char(0xC0 | (cp >> 6));
            out += char(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += char(0xE0 | (cp >> 12));
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        } else {
            out += char(0xF0 | (cp >> 18));
            out += char(0x80 | ((cp >> 12) & 0x3F));
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        }
    }

    bool string(std::string& out) {
        ++p;  // opening quote
        for (;;) {
            const char* q = p;
            while (q < end && *q != '"' && *q != '\\' && static_cast<unsigned char>(*q) >= 0x20) ++q;
            out.append(p, size_t(q - p));
            p = q;
            if (p >= end) return false;
            char c = *p++;
            if (c == '"') return true;
            if (c != '\\' || p >= end) return false;  // raw control character or dangling escape
            switch (char e = *p++) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        uint32_t lo = 0;
                        if (end - p >= 6 && p[0] == '\\' && p[1] == 'u') {
                            p += 2;
                            if (!hex4(lo)) return false;
                        }
                        cp = (lo >= 0xDC00 && lo <= 0xDFFF) ? 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) : 0xFFFD;
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        cp = 0xFFFD;
                    }
                    utf8(out, cp);
                    break;
                }
                default:
                    (void)e;
                    return false;
            }
        }
    }

    bool number(Value& v) {
        const char* s = p;
        if (p < end && *p == '-') ++p;
        while (p < end && ((*p >= '0' && *p <= '9') || *p == '.' || *p == 'e' || *p == 'E' || *p == '+' || *p == '-')) ++p;
        size_t n = size_t(p - s);
        if (n == 0 || n >= 64) return false;
        char buf[64];
        memcpy(buf, s, n);
        buf[n] = 0;
        char* stop = nullptr;
        v.number = strtod_l(buf, &stop, nullptr);  // NULL locale = "C": '.' is always the decimal point
        if (stop != buf + n) return false;
        v.type = Value::Type::Number;
        return true;
    }

    bool array(Value& v) {
        ++p;
        v.type = Value::Type::Array;
        ws();
        if (p < end && *p == ']') { ++p; return true; }
        for (;;) {
            v.items.emplace_back();
            if (!value(v.items.back())) return false;
            ws();
            if (p >= end) return false;
            if (*p == ',') { ++p; continue; }
            if (*p == ']') { ++p; return true; }
            return false;
        }
    }

    bool object(Value& v) {
        ++p;
        v.type = Value::Type::Object;
        ws();
        if (p < end && *p == '}') { ++p; return true; }
        for (;;) {
            ws();
            if (p >= end || *p != '"') return false;
            v.members.emplace_back();
            if (!string(v.members.back().first)) return false;
            ws();
            if (p >= end || *p != ':') return false;
            ++p;
            if (!value(v.members.back().second)) return false;
            ws();
            if (p >= end) return false;
            if (*p == ',') { ++p; continue; }
            if (*p == '}') { ++p; return true; }
            return false;
        }
    }

    bool value(Value& v) {
        ws();
        if (p >= end) return false;
        switch (*p) {
            case '{':
            case '[': {
                if (++depth > kMaxDepth) return false;
                bool ok = (*p == '{') ? object(v) : array(v);
                --depth;
                return ok;
            }
            case '"':
                v.type = Value::Type::String;
                return string(v.string);
            case 't':
                v.type = Value::Type::Bool;
                v.boolean = true;
                return literal("true", 4);
            case 'f':
                v.type = Value::Type::Bool;
                return literal("false", 5);
            case 'n':
                return literal("null", 4);
            default:
                return number(v);
        }
    }
};

}  // namespace

const Value& Value::operator[](std::string_view key) const {
    if (type != Type::Object) return kNull;
    for (const auto& m : members)
        if (m.first == key) return m.second;
    return kNull;
}

bool parse(std::string_view text, Value& out) {
    Parser ps{text.data(), text.data() + text.size()};
    if (!ps.value(out)) return false;
    ps.ws();
    return ps.p == ps.end;
}

bool parsePrefix(std::string_view text, Value& out) {
    Parser ps{text.data(), text.data() + text.size()};
    return ps.value(out);
}

void wipe(Value& v) {
    zero(v.string);
    for (auto& item : v.items) wipe(item);
    for (auto& m : v.members) {
        zero(m.first);
        wipe(m.second);
    }
}

void appendQuoted(std::string& out, std::string_view s) {
    out += '"';
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof buf, "\\u%04x", unsigned(static_cast<unsigned char>(c)));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    out += '"';
}

}  // namespace uq::json
