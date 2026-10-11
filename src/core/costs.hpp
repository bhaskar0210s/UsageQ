// Estimated cost and token totals from Claude Code's local session logs
// (~/.claude/projects/**/*.jsonl), priced at Anthropic API list rates.
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "pages.hpp"

namespace uq {

struct Price;

struct DayUsage {
    double cost = 0;
    uint64_t tokens = 0;

    DayUsage& operator+=(const DayUsage& o) {
        cost += o.cost;
        tokens += o.tokens;
        return *this;
    }
};

struct ModelUsage {
    std::string model;  // model id, e.g. "claude-opus-5-5"; empty = no entry
    double cost = 0;
    uint64_t tokens = 0;
};

struct CostSummary {
    bool valid = false;
    int64_t firstDay = 0;              // local midnight of days[0]
    std::array<DayUsage, 30> days{};   // oldest first; days[29] is today
    std::array<std::array<ModelUsage, 2>, 30> dayModels{};  // each day's top two models by cost
    DayUsage today, last30;
    bool hasWindow = false;            // a weekly limit window is known
    int64_t windowStart = 0, windowEnd = 0;
    DayUsage window, previousWindow;
    std::string topModel;              // by cost over the last 30 days
    uint64_t messages = 0;             // deduplicated API responses in the scanned range
    bool unpricedModels = false;       // tokens from a model with no known price
};

class CostScanner {
public:
    // Reads lines appended since the previous call. The first call (and the first call of each
    // new local day) rescans everything modified in the last month.
    void update(int64_t now);

    // `windowEnd`: reset time of the weekly limit window (0 if unknown).
    CostSummary summarize(int64_t now, int64_t windowEnd) const;

private:
    struct Slot {
        double cost = 0;
        uint64_t tokens = 0;
    };
    // One deduplicated API response. Claude Code logs a response once per content block and
    // in every session that resumes it; repeats differ only in (partial) output tokens.
    struct Entry {
        uint64_t key;
        uint32_t output;
        uint32_t meta;  // slot | model << 12 | flags << 20
    };
    struct FileState {
        uint64_t inode = 0;
        uint64_t offset = 0;
    };
    struct Model {
        std::string name;
        const Price* price;
    };

    void reset(int64_t now);
    void scanTree(const std::string& root);
    void scanFile(const char* path, FileState& state);
    void ingest(const char* begin, const char* end);
    int modelIndex(std::string_view raw);
    Entry* lookup(uint64_t key);
    void grow();
    DayUsage sumRange(int64_t from, int64_t to) const;

    int64_t base_ = 0, end_ = 0;  // covered time range [base_, end_)
    int dayKey_ = -1;
    long gmtOffset_ = 0;
    std::vector<int> dayStart_;   // first slot of each day, plus one past the end
    PageArray<Slot> slots_;       // 15-minute buckets
    std::vector<uint8_t> slotDay_;
    std::vector<Model> models_;
    std::vector<std::pair<std::string, int>> rawModels_;  // raw log name -> models_ index
    std::vector<double> modelCost_;      // models_.size() x days
    std::vector<uint64_t> modelTokens_;  // models_.size() x days
    PageArray<Entry> table_;      // open addressing, 16 bytes per response
    size_t used_ = 0;
    std::unordered_map<uint64_t, FileState> files_;
    PageArray<char> buffer_;      // read buffer, released after every update
    uint64_t messages_ = 0;
    bool unpriced_ = false;
};

}  // namespace uq
