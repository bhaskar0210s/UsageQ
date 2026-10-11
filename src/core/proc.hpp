#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace uq {

struct ProcResult {
    int status = -1;  // exit code, -1 if it could not run or was killed
    bool timedOut = false;
    std::string out;  // captured stdout (stderr is discarded)
};

// Runs `path` with `args` (args[0] is the program name), feeds `input` on stdin and
// captures stdout. The child is killed once `timeoutMs` elapses.
ProcResult runProcess(const char* path, const std::vector<std::string>& args, std::string_view input, int timeoutMs,
                      size_t maxOutput = 1u << 20);

}  // namespace uq
