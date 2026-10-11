#pragma once

#include <cstdint>

namespace tt {

struct StorageInfo {
    bool valid = false;
    uint64_t total = 0;
};

// Disk used by Claude Code: ~/.claude (logs, history, plugins...), ~/.claude.json,
// the installed CLI versions and its caches. Allocated bytes, like `du`.
StorageInfo measureStorage();

}  // namespace tt
