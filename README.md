<h1 align="center">Usage?</h1>

<p align="center"><b>How much Claude have I used?</b><br>
A tiny, native macOS menu bar app for your Claude Code limits and spending.</p>

<p align="center">
  <img src="docs/menubar-dark.png" width="84" alt="Usage? in the menu bar: two small meters and 38%">
  &nbsp;
  <img src="docs/menubar-light.png" width="84" alt="Usage? in a light menu bar">
</p>

<p align="center">
  <img src="docs/menu-dark.png" width="320" alt="Usage? menu, dark">
  &nbsp;&nbsp;
  <img src="docs/menu-light.png" width="320" alt="Usage? menu, light">
</p>

<p align="center"><sub>Screenshots use made-up demo data.</sub></p>

## What you see

- **Your limits as meters.** Session and weekly limits (including model-specific ones such as *Fable weekly*) show how much is used, with marks at 50%, 75% and 100%.
- **Pace on the meter itself.** A thin marker shows the *even pace*: where you'd be with steady use. The gap between it and your usage is your reserve (green) or how far over pace you are (orange).
- **Plain answers.** *12% in reserve*, *At this pace: lasts until reset*, or *100% by Wed 9:14 AM*. Resets are shown as clock times, *Resets 6:15 PM · in 2h 29m*.
- **Spending.** Cost and tokens for Today, This week, Last week and the last 30 days, estimated at API prices from your local Claude Code logs.
- **30 days at a glance.** Daily cost and token bars. Hover a day to see its totals and its top two models.
- **The essentials, nothing else.** Your plan, the disk space Claude Code uses, Settings and Quit, all in one footer.
- **In the menu bar.** Two tiny meters (session and weekly) and how much of your session you've used.

## Install

You need macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`), and to have signed in to Claude Code at least once.

```sh
git clone https://github.com/bhaskar0210s/UsageQ.git
cd UsageQ
make install
```

`make install` builds the app and installs it as `/Applications/UsageQ.app`, which Finder shows as **Usage?**. It also links the `usageq` command into `~/.local/bin` and starts the app. On first launch the app adds itself to Login Items; turn that off under ⚙︎ → Launch at Login. `make uninstall` removes everything again.

> **Why UsageQ?** The app is called **Usage?**, but a question mark can't go in repository names or terminal commands, so those use **UsageQ** / `usageq`.

## Using it

- **Click the meters icon** to open the card. Every click refreshes the numbers.
- **Hover the bars** to inspect any of the last 30 days. Move the pointer down and the day stays selected while you read it.
- **⚙︎ Settings:** refresh every 1, 2, 5 or 15 minutes (default 5), Launch at Login, and Show Claude Code Data in Finder.
- **⏻ Quit**, or press ⌘Q while the card is open.
- When the numbers aren't fresh, for example offline, a short note at the top says so and shows how old they are.

## For scripts and agents

```sh
usageq          # readable summary
usageq --json   # limits, pace, spending (30 daily points with each day's top models), disk use
```

```text
Claude · you@example.com · Max 20x · updated just now
Session        38% used  resets in 2h 29m   12% in reserve · lasts until reset
Fable weekly   52% used  resets in 4d 1h    10% over pace · 100% in 2d 17h
Today          $8.35       24.5M tokens
This week      $134.12     363M tokens
Last week      $249.40     668M tokens
Last 30 days   $961.07     2.6B tokens
Top model      Opus 5.5
Storage        1.4 GB
```

## How it works

- **Limits** come from the endpoint Claude Code uses for `/usage` (`api.anthropic.com/api/oauth/usage`). The app uses Claude Code's own login token. It reads the token from Claude Code's Keychain item through `/usr/bin/security`, which that item already trusts, so there's no prompt. Each request runs in a short-lived `/usr/bin/curl` process with the token passed on stdin. Nothing is stored or sent anywhere else.
- **Pace** compares your usage with steady use since the window opened. If your current rate would reach 100% before the reset, you see when.
- **Spending** is read from `~/.claude/projects/**/*.jsonl`. Each API response counts once, even though Claude Code logs it repeatedly. Prices follow Anthropic's API list prices, including cache writes (5-minute vs 1-hour), long-context tiers and fast mode. These are API-equivalent estimates; a subscription doesn't bill this way.
- The usage endpoint rate-limits bursts. The app calls it at most every 30 seconds and backs off when told to; the local log scan runs on every click.

## Small on purpose

About 10 MB of memory when idle, about 15 MB after the card has been opened. An empty AppKit menu bar app needs 8–14 MB on its own.

- The data layer (`src/core`) is plain C++20. The app (`src/app/main.mm`) is a thin AppKit shell, and the card is a single custom-drawn view using SF Pro, SF Symbols and system colors.
- Keychain and network access run in short-lived helper processes, so no networking stack stays loaded.
- The log scanner reads only newly appended lines after the first pass. Its buffers live on their own memory pages and are handed back to the system after every pass.

```sh
make leakcheck   # Apple's `leaks` on the CLI, then on the app through 100 refresh + open/close cycles
```

The app's own code shows zero leaks. `leaks` does list 26 KB from Apple's AppIntents framework, which an empty AppKit app reports identically.

## Develop

```sh
make            # app + CLI in build/
make dev        # debuggable build with test hooks:
                #   --soak N                         refresh + menu cycles, printing memory
                #   --render out.png --demo          draw the card with demo data (--dark, --day N, --stale)
                #   --render-bar out.png [--dark]    draw the menu bar item
```

```
src/core/   C++ data layer: limits API, credentials, log scanner, pricing, pace, storage
src/cli/    usageq command-line tool
src/app/    AppKit menu bar app
```

## Acknowledgements

Thanks to [CodexBar](https://github.com/steipete/CodexBar) (MIT), whose open-source Claude provider documents the usage endpoint and credential handling. Usage? is an independent, Claude-only app with its own design and code.

## License

MIT. Usage? is an independent project, not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.
