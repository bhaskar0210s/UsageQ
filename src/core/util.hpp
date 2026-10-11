#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace uq {

std::string homeDir();
int64_t nowSeconds();

// Reads a whole file (up to `maxBytes`). Returns false if missing, unreadable or too large.
bool readFile(const std::string& path, std::string& out, size_t maxBytes = 64u << 20);

// Overwrites a buffer that held secrets before it is released.
void secureZero(std::string& s);

uint64_t fnv1a(std::string_view s, uint64_t h = 1469598103934665603ULL);

// "2026-10-11T12:29:59.817889+00:00" / "...Z" -> unix seconds; 0 when invalid.
int64_t parseISO8601(std::string_view s);

// Local midnight of the day containing `t`, shifted by `dayOffset` days (DST aware).
int64_t localMidnight(int64_t t, int dayOffset = 0);

}  // namespace uq
