# Nocturnal for Windows and Linux

Close the lid. Keep working. Nocturnal keeps a laptop awake with the lid shut while AI agents (Claude Code, Codex, Gemini CLI, Cursor Agent, Aider, OpenCode, Ollama and others) are working, saves battery while it's shut, and lets it sleep once the work stops.

Same product and settings file as the Mac app. Windows 10/11 and Linux with systemd (Ubuntu 20.04+, Debian 11+, Fedora 32+, Arch, Mint, Pop!_OS and similar), x86-64. **Beta:** tested against a mock operating system, a fake logind and Windows builds, not yet on a range of real laptops; please report what happens on yours.

## Install

**Windows:** unzip `Nocturnal-windows-x86_64.zip` into a folder you'll keep (for example `C:\Users\you\Apps\Nocturnal`) and run `nocturnal-app.exe`. It appears in the system tray. Windows SmartScreen may warn because the app isn't code-signed yet: More info › Run anyway. Turn on Settings › Open at login in Nocturnal's menu.

**Linux:** `tar xf nocturnal-linux-x86_64.tar.gz && ./nocturnal-linux-x86_64/install.sh`. No root needed. The tray icon needs the AppIndicator library (the installer tells you the package name if it's missing); on GNOME also the "AppIndicator and KStatusNotifierItem Support" extension.

## What it does

- **When Busy** (default): awake only while an agent is working, or a command an agent started is still running (a build, a test run), plus anything you add under *Also While These Run* (Blender, ffmpeg, a Python training script…). Claude Code, once connected (`nocturnal connect claude`), reports through its own hooks when it's working, waiting for your approval, or finished. After work stops it waits the quiet time you chose (5 min by default), then lets the laptop sleep; with the lid already shut it puts it to sleep.
- **Always**: forever, for an hour, or until 07:00. **Off**: never (holds from `nocturnal run` and agents still work).
- **While closed**: Max Battery pauses chat, mail and office apps and slows browsers, terminals and code editors (music and calls are left alone; terminals and editors are never paused, since a frozen terminal stalls the command running in it); Balanced slows browsers, terminals, editors and chat apps; Full Speed leaves everything alone. Only apps on a fixed list are ever touched, never the desktop or anything an agent depends on (its whole process tree and the apps above it).
- **Limits**: stops at your battery limit (15% default) and, on Linux, if it gets too hot. Only the menu can loosen these; agents, the phone and settings-file edits can't.
- **Let It Sleep Now**: ends holds and timers; agents can't keep it awake until the lid next opens.
- **Phone control** (Settings › Phone control): a QR code pairs your phone with a small control page that works from anywhere. Messages go through ntfy.sh end-to-end encrypted (AES-256-GCM, key only in the QR code).
- **Phone alerts** (ntfy): a notification when an agent finishes or is waiting for you, and when the lid opens after a session. These go through ntfy.sh as plain text, unlike phone control.
- **Approve everything** (optional, risky): sets Claude Code and Codex to run without asking until the work finishes, for 8 hours, or until you turn it off. Only the tray menu can turn it on.

## Command line and agents

```
nocturnal                          what it's doing
nocturnal run -- npm test          awake exactly as long as the command runs
nocturnal on 90 | on until 7 | auto | off | sleep
nocturnal watch blender            also stay awake while Blender is busy
nocturnal rule chrome pause        per-app rule while the lid is closed
nocturnal doctor                   health check: what Nocturnal has changed right now, watchdog, setup
nocturnal rescue                   put back everything Nocturnal changed, even if the app is stuck
nocturnal mcp-setup                commands to add Nocturnal's MCP server to Claude Code, Codex, Gemini
```

MCP tools: `status`, `stay_awake`, `release`, `set_mode`, `set_preset`, `set_app_rule`, `watch_app`, `energy`, `set_setting`. A hold made through MCP ends when that agent session ends.

## How it keeps working with the lid shut

| | Windows | Linux |
|---|---|---|
| Stay awake | Power requests (shown in `powercfg /requests` as "Nocturnal: …"), released by Windows if Nocturnal exits | logind inhibitor lock (sleep, idle, lid switch), released by the kernel if Nocturnal exits; GNOME/KDE session inhibitors too |
| Lid closed | Sets the plan's "When I close the lid" to Do nothing while holding, puts your setting back after | logind ignores the lid while the lock is held |
| Sleep when done | Restores your lid setting, then sleeps (Modern Standby: turns the screen off) | logind Suspend |
| Slow an app | Idle priority + Efficiency mode (EcoQoS) | CPU limit on the app's own systemd unit; falls back to nice only when it can be undone |
| Pause an app | NtSuspendProcess / resume | SIGSTOP / SIGCONT |
| Low power while closed | Power mode: best power efficiency | power-profiles-daemon: power-saver |
| Watchdog | Task Scheduler, every minute, also on battery | systemd user timer, every minute |

Every change to an app or setting is written to disk before it's made. If Nocturnal crashes, the watchdog (or Nocturnal's next start) puts everything back; anything that can't be put back stays recorded, shows in the menu and `nocturnal doctor`, and is retried. Apps are only touched if they're provably the same process (pid, start time and program name all match).

## Known limits

- **Windows lid setting**: it's a stored power-plan setting, so if Nocturnal is killed while holding, closing the lid won't sleep until the watchdog (within a minute) or Nocturnal's next start restores it. Work or school PCs may block changing it; Nocturnal then says so.
- **Windows heat guard**: Windows has no temperature reading without admin rights, so the heat guard is Linux-only.
- **KDE Plasma** handles the lid itself. Set System Settings › Power Management › When laptop lid closed to "Do nothing"; Nocturnal then sleeps the laptop on close whenever nothing is working (and not while an external monitor is connected). Nocturnal shows a note until this is set.
- **Activity detection** for agents without hooks is CPU use, transcript writes and running commands. One waiting a long time on a slow remote response with nothing running can look idle; use `nocturnal run`, the MCP `stay_awake` tool, or a longer quiet time for those.
- **"Went idle"** (agents without hooks) means no activity, not success: Nocturnal can't tell a finished task from a crash or a question waiting for you.
- **Battery hours** are estimates. Until Nocturnal has measured this laptop with the lid shut, the figure is marked "rough".
- **Same-user programs**: anything running as you could still stop Nocturnal or change its files. The safety rules stop accidental and agent-driven loosening, not deliberate attacks.
- **Phone control** uses the phone page at https://nocturnal.tools/remote/ (to host your own copy, set `panelUrl` in remote.json). The relay (ntfy.sh) has small free limits, and Nocturnal only sends when the phone asks.

## Building

```
cargo test                                               # 133 unit tests (the engine runs against a mock OS)
cargo build --release --target x86_64-pc-windows-gnu     # Windows, from Linux with mingw
cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.31   # Linux, runs on glibc 2.30+
cargo build --bins --examples && tests/e2e-linux.sh      # 58 end-to-end checks against a fake logind
```
