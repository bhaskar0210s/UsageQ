#include "storage.hpp"

#include <fts.h>
#include <string>
#include <sys/stat.h>
#include <unordered_set>

#include "util.hpp"

namespace uq {

StorageInfo measureStorage() {
    StorageInfo info;
    const std::string home = homeDir();
    const std::string roots[] = {
        home + "/.claude",           home + "/.claude.json",        home + "/.local/share/claude",
        home + "/.local/state/claude", home + "/.config/claude",    home + "/.cache/claude",
        home + "/Library/Caches/claude-cli-nodejs",
    };
    std::unordered_set<uint64_t> hardLinks;  // count multiply-linked files once
    for (const std::string& root : roots) {
        struct stat st;
        if (lstat(root.c_str(), &st) != 0) continue;
        info.valid = true;
        if (!S_ISDIR(st.st_mode)) {
            info.total += uint64_t(st.st_blocks) * 512;
            continue;
        }
        char* paths[] = {const_cast<char*>(root.c_str()), nullptr};
        FTS* fts = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nullptr);
        if (!fts) continue;
        while (FTSENT* e = fts_read(fts)) {
            if (e->fts_info == FTS_DP || e->fts_info == FTS_DNR || e->fts_info == FTS_ERR || e->fts_info == FTS_NS)
                continue;
            const struct stat* s = e->fts_statp;
            if (s->st_nlink > 1 && !S_ISDIR(s->st_mode) &&
                !hardLinks.insert((uint64_t(s->st_dev) << 40) ^ uint64_t(s->st_ino)).second)
                continue;
            info.total += uint64_t(s->st_blocks) * 512;
        }
        fts_close(fts);
    }
    return info;
}

}  // namespace uq
