#include "proc.hpp"

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <ctime>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace tt {
namespace {

int64_t monotonicMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return int64_t(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

void closeFd(int& fd) {
    if (fd >= 0) close(fd);
    fd = -1;
}

}  // namespace

ProcResult runProcess(const char* path, const std::vector<std::string>& args, std::string_view input, int timeoutMs,
                      size_t maxOutput) {
    ProcResult r;
    int inPipe[2] = {-1, -1};
    int outPipe[2] = {-1, -1};
    if (pipe(inPipe) != 0) return r;
    if (pipe(outPipe) != 0) {
        closeFd(inPipe[0]);
        closeFd(inPipe[1]);
        return r;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // CLOEXEC_DEFAULT: the child inherits only the three descriptors set up above.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    sigset_t noSignals;
    sigemptyset(&noSignals);
    posix_spawnattr_setsigmask(&attr, &noSignals);
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    posix_spawnattr_setsigdefault(&attr, &defaults);

    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
    argv.push_back(nullptr);

    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, &actions, &attr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    closeFd(inPipe[0]);
    closeFd(outPipe[1]);
    int inFd = inPipe[1];
    int outFd = outPipe[0];
    if (rc != 0) {
        closeFd(inFd);
        closeFd(outFd);
        return r;
    }

    fcntl(inFd, F_SETNOSIGPIPE, 1);  // a child that exits early must not SIGPIPE us
    fcntl(inFd, F_SETFL, O_NONBLOCK);
    fcntl(outFd, F_SETFL, O_NONBLOCK);
    if (input.empty()) closeFd(inFd);

    const int64_t deadline = monotonicMs() + timeoutMs;
    size_t written = 0;
    char buf[16384];
    while (outFd >= 0) {
        int64_t left = deadline - monotonicMs();
        if (left <= 0) {
            r.timedOut = true;
            break;
        }
        struct pollfd fds[2];
        nfds_t n = 0;
        fds[n++] = {outFd, POLLIN, 0};
        if (inFd >= 0) fds[n++] = {inFd, POLLOUT, 0};
        if (poll(fds, n, int(left)) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (inFd >= 0 && fds[1].revents) {
            ssize_t w = write(inFd, input.data() + written, input.size() - written);
            if (w > 0) written += size_t(w);
            if ((w < 0 && errno != EAGAIN && errno != EINTR) || written >= input.size()) closeFd(inFd);
        }
        if (fds[0].revents) {
            ssize_t got = read(outFd, buf, sizeof buf);
            if (got > 0) {
                size_t keep = std::min(size_t(got), maxOutput - std::min(maxOutput, r.out.size()));
                r.out.append(buf, keep);
            } else if (got == 0 || (errno != EAGAIN && errno != EINTR)) {
                closeFd(outFd);
            }
        }
    }
    closeFd(inFd);
    closeFd(outFd);

    if (r.timedOut) kill(pid, SIGKILL);
    int status = 0;
    bool reaped = false;
    for (;;) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            reaped = true;
            break;
        }
        if (w < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (!r.timedOut && monotonicMs() >= deadline) {
            r.timedOut = true;
            kill(pid, SIGKILL);
        }
        usleep(2000);
    }
    r.status = (reaped && !r.timedOut && WIFEXITED(status)) ? WEXITSTATUS(status) : -1;
    return r;
}

}  // namespace tt
