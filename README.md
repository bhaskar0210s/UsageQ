<h1 align="center">TokenTank</h1>

<p align="center"><b>Tokens? Check the tank.</b><br>
A tiny macOS menu bar app that shows how much of your <b>Claude</b> usage is left, as fuel gauges, and tells you when you'll run dry.</p>

<p align="center">
  <img src="docs/menubar-dark.png" width="92" alt="TokenTank in the menu bar: a fuel gauge and 62%">
  &nbsp;
  <img src="docs/menubar-light.png" width="92" alt="TokenTank in a light menu bar">
</p>

<p align="center">
  <img src="docs/menu-dark.png" width="320" alt="TokenTank menu, dark">
  &nbsp;&nbsp;
  <img src="docs/menu-light.png" width="320" alt="TokenTank menu, light">
</p>

<p align="center"><sub>Screenshots use made-up demo data.</sub></p>

## What you get

- **One glance.** The menu bar shows a fuel gauge and how much of your current Claude session is left.
- **A straight answer.** The top of the menu says *All good*, or *Session runs dry ~5:02 PM at this pace*, so you never have to work out burn rates yourself.
- **Every limit as a gauge.** Session (5-hour), weekly, and model-specific weekly limits (Opus, Fable, ...), each with what's left, when it refills, and whether it lasts until then.
- **What it costs.** Today, this week, last week and the last 30 days, in dollars and tokens, estimated at API prices from your local Claude Code logs.
- **30-day history.** Cost and token bars for every day. Hover a day to see its totals and its top two models.
- **Storage.** How much disk Claude Code uses: logs, history, plugins and installed versions.
- **Built for agents too.** `tokentank --json` prints the same data for scripts and coding agents.
- **Tiny.** Native C++ with a thin AppKit shell. About 10 MB of memory; no Electron, no web views, no background daemons.
- **Zero setup.** It reuses your Claude Code login, read-only. No API keys, no accounts, no telemetry.

## Install

Needs macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`), and Claude Code signed in at least once.

```sh
git clone https://github.com/bhaskar0210s/TokenTank.git
cd TokenTank
make install
```

This builds the app, copies `TokenTank.app` to `/Applications`, links the `tokentank` command into `~/.local/bin`, and starts it. On its first launch it adds itself to Login Items; you can turn that off in **Settings → Launch at Login**. `make uninstall` removes everything again.

## Using it

- **Click the gauge** to open the menu. Every click refreshes the numbers.
- **Read the banner first:** green means nothing runs dry before it refills, amber means something will at your current pace, red means a limit is empty or about to be.
- **Gauges** read like a fuel gauge, from E (empty) to F (full). Under each one: when it refills, and either *Lasts to refill* or *Dry by 9:33 PM*.
- **Hover the chart** to inspect any of the last 30 days. Move the pointer down and the day stays selected while you read it.
- **Settings:** refresh every 1, 2, 5 or 15 minutes (default 5), and Launch at Login.

## For scripts and agents

```sh
tokentank          # readable summary
tokentank --json   # limits, forecasts, spend, 30 daily points with top models, storage
```

```text
Claude · you@example.com · Max 20x · updated just now
Session        62% left  refills in 2h 41m     lasts until it refills
Weekly         53% left  refills in 4d 3h      runs dry in 3d 6h at this pace
Today          $8.35       24.5M tokens
This week      $134.12     363M tokens
Last week      $249.40     668M tokens
Last 30 days   $961.07     2.6B tokens
Top model      Opus 5.5
Storage        1.4 GB
```

## How it works

- **Limits** come from the same endpoint Claude Code uses for `/usage` (`api.anthropic.com/api/oauth/usage`). The token is Claude Code's own, read from its Keychain item through `/usr/bin/security`, which that item already trusts, so there's no prompt. The request runs in a short-lived `/usr/bin/curl` process with the token passed on stdin. Nothing is stored or sent anywhere else.
- **Forecasts** assume you keep burning at your average rate since the window opened. If that would empty a limit before it refills, you get the time it runs dry.
- **Costs** are read from `~/.claude/projects/**/*.jsonl`. Each API response is counted once, even though Claude Code logs it repeatedly. Prices follow Anthropic's API list prices: 5-minute vs 1-hour cache writes, long-context tiers and fast mode included. These are API-equivalent estimates; your subscription doesn't bill this way.
- **The endpoint is rate-limited**, so TokenTank calls it at most every 30 seconds and backs off on HTTP 429. The local log scan runs on every click.

## Small on purpose

TokenTank uses about 10 MB of memory idle and around 15 MB after the menu has been opened. An empty AppKit menu bar app needs 8–14 MB on its own, so TokenTank adds very little on top.

- The data layer (`src/core`) is plain C++20; the app (`src/app/main.mm`) is a thin Objective-C++ shell, and the whole menu card is one custom-drawn view.
- Keychain and network access happen in short-lived child processes, so no TLS or networking stack stays loaded.
- Logs are parsed with a zero-copy field scanner. Its buffers live on their own memory pages and are returned to the system after every pass; after the first scan, only newly appended log lines are read.

```sh
make leakcheck   # runs Apple's `leaks` on the CLI and on the app through 100 refresh + menu cycles
```

TokenTank's own code shows zero leaks. In the app, `leaks` lists 26 KB from Apple's AppIntents framework, which an empty AppKit app reports identically.

## Develop

```sh
make            # app + CLI in build/
make dev        # debuggable build with test hooks:
                #   --soak N                     refresh + menu cycles, printing memory
                #   --render out.png --demo      draw the menu with demo data (--dark, --tiles 1-4, --day N)
                #   --render-bar out.png         draw the menu bar item
```

```
src/core/   C++ data layer: limits API, credentials, log scanner, pricing, forecasts, storage
src/cli/    tokentank command-line tool
src/app/    AppKit menu bar app
```

## Acknowledgements

Thanks to [CodexBar](https://github.com/steipete/CodexBar) (MIT), whose open-source Claude provider documents the usage endpoint and credential handling. TokenTank is an independent, Claude-only app with its own design and code.

## License

MIT. TokenTank is an independent project, not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.
