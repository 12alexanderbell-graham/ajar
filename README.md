<p align="center"><img src="docs/icon.png" width="96" alt="Ajar icon"></p>

# Ajar

[![CI](https://github.com/12alexanderbell-graham/ajar/actions/workflows/ci.yml/badge.svg)](https://github.com/12alexanderbell-graham/ajar/actions/workflows/ci.yml)

Close the lid. Your agents keep working.

Ajar keeps a laptop awake with the lid closed while Claude Code, Codex and other agents work, cuts the power that's wasted while it's shut, and lets it sleep when the work stops. macOS 14+, Windows 10/11, Linux (systemd).

## Install

- **Mac:** `brew install --cask 12alexanderbell-graham/ajar/ajar`, or download from https://12alexanderbell-graham.github.io/ajar/
- **Windows / Linux:** download from the same page (Linux: unpack, run `./install.sh`).
- **Hook up your agent:** `ajar connect`, then paste the output of `ajar prompt` into Claude Code or Codex.

<p align="center"><img src="docs/menu.png" width="320" alt="Ajar's menu bar panel"> &nbsp; <img src="docs/phone.png" width="220" alt="Ajar's phone remote"></p>

## What it does

- **Only while work is happening.** Awake while an agent (or an app you pick, like an Xcode build or ffmpeg) is working; sleeps a few minutes after it stops. Or Always, or Always for an hour.
- **Cuts wasted power with the lid shut.** Pauses or slows other apps, freezes booted simulators and Xcode previews, pauses background processes holding the speakers open, turns on Low Power Mode, and can switch the screen fully off. Everything comes back when you open the lid.
- **Real watts.** Reads whole-machine power from the battery controller (works on the charger too), and `ajar power test` measures what each saving is worth on your machine.
- **Your agent drives it.** MCP server and CLI: agents hold the machine awake while they work, read what's using power, and change any setting. `ajar connect` adds it to Claude Code and Codex; `ajar prompt` prints a setup prompt.
- **Phone remote.** A small end-to-end encrypted web page (via ntfy.sh) to check on it and switch modes from anywhere.
- **Stops before it hurts.** Sleeps at your battery limit and (Mac, Linux) when it gets too hot. Agents and scripts can make these stricter, never looser.

## Is it safe to give it sudo?

The only privileged thing Ajar does is run `pmset` (macOS) with a sudoers rule limited to the exact commands it needs: `disablesleep 0/1`, Low Power Mode on/off and `sleepnow`. Read it in [`mac/Ajar/System.swift`](mac/Ajar/System.swift) (`Setup`). Every change Ajar makes is written to a journal on disk before it's made, and a watchdog puts everything back if Ajar dies: sleep, Low Power Mode, brightness, the screen, paused and slowed apps. `ajar rescue` does the same by hand. Windows uses power requests and the lid setting of your power plan; Linux uses a logind inhibitor that the kernel drops if Ajar dies.

## Repository

- [`mac/`](mac/): the macOS app (Swift, SwiftUI). Open `mac/Ajar.xcodeproj`, or run `mac/install.sh`.
- [`windows-linux/`](windows-linux/): the Windows and Linux app (Rust). `cargo build --release`; tests: `cargo test`, `sh tests/e2e-linux.sh`.
- [`site/`](site/): the website and the phone page (`site/remote/`).
- For agents: [`site/llms.txt`](site/llms.txt) lists every command, MCP tool and setting.

## License

MIT
