#include "usage.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include "format.hpp"
#include "json.hpp"
#include "proc.hpp"
#include "util.hpp"

#ifndef UQ_VERSION
#define UQ_VERSION "dev"
#endif

namespace uq {
namespace {

std::string lower(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = char(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

// Parses Claude Code's credential JSON and wipes the source buffer.
bool credentialsFromJSON(std::string& text, Credentials& out) {
    json::Value root;
    bool parsed = json::parse(text, root);
    secureZero(text);
    if (parsed) {
        const json::Value& oauth = root["claudeAiOauth"];
        std::string_view token = oauth["accessToken"].str();
        if (!token.empty()) {
            out.accessToken.assign(token);
            double expires = oauth["expiresAt"].num(0);
            out.expiresAt = expires > 1e11 ? int64_t(expires / 1000) : int64_t(expires);  // stored in ms
            out.subscriptionType.assign(oauth["subscriptionType"].str());
            out.rateLimitTier.assign(oauth["rateLimitTier"].str());
        }
    }
    json::wipe(root);
    return out.valid();
}

std::string planLabel(std::string_view subscription, std::string_view tier, std::string_view seat,
                      std::string_view organizationType) {
    std::string sub = lower(subscription), t = lower(tier), s = lower(seat), org = lower(organizationType);
    if (sub.empty()) {
        if (org.find("team") != std::string::npos) sub = "team";
        else if (org.find("enterprise") != std::string::npos) sub = "enterprise";
        else if (t.find("max") != std::string::npos) sub = "max";
        else if (t.find("pro") != std::string::npos) sub = "pro";
    }
    if (sub == "team") {
        if (s == "team_tier_1") return "Team Premium";
        if (s == "team_standard") return "Team Standard";
        return "Team";
    }
    if (sub == "max") {
        if (t.find("20x") != std::string::npos) return "Max 20x";
        if (t.find("5x") != std::string::npos) return "Max 5x";
        return "Max";
    }
    if (sub == "pro") return "Pro";
    if (sub == "enterprise") return "Enterprise";
    if (!sub.empty()) sub[0] = char(std::toupper(static_cast<unsigned char>(sub[0])));
    return sub;
}

bool tokenIsSafe(const std::string& token) {
    if (token.empty() || token.size() > 4096) return false;
    for (char c : token)
        if (!(std::isalnum(static_cast<unsigned char>(c)) || (c && strchr("-_.~+/=", c)))) return false;
    return true;
}

}  // namespace

bool readCredentials(Credentials& out) {
    out = Credentials{};
    ProcResult r = runProcess("/usr/bin/security", {"security", "find-generic-password", "-s", "Claude Code-credentials", "-w"},
                              {}, 10000, 1u << 20);
    if (r.status == 0 && credentialsFromJSON(r.out, out)) return true;
    secureZero(r.out);

    std::string text;
    if (readFile(homeDir() + "/.claude/.credentials.json", text, 1u << 20) && credentialsFromJSON(text, out)) return true;
    secureZero(text);
    return false;
}

Account readAccount(const Credentials& creds) {
    Account account;
    std::string seat, organizationType;
    std::string text;
    // ~/.claude.json can grow large; only the "oauthAccount" object is parsed.
    if (readFile(homeDir() + "/.claude.json", text, 256u << 20)) {
        size_t key = text.find("\"oauthAccount\"");
        size_t colon = key == std::string::npos ? key : text.find(':', key);
        json::Value oauth;
        if (colon != std::string::npos && json::parsePrefix(std::string_view(text).substr(colon + 1), oauth)) {
            account.email.assign(oauth["emailAddress"].str());
            seat.assign(oauth["seatTier"].str());
            organizationType.assign(oauth["organizationType"].str());
        }
    }
    account.plan = planLabel(creds.subscriptionType, creds.rateLimitTier, seat, organizationType);
    return account;
}

UsageResult fetchUsage(const std::string& accessToken) {
    UsageResult res;
    if (!tokenIsSafe(accessToken)) {
        res.error = FetchError::Unauthorized;
        return res;
    }
    // The request is made by /usr/bin/curl so TLS and networking never load into this process.
    // The token travels over stdin (config file), never on the command line.
    std::string config;
    config.reserve(640);
    config += "url = \"https://api.anthropic.com/api/oauth/usage\"\n";
    config += "header = \"Authorization: Bearer ";
    config += accessToken;
    config += "\"\n";
    config += "header = \"anthropic-beta: oauth-2025-04-20\"\n";
    config += "header = \"Accept: application/json\"\n";
    config += "user-agent = \"UsageQ/" UQ_VERSION "\"\n";
    config += "proto = \"=https\"\nsilent\nshow-error\nconnect-timeout = 10\nmax-time = 20\n";
    config += "write-out = \"\\n%{http_code} %header{retry-after}\"\n";
    ProcResult r = runProcess("/usr/bin/curl", {"curl", "-q", "-K", "-"}, config, 30000, 4u << 20);
    secureZero(config);

    size_t nl = r.out.rfind('\n');
    if (r.status != 0 || nl == std::string::npos) {
        res.error = FetchError::Network;
        return res;
    }
    char* rest = nullptr;
    res.httpStatus = int(strtol(r.out.c_str() + nl + 1, &rest, 10));
    res.retryAfter = rest ? std::max(0, atoi(rest)) : 0;  // an HTTP-date value parses as 0
    switch (res.httpStatus) {
        case 200:
            if (!parseUsage(std::string_view(r.out.data(), nl), res.windows)) res.error = FetchError::BadResponse;
            break;
        case 401: res.error = FetchError::Unauthorized; break;
        case 403: res.error = FetchError::Forbidden; break;
        case 429: res.error = FetchError::RateLimited; break;
        default: res.error = (res.httpStatus == 0 || res.httpStatus >= 500) ? FetchError::Network : FetchError::BadResponse;
    }
    return res;
}

bool parseUsage(std::string_view body, std::vector<LimitWindow>& out) {
    json::Value root;
    if (!json::parse(body, root) || !root.isObject()) return false;
    out.clear();

    auto add = [&](std::string title, double used, std::string_view resetsAt, int minutes, bool session) {
        for (const auto& w : out)
            if (w.title == title) return;
        LimitWindow w;
        w.title = std::move(title);
        w.usedPercent = std::clamp(used, 0.0, 1000.0);
        // Resets fall on whole minutes but arrive as 11:59:59.8 or 12:00:00.1; round away the jitter.
        const int64_t t = parseISO8601(resetsAt);
        w.resetsAt = t > 0 ? (t + 30) / 60 * 60 : 0;
        w.windowMinutes = minutes;
        w.isSession = session;
        out.push_back(std::move(w));
    };
    auto window = [&](std::string_view key, const char* title, int minutes, bool session) {
        const json::Value& v = root[key];
        if (v["utilization"].isNumber()) add(title, v["utilization"].num(), v["resets_at"].str(), minutes, session);
    };

    window("five_hour", "Session", 300, true);
    window("seven_day", "Weekly", 10080, false);
    for (const json::Value& limit : root["limits"].items) {
        if (!limit["percent"].isNumber()) continue;
        std::string_view kind = limit["kind"].str();
        if (kind == "session") {
            add("Session", limit["percent"].num(), limit["resets_at"].str(), 300, true);
        } else if (kind == "weekly" || kind == "weekly_scoped") {
            std::string name(limit["scope"]["model"]["display_name"].str());
            bool allModels = name.empty() || lower(name) == "all models";
            add(allModels ? "Weekly" : name + " weekly", limit["percent"].num(), limit["resets_at"].str(), 10080, false);
        }
    }
    window("seven_day_opus", "Opus weekly", 10080, false);
    window("seven_day_sonnet", "Sonnet weekly", 10080, false);

    std::stable_partition(out.begin(), out.end(), [](const LimitWindow& w) { return w.isSession; });
    return true;
}

LimitWindow effectiveWindow(const LimitWindow& w, int64_t now) {
    LimitWindow r = w;
    if (r.resetsAt > 0 && now >= r.resetsAt) {
        r.usedPercent = 0;
        const int64_t period = int64_t(r.windowMinutes) * 60;
        if (!r.isSession && period > 0) {
            while (r.resetsAt <= now) r.resetsAt += period;
        } else {
            r.resetsAt = 0;  // a new session starts with the next message
        }
    }
    return r;
}

Pace computePace(const LimitWindow& w, int64_t now) {
    Pace pace;
    if (w.resetsAt <= 0 || w.windowMinutes <= 0) return pace;
    const double duration = w.windowMinutes * 60.0;
    const double untilReset = double(w.resetsAt - now);
    if (untilReset <= 0 || untilReset > duration) return pace;
    const double elapsed = std::clamp(duration - untilReset, 0.0, duration);
    const double expected = std::clamp(elapsed / duration * 100.0, 0.0, 100.0);
    const double actual = std::clamp(w.usedPercent, 0.0, 100.0);
    if (elapsed <= 0 && actual > 0) return pace;
    if (w.isSession && (actual >= 100 || expected < 3)) return pace;

    pace.valid = true;
    pace.expected = expected;
    pace.delta = actual - expected;
    if (actual >= 100) {
        pace.hasEta = true;
        pace.etaSeconds = 0;
    } else if (elapsed > 0 && actual > 0) {
        const double toEmpty = (100.0 - actual) * elapsed / actual;
        if (toEmpty >= untilReset) {
            pace.lastsToReset = true;
        } else {
            pace.hasEta = true;
            pace.etaSeconds = toEmpty;
        }
    } else if (elapsed > 0) {
        pace.lastsToReset = true;
    }
    return pace;
}

std::string paceText(const Pace& pace, bool session) {
    (void)session;
    if (!pace.valid) return {};
    const long delta = std::lround(std::fabs(pace.delta));
    std::string text = delta == 0 ? "on pace" : std::to_string(delta) + (pace.delta < 0 ? "% in reserve" : "% over pace");
    if (pace.lastsToReset) {
        text += " \u00B7 lasts until reset";
    } else if (pace.hasEta) {
        const std::string eta = formatCountdown(int64_t(pace.etaSeconds));
        text += eta == "now" ? " \u00B7 at 100% now" : " \u00B7 100% in " + eta;
    }
    return text;
}

}  // namespace uq
