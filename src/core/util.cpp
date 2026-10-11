#include "util.hpp"

#include <cerrno>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

namespace tt {

std::string homeDir() {
    if (const char* h = getenv("HOME"); h && *h) return h;
    struct passwd pw;
    struct passwd* res = nullptr;
    char buf[4096];
    if (getpwuid_r(getuid(), &pw, buf, sizeof buf, &res) == 0 && res && res->pw_dir) return res->pw_dir;
    return "/";
}

int64_t nowSeconds() { return int64_t(time(nullptr)); }

bool readFile(const std::string& path, std::string& out, size_t maxBytes) {
    out.clear();
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0 || size_t(st.st_size) > maxBytes) {
        close(fd);
        return false;
    }
    out.resize(size_t(st.st_size));
    size_t got = 0;
    while (got < out.size()) {
        ssize_t n = read(fd, out.data() + got, out.size() - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            out.clear();
            return false;
        }
        if (n == 0) break;
        got += size_t(n);
    }
    out.resize(got);
    close(fd);
    return true;
}

void secureZero(std::string& s) {
    volatile char* v = s.data();
    for (size_t i = 0; i < s.size(); ++i) v[i] = 0;
    s.clear();
}

uint64_t fnv1a(std::string_view s, uint64_t h) {
    for (unsigned char c : s) {
        h ^= c;
        h *= 1099511628211ULL;
    }
    return h;
}

namespace {

// Howard Hinnant's days_from_civil.
int64_t daysFromCivil(int64_t y, int m, int d) {
    y -= m <= 2;
    const int64_t era = (y >= 0 ? y : y - 399) / 400;
    const int64_t yoe = y - era * 400;
    const int64_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

int digits(std::string_view s, size_t at, size_t n) {
    if (at + n > s.size()) return -1;
    int v = 0;
    for (size_t i = at; i < at + n; ++i) {
        if (s[i] < '0' || s[i] > '9') return -1;
        v = v * 10 + (s[i] - '0');
    }
    return v;
}

}  // namespace

int64_t parseISO8601(std::string_view s) {
    if (s.size() < 19 || s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != ' ') || s[13] != ':' || s[16] != ':')
        return 0;
    int year = digits(s, 0, 4), mon = digits(s, 5, 2), day = digits(s, 8, 2);
    int hour = digits(s, 11, 2), min = digits(s, 14, 2), sec = digits(s, 17, 2);
    if (year < 0 || mon < 1 || mon > 12 || day < 1 || day > 31 || hour < 0 || hour > 23 || min < 0 || min > 59 ||
        sec < 0 || sec > 60)
        return 0;
    size_t i = 19;
    if (i < s.size() && s[i] == '.')
        for (++i; i < s.size() && s[i] >= '0' && s[i] <= '9'; ++i) {}
    int64_t offset = 0;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
        int oh = digits(s, i + 1, 2);
        size_t mAt = (i + 3 < s.size() && s[i + 3] == ':') ? i + 4 : i + 3;
        int om = digits(s, mAt, 2);
        if (oh < 0) return 0;
        offset = (oh * 3600 + (om < 0 ? 0 : om) * 60) * (s[i] == '-' ? -1 : 1);
    }
    return daysFromCivil(year, mon, day) * 86400 + hour * 3600 + min * 60 + sec - offset;
}

int64_t localMidnight(int64_t t, int dayOffset) {
    time_t tt = time_t(t);
    struct tm tm;
    localtime_r(&tt, &tm);
    tm.tm_mday += dayOffset;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    tm.tm_isdst = -1;
    return int64_t(mktime(&tm));
}

}  // namespace tt
