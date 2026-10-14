// Notifications at chosen percentages ("Notify at" in Settings).
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "usage.hpp"

namespace uq {

// "50,75" -> {50, 75}: whole percentages from 1 to 100, sorted, without repeats. Anything else
// between the commas is skipped.
std::vector<int> parseThresholds(std::string_view text);

// {50, 75} -> "50,75"
std::string formatThresholds(const std::vector<int>& thresholds);

struct Alert {
    LimitWindow window;  // the limit as it is now
    int percent = 0;     // the threshold it reached
};

// Remembers, for each limit and reset period, the highest threshold already announced, so each
// threshold notifies once per period. Reaching several at once gives one alert, for the highest.
class AlertTracker {
public:
    // `thresholds` sorted ascending, as parseThresholds returns them.
    std::vector<Alert> check(const std::vector<LimitWindow>& windows, const std::vector<int>& thresholds,
                             int64_t now);

    // One line per limit, kept between launches so a restart doesn't announce a threshold again.
    std::string save() const;
    void load(std::string_view text);

private:
    struct Mark {
        std::string title;
        int64_t resetsAt = 0;
        int percent = 0;
    };
    std::vector<Mark> marks_;
};

}  // namespace uq
