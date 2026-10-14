// Unit tests for the core: `make test` (built with AddressSanitizer and UBSan).

#include <cstdio>
#include <string>
#include <vector>

#include "../src/core/alerts.hpp"
#include "../src/core/format.hpp"
#include "../src/core/usage.hpp"

namespace {

int failures = 0;
int checks = 0;

#define CHECK(cond)                                                                \
    do {                                                                           \
        ++checks;                                                                  \
        if (!(cond)) {                                                             \
            ++failures;                                                            \
            std::fprintf(stderr, "%s:%d: FAILED %s\n", __FILE__, __LINE__, #cond); \
        }                                                                          \
    } while (0)

using uq::AlertTracker;
using uq::LimitWindow;

constexpr int64_t kNow = 1'800'000'000;
constexpr int64_t kHour = 3600;

LimitWindow session(double used, int64_t resetsAt = kNow + 2 * kHour) {
    return {"Session", used, resetsAt, 300, true};
}

LimitWindow weekly(double used, int64_t resetsAt = kNow + 4 * 24 * kHour) {
    return {"Fable weekly", used, resetsAt, 10080, false};
}

// The percentages announced for `windows`, in order.
std::vector<int> fire(AlertTracker& t, const std::vector<LimitWindow>& windows, const std::vector<int>& at,
                      int64_t now = kNow) {
    std::vector<int> out;
    for (const uq::Alert& a : t.check(windows, at, now)) out.push_back(a.percent);
    return out;
}

void testParse() {
    using V = std::vector<int>;
    CHECK(uq::parseThresholds("50,75") == V({50, 75}));
    CHECK(uq::parseThresholds("75,50,50") == V({50, 75}));
    CHECK(uq::parseThresholds("0,101,abc,,5") == V({5}));
    CHECK(uq::parseThresholds("").empty());
    CHECK(uq::parseThresholds(",,,").empty());
    CHECK(uq::parseThresholds("100") == V({100}));
    CHECK(uq::parseThresholds(" 50 , 75 ") == V({50, 75}));
    CHECK(uq::parseThresholds("1000,-5,5.5,90") == V({90}));
    CHECK(uq::formatThresholds({50, 75}) == "50,75");
    CHECK(uq::formatThresholds({}).empty());
    CHECK(uq::formatThresholds(uq::parseThresholds("90,50,75,50")) == "50,75,90");
}

void testCrossing() {
    const std::vector<int> at = {50, 75};
    AlertTracker t;
    CHECK(fire(t, {session(40)}, at).empty());
    CHECK(fire(t, {session(52)}, at) == std::vector<int>({50}));
    CHECK(fire(t, {session(60)}, at).empty());           // 50 is done for this period
    CHECK(fire(t, {session(80)}, at) == std::vector<int>({75}));
    CHECK(fire(t, {session(95)}, at).empty());
    CHECK(fire(t, {session(100)}, {50, 75, 100}) == std::vector<int>({100}));  // a value added later

    AlertTracker jump;
    CHECK(fire(jump, {session(40)}, at).empty());
    CHECK(fire(jump, {session(80)}, at) == std::vector<int>({75}));  // both passed: one alert, the highest

    AlertTracker start;  // already past both when the app starts
    CHECK(fire(start, {session(90)}, at) == std::vector<int>({75}));
    CHECK(fire(start, {session(90)}, at).empty());

    AlertTracker rounding;  // 74.6% shows as 75% on the card
    CHECK(fire(rounding, {session(74.6)}, at) == std::vector<int>({75}));
    AlertTracker below;
    CHECK(fire(below, {session(74.4)}, at) == std::vector<int>({50}));

    AlertTracker none;
    CHECK(fire(none, {session(90)}, {}).empty());
}

void testPeriods() {
    const std::vector<int> at = {50, 75};
    AlertTracker t;
    CHECK(fire(t, {session(55)}, at) == std::vector<int>({50}));
    CHECK(fire(t, {session(56, kNow + 2 * kHour + 60)}, at).empty());  // resets_at moved a minute: same period
    CHECK(fire(t, {session(55, kNow + 7 * kHour)}, at) == std::vector<int>({50}));  // next session

    // Past its reset the window counts as fresh (0%), so nothing fires until new numbers arrive.
    AlertTracker stale;
    CHECK(fire(stale, {session(90, kNow - 60)}, at).empty());
    CHECK(fire(stale, {weekly(90, kNow - 60)}, at).empty());
}

void testLimitsAreSeparate() {
    const std::vector<int> at = {50, 75};
    AlertTracker t;
    const std::vector<uq::Alert> first = t.check({session(60), weekly(80)}, at, kNow);
    CHECK(first.size() == 2);
    if (first.size() == 2) {
        CHECK(first[0].window.title == "Session" && first[0].percent == 50);
        CHECK(first[1].window.title == "Fable weekly" && first[1].percent == 75);
    }
    CHECK(fire(t, {session(76), weekly(85)}, at) == std::vector<int>({75}));
}

void testSaveLoad() {
    const std::vector<int> at = {50, 75};
    AlertTracker t;
    CHECK(fire(t, {session(60), weekly(80)}, at).size() == 2);
    const std::string saved = t.save();
    CHECK(saved == "Session\t" + std::to_string(kNow + 2 * kHour) + "\t50\nFable weekly\t" +
                       std::to_string(kNow + 4 * 24 * kHour) + "\t75\n");

    AlertTracker restarted;
    restarted.load(saved);
    CHECK(fire(restarted, {session(60), weekly(80)}, at).empty());  // no repeats after a relaunch
    CHECK(fire(restarted, {session(76), weekly(80)}, at) == std::vector<int>({75}));

    AlertTracker garbage;
    garbage.load("no tabs here\n\t1\t2\nSession\tx\t50\nSession\t5\t500\n");
    CHECK(garbage.save().empty());
    CHECK(fire(garbage, {session(60)}, at) == std::vector<int>({50}));
}

void testFormat() {
    CHECK(uq::formatPercent(74.6) == "75%");
    CHECK(uq::formatPercent(0) == "0%");
    CHECK(uq::formatCountdown(0) == "now");
    CHECK(uq::formatCountdown(59) == "1m");
    CHECK(uq::formatCountdown(3660) == "1h 1m");
    CHECK(uq::formatCountdown(4 * 86400 + 3600) == "4d 1h");
}

void testEffectiveWindow() {
    const LimitWindow s = uq::effectiveWindow(session(80, kNow - 1), kNow);
    CHECK(s.usedPercent == 0 && s.resetsAt == 0);
    const LimitWindow w = uq::effectiveWindow(weekly(80, kNow - 1), kNow);
    CHECK(w.usedPercent == 0 && w.resetsAt == kNow - 1 + 7 * 24 * kHour);
    const LimitWindow live = uq::effectiveWindow(session(80), kNow);
    CHECK(live.usedPercent == 80);
}

}  // namespace

int main() {
    testParse();
    testCrossing();
    testPeriods();
    testLimitsAreSeparate();
    testSaveLoad();
    testFormat();
    testEffectiveWindow();
    std::printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
