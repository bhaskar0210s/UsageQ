#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace tt {

std::string formatUSD(double usd);               // "$1,436.15"
std::string formatUSDShort(double usd);          // "$1,436" from $100 up, "$12.40" below
std::string formatTokens(double tokens);         // "366M", "3.7B", "2B"
std::string formatBytes(uint64_t bytes);         // "1.7 GB" (decimal units, like Finder)
std::string formatCountdown(int64_t seconds);    // "4h 26m", "5d 3h", "12m", "now"
std::string formatAgo(int64_t seconds);          // "just now", "5m ago"
std::string formatPercent(double percent);       // "23%"
std::string formatShortDate(int64_t t);          // "Oct 9" (local time)
std::string formatISODate(int64_t t);            // "2026-10-09" (local time)
std::string formatISOTime(int64_t t);            // "2026-10-09T12:00:00Z"
std::string modelDisplayName(std::string_view id); // "claude-opus-5-5" -> "Opus 5.5"

}  // namespace tt
