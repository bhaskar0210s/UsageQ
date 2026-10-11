// usageq: the menu bar app's data as text or JSON, for terminals and coding agents.
#include <cstdio>
#include <cstring>
#include <string>

#include "../core/engine.hpp"
#include "../core/util.hpp"

#ifndef UQ_VERSION
#define UQ_VERSION "dev"
#endif

static void usage() {
    puts("usage: usageq [--json]\n"
         "\n"
         "Claude usage from the same sources as the UsageQ menu bar app:\n"
         "  limits   session and weekly limits (Claude Code's login, read-only)\n"
         "  cost     estimated from local Claude Code logs at API list prices\n"
         "  storage  disk used by Claude Code\n"
         "\n"
         "  --json     machine-readable output (for scripts and agents)\n"
         "  --version  print the version");
}

int main(int argc, char** argv) {
    bool json = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--json") || !strcmp(argv[i], "-j")) {
            json = true;
        } else if (!strcmp(argv[i], "--version")) {
            puts("usageq " UQ_VERSION);
            return 0;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage();
            return 0;
        } else {
            fprintf(stderr, "usageq: unknown option %s\n", argv[i]);
            usage();
            return 2;
        }
    }
    uq::Engine engine;
    const int64_t now = uq::nowSeconds();
    engine.refresh(now, true);
    const uq::Snapshot& s = engine.snapshot();
    const std::string out = json ? uq::snapshotJSON(s, now) : uq::snapshotText(s, now);
    fwrite(out.data(), 1, out.size(), stdout);
    return (s.windows.empty() && !s.cost.valid) ? 1 : 0;
}
