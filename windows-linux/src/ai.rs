//! Everything an AI agent needs to understand and drive Ajar: every setting described once (shared by
//! `ajar settings`, the MCP tools and `ajar set`), the setup prompt, and one-step connection to Claude Code and
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
        note: Some("Can only be raised from commands; lowering it is the person's call in the Ajar menu."), get: |c| json!(c.battery_floor) },
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
    Spec { key: "notify_done", kind: "bool", allowed: &["on", "off"], category: "Notifications",
        description: "Notification when an agent that was busy goes idle.", note: None, get: |c| json!(c.notify_done) },
    Spec { key: "ntfy_topic", kind: "string", allowed: &[], category: "Notifications",
        description: "ntfy.sh topic for phone alerts when work goes idle; empty turns them off.", note: None, get: |c| json!(c.ntfy_topic) },
];

pub const LISTS: &[(&str, &str, &str)] = &[
    ("app_rules", "ajar rule <app> leave|slow|pause|default  (MCP: set_app_rule)", "Per-app override of the preset while the lid is closed."),
    ("watched_apps", "ajar watch <app> [--remove]  (MCP: watch_app)", "Apps or tools that keep the laptop awake while busy."),
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
        "how_to_change": "ajar set <key> <value>, MCP set_setting, or edit config.json (reloads instantly).",
    })
}

pub const SETUP_PROMPT: &str = "Ajar is installed on this laptop. It keeps the machine awake with the lid closed while you (and other agents) work, and cuts power use while the lid is shut. You can control all of it through the `ajar` MCP tools (or the `ajar` command). Set it up for me:

1. Call settings and power to see every setting and what is using power right now.
2. Ask me, in one short message: which apps must keep running at full speed with the lid shut (music, calls, a local model, Docker...), and whether the laptop should stay awake only while agents work or always.
3. Apply the strongest savings that don't touch what I named: preset max_battery, low_power, and per-app rules with set_app_rule.
4. From now on, call stay_awake before long work and release when it's done.

Never turn off the heat guard or lower the battery limit; Ajar won't let you, and that's on purpose.";

fn home() -> PathBuf {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from).unwrap_or_default()
}

fn server() -> (String, Vec<String>) {
    let exe = std::env::current_exe().ok();
    // The MCP server lives in the `ajar` command next to the tray app.
    let cli = exe.as_ref().and_then(|p| p.parent()).map(|d| d.join(if cfg!(windows) { "ajar.exe" } else { "ajar" }));
    let path = cli.filter(|p| p.exists()).or(exe).map(|p| p.display().to_string()).unwrap_or_else(|| "ajar".into());
    (path, vec!["mcp".into()])
}

pub fn claude_code_config() -> PathBuf {
    home().join(".claude.json")
}

pub fn codex_config() -> PathBuf {
    home().join(".codex").join("config.toml")
}

pub fn connect_claude_code() -> Result<String, String> {
    connect_claude_code_at(&claude_code_config())
}

pub fn connect_codex() -> Result<String, String> {
    connect_codex_at(&codex_config())
}

/// Adds `ajar` to Claude Code's user-scope MCP servers (every project), keeping the rest of the file.
fn connect_claude_code_at(path: &Path) -> Result<String, String> {
    let path = path.to_path_buf();
    let mut root: Value = match std::fs::read(&path) {
        Ok(b) => serde_json::from_slice(&b).map_err(|_| format!("{} isn't valid JSON, so I left it alone", path.display()))?,
        Err(_) => json!({}),
    };
    if !root.is_object() {
        return Err(format!("{} isn't a JSON object, so I left it alone", path.display()));
    }
    if path.exists() {
        std::fs::copy(&path, path.with_extension("json.ajar-backup")).map_err(|e| e.to_string())?;
    }
    let (cmd, args) = server();
    if !root["mcpServers"].is_object() {
        root["mcpServers"] = json!({});
    }
    root["mcpServers"]["ajar"] = json!({ "type": "stdio", "command": cmd, "args": args, "env": {} });
    write_atomic(&path, serde_json::to_string_pretty(&root).unwrap_or_default().as_bytes())?;
    Ok("Added to Claude Code for all projects. New sessions can use Ajar.".into())
}

/// Appends an `[mcp_servers.ajar]` table to Codex's config.toml; an existing entry is left alone.
fn connect_codex_at(path: &Path) -> Result<String, String> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    if existing.contains("[mcp_servers.ajar]") {
        return Ok("Codex already has Ajar.".into());
    }
    let (cmd, args) = server();
    let q = |s: &str| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""));
    let block = format!("\n[mcp_servers.ajar]\ncommand = {}\nargs = [{}]\n", q(&cmd), args.iter().map(|a| q(a)).collect::<Vec<_>>().join(", "));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    if !existing.is_empty() {
        std::fs::write(path.with_extension("toml.ajar-backup"), &existing).map_err(|e| e.to_string())?;
    }
    write_atomic(path, format!("{existing}{block}").as_bytes())?;
    Ok("Added to Codex. New sessions can use Ajar.".into())
}

fn write_atomic(path: &Path, data: &[u8]) -> Result<(), String> {
    let tmp = path.with_extension("ajar-tmp");
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

pub fn status() -> Value {
    let cc = std::fs::read(claude_code_config()).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    let codex = std::fs::read_to_string(codex_config()).unwrap_or_default();
    json!([
        { "agent": "claude_code", "installed": claude_code_config().exists(), "connected": cc.map(|v| v["mcpServers"]["ajar"].is_object()).unwrap_or(false) },
        { "agent": "codex", "installed": codex_config().parent().is_some_and(Path::exists), "connected": codex.contains("[mcp_servers.ajar]") },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describe_lists_every_setting_with_values() {
        let d = describe(&Config::default(), Path::new("/tmp/config.json"));
        let keys: Vec<&str> = d["settings"].as_array().unwrap().iter().map(|s| s["key"].as_str().unwrap()).collect();
        assert!(keys.contains(&"battery_floor") && keys.contains(&"heat_guard") && keys.contains(&"preset"));
        let floor = d["settings"].as_array().unwrap().iter().find(|s| s["key"] == "battery_floor").unwrap();
        assert_eq!(floor["value"], json!(15));
        assert!(floor["note"].as_str().unwrap().contains("raised"));
    }

    #[test]
    fn connect_keeps_other_servers_and_backs_up() {
        let dir = std::env::temp_dir().join(format!("ajar-ai-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cc = dir.join(".claude.json");
        let codex = dir.join(".codex/config.toml");
        std::fs::write(&cc, r#"{"mcpServers":{"other":{"command":"x"}},"theme":"light"}"#).unwrap();
        connect_claude_code_at(&cc).unwrap();
        let v: Value = serde_json::from_slice(&std::fs::read(dir.join(".claude.json")).unwrap()).unwrap();
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["theme"], "light");
        assert_eq!(v["mcpServers"]["ajar"]["args"], json!(["mcp"]));
        assert!(dir.join(".claude.json.ajar-backup").exists());
        std::fs::write(&cc, "not json").unwrap();
        assert!(connect_claude_code_at(&cc).is_err());
        assert_eq!(std::fs::read_to_string(&cc).unwrap(), "not json");
        connect_codex_at(&codex).unwrap();
        let t = std::fs::read_to_string(&codex).unwrap();
        assert!(t.contains("[mcp_servers.ajar]") && t.contains("args = [\"mcp\"]"));
        assert_eq!(connect_codex_at(&codex).unwrap(), "Codex already has Ajar.");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
