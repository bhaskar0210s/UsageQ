// Claude subscription limits: credentials, account info, and the OAuth usage endpoint.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace tt {

struct Credentials {
    std::string accessToken;
    int64_t expiresAt = 0;  // unix seconds, 0 = unknown
    std::string subscriptionType;
    std::string rateLimitTier;

    bool valid() const { return !accessToken.empty(); }
    bool expired(int64_t now) const { return expiresAt > 0 && now >= expiresAt - 30; }
};

struct Account {
    std::string email;
    std::string plan;  // "Team Premium", "Max 20x", ...
};

struct LimitWindow {
    std::string title;  // "Session", "Weekly", "Fable weekly"
    double usedPercent = 0;
    int64_t resetsAt = 0;  // unix seconds, 0 = unknown
    int windowMinutes = 0;
    bool isSession = false;
};

enum class FetchError { None, Network, Unauthorized, Forbidden, RateLimited, BadResponse };

struct UsageResult {
    FetchError error = FetchError::None;
    int httpStatus = 0;
    int retryAfter = 0;  // seconds, from a 429's Retry-After header
    std::vector<LimitWindow> windows;
};

// Claude Code's login: Keychain item "Claude Code-credentials" (read through /usr/bin/security,
// which the item already trusts, so no prompt), then ~/.claude/.credentials.json.
bool readCredentials(Credentials& out);

// Email from ~/.claude.json, plan from credentials + seat tier.
Account readAccount(const Credentials& creds);

UsageResult fetchUsage(const std::string& accessToken);
bool parseUsage(std::string_view body, std::vector<LimitWindow>& out);

// A window whose reset time has passed is shown as fresh (0%) until the next fetch.
LimitWindow effectiveWindow(const LimitWindow& w, int64_t now);

struct Pace {
    bool valid = false;
    double expected = 0;  // % that would be used at an even pace
    double delta = 0;     // actual - expected
    bool lastsToReset = false;
    bool hasEta = false;
    double etaSeconds = 0;
};

// CodexBar-compatible pace: linear burn since the window started.
Pace computePace(const LimitWindow& w, int64_t now);

// "runs dry in 3h 4m at this pace", "lasts until it refills"; empty when there is nothing to say.
std::string paceText(const Pace& pace, bool session);

}  // namespace tt
