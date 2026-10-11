#include "costs.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fts.h>
#include <sys/stat.h>
#include <unistd.h>

#include "util.hpp"

namespace uq {

// $ per million tokens. Cache writes cost 1.25x input (5-minute TTL) or 2x input (1-hour TTL).
struct Price {
    const char* model;
    double input, output, cacheRead;
    int64_t longContextAbove;  // prompt size that switches the whole request to long rates; 0 = flat
    double inputLong, outputLong, cacheReadLong;
    double fastMultiplier;     // `"speed": "fast"` responses
};

namespace {

constexpr int kHistoryDays = 32;         // full days kept before today
constexpr int kDays = kHistoryDays + 1;  // ... plus today
constexpr int64_t kSlotSeconds = 900;    // 15 minutes: every UTC offset is a multiple of this
constexpr size_t kInitialBuffer = 1u << 20;
constexpr size_t kMaxLine = 64u << 20;
constexpr uint32_t kFast = 1, kLong = 2;

constexpr Price flat(const char* m, double in, double out, double read, double fast = 1) {
    return {m, in, out, read, 0, in, out, read, fast};
}
constexpr Price tiered(const char* m, double in, double out, double read, int64_t above, double in2, double out2,
                       double read2) {
    return {m, in, out, read, above, in2, out2, read2, 1};
}

// Anthropic API list prices, October 2026. Matched by longest model-name prefix.
constexpr Price kPrices[] = {
    flat("claude-fable-5-1", 10, 50, 0.25),
    flat("claude-mythos-5-1", 10, 50, 0.25),
    flat("claude-fable-5", 10, 50, 1),
    flat("claude-mythos-5", 10, 50, 1),
    flat("claude-opus-5-5", 4, 20, 0.2, 2),
    flat("claude-opus-5", 5, 25, 0.5, 2),
    flat("claude-opus-4-8", 5, 25, 0.5),
    flat("claude-opus-4-7", 5, 25, 0.5),
    flat("claude-opus-4-6", 5, 25, 0.5),
    flat("claude-opus-4-5", 5, 25, 0.5),
    flat("claude-opus-4-1", 15, 75, 1.5),
    flat("claude-opus-4", 15, 75, 1.5),
    flat("claude-sonnet-5-5", 2, 10, 0.2),
    flat("claude-sonnet-5", 2, 10, 0.2),
    flat("claude-sonnet-4-6", 3, 15, 0.3),
    tiered("claude-sonnet-4-5", 3, 15, 0.3, 200000, 6, 22.5, 0.6),
    tiered("claude-sonnet-4", 3, 15, 0.3, 200000, 6, 22.5, 0.6),
    flat("claude-3-7-sonnet", 3, 15, 0.3),
    flat("claude-3-5-sonnet", 3, 15, 0.3),
    tiered("claude-haiku-5-5", 0.1, 0.5, 0.01, 100000, 0.5, 2.5, 0.05),
    flat("claude-haiku-4-5", 1, 5, 0.1),
    flat("claude-3-5-haiku", 0.8, 4, 0.08),
    flat("claude-3-haiku", 0.25, 1.25, 0.03),
};

const Price* findPrice(std::string_view name) {
    const Price* best = nullptr;
    size_t bestLength = 0;
    for (const Price& p : kPrices) {
        const size_t n = strlen(p.model);
        if (n > bestLength && name.size() >= n && name.compare(0, n, p.model) == 0 &&
            (name.size() == n || name[n] == '-')) {
            best = &p;
            bestLength = n;
        }
    }
    return best;
}

// "us.anthropic.claude-opus-4-5-20251101-v1:0", "claude-opus-4-5@20251101", "claude-opus-5-5[1m]"
// -> "claude-opus-4-5" / "claude-opus-5-5".
std::string normalizeModel(std::string_view m) {
    if (size_t a = m.find("anthropic."); a != std::string_view::npos) m.remove_prefix(a + 10);
    if (size_t cut = m.find_first_of("@["); cut != std::string_view::npos) m = m.substr(0, cut);
    if (size_t v = m.rfind("-v"); v != std::string_view::npos && m.find(':', v) != std::string_view::npos)
        m = m.substr(0, v);
    if (m.size() > 9 && m[m.size() - 9] == '-' &&
        std::all_of(m.end() - 8, m.end(), [](char c) { return c >= '0' && c <= '9'; }))
        m.remove_suffix(9);
    return std::string(m);
}

size_t mix(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return size_t(x);
}

// ---------------------------------------------------------------------------------------------
// Zero-copy reader for one JSONL line. It extracts only the fields we price and skips the rest
// (message content can be megabytes) with memchr-driven string skipping.

struct Line {
    std::string_view type, timestamp, requestId, sessionId, messageId, model, speed;
    int64_t input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cacheWrite1h = 0;
    bool hasUsage = false;
};

inline void skipSpace(const char*& p, const char* e) {
    while (p < e && static_cast<unsigned char>(*p) <= ' ') ++p;
}

// `p` is at an opening quote; leaves it after the closing quote. Escapes are not decoded.
inline bool readString(const char*& p, const char* e, std::string_view* out) {
    const char* const s = ++p;
    for (;;) {
        const char* q = static_cast<const char*>(memchr(p, '"', size_t(e - p)));
        if (!q) return false;
        const char* b = q;
        while (b > s && b[-1] == '\\') --b;
        p = q + 1;
        if (((q - b) & 1) == 0) {
            if (out) *out = std::string_view(s, size_t(q - s));
            return true;
        }
    }
}

bool skipValue(const char*& p, const char* e) {
    skipSpace(p, e);
    if (p >= e) return false;
    if (*p == '"') return readString(p, e, nullptr);
    if (*p == '{' || *p == '[') {
        int depth = 0;
        while (p < e) {
            const char c = *p;
            if (c == '"') {
                if (!readString(p, e, nullptr)) return false;
                continue;
            }
            if (c == '{' || c == '[') {
                ++depth;
            } else if ((c == '}' || c == ']') && --depth == 0) {
                ++p;
                return true;
            }
            ++p;
        }
        return false;
    }
    while (p < e && *p != ',' && *p != '}' && *p != ']' && static_cast<unsigned char>(*p) > ' ') ++p;
    return true;
}

bool readText(const char*& p, const char* e, std::string_view& out) {
    if (p < e && *p == '"') return readString(p, e, &out);
    return skipValue(p, e);
}

bool readCount(const char*& p, const char* e, int64_t& out) {
    if (p < e && *p >= '0' && *p <= '9') {
        int64_t v = 0;
        while (p < e && *p >= '0' && *p <= '9') {
            if (v < (int64_t(1) << 40)) v = v * 10 + (*p - '0');
            ++p;
        }
        out = v;
        return (p < e && (*p == '.' || *p == 'e' || *p == 'E')) ? skipValue(p, e) : true;
    }
    return skipValue(p, e);  // null, negative or malformed: ignore
}

template <class OnMember>
bool members(const char*& p, const char* e, OnMember&& onMember) {
    skipSpace(p, e);
    if (p >= e || *p != '{') return skipValue(p, e);
    ++p;
    skipSpace(p, e);
    if (p < e && *p == '}') {
        ++p;
        return true;
    }
    for (;;) {
        skipSpace(p, e);
        std::string_view key;
        if (p >= e || *p != '"' || !readString(p, e, &key)) return false;
        skipSpace(p, e);
        if (p >= e || *p != ':') return false;
        ++p;
        skipSpace(p, e);
        if (!onMember(key, p)) return false;
        skipSpace(p, e);
        if (p >= e) return false;
        if (*p == ',') {
            ++p;
            continue;
        }
        if (*p == '}') {
            ++p;
            return true;
        }
        return false;
    }
}

bool parseLine(const char* begin, const char* e, Line& l) {
    const char* p = begin;
    return members(p, e, [&](std::string_view k, const char*& q) {
        if (k == "type") return readText(q, e, l.type);
        if (k == "timestamp") return readText(q, e, l.timestamp);
        if (k == "requestId") return readText(q, e, l.requestId);
        if (k == "sessionId") return readText(q, e, l.sessionId);
        if (k != "message") return skipValue(q, e);
        return members(q, e, [&](std::string_view k2, const char*& r) {
            if (k2 == "id") return readText(r, e, l.messageId);
            if (k2 == "model") return readText(r, e, l.model);
            if (k2 != "usage") return skipValue(r, e);
            l.hasUsage = true;
            return members(r, e, [&](std::string_view k3, const char*& s) {
                if (k3 == "input_tokens") return readCount(s, e, l.input);
                if (k3 == "output_tokens") return readCount(s, e, l.output);
                if (k3 == "cache_read_input_tokens") return readCount(s, e, l.cacheRead);
                if (k3 == "cache_creation_input_tokens") return readCount(s, e, l.cacheWrite);
                if (k3 == "speed") return readText(s, e, l.speed);
                if (k3 != "cache_creation") return skipValue(s, e);
                return members(s, e, [&](std::string_view k4, const char*& t) {
                    if (k4 == "ephemeral_1h_input_tokens") return readCount(t, e, l.cacheWrite1h);
                    return skipValue(t, e);
                });
            });
        });
    });
}

double messageCost(const Price* p, const Line& l, uint32_t flags) {
    if (!p) return 0;
    const bool longRates = flags & kLong;
    const double in = longRates ? p->inputLong : p->input;
    const double out = longRates ? p->outputLong : p->output;
    const double read = longRates ? p->cacheReadLong : p->cacheRead;
    const int64_t write1h = std::clamp<int64_t>(l.cacheWrite1h, 0, l.cacheWrite);
    const int64_t write5m = l.cacheWrite - write1h;
    const double usd = (double(l.input) * in + double(l.output) * out + double(l.cacheRead) * read +
                        double(write5m) * in * 1.25 + double(write1h) * in * 2.0) / 1e6;
    return (flags & kFast) ? usd * p->fastMultiplier : usd;
}

double outputCost(const Price* p, uint32_t tokens, uint32_t flags) {
    if (!p) return 0;
    const double usd = double(tokens) * ((flags & kLong) ? p->outputLong : p->output) / 1e6;
    return (flags & kFast) ? usd * p->fastMultiplier : usd;
}

}  // namespace

// ---------------------------------------------------------------------------------------------

void CostScanner::reset(int64_t now) {
    time_t t = time_t(now);
    struct tm tm;
    localtime_r(&t, &tm);
    dayKey_ = (tm.tm_year + 1900) * 1000 + tm.tm_yday;
    gmtOffset_ = tm.tm_gmtoff;
    base_ = localMidnight(now, -kHistoryDays);
    end_ = localMidnight(now, 1);

    const size_t slotCount = size_t((end_ - base_ + kSlotSeconds - 1) / kSlotSeconds);
    slots_.allocate(slotCount);
    slotDay_.assign(slotCount, 0);
    dayStart_.assign(kDays + 1, 0);
    for (int d = 0; d <= kDays; ++d)
        dayStart_[size_t(d)] = int((localMidnight(now, d - kHistoryDays) - base_) / kSlotSeconds);
    for (int d = 0; d < kDays; ++d)
        for (int s = dayStart_[size_t(d)]; s < dayStart_[size_t(d) + 1] && s < int(slotCount); ++s)
            slotDay_[size_t(s)] = uint8_t(d);

    models_.clear();
    rawModels_.clear();
    modelCost_.clear();
    modelTokens_.clear();
    table_.allocate(1u << 14);
    used_ = 0;
    files_.clear();
    messages_ = 0;
    unpriced_ = false;
}

void CostScanner::update(int64_t now) {
    time_t t = time_t(now);
    struct tm tm;
    localtime_r(&t, &tm);
    if ((tm.tm_year + 1900) * 1000 + tm.tm_yday != dayKey_ || tm.tm_gmtoff != gmtOffset_) reset(now);

    const std::string home = homeDir();
    std::vector<std::string> roots = {home + "/.claude/projects", home + "/.config/claude/projects"};
    if (const char* dir = getenv("CLAUDE_CONFIG_DIR"); dir && *dir) {
        std::string custom = std::string(dir) + "/projects";
        if (std::find(roots.begin(), roots.end(), custom) == roots.end()) roots.push_back(custom);
    }
    for (const auto& root : roots) scanTree(root);
    buffer_.release();  // don't hold the read buffer between scans
}

void CostScanner::scanTree(const std::string& root) {
    struct stat rootStat;
    if (stat(root.c_str(), &rootStat) != 0 || !S_ISDIR(rootStat.st_mode)) return;
    char* paths[] = {const_cast<char*>(root.c_str()), nullptr};
    FTS* fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_COMFOLLOW, nullptr);
    if (!fts) return;
    while (FTSENT* ent = fts_read(fts)) {
        if (ent->fts_info != FTS_F) continue;
        const size_t len = ent->fts_pathlen;
        if (len < 6 || memcmp(ent->fts_path + len - 6, ".jsonl", 6) != 0) continue;
        const struct stat* st = ent->fts_statp;
        if (st->st_mtimespec.tv_sec < base_) continue;  // nothing in range
        FileState& state = files_[fnv1a(std::string_view(ent->fts_path, len))];
        if (state.inode != uint64_t(st->st_ino)) {
            state.inode = uint64_t(st->st_ino);
            state.offset = 0;
        }
        const uint64_t size = uint64_t(st->st_size);
        if (size < state.offset) state.offset = 0;  // rewritten: re-read (dedup prevents double counting)
        if (size > state.offset) scanFile(ent->fts_path, state);
    }
    fts_close(fts);
}

void CostScanner::scanFile(const char* path, FileState& state) {
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    if (buffer_.empty() && !buffer_.allocate(kInitialBuffer)) {
        close(fd);
        return;
    }
    uint64_t lineStart = state.offset;  // file offset of buffer_[0]
    size_t have = 0;
    bool skipping = false;  // inside a line too long to buffer
    for (;;) {
        if (have == buffer_.size()) {
            if (buffer_.size() < kMaxLine && buffer_.grow(buffer_.size() * 2)) {
                // keep reading into the larger buffer
            } else {
                skipping = true;
                lineStart += have;
                have = 0;
            }
        }
        const ssize_t n = pread(fd, buffer_.data() + have, buffer_.size() - have, off_t(lineStart + have));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        have += size_t(n);

        char* const start = buffer_.data();
        char* const stop = start + have;
        char* line = start;
        while (char* nl = static_cast<char*>(memchr(line, '\n', size_t(stop - line)))) {
            if (skipping)
                skipping = false;
            else
                ingest(line, nl);
            line = nl + 1;
        }
        if (const size_t consumed = size_t(line - start)) {
            memmove(start, line, have - consumed);
            have -= consumed;
            lineStart += consumed;
            if (!skipping) state.offset = lineStart;  // a trailing partial line is re-read next time
        }
    }
    close(fd);
}

int CostScanner::modelIndex(std::string_view raw) {
    if (raw.empty() || raw.front() == '<') return -1;  // "<synthetic>" placeholder messages
    for (const auto& [name, index] : rawModels_)
        if (name == raw) return index;
    const std::string name = normalizeModel(raw);
    int index = -1;
    for (size_t i = 0; i < models_.size(); ++i)
        if (models_[i].name == name) index = int(i);
    if (index < 0) {
        if (models_.size() >= 255) return -1;
        models_.push_back({name, findPrice(name)});
        modelCost_.resize(models_.size() * kDays, 0.0);
        modelTokens_.resize(models_.size() * kDays, 0);
        index = int(models_.size() - 1);
    }
    rawModels_.emplace_back(std::string(raw), index);
    return index;
}

CostScanner::Entry* CostScanner::lookup(uint64_t key) {
    const size_t mask = table_.size() - 1;
    for (size_t i = mix(key) & mask;; i = (i + 1) & mask) {
        Entry& e = table_[i];
        if (e.key == key || e.key == 0) return &e;
    }
}

void CostScanner::grow() {
    PageArray<Entry> old;
    old.swap(table_);
    if (!table_.allocate(old.size() * 2)) {
        old.swap(table_);  // out of memory: keep probing the full table
        return;
    }
    for (size_t i = 0; i < old.size(); ++i)
        if (old[i].key) *lookup(old[i].key) = old[i];
}

void CostScanner::ingest(const char* begin, const char* end) {
    const size_t length = size_t(end - begin);
    if (length < 64 || !memmem(begin, length, "\"usage\":", 8)) return;
    Line l;
    if (!parseLine(begin, end, l) || l.type != "assistant" || !l.hasUsage) return;
    if (l.input <= 0 && l.output <= 0 && l.cacheRead <= 0 && l.cacheWrite <= 0) return;
    const int64_t ts = parseISO8601(l.timestamp);
    if (ts < base_ || ts >= end_) return;
    const int slot = int((ts - base_) / kSlotSeconds);
    if (slot < 0 || slot >= int(slots_.size())) return;
    const int model = modelIndex(l.model);
    if (model < 0) return;
    const Price* price = models_[size_t(model)].price;

    uint32_t flags = 0;
    if (l.speed == "fast") flags |= kFast;
    if (price && price->longContextAbove > 0 && l.input + l.cacheRead + l.cacheWrite > price->longContextAbove)
        flags |= kLong;
    const uint32_t output = uint32_t(std::min<int64_t>(l.output, UINT32_MAX));

    if (!l.messageId.empty()) {
        uint64_t key = fnv1a("|", fnv1a(l.messageId));
        key = fnv1a(l.requestId.empty() ? l.sessionId : l.requestId, key);
        if (key == 0) key = 1;
        Entry* entry = lookup(key);
        if (entry->key == key) {
            if (output > entry->output) {  // a later copy carries the final output count
                const uint32_t delta = output - entry->output;
                entry->output = output;
                const size_t s = entry->meta & 0xFFF, m = (entry->meta >> 12) & 0xFF;
                const double cost = outputCost(models_[m].price, delta, entry->meta >> 20);
                slots_[s].cost += cost;
                slots_[s].tokens += delta;
                modelCost_[m * kDays + slotDay_[s]] += cost;
                modelTokens_[m * kDays + slotDay_[s]] += delta;
            }
            return;
        }
        *entry = Entry{key, output, uint32_t(slot) | (uint32_t(model) << 12) | (flags << 20)};
        if (++used_ * 4 >= table_.size() * 3) grow();
    }

    const double cost = messageCost(price, l, flags);
    const uint64_t tokens = uint64_t(l.input + l.output + l.cacheRead + l.cacheWrite);
    if (!price) unpriced_ = true;
    slots_[size_t(slot)].cost += cost;
    slots_[size_t(slot)].tokens += tokens;
    const size_t cell = size_t(model) * kDays + slotDay_[size_t(slot)];
    modelCost_[cell] += cost;
    modelTokens_[cell] += tokens;
    ++messages_;
}

DayUsage CostScanner::sumRange(int64_t from, int64_t to) const {
    DayUsage u;
    // Edges snap to the nearest 15-minute boundary.
    auto slotAt = [this](int64_t t) { return (t - base_ + kSlotSeconds / 2) / kSlotSeconds; };
    const int64_t a = std::max<int64_t>(0, from < base_ ? 0 : slotAt(from));
    const int64_t b = std::min<int64_t>(int64_t(slots_.size()), to < base_ ? 0 : slotAt(to));
    for (int64_t k = a; k < b; ++k) {
        u.cost += slots_[size_t(k)].cost;
        u.tokens += slots_[size_t(k)].tokens;
    }
    return u;
}

CostSummary CostScanner::summarize(int64_t now, int64_t windowEnd) const {
    CostSummary s;
    if (slots_.empty()) return s;
    s.valid = true;
    const int today = kHistoryDays;
    for (int i = 0; i < 30; ++i) {
        const int d = today - 29 + i;
        DayUsage u;
        for (int k = dayStart_[size_t(d)]; k < dayStart_[size_t(d) + 1]; ++k) {
            u.cost += slots_[size_t(k)].cost;
            u.tokens += slots_[size_t(k)].tokens;
        }
        s.days[size_t(i)] = u;
        s.last30 += u;
    }
    for (int i = 0; i < 30; ++i) {
        const size_t d = size_t(today - 29 + i);
        auto& top = s.dayModels[size_t(i)];
        for (size_t m = 0; m < models_.size(); ++m) {
            const ModelUsage u{models_[m].name, modelCost_[m * kDays + d], modelTokens_[m * kDays + d]};
            if (u.cost <= 0 && u.tokens == 0) continue;
            auto beats = [&u](const ModelUsage& o) {
                return o.model.empty() || u.cost > o.cost || (u.cost == o.cost && u.tokens > o.tokens);
            };
            if (beats(top[0])) {
                top[1] = std::move(top[0]);
                top[0] = u;
            } else if (beats(top[1])) {
                top[1] = u;
            }
        }
    }
    s.firstDay = base_ + int64_t(dayStart_[size_t(today - 29)]) * kSlotSeconds;
    s.today = s.days[29];
    if (windowEnd > 0) {
        s.hasWindow = true;
        s.windowEnd = windowEnd;
        s.windowStart = windowEnd - 7 * 86400;
        s.window = sumRange(s.windowStart, windowEnd);
        s.previousWindow = sumRange(s.windowStart - 7 * 86400, s.windowStart);
    }
    double best = 0;
    for (size_t m = 0; m < models_.size(); ++m) {
        double cost = 0;
        for (int d = today - 29; d <= today; ++d) cost += modelCost_[m * kDays + size_t(d)];
        if (cost > best) {
            best = cost;
            s.topModel = models_[m].name;
        }
    }
    s.messages = messages_;
    s.unpricedModels = unpriced_;
    return s;
}

}  // namespace uq
