//! `ajar`: the command line for people, scripts and AI agents. Talks to the running tray app.

use ajar::engine::run_watchdog;
use ajar::platform::{self, Platform};
use ajar::{ipc, mcp, state};
use serde_json::{json, Value};
use std::process::ExitCode;
use std::time::Duration;

const HELP: &str = "ajar: keep the laptop awake with the lid closed while work runs

  ajar                          what Ajar is doing (add --json for machine-readable)
  ajar run -- <command…>        keep awake while a command runs, then let it sleep
  ajar on [minutes | until 7]   stay awake (for a while, or until 07:00)
  ajar auto                     stay awake only while an agent is working (default)
  ajar off                      never keep awake (holds from `run` and agents still work)
  ajar hold [minutes] [reason]  keep awake until `ajar release` (or for N minutes)
  ajar release [id]             end one hold, or all
  ajar wake-at HH:MM [minutes]  wake from sleep then and stay awake a while (off cancels)
  ajar check-in 0|15|30|60      while asleep with the lid shut, wake this often to pick up a wake from the phone
  ajar preset max_battery | balanced | full_speed
  ajar rule <app> leave | slow | pause | default
  ajar watch <app> [--remove]   an app that keeps it awake while busy (blender, ffmpeg…)
  ajar set <key> <value>        change any setting
  ajar settings                 every setting, its value, allowed values and what it does
  ajar power                    power use now and which setting would cut it
  ajar energy                   apps using the most CPU, and what closing the lid does to each
  ajar config                   where the settings file is
  ajar sleep                    let it sleep now (agents wait until the lid opens again)
  ajar mcp                      run as an MCP server (stdio) for Claude Code, Codex, Gemini…
  ajar mcp-setup                print the commands that add Ajar to your agents
  ajar connect [claude|codex]   add Ajar's MCP server to Claude Code and Codex
  ajar prompt                   the prompt that has your agent set Ajar up with you

  ajar doctor                   health check: what Ajar has changed, watchdog, journals
  ajar rescue                   put every app and setting Ajar changed back, even if the app is stuck
  ajar install                  register the watchdog (done automatically on first launch)
  ajar uninstall                put everything back, then remove the watchdog and login item
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json_out = args.iter().any(|a| a == "--json");
    let args: Vec<String> = args.into_iter().filter(|a| a != "--json").collect();
    let root = state::dir();
    let cmd = args.first().map(String::as_str).unwrap_or("status");
    let rest = &args[args.len().min(1)..];

    let request: (&str, Value) = match cmd {
        "help" | "-h" | "--help" => {
            print!("{HELP}");
            return ExitCode::SUCCESS;
        }
        "-V" | "--version" | "version" => {
            println!("ajar {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        "mcp" => {
            mcp::serve(&root);
            return ExitCode::SUCCESS;
        }
        "settings" | "schema" => {
            let r = match ipc::call(&root, "schema", json!({}), Duration::from_secs(10)) {
                Ok(v) => v,
                Err(e) => return fail(&e),
            };
            if json_out {
                println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
                return ExitCode::SUCCESS;
            }
            for s in r["settings"].as_array().cloned().unwrap_or_default() {
                let allowed: Vec<String> = s["allowed"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
                println!(
                    "{} = {}   [{}]",
                    s["key"].as_str().unwrap_or(""),
                    s["value"],
                    allowed.join("|")
                );
                println!(
                    "    {}{}",
                    s["description"].as_str().unwrap_or(""),
                    s["note"]
                        .as_str()
                        .map(|n| format!(" ({n})"))
                        .unwrap_or_default()
                );
            }
            println!("\nChange with: ajar set <key> <value>. Per-app rules: ajar rule <app> leave|slow|pause. File: {}", r["config_file"].as_str().unwrap_or(""));
            return ExitCode::SUCCESS;
        }
        "power" => {
            let r = match ipc::call(&root, "power", json!({}), Duration::from_secs(10)) {
                Ok(v) => v,
                Err(e) => return fail(&e),
            };
            if json_out {
                println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
                return ExitCode::SUCCESS;
            }
            match r["system_watts"].as_f64() {
                Some(w) => println!("Using {w} W now ({}).", r["source"].as_str().unwrap_or("")),
                None => println!("Power: {}.", r["source"].as_str().unwrap_or("unknown")),
            }
            for s in r["suspects"].as_array().cloned().unwrap_or_default() {
                let active = s["active"].as_bool() == Some(true);
                println!(
                    "{} {}",
                    if active { "•" } else { "✓" },
                    s["title"].as_str().unwrap_or("")
                );
                if active {
                    println!(
                        "    fix: ajar set {} {}",
                        s["setting"].as_str().unwrap_or(""),
                        s["suggested_value"].as_str().unwrap_or("")
                    );
                }
            }
            return ExitCode::SUCCESS;
        }
        "connect" => {
            let which = rest.first().map(String::as_str).unwrap_or("all");
            let mut did = false;
            if matches!(which, "claude" | "claude-code")
                || (which == "all" && ajar::ai::claude_code_config().exists())
            {
                println!(
                    "Claude Code: {}",
                    ajar::ai::connect_claude_code().unwrap_or_else(|e| e)
                );
                did = true;
            }
            if which == "codex"
                || (which == "all"
                    && ajar::ai::codex_config()
                        .parent()
                        .is_some_and(|d| d.exists()))
            {
                println!("Codex: {}", ajar::ai::connect_codex().unwrap_or_else(|e| e));
                did = true;
            }
            if !did {
                println!("No agent found here. Use: ajar connect claude | codex");
                return ExitCode::from(2);
            }
            return ExitCode::SUCCESS;
        }
        "prompt" => {
            println!("{}", ajar::ai::SETUP_PROMPT);
            return ExitCode::SUCCESS;
        }
        "mcp-setup" => {
            let exe = std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "ajar".into());
            println!("Claude Code:  claude mcp add ajar -- \"{exe}\" mcp");
            println!("Codex:        codex mcp add ajar -- \"{exe}\" mcp");
            println!("Gemini CLI:   gemini mcp add ajar \"{exe}\" mcp");
            println!("\nAny other MCP client: command \"{exe}\", argument \"mcp\" (stdio).");
            return ExitCode::SUCCESS;
        }
        "run" => return run(&root, rest),
        "doctor" => return doctor(&root),
        "rescue" => return rescue(&root),
        "install" => {
            let mut p = platform::native();
            return match p.install_watchdog() {
                Ok(()) => {
                    state::touch(&root.join("installed"));
                    println!("Watchdog installed.");
                    ExitCode::SUCCESS
                }
                Err(e) => fail(&e),
            };
        }
        "uninstall" => return uninstall(&root),
        "sleep" => ("sleep_now", json!({})),
        "status" => ("status", json!({})),
        "energy" => ("energy", json!({})),
        "config" => ("config", json!({})),
        "auto" => ("mode", json!({ "mode": "auto" })),
        "off" => ("mode", json!({ "mode": "off" })),
        "on" => match parse_on(rest) {
            Ok(minutes) => ("mode", json!({ "mode": "always", "minutes": minutes })),
            Err(e) => return fail(&e),
        },
        "hold" => {
            let (minutes, reason) = match rest.first().and_then(|m| m.parse::<f64>().ok()) {
                Some(m) => (Some(m), rest[1..].join(" ")),
                None => (None, rest.join(" ")),
            };
            let reason = if reason.trim().is_empty() {
                "Held from the command line".to_string()
            } else {
                reason
            };
            ("hold", json!({ "minutes": minutes, "reason": reason }))
        }
        "release" => ("release", json!({ "id": rest.first() })),
        "wake-at" | "wake_at" => match rest.first() {
            Some(t) => (
                "wake_at",
                json!({ "time": t, "minutes": rest.get(1).and_then(|m| m.parse::<f64>().ok()) }),
            ),
            None => return fail("usage: ajar wake-at HH:MM [minutes] | off"),
        },
        "check-in" | "check_in" => match rest.first() {
            Some(m) => (
                "set",
                json!({ "key": "check_in_minutes", "value": m.parse::<f64>().ok() }),
            ),
            None => return fail("usage: ajar check-in 0 | 15 | 30 | 60"),
        },
        "preset" => match rest.first() {
            Some(p) => ("preset", json!({ "preset": p })),
            None => return fail("usage: ajar preset max_battery | balanced | full_speed"),
        },
        "rule" => match (rest.first(), rest.get(1)) {
            (Some(a), Some(r)) => ("rule", json!({ "app": a, "rule": r })),
            _ => return fail("usage: ajar rule <app> leave | slow | pause | default"),
        },
        "watch" => match rest.iter().find(|a| !a.starts_with("--")) {
            Some(a) => (
                "watch",
                json!({ "app": a, "remove": rest.iter().any(|x| x == "--remove") }),
            ),
            None => return fail("usage: ajar watch <app> [--remove]"),
        },
        "set" => match (rest.first(), rest.get(1)) {
            (Some(k), Some(v)) => ("set", json!({ "key": k, "value": v })),
            (Some(k), None) if k == "ntfy_topic" => ("set", json!({ "key": k, "value": "" })),
            _ => return fail("usage: ajar set <key> <value>"),
        },
        other => return fail(&format!("unknown command {other:?}. Try `ajar help`.")),
    };

    match ipc::call(&root, request.0, request.1, Duration::from_secs(10)) {
        Ok(v) => {
            if json_out {
                println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
            } else {
                print_human(cmd, &v);
            }
            if v.get("ok") == Some(&json!(false)) {
                ExitCode::from(1)
            } else {
                ExitCode::SUCCESS
            }
        }
        Err(e) => fail(&e),
    }
}

fn fail(msg: &str) -> ExitCode {
    eprintln!("ajar: {msg}");
    ExitCode::from(2)
}

/// `on`, `on 90`, `on until 7`, `on until 07:00`.
fn parse_on(rest: &[String]) -> Result<Option<f64>, String> {
    match rest {
        [] => Ok(None),
        [m] => m
            .parse::<f64>()
            .ok()
            .filter(|m| m.is_finite() && *m > 0.0)
            .map(Some)
            .ok_or_else(|| format!("{m:?} isn't a number of minutes")),
        [u, h] if u == "until" => {
            let hour: u32 = h
                .split(':')
                .next()
                .and_then(|x| x.parse().ok())
                .filter(|h| *h < 24)
                .ok_or("use an hour like 7 or 07:00")?;
            let now = ajar::now();
            let t = ajar::format::next_local_hour(now, hour);
            Ok(Some(((t - now) as f64 / 60.0).ceil()))
        }
        _ => Err("usage: ajar on [minutes | until <hour>]".into()),
    }
}

fn print_human(cmd: &str, v: &Value) {
    if let Some(e) = v.get("error").and_then(Value::as_str) {
        println!("{e}");
        return;
    }
    match cmd {
        "status" => {
            println!("{}", v["status"].as_str().unwrap_or(""));
            if let Some(b) = v.get("battery") {
                let mut line = format!("Battery {}%", b["percent"]);
                if b["on_power"] == json!(true) {
                    line.push_str(" · plugged in");
                } else if let Some(h) = v["hours_left_closed"].as_f64() {
                    line.push_str(&format!(
                        " · ≈{} left with the lid closed",
                        ajar::format::hm(h)
                    ));
                }
                println!("{line}");
            }
            if let Some(w) = v["warning"].as_str() {
                println!("Note: {w}");
            }
            for a in v["watching"].as_array().into_iter().flatten() {
                let state = if a["working"] == json!(true) {
                    format!("working ({}% CPU)", a["cpu_percent"])
                } else {
                    "idle".into()
                };
                let project = a["project"]
                    .as_str()
                    .filter(|p| !p.is_empty())
                    .map(|p| format!(" in {p}"))
                    .unwrap_or_default();
                let track = if a["keeps_awake"] == json!(false) {
                    " · tracked only"
                } else {
                    ""
                };
                println!(
                    "  {}{project}: {state}{track}",
                    a["name"].as_str().unwrap_or("")
                );
            }
            for h in v["holds"].as_array().into_iter().flatten() {
                println!(
                    "  hold {}: {}",
                    h["id"].as_str().unwrap_or(""),
                    h["reason"].as_str().unwrap_or("")
                );
            }
        }
        "energy" => {
            for a in v["apps"].as_array().into_iter().flatten() {
                println!(
                    "{:>6.1}%  {:<24} lid closed: {}",
                    a["cpu_percent"].as_f64().unwrap_or(0.0),
                    a["name"].as_str().unwrap_or(""),
                    a["while_closed"].as_str().unwrap_or("")
                );
            }
        }
        "config" => println!("{}", v["path"].as_str().unwrap_or("")),
        "hold" => println!(
            "Holding (id {}). {}",
            v["hold"]["id"].as_str().unwrap_or("?"),
            v["status"].as_str().unwrap_or("")
        ),
        "release" => println!(
            "Released {}. {}",
            v["released"],
            v["status"].as_str().unwrap_or("")
        ),
        _ => println!("{}", v["status"].as_str().unwrap_or("Done")),
    }
}

/// Keeps the machine awake for exactly as long as the command runs. The hold is tied to the child's pid, so
/// it ends even if this wrapper is killed.
fn run(root: &std::path::Path, rest: &[String]) -> ExitCode {
    let cmdline: Vec<&String> = rest.iter().skip_while(|a| *a == "--").collect();
    let Some((prog, args)) = cmdline.split_first() else {
        return fail("usage: ajar run -- <command> [args…]");
    };
    let reason = format!(
        "Running {}",
        std::path::Path::new(prog.as_str())
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| prog.to_string())
    );
    // Hold first, tied to this wrapper (a short bridge so nothing runs unprotected), then re-tie it to the
    // command once it has started. If this wrapper is killed, the hold ends with it.
    let me = std::process::id();
    let bridge = ipc::call(
        root,
        "hold",
        json!({ "reason": reason, "pid": me }),
        Duration::from_secs(5),
    );
    if let Err(e) = &bridge {
        eprintln!("ajar: not keeping awake ({e}); running anyway");
    }
    let mut child = match std::process::Command::new(prog).args(args).spawn() {
        Ok(c) => c,
        Err(e) => {
            release(root, &bridge);
            return fail(&format!("couldn't start {prog}: {e}"));
        }
    };
    let hold = if bridge.is_ok() {
        ipc::call(
            root,
            "hold",
            json!({ "reason": reason, "pid": child.id() }),
            Duration::from_secs(5),
        )
    } else {
        Err(String::new())
    };
    release(root, &bridge);
    let status = child.wait();
    release(root, &hold);
    match status {
        Ok(s) => ExitCode::from(exit_code(&s)),
        Err(e) => fail(&format!("{e}")),
    }
}

fn release(root: &std::path::Path, hold: &Result<Value, String>) {
    if let Ok(v) = hold {
        if let Some(id) = v["hold"]["id"].as_str() {
            let _ = ipc::call(root, "release", json!({ "id": id }), Duration::from_secs(5));
        }
    }
}

/// The child's exit code; on Unix a signal becomes 128 + signal number, like a shell.
fn exit_code(s: &std::process::ExitStatus) -> u8 {
    if let Some(c) = s.code() {
        return c.clamp(0, 255) as u8;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = s.signal() {
            return (128 + sig).clamp(0, 255) as u8;
        }
    }
    1
}

fn journal_lines(root: &std::path::Path) -> Vec<String> {
    let mut out = vec![];
    let touched: Vec<state::Touched> =
        state::load_json(&root.join("touched.json")).unwrap_or_default();
    for t in touched {
        out.push(format!(
            "{} {} (pid {})",
            if t.paused { "paused" } else { "slowed" },
            t.exe,
            t.pid
        ));
    }
    let r: state::Restore = state::load_json(&root.join("restore.json")).unwrap_or_default();
    if let Some(p) = r.power_profile {
        out.push(format!("power profile switched to power-saver (was {p})"));
    }
    if let Some(o) = r.power_overlay {
        out.push(format!("power mode switched to best efficiency (was {o})"));
    }
    if let Some((ac, dc)) = r.lid_action {
        out.push(format!(
            "lid-close action set to Do nothing (was {ac} plugged in, {dc} on battery)"
        ));
    }
    out
}

fn doctor(root: &std::path::Path) -> ExitCode {
    let mut p = platform::native();
    println!("Ajar folder: {}", root.display());
    match state::age_of(&root.join("alive")) {
        Some(a) if a < 15 => println!("App: running"),
        Some(a) => println!(
            "App: not running (last seen {})",
            ajar::format::minutes(a as f64 / 60.0)
        ),
        None => println!("App: never ran here"),
    }
    match p.watchdog_installed() {
        Some(true) => println!("Watchdog: installed"),
        Some(false) => println!("Watchdog: NOT installed (run `ajar install`)"),
        None => println!("Watchdog: can't tell"),
    }
    match p.ready() {
        Ok(()) => println!("Keep-awake control: available"),
        Err(e) => println!("Keep-awake control: {e}"),
    }
    let changes = journal_lines(root);
    if changes.is_empty() {
        println!("Changes Ajar has made right now: none");
    } else {
        println!("Changes Ajar has made right now (put back when the lid opens or work ends):");
        for c in changes {
            println!("  {c}");
        }
    }
    if ipc::app_running(root) {
        if let Ok(v) = ipc::call(root, "status", json!({}), Duration::from_secs(5)) {
            println!("Status: {}", v["status"].as_str().unwrap_or(""));
            for k in ["warning", "setup_error", "blocked_by"] {
                if let Some(w) = v[k].as_str() {
                    println!("Note: {w}");
                }
            }
        }
    }
    ExitCode::SUCCESS
}

/// Stops the app if it's running (it puts things back as it quits), then undoes anything left in the journals
/// directly. Works when the app is stuck or gone.
fn put_everything_back(root: &std::path::Path) -> Result<(), Vec<String>> {
    if ipc::app_running(root) {
        let _ = ipc::call(root, "quit", json!({}), Duration::from_secs(5));
        for _ in 0..50 {
            if !ajar::state::heartbeat_process_alive(&root.join("alive")) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    let mut p = platform::native();
    let r = run_watchdog(&mut p, root, true);
    let left = journal_lines(root);
    if r == "restored" && left.is_empty() {
        Ok(())
    } else {
        Err(left)
    }
}

fn rescue(root: &std::path::Path) -> ExitCode {
    match put_everything_back(root) {
        Ok(()) => {
            println!("Everything Ajar changed is back to how it was. Ajar is stopped; start it again from your apps.");
            ExitCode::SUCCESS
        }
        Err(left) => {
            println!("Some changes couldn't be undone:");
            for l in &left {
                println!("  {l}");
            }
            println!("They stay recorded and will be retried. To undo by hand: resume or restart those apps; on Windows, set \"When I close the lid\" back in Control Panel › Power Options.");
            ExitCode::from(1)
        }
    }
}

fn uninstall(root: &std::path::Path) -> ExitCode {
    // The watchdog is the safety net for undoing Ajar's changes, so it's only removed once nothing is left.
    if let Err(left) = put_everything_back(root) {
        println!("Not uninstalling yet: these changes couldn't be undone, and the watchdog stays to keep retrying:");
        for l in &left {
            println!("  {l}");
        }
        return ExitCode::from(1);
    }
    let mut p = platform::native();
    match p.uninstall() {
        Ok(()) => {
            state::remove(&root.join("installed"));
            println!("Ajar's watchdog and login item are removed and nothing it changed is left. Delete the app and {} to finish.", root.display());
            ExitCode::SUCCESS
        }
        Err(e) => fail(&e),
    }
}
