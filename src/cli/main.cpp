// tokentank: the menu bar app's data as text or JSON, for terminals and coding agents.
#include <cstdio>
#include <cstring>
#include <string>

#include "../core/engine.hpp"
#include "../core/util.hpp"

#ifndef TT_VERSION
#define TT_VERSION "dev"
#endif

static void usage() {
    puts("usage: tokentank [--json]\n"
         "\n"
         "Claude usage from the same sources as the TokenTank menu bar app:\n"
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
            puts("tokentank " TT_VERSION);
            return 0;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage();
            return 0;
        } else {
            fprintf(stderr, "tokentank: unknown option %s\n", argv[i]);
            usage();
            return 2;
        }
    }
    tt::Engine engine;
    const int64_t now = tt::nowSeconds();
    engine.refresh(now, true);
    const tt::Snapshot& s = engine.snapshot();
    const std::string out = json ? tt::snapshotJSON(s, now) : tt::snapshotText(s, now);
    fwrite(out.data(), 1, out.size(), stdout);
    return (s.windows.empty() && !s.cost.valid) ? 1 : 0;
}
