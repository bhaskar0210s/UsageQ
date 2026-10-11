// Ties the data sources together. Not thread-safe: drive one Engine from one queue.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "costs.hpp"
#include "storage.hpp"
#include "usage.hpp"

namespace tt {

struct Snapshot {
    int64_t updatedAt = 0;              // last successful limits fetch
    std::vector<LimitWindow> windows;   // last known limits (kept when a fetch fails)
    std::string notice;                 // why the limits may be stale; empty when fine
    Account account;
    CostSummary cost;
    StorageInfo storage;
};

class Engine {
public:
    // Fetches limits (at most every 30 s) and reads new log lines. Disk usage is only
    // measured when asked for, at most once a minute.
    void refresh(int64_t now, bool measureStorageNow);
    const Snapshot& snapshot() const { return snap_; }

private:
    Credentials creds_;
    uint64_t rejectedToken_ = 0;  // hash of a token the API refused; wait for Claude Code to renew it
    int64_t accountReadAt_ = 0;
    int64_t lastFetchAt_ = 0;
    int64_t retryAfter_ = 0;
    int rateLimitStrikes_ = 0;
    FetchError lastError_ = FetchError::None;
    int lastStatus_ = 0;
    int64_t storageAt_ = 0;
    CostScanner scanner_;
    Snapshot snap_;
};

// End of the weekly window used for "current window" cost (all-models weekly if present).
int64_t weeklyWindowEnd(const std::vector<LimitWindow>& windows, int64_t now);

// Session window (or the first window) shown in the menu bar; nullptr if none.
const LimitWindow* primaryWindow(const std::vector<LimitWindow>& windows);

std::string snapshotJSON(const Snapshot& s, int64_t now);
std::string snapshotText(const Snapshot& s, int64_t now);

}  // namespace tt
