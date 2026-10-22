//! Everything an AI agent needs to understand and drive Nocturnal: every setting described once (shared by
//! `nocturnal settings`, the MCP tools and `nocturnal set`), the setup prompt, and one-step connection to Claude Code and
//! Codex. Connecting keeps everything else in the agent's config and saves a backup first.

use crate::config::Config;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub struct Spec {
    pub key: &'static str,
    pub kind: &'static str,
    pub allowed: &'static [&'static str],
    pub category: &'static str,
    pub description: &'static str,
    pub note: Option<&'static str>,
    pub get: fn(&Config) -> Value,
}

pub const SETTINGS: &[Spec] = &[
    Spec { key: "mode", kind: "enum", allowed: &["auto", "always", "off"], category: "When to stay awake",
        description: "auto (When Busy): awake only while an agent or watched app is working. always: until turned off. off: normal sleep (explicit holds still work).",
        note: None, get: |c| json!(match c.mode { crate::config::Mode::On => "always", crate::config::Mode::Auto => "auto", crate::config::Mode::Off => "off" }) },
    Spec { key: "preset", kind: "enum", allowed: &["max_battery", "balanced", "full_speed"], category: "While the lid is closed",
        description: "What happens to other apps with the lid shut. max_battery: pause chat, document, launcher and sync apps and slow browsers (music and calls keep going). balanced: slow them. full_speed: leave them.",
        note: None, get: |c| json!(match c.preset { crate::config::Preset::Longest => "max_battery", crate::config::Preset::Balanced => "balanced", crate::config::Preset::Speed => "full_speed" }) },
    Spec { key: "low_power", kind: "bool", allowed: &["on", "off"], category: "While the lid is closed",
        description: "Power-saver mode while the lid is closed; your setting comes back when it opens.",
        note: None, get: |c| json!(c.low_power_while_closed) },
    Spec { key: "battery_floor", kind: "int", allowed: &["0-80"], category: "Safety",
        description: "Sleep when the battery reaches this percent (0 = never stop for battery).",
        note: Some("Can only be raised from commands; lowering it is the person's call in the Nocturnal menu."), get: |c| json!(c.battery_floor) },
    Spec { key: "heat_guard", kind: "bool", allowed: &["on", "off"], category: "Safety",
        description: "Switch to the strictest rules when the laptop gets hot and sleep if it gets critical.",
        note: Some("Can only be turned on from commands."), get: |c| json!(c.heat_guard) },
    Spec { key: "only_on_power", kind: "bool", allowed: &["on", "off"], category: "Safety",
        description: "Only stay awake while the charger is covering the load.", note: None, get: |c| json!(c.only_on_power) },
    Spec { key: "quiet_minutes", kind: "int", allowed: &["1-240"], category: "When to stay awake",
        description: "In auto mode, sleep after an agent has been quiet this many minutes.", note: None, get: |c| json!(c.quiet_minutes) },
    Spec { key: "sleep_when_done", kind: "bool", allowed: &["on", "off"], category: "When to stay awake",
        description: "In auto mode, let the laptop sleep once the work stops.", note: None, get: |c| json!(c.sleep_when_done) },
    Spec { key: "claude_app", kind: "bool", allowed: &["on", "off"], category: "When to stay awake",
        description: "Count the Claude desktop app as an agent.", note: None, get: |c| json!(c.count_claude_app) },
    Spec { key: "check_in_minutes", kind: "enum", allowed: &["0", "15", "30", "60"], category: "While asleep",
        description: "With the lid shut and the laptop asleep, wake it every this many minutes for about 25 seconds to pick up a wake sent from the phone, then sleep again. 0 = off. Costs a little battery per check-in; a laptop that's shut down can't be woken.",
        note: None, get: |c| json!(c.check_in_minutes) },
    Spec { key: "notify_done", kind: "bool", allowed: &["on", "off"], category: "Notifications",
        description: "Notification when an agent that was busy goes idle.", note: None, get: |c| json!(c.notify_done) },
    Spec { key: "ntfy_topic", kind: "string", allowed: &[], category: "Notifications",
        description: "ntfy.sh topic for phone alerts when work goes idle; empty turns them off.", note: None, get: |c| json!(c.ntfy_topic) },
];

pub const LISTS: &[(&str, &str, &str)] = &[
    (
        "app_rules",
        "nocturnal rule <app> leave|slow|pause|default  (MCP: set_app_rule)",
        "Per-app override of the preset while the lid is closed.",
    ),
    (
        "watched_apps",
        "nocturnal watch <app> [--remove]  (MCP: watch_app)",
        "Apps or tools that keep the laptop awake while busy.",
    ),
];

pub fn describe(c: &Config, config_path: &Path) -> Value {
    let settings: Vec<Value> = SETTINGS
        .iter()
        .map(|s| {
            let mut d = json!({ "key": s.key, "type": s.kind, "category": s.category, "description": s.description, "value": (s.get)(c) });
            if !s.allowed.is_empty() {
                d["allowed"] = json!(s.allowed);
            }
            if let Some(n) = s.note {
                d["note"] = json!(n);
            }
            d
        })
        .collect();
    json!({
        "ok": true,
        "settings": settings,
        "lists": LISTS.iter().map(|(n, how, what)| json!({ "name": n, "how": how, "what": what })).collect::<Vec<_>>(),
        "config_file": config_path.to_string_lossy(),
        "how_to_change": "nocturnal set <key> <value>, MCP set_setting, or edit config.json (reloads instantly).",
    })
}

pub const SETUP_PROMPT: &str = "Nocturnal is installed on this laptop. It keeps the machine awake with the lid closed while you (and other agents) work, and cuts power use while the lid is shut. You can control all of it through the `nocturnal` MCP tools (or the `nocturnal` command). Set it up for me:

1. Call settings and power to see every setting and what is using power right now.
2. Ask me, in one short message: which apps must keep running at full speed with the lid shut (music, calls, a local model, Docker...), and whether the laptop should stay awake only while agents work or always.
3. Apply the strongest savings that don't touch what I named: preset max_battery, low_power, and per-app rules with set_app_rule.
4. From now on, call stay_awake before long work and release when it's done.

Never turn off the heat guard or lower the battery limit; Nocturnal won't let you, and that's on purpose.";

fn home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .unwrap_or_default()
}

fn server() -> (String, Vec<String>) {
    let exe = std::env::current_exe().ok();
    // The MCP server lives in the `nocturnal` command next to the tray app.
    let cli = exe.as_ref().and_then(|p| p.parent()).map(|d| {
        d.join(if cfg!(windows) {
            "nocturnal.exe"
        } else {
            "nocturnal"
        })
    });
    let path = cli
        .filter(|p| p.exists())
        .or(exe)
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "nocturnal".into());
    (path, vec!["mcp".into()])
}

pub fn claude_code_config() -> PathBuf {
    home().join(".claude.json")
}

pub fn codex_config() -> PathBuf {
    home().join(".codex").join("config.toml")
}

/// The `nocturnal` command (never the tray app: run with a hook's arguments, that would start a second tray).
fn cli_exe() -> Option<String> {
    let me = std::env::current_exe().ok()?;
    let name = if cfg!(windows) {
        "nocturnal.exe"
    } else {
        "nocturnal"
    };
    let p = if me.file_name().and_then(|n| n.to_str()) == Some(name) {
        me
    } else {
        me.parent()?.join(name)
    };
    p.exists().then(|| p.display().to_string())
}

pub fn connect_claude_code() -> Result<String, String> {
    let mcp = connect_claude_code_at(&claude_code_config())?;
    let Some(exe) = cli_exe() else {
        return Ok(format!("{mcp} (The nocturnal command wasn't found next to the app, so its status hooks weren't added.)"));
    };
    Ok(match install_hooks(&claude_settings(), &exe) {
        Ok(()) => format!("{mcp} It now tells Nocturnal when it's working, waiting for you, or done (new sessions)."),
        Err(e) => format!("{mcp} Couldn't add its status hooks: {e}"),
    })
}

/// Claude Code's user settings, where its hooks live.
pub fn claude_settings() -> PathBuf {
    home().join(".claude").join("settings.json")
}

/// Both halves of the Claude Code connection are in place: the MCP server and the lifecycle hooks.
pub fn claude_code_hooks_installed() -> bool {
    crate::approve::read_claude(&crate::approve::Paths {
        journal: PathBuf::new(),
        claude: claude_settings(),
        codex: PathBuf::new(),
    })
    .is_ok_and(|(c, _)| cli_exe().is_some_and(|exe| crate::events::hooks_installed(&c, &exe)))
}

/// Adds Nocturnal's lifecycle hooks to Claude Code's settings (a copy of the file is kept next to it first).
fn install_hooks(path: &Path, exe: &str) -> Result<(), String> {
    let p = crate::approve::Paths {
        journal: PathBuf::new(),
        claude: path.to_path_buf(),
        codex: PathBuf::new(),
    };
    let (c, raw) = crate::approve::read_claude(&p)?;
    if let Some(r) = &raw {
        std::fs::write(path.with_extension("json.nocturnal-backup"), r)
            .map_err(|e| e.to_string())?;
    }
    let out = crate::events::with_hooks(&c, exe);
    crate::approve::write(
        path,
        &serde_json::to_string_pretty(&Value::Object(out)).unwrap_or_default(),
    )
}

fn remove_hooks(path: &Path) {
    let p = crate::approve::Paths {
        journal: PathBuf::new(),
        claude: path.to_path_buf(),
        codex: PathBuf::new(),
    };
    if let Ok((c, Some(_))) = crate::approve::read_claude(&p) {
        let (out, changed) = crate::events::without_hooks(&c);
        if changed {
            let _ = crate::approve::write(
                path,
                &serde_json::to_string_pretty(&Value::Object(out)).unwrap_or_default(),
            );
        }
    }
}

pub fn connect_codex() -> Result<String, String> {
    connect_codex_at(&codex_config())
}

/// Adds `nocturnal` to Claude Code's user-scope MCP servers (every project), keeping the rest of the file.
fn connect_claude_code_at(path: &Path) -> Result<String, String> {
    let path = path.to_path_buf();
    let mut root: Value = match std::fs::read(&path) {
        Ok(b) => serde_json::from_slice(&b)
            .map_err(|_| format!("{} isn't valid JSON, so I left it alone", path.display()))?,
        Err(_) => json!({}),
    };
    if !root.is_object() {
        return Err(format!(
            "{} isn't a JSON object, so I left it alone",
            path.display()
        ));
    }
    if path.exists() {
        std::fs::copy(&path, path.with_extension("json.nocturnal-backup"))
            .map_err(|e| e.to_string())?;
    }
    let (cmd, args) = server();
    if !root["mcpServers"].is_object() {
        root["mcpServers"] = json!({});
    }
    root["mcpServers"]["nocturnal"] =
        json!({ "type": "stdio", "command": cmd, "args": args, "env": {} });
    write_atomic(
        &path,
        serde_json::to_string_pretty(&root)
            .unwrap_or_default()
            .as_bytes(),
    )?;
    Ok("Added to Claude Code for all projects. New sessions can use Nocturnal.".into())
}

/// Appends an `[mcp_servers.nocturnal]` table to Codex's config.toml; an existing entry is left alone.
fn connect_codex_at(path: &Path) -> Result<String, String> {
    let existing = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => {
            return Err(format!(
                "Couldn't read {}, so I left it alone",
                path.display()
            ))
        }
    };
    if existing.contains("[mcp_servers.nocturnal]") {
        return Ok("Codex already has Nocturnal.".into());
    }
    let (cmd, args) = server();
    let q = |s: &str| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""));
    let block = format!(
        "\n[mcp_servers.nocturnal]\ncommand = {}\nargs = [{}]\n",
        q(&cmd),
        args.iter().map(|a| q(a)).collect::<Vec<_>>().join(", ")
    );
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    if !existing.is_empty() {
        std::fs::write(path.with_extension("toml.nocturnal-backup"), &existing)
            .map_err(|e| e.to_string())?;
    }
    write_atomic(path, format!("{existing}{block}").as_bytes())?;
    Ok("Added to Codex. New sessions can use Nocturnal.".into())
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("nocturnal-tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Removes Nocturnal's MCP entry from Claude Code and Codex (uninstall), so they don't keep starting a program that's
/// about to be deleted. Everything else in their configs stays; a file that can't be read is left alone.
pub fn disconnect_all() {
    remove_hooks(&claude_settings());
    let cc = claude_code_config();
    if let Some(mut root) = std::fs::read(&cc)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
    {
        if let Some(servers) = root.get_mut("mcpServers").and_then(Value::as_object_mut) {
            if servers.remove("nocturnal").is_some() {
                let _ = std::fs::copy(&cc, cc.with_extension("json.nocturnal-backup"));
                let _ = write_atomic(
                    &cc,
                    serde_json::to_string_pretty(&root)
                        .unwrap_or_default()
                        .as_bytes(),
                );
            }
        }
    }
    let cx = codex_config();
    if let Ok(text) = std::fs::read_to_string(&cx) {
        let lines: Vec<&str> = text.split('\n').collect();
        if let Some(start) = lines
            .iter()
            .position(|l| l.trim() == "[mcp_servers.nocturnal]")
        {
            let end = lines[start + 1..]
                .iter()
                .position(|l| l.trim_start().starts_with('['))
                .map_or(lines.len(), |i| start + 1 + i);
            let kept: Vec<&str> = lines[..start]
                .iter()
                .chain(&lines[end..])
                .copied()
                .collect();
            let _ = std::fs::write(cx.with_extension("toml.nocturnal-backup"), &text);
            let _ = write_atomic(&cx, kept.join("\n").as_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_lists_every_setting_with_values() {
        let d = describe(&Config::default(), Path::new("/tmp/config.json"));
        let keys: Vec<&str> = d["settings"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["key"].as_str().unwrap())
            .collect();
        assert!(
            keys.contains(&"battery_floor")
                && keys.contains(&"heat_guard")
                && keys.contains(&"preset")
        );
        let floor = d["settings"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["key"] == "battery_floor")
            .unwrap();
        assert_eq!(floor["value"], json!(15));
        assert!(floor["note"].as_str().unwrap().contains("raised"));
    }

    #[test]
    fn connect_keeps_other_servers_and_backs_up() {
        let dir = std::env::temp_dir().join(format!("nocturnal-ai-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cc = dir.join(".claude.json");
        let codex = dir.join(".codex/config.toml");
        std::fs::write(
            &cc,
            r#"{"mcpServers":{"other":{"command":"x"}},"theme":"light"}"#,
        )
        .unwrap();
        connect_claude_code_at(&cc).unwrap();
        let v: Value =
            serde_json::from_slice(&std::fs::read(dir.join(".claude.json")).unwrap()).unwrap();
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["theme"], "light");
        assert_eq!(v["mcpServers"]["nocturnal"]["args"], json!(["mcp"]));
        assert!(dir.join(".claude.json.nocturnal-backup").exists());
        std::fs::write(&cc, "not json").unwrap();
        assert!(connect_claude_code_at(&cc).is_err());
        assert_eq!(std::fs::read_to_string(&cc).unwrap(), "not json");
        connect_codex_at(&codex).unwrap();
        let t = std::fs::read_to_string(&codex).unwrap();
        assert!(t.contains("[mcp_servers.nocturnal]") && t.contains("args = [\"mcp\"]"));
        assert_eq!(
            connect_codex_at(&codex).unwrap(),
            "Codex already has Nocturnal."
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
