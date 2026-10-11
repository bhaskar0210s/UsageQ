#include "format.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <vector>
#include <cstdio>
#include <cstring>
#include <ctime>

namespace tt {

std::string formatUSD(double usd) {
    long long cents = llround(usd * 100);
    bool negative = cents < 0;
    if (negative) cents = -cents;
    std::string digits = std::to_string(cents / 100);
    std::string grouped;
    for (size_t i = 0; i < digits.size(); ++i) {
        if (i && (digits.size() - i) % 3 == 0) grouped += ',';
        grouped += digits[i];
    }
    char frac[8];
    snprintf(frac, sizeof frac, ".%02lld", cents % 100);
    return (negative ? "-$" : "$") + grouped + frac;
}

std::string formatUSDShort(double usd) {
    if (std::fabs(usd) < 100) return formatUSD(usd);
    std::string full = formatUSD(std::round(usd));
    return full.substr(0, full.size() - 3);  // drop ".00"
}

std::string formatTokens(double tokens) {
    static const char* const kSuffix[] = {"", "K", "M", "B", "T"};
    int i = 0;
    while (tokens >= 999.5 && i < 4) {
        tokens /= 1000;
        ++i;
    }
    char buf[32];
    if (i == 0) {
        snprintf(buf, sizeof buf, "%.0f", tokens);
    } else if (tokens >= 99.95) {
        snprintf(buf, sizeof buf, "%.0f%s", tokens, kSuffix[i]);
    } else {
        snprintf(buf, sizeof buf, "%.1f", tokens);
        size_t n = strlen(buf);
        if (n > 2 && buf[n - 2] == '.' && buf[n - 1] == '0') buf[n - 2] = 0;  // "2.0" -> "2"
        strlcat(buf, kSuffix[i], sizeof buf);
    }
    return buf;
}

std::string formatBytes(uint64_t bytes) {
    static const char* const kUnit[] = {"bytes", "KB", "MB", "GB", "TB"};
    double v = double(bytes);
    int i = 0;
    while (v >= 999.5 && i < 4) {
        v /= 1000;
        ++i;
    }
    char buf[32];
    if (i == 0)
        snprintf(buf, sizeof buf, "%llu bytes", static_cast<unsigned long long>(bytes));
    else if (v >= 10 || i < 2)
        snprintf(buf, sizeof buf, "%.0f %s", v, kUnit[i]);
    else
        snprintf(buf, sizeof buf, "%.1f %s", v, kUnit[i]);
    return buf;
}

std::string formatCountdown(int64_t seconds) {
    if (seconds < 1) return "now";
    int64_t total = std::max<int64_t>(1, (seconds + 59) / 60);
    int64_t d = total / 1440, h = (total / 60) % 24, m = total % 60;
    char buf[48];
    if (d > 0) {
        if (h > 0)
            snprintf(buf, sizeof buf, "%lldd %lldh", d, h);
        else if (m > 0)
            snprintf(buf, sizeof buf, "%lldd %lldm", d, m);
        else
            snprintf(buf, sizeof buf, "%lldd", d);
    } else if (h > 0) {
        if (m > 0)
            snprintf(buf, sizeof buf, "%lldh %lldm", h, m);
        else
            snprintf(buf, sizeof buf, "%lldh", h);
    } else {
        snprintf(buf, sizeof buf, "%lldm", m);
    }
    return buf;
}

std::string formatAgo(int64_t seconds) {
    if (seconds < 60) return "just now";
    char buf[32];
    if (seconds < 3600)
        snprintf(buf, sizeof buf, "%lldm ago", static_cast<long long>(seconds / 60));
    else if (seconds < 86400)
        snprintf(buf, sizeof buf, "%lldh ago", static_cast<long long>(seconds / 3600));
    else
        snprintf(buf, sizeof buf, "%lldd ago", static_cast<long long>(seconds / 86400));
    return buf;
}

std::string formatPercent(double percent) {
    char buf[16];
    snprintf(buf, sizeof buf, "%.0f%%", std::floor(percent + 0.5));
    return buf;
}

namespace {
std::string localStrftime(int64_t t, const char* fmt) {
    time_t tt = time_t(t);
    struct tm tm;
    localtime_r(&tt, &tm);
    char buf[64];
    size_t n = strftime(buf, sizeof buf, fmt, &tm);
    return std::string(buf, n);
}
}  // namespace

std::string formatShortDate(int64_t t) { return localStrftime(t, "%b %-d"); }
std::string formatISODate(int64_t t) { return localStrftime(t, "%Y-%m-%d"); }

std::string formatISOTime(int64_t t) {
    time_t tt = time_t(t);
    struct tm tm;
    gmtime_r(&tt, &tm);
    char buf[32];
    size_t n = strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return std::string(buf, n);
}

// "claude-opus-5-5" -> "Opus 5.5", "claude-fable-5" -> "Fable 5", "claude-3-5-sonnet" -> "Sonnet 3.5".
// Anything else is returned unchanged.
std::string modelDisplayName(std::string_view id) {
    if (id.substr(0, 7) != "claude-") return std::string(id);
    std::vector<std::string_view> parts;
    for (std::string_view rest = id.substr(7); !rest.empty();) {
        const size_t dash = rest.find('-');
        parts.push_back(rest.substr(0, dash));
        rest = dash == std::string_view::npos ? std::string_view() : rest.substr(dash + 1);
    }
    auto numeric = [](std::string_view p) {
        return !p.empty() && std::all_of(p.begin(), p.end(), [](char c) { return c >= '0' && c <= '9'; });
    };
    std::string family, version;
    size_t i = 0;
    if (!parts.empty() && !numeric(parts[0])) family = parts[i++];  // claude-<family>-<version>
    for (; i < parts.size() && numeric(parts[i]); ++i) version += (version.empty() ? "" : ".") + std::string(parts[i]);
    if (family.empty() && i + 1 == parts.size()) family = parts[i++];  // claude-<version>-<family>
    if (family.empty() || i != parts.size()) return std::string(id);
    family[0] = char(std::toupper(static_cast<unsigned char>(family[0])));
    return version.empty() ? family : family + " " + version;
}

}  // namespace tt
