#include "alerts.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace uq {

namespace {

// resets_at can move by a minute between responses; a new period moves it by hours.
constexpr int64_t kSamePeriod = 15 * 60;

}  // namespace

std::vector<int> parseThresholds(std::string_view text) {
    std::vector<int> out;
    while (!text.empty()) {
        const size_t comma = text.find(',');
        std::string_view part = text.substr(0, comma);
        text = comma == std::string_view::npos ? std::string_view() : text.substr(comma + 1);
        while (!part.empty() && part.front() == ' ') part.remove_prefix(1);
        while (!part.empty() && part.back() == ' ') part.remove_suffix(1);
        if (part.empty() || part.size() > 3) continue;
        int value = 0;
        bool digits = true;
        for (char c : part) {
            if (c < '0' || c > '9') {
                digits = false;
                break;
            }
            value = value * 10 + (c - '0');
        }
        if (digits && value >= 1 && value <= 100) out.push_back(value);
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

std::string formatThresholds(const std::vector<int>& thresholds) {
    std::string out;
    for (int t : thresholds) {
        if (!out.empty()) out += ',';
        out += std::to_string(t);
    }
    return out;
}

std::vector<Alert> AlertTracker::check(const std::vector<LimitWindow>& windows, const std::vector<int>& thresholds,
                                       int64_t now) {
    std::vector<Alert> alerts;
    for (const LimitWindow& raw : windows) {
        const LimitWindow w = effectiveWindow(raw, now);
        if (w.resetsAt <= 0) continue;  // not started yet
        auto mark = std::find_if(marks_.begin(), marks_.end(), [&](const Mark& m) { return m.title == w.title; });
        if (mark == marks_.end()) mark = marks_.insert(marks_.end(), Mark{w.title, w.resetsAt, 0});
        if (std::llabs(mark->resetsAt - w.resetsAt) > kSamePeriod) mark->percent = 0;  // a new period
        mark->resetsAt = w.resetsAt;
        // Compare what the card shows ("75%" for 74.6), so the alert never disagrees with it.
        const double shown = std::floor(w.usedPercent + 0.5);
        int reached = 0;
        for (int t : thresholds)
            if (shown >= t) reached = t;
        if (reached > mark->percent) {
            mark->percent = reached;
            alerts.push_back({w, reached});
        }
    }
    return alerts;
}

std::string AlertTracker::save() const {
    std::string out;
    for (const Mark& m : marks_) {
        if (m.percent <= 0) continue;
        out += m.title + '\t' + std::to_string(m.resetsAt) + '\t' + std::to_string(m.percent) + '\n';
    }
    return out;
}

void AlertTracker::load(std::string_view text) {
    marks_.clear();
    while (!text.empty()) {
        const size_t end = text.find('\n');
        const std::string_view line = text.substr(0, end);
        text = end == std::string_view::npos ? std::string_view() : text.substr(end + 1);
        const size_t a = line.find('\t');
        const size_t b = a == std::string_view::npos ? a : line.find('\t', a + 1);
        if (b == std::string_view::npos || a == 0) continue;
        Mark m;
        m.title = std::string(line.substr(0, a));
        m.resetsAt = std::strtoll(std::string(line.substr(a + 1, b - a - 1)).c_str(), nullptr, 10);
        m.percent = std::atoi(std::string(line.substr(b + 1)).c_str());
        if (m.resetsAt > 0 && m.percent > 0 && m.percent <= 100) marks_.push_back(std::move(m));
    }
}

}  // namespace uq
