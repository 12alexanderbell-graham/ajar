//! "Approve everything": sets Claude Code and Codex to run without asking (their own built-in modes) and puts the
//! person's settings back when it's turned off. Same files, values and rules as the Mac app:
//! • Claude Code: `permissions.defaultMode = "bypassPermissions"` and `skipDangerousModePermissionPrompt = true`
//!   in ~/.claude/settings.json (the person confirmed the same warning in Nocturnal's menu).
//! • Codex: top-level `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in config.toml.
//!
//! These are user-wide defaults for new sessions; it never answers the operating system's own prompts. Only the
//! tray menu can turn it on (never the CLI, MCP, the phone or the settings file), so an agent can't grant itself
//! this, and it turns itself off when the work finishes, at a set time, or when the person turns it off.
//!
//! The journal file is the switch: it exists exactly while it's on (or while something couldn't be put back yet).
//! Each file is marked as touched, durably, *before* it's written, and the journal is removed only once every
//! touched file has been put back and read again to check. Putting back only changes values that are still
//! Nocturnal's, so it's safe to repeat.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

pub const CODEX_APPROVAL: &str = "approval_policy = \"never\"";
pub const CODEX_SANDBOX: &str = "sandbox_mode = \"danger-full-access\"";
/// "When the work finishes" still ends after a day, so a session that never starts can't leave it on.
pub const WORK_CAP_SECS: u64 = 24 * 3600;

/// When it turns itself off.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Ends {
    Work,
    Time,
    Manual,
}

#[derive(Default, Serialize, Deserialize, Clone, Debug)]
pub struct Journal {
    claude_mode: Option<String>,
    claude_skip: Option<bool>,
    #[serde(default)]
    claude_touched: bool,
    codex_approval: Option<String>,
    codex_sandbox: Option<String>,
    #[serde(default)]
    codex_touched: bool,
    /// None (older journals) = when the person turns it off.
    #[serde(default)]
    pub ends: Option<Ends>,
    /// Unix seconds: the set time, or the latest it can last while waiting for work.
    #[serde(default)]
    pub ends_at: Option<u64>,
    #[serde(default)]
    pub saw_work: bool,
    /// Why the last attempt to put things back failed. While set, it may still be in force.
    #[serde(default)]
    pub problem: Option<String>,
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

pub fn load(p: &Paths) -> Option<Journal> {
    std::fs::read_to_string(&p.journal)
        .ok()
        .and_then(|t| serde_json::from_str::<Journal>(&t).ok())
}

/// The last failure to put things back, if any.
pub fn problem(p: &Paths) -> Option<String> {
    if !is_on(p) {
        return None;
    }
    match load(p) {
        Some(j) => j.problem,
        None => Some("Its record is damaged".into()),
    }
}

/// Reads ~/.claude/settings.json: the object and the exact text (for compare-and-swap). Only a missing file reads
/// as empty; any other failure (permissions, a folder in its place, a disk error) is an error, so a file that
/// couldn't be read is never replaced with a fresh one.
pub fn read_claude(p: &Paths) -> Result<(Map<String, Value>, Option<String>), String> {
    let text = match std::fs::read_to_string(&p.claude) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Map::new(), None)),
        Err(e) => {
            return Err(format!(
                "Couldn't read ~/.claude/settings.json ({e}), so it was left alone."
            ))
        }
    };
    if text.trim().is_empty() {
        return Ok((Map::new(), Some(text)));
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(m)) => Ok((m, Some(text))),
        _ => Err(
            "Couldn't read ~/.claude/settings.json (it isn't plain JSON), so it was left alone."
                .into(),
        ),
    }
}

fn read_codex(p: &Paths) -> Result<Option<String>, String> {
    match std::fs::read_to_string(&p.codex) {
        Ok(t) => Ok(Some(t)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!(
            "Couldn't read Codex's config.toml ({e}), so it was left alone."
        )),
    }
}

/// Temp file, flushed, renamed: a crash leaves the old file or the new one, never half of either.
pub fn write(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension(format!("nocturnal-tmp{}", std::process::id()));
    let r = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(&tmp, path)
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r.map_err(|e| format!("Couldn't write {}: {e}", path.display()))
}

/// Writes only if the file still holds exactly `expect` (None = no file): Claude Code or an editor may be saving it.
fn write_if_unchanged(
    path: &Path,
    expect: Option<&str>,
    text: &str,
    name: &str,
) -> Result<(), String> {
    let now = match std::fs::read_to_string(path) {
        Ok(t) => Some(t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("Couldn't read {name} ({e}).")),
    };
    if now.as_deref() != expect {
        return Err(format!(
            "{name} changed while Nocturnal was editing it; try again."
        ));
    }
    write(path, text)
}

fn save_journal(p: &Paths, j: &Journal) -> Result<(), String> {
    write(&p.journal, &serde_json::to_string(j).unwrap_or_default())
}

pub fn turn_on(p: &Paths, ends: Ends, hours: Option<f64>, now: u64) -> Result<(), String> {
    if is_on(p) {
        return Ok(());
    }
    // Read both first, so a problem with either changes nothing.
    let (claude, claude_raw) = read_claude(p)?;
    let codex_raw = read_codex(p)?;
    let codex = codex_raw.clone().unwrap_or_default();
    toml_top::check(&codex)?;
    let perms = claude
        .get("permissions")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let j = Journal {
        claude_mode: perms
            .get("defaultMode")
            .and_then(Value::as_str)
            .map(str::to_string),
        claude_skip: claude
            .get("skipDangerousModePermissionPrompt")
            .and_then(Value::as_bool),
        // Marked before either file is written: if Nocturnal dies from here on, turning it off puts back whatever
        // was written. Nothing written yet means nothing to undo.
        claude_touched: true,
        codex_approval: toml_top::line(&codex, "approval_policy"),
        codex_sandbox: toml_top::line(&codex, "sandbox_mode"),
        codex_touched: true,
        ends: Some(ends),
        ends_at: match ends {
            Ends::Time => Some(now + (hours.unwrap_or(8.0) * 3600.0) as u64),
            Ends::Work => Some(now + WORK_CAP_SECS),
            Ends::Manual => None,
        },
        saw_work: false,
        problem: None,
    };
    save_journal(p, &j).map_err(|_| {
        "Couldn't save Nocturnal's record of your settings, so nothing was changed.".to_string()
    })?;
    let r = (|| -> Result<(), String> {
        let mut c = claude.clone();
        let mut perms = perms.clone();
        perms.insert("defaultMode".into(), json!("bypassPermissions"));
        c.insert("permissions".into(), Value::Object(perms));
        c.insert("skipDangerousModePermissionPrompt".into(), json!(true));
        write_if_unchanged(
            &p.claude,
            claude_raw.as_deref(),
            &serde_json::to_string_pretty(&Value::Object(c)).unwrap_or_default(),
            "~/.claude/settings.json",
        )?;
        let t = toml_top::set(&codex, "approval_policy", Some(CODEX_APPROVAL))?;
        let t = toml_top::set(&t, "sandbox_mode", Some(CODEX_SANDBOX))?;
        write_if_unchanged(&p.codex, codex_raw.as_deref(), &t, "Codex's config.toml")?;
        // Read both back: it's only "on" once both tools would actually see it.
        let (c2, _) = read_claude(p)?;
        let t2 = read_codex(p)?.unwrap_or_default();
        let mode = c2
            .get("permissions")
            .and_then(|v| v.get("defaultMode"))
            .and_then(Value::as_str);
        if mode != Some("bypassPermissions")
            || toml_top::line(&t2, "approval_policy").as_deref() != Some(CODEX_APPROVAL)
            || toml_top::line(&t2, "sandbox_mode").as_deref() != Some(CODEX_SANDBOX)
        {
            return Err("The settings didn't stick (another app may have rewritten them), so it was turned off again.".into());
        }
        Ok(())
    })();
    // A failure partway puts back whatever was changed, so it's never left half on. If even that fails, the
    // journal stays and the menu says so.
    r.inspect_err(|_| {
        let _ = turn_off(p);
    })
}

/// Puts back what was there, but only where the value is still Nocturnal's. Keeps the journal, and returns the
/// reason, if any file couldn't be put back and checked.
/// Nocturnal is quitting or has died: nothing is left to watch for the work finishing or the time running out,
/// so an Approve everything that was meant to end by itself ends now. Only "When I turn it off" stays on.
/// Returns whether it turned it off.
pub fn end_unwatched(p: &Paths) -> bool {
    let Some(j) = load(p) else { return false };
    if matches!(j.ends, None | Some(Ends::Manual)) {
        return false;
    }
    turn_off(p).is_ok()
}

pub fn turn_off(p: &Paths) -> Result<(), String> {
    if !is_on(p) {
        return Ok(());
    }
    // A damaged journal still means "on": undo Nocturnal's own values (they can only be Nocturnal's) without the
    // previous ones, rather than leaving both tools running without asking.
    let mut j = load(p).unwrap_or(Journal {
        claude_touched: true,
        codex_touched: true,
        ..Default::default()
    });
    let mut problems: Vec<String> = vec![];
    if j.claude_touched {
        match restore_claude(p, &j) {
            Ok(()) => j.claude_touched = false,
            Err(e) => problems.push(e),
        }
    }
    if j.codex_touched {
        match restore_codex(p, &j) {
            Ok(()) => j.codex_touched = false,
            Err(e) => problems.push(e),
        }
    }
    if problems.is_empty() {
        return std::fs::remove_file(&p.journal).map_err(|e| {
            format!("Put your settings back, but couldn't remove Nocturnal's record of them ({e}). It will try again.")
        });
    }
    let why = problems.join(" ");
    j.problem = Some(why.clone());
    let _ = save_journal(p, &j);
    Err(format!(
        "{why} Approve everything may still be on; Nocturnal keeps trying."
    ))
}

fn restore_claude(p: &Paths, j: &Journal) -> Result<(), String> {
    let (c0, raw) = read_claude(p)?;
    if raw.is_none() {
        return Ok(()); // no file: nothing to undo
    }
    let mut c = c0.clone();
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
    if c != c0 {
        write_if_unchanged(
            &p.claude,
            raw.as_deref(),
            &serde_json::to_string_pretty(&Value::Object(c)).unwrap_or_default(),
            "~/.claude/settings.json",
        )?;
    }
    let (after, _) = read_claude(p)?;
    let mode = after
        .get("permissions")
        .and_then(|v| v.get("defaultMode"))
        .and_then(Value::as_str);
    if mode == Some("bypassPermissions") && j.claude_mode.as_deref() != Some("bypassPermissions") {
        return Err("~/.claude/settings.json still says bypassPermissions.".into());
    }
    Ok(())
}

fn restore_codex(p: &Paths, j: &Journal) -> Result<(), String> {
    let Some(t0) = read_codex(p)? else {
        return Ok(());
    };
    let mut t = t0.clone();
    if toml_top::line(&t, "approval_policy").as_deref() == Some(CODEX_APPROVAL) {
        t = toml_top::set(&t, "approval_policy", j.codex_approval.as_deref())?;
    }
    if toml_top::line(&t, "sandbox_mode").as_deref() == Some(CODEX_SANDBOX) {
        t = toml_top::set(&t, "sandbox_mode", j.codex_sandbox.as_deref())?;
    }
    if t != t0 {
        write_if_unchanged(&p.codex, Some(&t0), &t, "Codex's config.toml")?;
    }
    let after = read_codex(p)?.unwrap_or_default();
    let still_approval = toml_top::line(&after, "approval_policy").as_deref()
        == Some(CODEX_APPROVAL)
        && j.codex_approval.as_deref() != Some(CODEX_APPROVAL);
    let still_sandbox = toml_top::line(&after, "sandbox_mode").as_deref() == Some(CODEX_SANDBOX)
        && j.codex_sandbox.as_deref() != Some(CODEX_SANDBOX);
    if still_approval || still_sandbox {
        return Err("Codex's config.toml still says never ask.".into());
    }
    Ok(())
}

/// Notes that Nocturnal kept the computer awake for work since it was turned on ("when the work finishes").
pub fn mark_work(p: &Paths) {
    if let Some(mut j) = load(p) {
        if j.ends == Some(Ends::Work) && !j.saw_work && j.problem.is_none() {
            j.saw_work = true;
            let _ = save_journal(p, &j);
        }
    }
}

/// Why it should turn itself off now, if it should ("retry" while something couldn't be put back yet).
pub fn expiry(p: &Paths, holding_for_work: bool, now: u64) -> Option<&'static str> {
    let j = load(p)?;
    if j.problem.is_some() {
        return Some("retry");
    }
    if j.ends_at.is_some_and(|at| now >= at) {
        return Some(if j.ends == Some(Ends::Time) {
            "Its time was up"
        } else {
            "No work started for a day"
        });
    }
    if j.ends == Some(Ends::Work) && j.saw_work && !holding_for_work {
        return Some("The work finished");
    }
    None
}

/// One line for the menu: how and when it ends.
pub fn ends_line(p: &Paths) -> Option<String> {
    let j = load(p)?;
    if j.problem.is_some() {
        return Some("Couldn't put your settings back yet".into());
    }
    Some(match j.ends {
        Some(Ends::Work) if j.saw_work => "Turns off when the work finishes".into(),
        Some(Ends::Work) => "Turns off when the next work finishes".into(),
        Some(Ends::Time) => match j.ends_at {
            Some(at) => format!("Turns off at {}", crate::format::clock(at)),
            None => "Turns off later".into(),
        },
        Some(Ends::Manual) | None => "Stays on until you turn it off".into(),
    })
}

/// Top-level `key = value` lines in a TOML file, edited as text so comments and layout stay as they are. Knows
/// enough TOML not to be fooled: table headers end the top level, lines inside multi-line strings and multi-line
/// arrays are never keys, and quoted keys (`"approval_policy" = …`) count. Same rules as the Mac app.
pub mod toml_top {
    struct Entry {
        index: usize,
        key: String,
    }

    fn scan(lines: &[&str]) -> Vec<Entry> {
        let mut entries = vec![];
        let mut multi: Option<&str> = None;
        let mut depth: i32 = 0;
        for (i, raw) in lines.iter().enumerate() {
            if let Some(m) = multi {
                if raw.matches(m).count() % 2 == 1 {
                    multi = None;
                }
                continue;
            }
            if depth > 0 {
                depth = (depth + bracket_delta(&strip_strings(raw))).max(0);
                continue;
            }
            let t = raw.trim();
            if t.is_empty() || t.starts_with('#') {
                continue;
            }
            if t.starts_with('[') {
                break; // a table header: the top level ends here
            }
            let Some(eq) = key_end(t) else { continue };
            entries.push(Entry {
                index: i,
                key: unquote(t[..eq].trim()).to_string(),
            });
            let value = &t[eq + 1..];
            for d in ["\"\"\"", "'''"] {
                if value.matches(d).count() % 2 == 1 {
                    multi = Some(d);
                    break;
                }
            }
            if multi.is_none() {
                depth = bracket_delta(&strip_strings(value)).max(0);
            }
        }
        entries
    }

    /// Where the key part of a `key = value` line ends (the `=` outside quotes).
    fn key_end(t: &str) -> Option<usize> {
        let mut quote: Option<char> = None;
        for (i, ch) in t.char_indices() {
            match quote {
                Some(q) => {
                    if ch == q {
                        quote = None
                    }
                }
                None if ch == '"' || ch == '\'' => quote = Some(ch),
                None if ch == '=' => return Some(i),
                None => {}
            }
        }
        None
    }

    fn unquote(k: &str) -> &str {
        let b = k.as_bytes();
        if b.len() >= 2 && b[0] == b[b.len() - 1] && (b[0] == b'"' || b[0] == b'\'') {
            &k[1..k.len() - 1]
        } else {
            k
        }
    }

    /// The text with quoted strings and a trailing comment removed (brackets inside strings don't count).
    pub fn strip_strings(s: &str) -> String {
        let mut out = String::new();
        let mut quote: Option<char> = None;
        let mut escaped = false;
        for ch in s.chars() {
            if let Some(q) = quote {
                if escaped {
                    escaped = false;
                } else if ch == '\\' && q == '"' {
                    escaped = true;
                } else if ch == q {
                    quote = None;
                }
                continue;
            }
            if ch == '"' || ch == '\'' {
                quote = Some(ch);
                continue;
            }
            if ch == '#' {
                break;
            }
            out.push(ch);
        }
        out
    }

    fn bracket_delta(s: &str) -> i32 {
        s.chars()
            .map(|c| match c {
                '[' => 1,
                ']' => -1,
                _ => 0,
            })
            .sum()
    }

    fn split(text: &str) -> Vec<&str> {
        text.split('\n').collect()
    }

    /// The top-level `key = …` line, verbatim.
    pub fn line(text: &str, key: &str) -> Option<String> {
        let lines = split(text);
        scan(&lines)
            .into_iter()
            .find(|e| e.key == key)
            .map(|e| lines[e.index].to_string())
    }

    /// Refuses files whose top level can't be edited safely (the same key twice).
    pub fn check(text: &str) -> Result<(), String> {
        let lines = split(text);
        let entries = scan(&lines);
        for k in ["approval_policy", "sandbox_mode"] {
            if entries.iter().filter(|e| e.key == k).count() > 1 {
                return Err(format!(
                    "Codex's config.toml sets {k} twice, so Nocturnal left it alone."
                ));
            }
        }
        Ok(())
    }

    /// Replaces the top-level `key = …` line with `line` (None removes it), or adds `line` at the top. Checks the
    /// result has the key exactly once (or not at all when removing), so it never writes a broken file.
    pub fn set(text: &str, key: &str, line: Option<&str>) -> Result<String, String> {
        let mut lines: Vec<String> = if text.is_empty() {
            vec![]
        } else {
            text.split('\n').map(str::to_string).collect()
        };
        let found = {
            let refs: Vec<&str> = lines.iter().map(String::as_str).collect();
            scan(&refs)
                .into_iter()
                .find(|e| e.key == key)
                .map(|e| e.index)
        };
        match (found, line) {
            (Some(i), Some(l)) => lines[i] = l.to_string(),
            (Some(i), None) => {
                lines.remove(i);
            }
            (None, Some(l)) => lines.insert(0, l.to_string()),
            (None, None) => {}
        }
        let out = lines.join("\n");
        let count = scan(&split(&out)).iter().filter(|e| e.key == key).count();
        if count != usize::from(line.is_some()) {
            return Err(format!(
                "Couldn't edit {key} in Codex's config.toml safely, so it was left alone."
            ));
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(name: &str) -> Paths {
        let d =
            std::env::temp_dir().join(format!("nocturnal-approve-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        Paths {
            journal: d.join("auto-approve.json"),
            claude: d.join("claude/settings.json"),
            codex: d.join("codex/config.toml"),
        }
    }

    const NOW: u64 = 1_800_000_000;

    #[test]
    fn quitting_ends_it_unless_it_was_set_to_stay_on() {
        for (name, ends, ended) in [
            ("quit-work", Ends::Work, true),
            ("quit-time", Ends::Time, true),
            ("quit-manual", Ends::Manual, false),
        ] {
            let p = paths(name);
            write(
                &p.claude,
                r#"{"permissions":{"defaultMode":"acceptEdits"}}"#,
            )
            .unwrap();
            turn_on(&p, ends, Some(8.0), NOW).unwrap();
            assert_eq!(end_unwatched(&p), ended, "{name}");
            assert_eq!(is_on(&p), !ended, "{name}");
            if ended {
                let c: Value =
                    serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
                assert_eq!(
                    c["permissions"]["defaultMode"], "acceptEdits",
                    "{name}: the person's own setting is back"
                );
            }
        }
        assert!(
            !end_unwatched(&paths("quit-none")),
            "nothing on: nothing to do"
        );
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
        turn_on(&p, Ends::Manual, None, NOW).unwrap();
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
        turn_on(&p, Ends::Manual, None, NOW).unwrap();
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
        assert!(turn_on(&p2, Ends::Manual, None, NOW).is_err());
        assert!(!is_on(&p2));
    }

    /// A crash right after the journal was written, before either file: turning off changes nothing and finishes.
    #[test]
    fn crash_before_any_write_turns_off_cleanly() {
        let p = paths("crash0");
        let claude = r#"{"permissions":{"defaultMode":"acceptEdits"}}"#;
        write(&p.claude, claude).unwrap();
        let j = Journal {
            claude_mode: Some("acceptEdits".into()),
            claude_touched: true,
            codex_touched: true,
            ..Default::default()
        };
        save_journal(&p, &j).unwrap();
        turn_off(&p).unwrap();
        assert!(!is_on(&p));
        assert_eq!(
            std::fs::read_to_string(&p.claude).unwrap(),
            claude,
            "untouched file not rewritten"
        );
        assert!(!p.codex.exists(), "no Codex file created");
    }

    /// A crash after Claude's file was written but before the journal noted anything more: still put back.
    #[test]
    fn crash_after_claude_write_is_put_back() {
        let p = paths("crash1");
        write(&p.claude, r#"{"permissions":{"defaultMode":"bypassPermissions"},"skipDangerousModePermissionPrompt":true}"#).unwrap();
        let j = Journal {
            claude_mode: Some("default".into()),
            claude_touched: true,
            codex_touched: true,
            ..Default::default()
        };
        save_journal(&p, &j).unwrap();
        turn_off(&p).unwrap();
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert_eq!(c["permissions"]["defaultMode"], "default");
        assert!(c.get("skipDangerousModePermissionPrompt").is_none());
    }

    /// A touched file that can't be read keeps the journal (still "on", with the reason) instead of claiming off.
    #[test]
    fn unreadable_file_keeps_it_on_with_a_reason() {
        let p = paths("unreadable");
        turn_on(&p, Ends::Manual, None, NOW).unwrap();
        // A folder where the file should be: reading fails with something other than "not found".
        std::fs::remove_file(&p.claude).unwrap();
        std::fs::create_dir_all(&p.claude).unwrap();
        let err = turn_off(&p).unwrap_err();
        assert!(err.contains("still be on"), "{err}");
        assert!(is_on(&p));
        assert!(problem(&p).is_some());
        assert_eq!(expiry(&p, false, NOW), Some("retry"));
        // Codex was put back on the first try and isn't touched again.
        assert!(!std::fs::read_to_string(&p.codex).unwrap().contains("never"));
        // Fixed: the retry finishes.
        std::fs::remove_dir(&p.claude).unwrap();
        write(
            &p.claude,
            r#"{"permissions":{"defaultMode":"bypassPermissions"}}"#,
        )
        .unwrap();
        turn_off(&p).unwrap();
        assert!(!is_on(&p));
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert!(c.get("permissions").is_none());
    }

    #[test]
    fn unreadable_claude_file_is_never_replaced_on_turn_on() {
        let p = paths("dirclaude");
        std::fs::create_dir_all(&p.claude).unwrap();
        assert!(turn_on(&p, Ends::Manual, None, NOW).is_err());
        assert!(!is_on(&p));
        assert!(p.claude.is_dir());
    }

    #[test]
    fn damaged_journal_still_undoes_nocturnals_values() {
        let p = paths("damaged");
        turn_on(&p, Ends::Manual, None, NOW).unwrap();
        write(&p.journal, "{not json").unwrap();
        turn_off(&p).unwrap();
        assert!(!is_on(&p));
        let c: Value = serde_json::from_str(&std::fs::read_to_string(&p.claude).unwrap()).unwrap();
        assert!(c.get("permissions").is_none());
        assert!(!std::fs::read_to_string(&p.codex)
            .unwrap()
            .contains("danger"));
    }

    #[test]
    fn ends_when_the_work_finishes_or_the_time_is_up() {
        let p = paths("ends");
        turn_on(&p, Ends::Work, None, NOW).unwrap();
        assert_eq!(expiry(&p, false, NOW + 60), None, "no work yet");
        mark_work(&p);
        assert_eq!(expiry(&p, true, NOW + 60), None, "still working");
        assert_eq!(expiry(&p, false, NOW + 120), Some("The work finished"));
        assert_eq!(
            expiry(&p, true, NOW + WORK_CAP_SECS),
            Some("No work started for a day")
        );
        turn_off(&p).unwrap();
        turn_on(&p, Ends::Time, Some(2.0), NOW).unwrap();
        assert_eq!(expiry(&p, false, NOW + 7199), None);
        assert_eq!(expiry(&p, false, NOW + 7200), Some("Its time was up"));
        turn_off(&p).unwrap();
    }

    #[test]
    fn toml_top_level_is_found_safely() {
        use toml_top::*;
        let t = "# comment\nmodel = \"x\"\nnotes = \"\"\"\napproval_policy = \"inside a string\"\n\"\"\"\nlist = [\n  [1, 2],\n  \"]\",\n]\n\"sandbox_mode\" = \"read-only\"\n[table]\napproval_policy = \"in a table\"\n";
        assert_eq!(line(t, "approval_policy"), None);
        assert_eq!(
            line(t, "sandbox_mode").as_deref(),
            Some("\"sandbox_mode\" = \"read-only\"")
        );
        let t2 = set(t, "sandbox_mode", Some(CODEX_SANDBOX)).unwrap();
        assert!(t2.contains(CODEX_SANDBOX) && !t2.contains("read-only"));
        let t3 = set(&t2, "approval_policy", Some(CODEX_APPROVAL)).unwrap();
        assert!(t3.starts_with(CODEX_APPROVAL));
        assert!(
            t3.contains("approval_policy = \"inside a string\""),
            "string body untouched"
        );
        assert!(
            t3.contains("approval_policy = \"in a table\""),
            "table untouched"
        );
        let back = set(&t3, "approval_policy", None).unwrap();
        assert_eq!(back, t2);
        assert!(check("approval_policy = \"a\"\napproval_policy = \"b\"\n").is_err());
    }
}
