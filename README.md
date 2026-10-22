<p align="center"><img src="docs/icon.png" width="96" alt="Ajar icon"></p>

# Ajar

[![CI](https://github.com/12alexanderbell-graham/ajar/actions/workflows/ci.yml/badge.svg)](https://github.com/12alexanderbell-graham/ajar/actions/workflows/ci.yml)

**Close the lid. Your AI keeps working.**

Ajar keeps your laptop awake with the lid shut while your AI agents work, then lets it sleep. Free, for macOS 14+, Windows 10/11 and Linux (systemd).

With the lid shut it pauses apps you aren't using and turns on Low Power Mode. On an M5 Max with iOS simulators open: **18.3 W down to 3.1 W.**

## Install

- **Mac:** `brew install --cask 12alexanderbell-graham/ajar/ajar`, or download from https://ajar.tools
- **Windows / Linux:** download from the same page (Linux: unpack, run `./install.sh`).
- **Connect your agent:** `ajar connect`, then paste the output of `ajar prompt` into Claude Code or Codex.

<p align="center"><img src="docs/menu.png" width="320" alt="Ajar's menu on the Now tab: When Busy, 'Keeps working', battery figures"> &nbsp; <img src="docs/phone.png" width="220" alt="Ajar's phone page"></p>

## What it does

- **Off, When Busy or Always.** When Busy keeps it awake while an agent works and sleeps a few minutes after.
- **Apps tab.** What keeps it awake (add any app with +), what closing the lid slows or pauses, the battery limit, and a rule per app.
- **Saves power with the lid shut.** Pauses other apps, simulators and silent audio, turns on Low Power Mode. Opening the lid puts it all back.
- **Measures it.** `ajar power test` reads whole-laptop power from the battery controller.
- **Agents can use it.** MCP server and CLI, so agents keep the laptop awake for long jobs.
- **Phone page.** Check on it from anywhere, end-to-end encrypted over ntfy.sh. While it sleeps with the lid shut it can check in every 15–60 minutes, so a Wake from the phone gets through.
- **Wakes on a schedule.** `ajar wake-at 07:00` wakes it from sleep and keeps it awake a while.
- **Approve everything (optional, risky).** One switch sets Claude Code and Codex to run without asking; turning it off puts your settings back. Only you can turn it on, in Ajar itself.
- **Battery and heat limits.** Sleeps at your battery limit or if it gets too hot. Agents can't loosen these.

## Is it safe to give it sudo?

On the Mac it only runs `pmset`, through a sudoers rule limited to `disablesleep 0/1`, Low Power Mode on/off and `sleepnow` (see `Setup` in [`mac/Ajar/System.swift`](mac/Ajar/System.swift)). Every change is logged to disk first, and a watchdog undoes them if Ajar quits. `ajar rescue` does the same by hand. Windows uses power requests and your power plan's lid setting; Linux uses a logind inhibitor.

## Repository

- [`mac/`](mac/): the macOS app (Swift, SwiftUI). Open `mac/Ajar.xcodeproj`, or run `mac/install.sh`. Signed and notarized release: `mac/release.sh TEAMID`.
- [`windows-linux/`](windows-linux/): the Windows and Linux app (Rust). `cargo build --release`; tests: `cargo test`, `sh tests/e2e-linux.sh`.
- [`site/`](site/): the website and the phone page (`site/remote/`).
- For agents: [`site/llms.txt`](site/llms.txt) lists every command, MCP tool and setting.

## License

MIT
