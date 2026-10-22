//! "Approve everything": sets Claude Code and Codex to run without asking (their own built-in modes) and puts the
//! person's settings back when it's turned off. Same files and values as the Mac app:
//! • Claude Code: `permissions.defaultMode = "bypassPermissions"` and `skipDangerousModePermissionPrompt = true`
//!   in ~/.claude/settings.json (the person confirmed the same warning in Nocturnal's menu).
//! • Codex: top-level `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in config.toml.
//!
//! Only the tray menu can turn it on (never the CLI, MCP, the phone or the settings file), so an agent can't grant
//! itself this. The journal file is the switch: it exists exactly while it's on, and holds what to put back.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

pub const CODEX_APPROVAL: &str = "approval_policy = \"never\"";
pub const CODEX_SANDBOX: &str = "sandbox_mode = \"danger-full-access\"";

#[derive(Default, Serialize, Deserialize)]
struct Journal {
    claude_mode: Option<String>,
    claude_skip: Option<bool>,
    claude_touched: bool,
    codex_approval: Option<String>,
    codex_sandbox: Option<String>,
    codex_touched: bool,
}

pub struct Paths {
    pub journal: PathBuf,
    pub claude: PathBuf,
    pub codex: PathBuf,
}

impl Paths {
    pub fn new(root: &Path) -> Paths {
        let home = crate::state::home();
        let codex_home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        Paths {
            journal: root.join("auto-approve.json"),
            claude: home.join(".claude").join("settings.json"),
            codex: codex_home.join("config.toml"),
        }
    }
}

pub fn is_on(p: &Paths) -> bool {
    p.journal.exists()
}

fn read_claude(p: &Paths) -> Result<Map<String, Value>, String> {
    let Ok(text) = std::fs::read_to_string(&p.claude) else {
        return Ok(Map::new());
    };
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(m)) => Ok(m),
        _ => Err(
            "Couldn't read ~/.claude/settings.json (it isn't plain JSON), so nothing was changed."
                .into(),
        ),
    }
}

fn write(path: &Path, text: &str) -> Result<(), String> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("nocturnal-tmp");
    std::fs::write(&tmp, text)
        .and_then(|_| std::fs::rename(&tmp, path))
        .map_err(|e| format!("Couldn't write {}: {e}", path.display()))
}

fn save_journal(p: &Paths, j: &Journal) -> Result<(), String> {
    write(&p.journal, &serde_json::to_string(j).unwrap_or_default())
}

pub fn turn_on(p: &Paths) -> Result<(), String> {
    if is_on(p) {
        return Ok(());
    }
    let claude = read_claude(p)?;
    // An existing Codex config that can't be read is never overwritten.
    let codex = match std::fs::read_to_string(&p.codex) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => return Err("Couldn't read Codex's config.toml, so nothing was changed.".into()),
    };
    let perms = claude
        .get("permissions")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut j = Journal {
        claude_mode: perms
            .get("defaultMode")
            .and_then(Value::as_str)
            .map(str::to_string),
        claude_skip: claude
            .get("skipDangerousModePermissionPrompt")
            .and_then(Value::as_bool),
        codex_approval: top_level_line(&codex, "approval_policy"),
        codex_sandbox: top_level_line(&codex, "sandbox_mode"),
        ..Default::default()
    };
    // Journal before touching anything: if Nocturnal dies halfway, turning it off still puts things back.
    save_journal(p, &j)?;
    // A failure partway puts back whatever was changed, so it's never left half on.
    apply(p, claude, perms, &codex, &mut j).inspect_err(|_| {
        let _ = turn_off(p);
    })
}

fn apply(
    p: &Paths,
    mut claude: Map<String, Value>,
    mut perms: Map<String, Value>,
    codex: &str,
    j: &mut Journal,
) -> Result<(), String> {
    perms.insert("defaultMode".into(), json!("bypassPermissions"));
    claude.insert("permissions".into(), Value::Object(perms));
    claude.insert("skipDangerousModePermissionPrompt".into(), json!(true));
    write(
        &p.claude,
        &serde_json::to_string_pretty(&Value::Object(claude)).unwrap_or_default(),
    )?;
    j.claude_touched = true;
    save_journal(p, j)?;
    let t = set_top_level(codex, "approval_policy", Some(CODEX_APPROVAL));
    let t = set_top_level(&t, "sandbox_mode", Some(CODEX_SANDBOX));
    write(&p.codex, &t)?;
    j.codex_touched = true;
    save_journal(p, j)
}

/// Puts back what was there, but only where the value is still Nocturnal's.
pub fn turn_off(p: &Paths) -> Result<(), String> {
    if !is_on(p) {
        return Ok(());
    }
    // A damaged journal still means "on": undo Nocturnal's own values (they can only be Nocturnal's) without the
    // previous ones, rather than leaving both tools running without asking.
    let j = std::fs::read_to_string(&p.journal)
        .ok()
        .and_then(|t| serde_json::from_str::<Journal>(&t).ok())
        .unwrap_or(Journal {
            claude_touched: true,
            codex_touched: true,
            ..Default::default()
        });
    if j.claude_touched {
        if let Ok(mut c) = read_claude(p) {
            let mut perms = c
                .get("permissions")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            if perms.get("defaultMode").and_then(Value::as_str) == Some("bypassPermissions") {
                match &j.claude_mode {
                    Some(m) => perms.insert("defaultMode".into(), json!(m)),
                    None => perms.remove("defaultMode"),
                };
            }
            if perms.is_empty() {
                c.remove("permissions");
            } else {
                c.insert("permissions".into(), Value::Object(perms));
            }
            if c.get("skipDangerousModePermissionPrompt")
                .and_then(Value::as_bool)
                == Some(true)
            {
                match j.claude_skip {
                    Some(s) => c.insert("skipDangerousModePermissionPrompt".into(), json!(s)),
                    None => c.remove("skipDangerousModePermissionPrompt"),
                };
            }
            write(
                &p.claude,
                &serde_json::to_string_pretty(&Value::Object(c)).unwrap_or_default(),
            )?;
        }
    }
    if j.codex_touched {
        if let Ok(mut t) = std::fs::read_to_string(&p.codex) {
            if top_level_line(&t, "approval_policy").as_deref() == Some(CODEX_APPROVAL) {
                t = set_top_level(&t, "approval_policy", j.codex_approval.as_deref());
            }
            if top_level_line(&t, "sandbox_mode").as_deref() == Some(CODEX_SANDBOX) {
                t = set_top_level(&t, "sandbox_mode", j.codex_sandbox.as_deref());
            }
            write(&p.codex, &t)?;
        }
    }
    std::fs::remove_file(&p.journal).map_err(|e| e.to_string())
}

fn is_key_line(trimmed: &str, key: &str) -> bool {
    trimmed
        .strip_prefix(key)
        .is_some_and(|rest| rest.trim_start().starts_with('='))
}

/// The top-level `key = …` line (before the first [table]), verbatim.
pub fn top_level_line(text: &str, key: &str) -> Option<String> {
    for raw in text.split('\n') {
        let t = raw.trim();
        if t.starts_with('[') {
            return None;
        }
        if is_key_line(t, key) {
            return Some(raw.to_string());
        }
    }
    None
}

/// Replaces the top-level `key = …` line with `line` (None removes it), or adds `line` at the top.
pub fn set_top_level(text: &str, key: &str, line: Option<&str>) -> String {
    let mut lines: Vec<String> = if text.is_empty() {
        vec![]
    } else {
        text.split('\n').map(str::to_string).collect()
    };
    for i in 0..lines.len() {
        let t = lines[i].trim();
        if t.starts_with('[') {
            break;
        }
        if is_key_line(t, key) {
            match line {
                Some(l) => lines[i] = l.to_string(),
                None => {
                    lines.remove(i);
                }
            }
            return lines.join("\n");
        }
    }
    match line {
        Some(l) => {
            lines.insert(0, l.to_string());
            lines.join("\n")
        }
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(name: &str) -> Paths {
        let d = std::env::temp_dir().join(format!("nocturnal-approve-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Paths {
            journal: d.join("auto-approve.json"),
            claude: d.join("claude/settings.json"),
            codex: d.join("codex/config.toml"),
        }
    }

    #[test]
    fn on_then_off_puts_everything_back() {
        let p = paths("roundtrip");
        write(
            &p.claude,
            r#"{"model":"opus","permissions":{"defaultMode":"acceptEdits","allow":["Bash(ls)"]}}"#,
        )
        .unwrap();
        write(&p.codex, "model = \"gpt-5\"\napproval_policy = \"on-request\"\n\n[profiles.fast]\nsandbox_mode = \"read-only\"\n").unwrap();
        turn_on(&p).unwrap();
        assert!(is_on(&p));
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert_eq!(c["permissions"]["defaultMode"], "bypassPermissions");
        assert_eq!(
            c["permissions"]["allow"][0], "Bash(ls)",
            "other settings kept"
        );
        assert_eq!(c["skipDangerousModePermissionPrompt"], true);
        let t = std::fs::read_to_string(&p.codex).unwrap();
        assert!(
            t.contains(CODEX_APPROVAL) && t.starts_with(CODEX_SANDBOX),
            "{t}"
        );
        assert!(
            t.contains("[profiles.fast]\nsandbox_mode = \"read-only\""),
            "tables untouched"
        );
        turn_off(&p).unwrap();
        assert!(!is_on(&p));
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert_eq!(c["permissions"]["defaultMode"], "acceptEdits");
        assert!(c.get("skipDangerousModePermissionPrompt").is_none());
        assert_eq!(std::fs::read_to_string(&p.codex).unwrap(), "model = \"gpt-5\"\napproval_policy = \"on-request\"\n\n[profiles.fast]\nsandbox_mode = \"read-only\"\n");
    }

    #[test]
    fn a_value_the_person_changed_meanwhile_is_left_alone_and_bad_json_changes_nothing() {
        let p = paths("changed");
        turn_on(&p).unwrap();
        write(
            &p.claude,
            r#"{"permissions":{"defaultMode":"plan"},"skipDangerousModePermissionPrompt":true}"#,
        )
        .unwrap();
        turn_off(&p).unwrap();
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert_eq!(c["permissions"]["defaultMode"], "plan");
        let p2 = paths("badjson");
        write(&p2.claude, "{ // comment\n}").unwrap();
        assert!(turn_on(&p2).is_err());
        assert!(!is_on(&p2));
    }
}
