#include "engine.hpp"

#include <algorithm>
#include <cstdio>
#include <ctime>

#include "format.hpp"
#include "json.hpp"
#include "util.hpp"

namespace tt {

void Engine::refresh(int64_t now, bool measureStorageNow) {
    tzset();  // pick up time zone changes

    auto tokenHash = [this] { return creds_.valid() ? fnv1a(creds_.accessToken) : 0; };
    if (!creds_.valid() || creds_.expired(now) || tokenHash() == rejectedToken_) {
        // Claude Code renews its own token; re-read the Keychain until a usable one shows up.
        Credentials fresh;
        if (readCredentials(fresh)) creds_ = std::move(fresh);
    }
    if (snap_.account.email.empty() || now - accountReadAt_ >= 600) {
        snap_.account = readAccount(creds_);
        accountReadAt_ = now;
    }

    const bool usable = creds_.valid() && !creds_.expired(now) && tokenHash() != rejectedToken_;
    // The endpoint rate-limits bursts, so repeated menu clicks reuse a fetch from the last 30 s.
    if (usable && now >= retryAfter_ && now - lastFetchAt_ >= 30) {
        lastFetchAt_ = now;
        UsageResult r = fetchUsage(creds_.accessToken);
        lastError_ = r.error;
        lastStatus_ = r.httpStatus;
        switch (r.error) {
            case FetchError::None:
                snap_.windows = std::move(r.windows);
                snap_.updatedAt = now;
                rateLimitStrikes_ = 0;
                retryAfter_ = 0;
                break;
            case FetchError::Unauthorized:
                rejectedToken_ = tokenHash();
                break;
            case FetchError::RateLimited:
                rateLimitStrikes_ = std::min(rateLimitStrikes_ + 1, 5);
                retryAfter_ = now + (r.retryAfter > 0 ? std::clamp<int64_t>(r.retryAfter, 30, 3600)
                                                      : int64_t(60) << rateLimitStrikes_);
                break;
            default:
                break;
        }
    }

    // Transient failures stay quiet while the last update is recent; the card shows its age.
    const bool fresh = snap_.updatedAt > 0 && now - snap_.updatedAt < 900;
    if (!creds_.valid())
        snap_.notice = "Not signed in — run claude to log in";
    else if (!usable || lastError_ == FetchError::Unauthorized)
        snap_.notice = "Sign-in expired — open Claude Code to renew it";
    else if (lastError_ == FetchError::Forbidden)
        snap_.notice = "This login can't read usage limits";
    else if (lastError_ == FetchError::BadResponse)
        snap_.notice = "Unexpected response from Claude (HTTP " + std::to_string(lastStatus_) + ")";
    else if (lastError_ == FetchError::RateLimited && !fresh)
        snap_.notice = "Claude is rate limiting usage checks — retrying later";
    else if (lastError_ == FetchError::Network && !fresh)
        snap_.notice = "Offline — showing the last update";
    else
        snap_.notice.clear();

    scanner_.update(now);
    snap_.cost = scanner_.summarize(now, weeklyWindowEnd(snap_.windows, now));

    if (measureStorageNow && (storageAt_ == 0 || now - storageAt_ >= 60)) {
        snap_.storage = measureStorage();
        storageAt_ = now;
    }
}

int64_t weeklyWindowEnd(const std::vector<LimitWindow>& windows, int64_t now) {
    const LimitWindow* pick = nullptr;
    for (const auto& w : windows) {
        if (w.isSession || w.windowMinutes < 10080 || w.resetsAt <= 0) continue;
        if (!pick || w.title == "Weekly") pick = &w;  // prefer the all-models window
    }
    return pick ? effectiveWindow(*pick, now).resetsAt : 0;
}

const LimitWindow* primaryWindow(const std::vector<LimitWindow>& windows) {
    for (const auto& w : windows)
        if (w.isSession) return &w;
    return windows.empty() ? nullptr : &windows.front();
}

namespace {

void appendNumber(std::string& out, const char* fmt, double v) {
    char buf[48];
    snprintf(buf, sizeof buf, fmt, v);
    out += buf;
}

void appendUsage(std::string& out, const DayUsage& u) {
    out += "{\"usd\":";
    appendNumber(out, "%.2f", u.cost);
    out += ",\"tokens\":" + std::to_string(u.tokens) + "}";
}

std::string pad(std::string s, size_t width) {
    // Width in characters; strings here are ASCII except the middle dot and dash.
    size_t visible = 0;
    for (unsigned char c : s)
        if ((c & 0xC0) != 0x80) ++visible;
    if (visible < width) s.append(width - visible, ' ');
    return s;
}

}  // namespace

std::string snapshotJSON(const Snapshot& s, int64_t now) {
    std::string o = "{\n  \"updated_at\": ";
    if (s.updatedAt) json::appendQuoted(o, formatISOTime(s.updatedAt));
    else o += "null";
    o += ",\n  \"notice\": ";
    if (s.notice.empty()) o += "null";
    else json::appendQuoted(o, s.notice);

    o += ",\n  \"account\": {\"email\": ";
    json::appendQuoted(o, s.account.email);
    o += ", \"plan\": ";
    json::appendQuoted(o, s.account.plan);
    o += "},\n  \"limits\": [";
    for (size_t i = 0; i < s.windows.size(); ++i) {
        const LimitWindow w = effectiveWindow(s.windows[i], now);
        const Pace pace = computePace(w, now);
        o += i ? ",\n    {" : "\n    {";
        o += "\"name\": ";
        json::appendQuoted(o, w.title);
        o += ", \"used_percent\": ";
        appendNumber(o, "%.1f", w.usedPercent);
        o += ", \"left_percent\": ";
        appendNumber(o, "%.1f", std::max(0.0, 100.0 - w.usedPercent));
        o += ", \"window_minutes\": " + std::to_string(w.windowMinutes);
        o += ", \"resets_at\": ";
        if (w.resetsAt) json::appendQuoted(o, formatISOTime(w.resetsAt));
        else o += "null";
        o += ", \"resets_in\": ";
        if (w.resetsAt) json::appendQuoted(o, formatCountdown(w.resetsAt - now));
        else o += "null";
        o += ", \"pace\": ";
        if (pace.valid) {
            o += "{\"expected_percent\": ";
            appendNumber(o, "%.1f", pace.expected);
            o += ", \"delta_percent\": ";
            appendNumber(o, "%.1f", pace.delta);
            o += ", \"lasts_until_reset\": ";
            o += pace.lastsToReset ? "true" : "false";
            o += ", \"runs_out_in_seconds\": ";
            o += pace.hasEta ? std::to_string(int64_t(pace.etaSeconds)) : "null";
            o += ", \"summary\": ";
            json::appendQuoted(o, paceText(pace, w.isSession));
            o += "}";
        } else {
            o += "null";
        }
        o += "}";
    }
    o += s.windows.empty() ? "]" : "\n  ]";

    const CostSummary& c = s.cost;
    o += ",\n  \"cost\": ";
    if (!c.valid) {
        o += "null";
    } else {
        o += "{\n    \"note\": \"Estimated from local Claude Code logs at API list prices\",";
        o += "\n    \"today\": ";
        appendUsage(o, c.today);
        o += ",\n    \"last_30_days\": ";
        appendUsage(o, c.last30);
        if (c.hasWindow) {
            o += ",\n    \"current_window\": {\"start\": ";
            json::appendQuoted(o, formatISOTime(c.windowStart));
            o += ", \"end\": ";
            json::appendQuoted(o, formatISOTime(c.windowEnd));
            o += ", \"usage\": ";
            appendUsage(o, c.window);
            o += "},\n    \"previous_window\": ";
            appendUsage(o, c.previousWindow);
        }
        o += ",\n    \"top_model\": ";
        json::appendQuoted(o, c.topModel);
        o += ",\n    \"daily\": [";
        for (size_t i = 0; i < c.days.size(); ++i) {
            // Noon of each day keeps the date right across DST changes.
            const int64_t day = localMidnight(c.firstDay + int64_t(i) * 86400 + 43200);
            o += i ? ",\n      {\"date\": " : "\n      {\"date\": ";
            json::appendQuoted(o, formatISODate(day));
            o += ", \"usd\": ";
            appendNumber(o, "%.2f", c.days[i].cost);
            o += ", \"tokens\": " + std::to_string(c.days[i].tokens) + ", \"top_models\": [";
            bool first = true;
            for (const ModelUsage& m : c.dayModels[i]) {
                if (m.model.empty()) continue;
                o += first ? "{\"model\": " : ", {\"model\": ";
                first = false;
                json::appendQuoted(o, m.model);
                o += ", \"usd\": ";
                appendNumber(o, "%.2f", m.cost);
                o += ", \"tokens\": " + std::to_string(m.tokens) + "}";
            }
            o += "]}";
        }
        o += "\n    ]\n  }";
    }

    o += ",\n  \"storage\": ";
    o += s.storage.valid ? "{\"total_bytes\": " + std::to_string(s.storage.total) + "}" : std::string("null");
    o += "\n}\n";
    return o;
}

std::string snapshotText(const Snapshot& s, int64_t now) {
    std::string o = "Claude";
    if (!s.account.email.empty()) o += " \u00B7 " + s.account.email;
    if (!s.account.plan.empty()) o += " \u00B7 " + s.account.plan;
    o += s.updatedAt ? " \u00B7 updated " + formatAgo(now - s.updatedAt) : std::string(" \u00B7 limits unavailable");
    o += "\n";
    if (!s.notice.empty()) o += "! " + s.notice + "\n";
    for (const LimitWindow& raw : s.windows) {
        const LimitWindow w = effectiveWindow(raw, now);
        std::string line = pad(w.title, 15) + pad(formatPercent(std::max(0.0, 100.0 - w.usedPercent)) + " left", 10);
        if (w.resetsAt) line += pad("refills in " + formatCountdown(w.resetsAt - now), 20);
        line += paceText(computePace(w, now), w.isSession);
        line.erase(line.find_last_not_of(' ') + 1);
        o += line + "\n";
    }
    const CostSummary& c = s.cost;
    if (c.valid) {
        auto row = [&](const char* label, const DayUsage& u) {
            o += pad(label, 15) + pad(formatUSD(u.cost), 12) + formatTokens(double(u.tokens)) + " tokens\n";
        };
        row("Today", c.today);
        if (c.hasWindow) row("This week", c.window);
        if (c.hasWindow) row("Last week", c.previousWindow);
        row("Last 30 days", c.last30);
        if (!c.topModel.empty()) o += pad("Top model", 15) + modelDisplayName(c.topModel) + "\n";
    }
    if (s.storage.valid) o += pad("Storage", 15) + formatBytes(s.storage.total) + "\n";
    return o;
}

}  // namespace tt
