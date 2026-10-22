//! What an agent itself says it's doing, from its own lifecycle hooks (Claude Code's `UserPromptSubmit`, `Stop`,
//! `Notification` and session events). Same files and rules as the Mac app: far more reliable than guessing from
//! CPU use. A quiet two-hour build is still "working", a question waiting for an answer is "waiting", and a
//! finished turn is "finished" even while an MCP server keeps ticking. The CPU guess stays as the fallback.
//!
//! Each hook runs `nocturnal event claude-code`, which writes one small file per session into `agent-events/`
//! and returns at once. Nocturnal reads them on its next sample; a session whose process has gone is dropped.

use crate::procs::Proc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentState {
    /// Open, nothing asked yet.
    Idle,
    /// A prompt was sent and the turn hasn't ended.
    Working,
    /// Asking the person: a permission prompt or a question.
    Waiting,
    /// The turn ended.
    Finished,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentState::Idle => "idle",
            AgentState::Working => "working",
            AgentState::Waiting => "waiting",
            AgentState::Finished => "finished",
        }
    }
    fn rank(self) -> u8 {
        match self {
            AgentState::Working => 3,
            AgentState::Waiting => 2,
            AgentState::Finished => 1,
            AgentState::Idle => 0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AgentEvent {
    pub agent: String,
    pub session: String,
    pub state: AgentState,
    pub at: u64,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default, rename = "pidStart")]
    pub pid_start: Option<u64>,
    #[serde(default)]
    pub detail: Option<String>,
}

/// "Working" with no sign of life at all for this long is treated as unknown: a turn the person interrupted ends
/// without a Stop event.
pub const STUCK_AFTER: u64 = 30 * 60;
/// How long a question waiting for an answer keeps the computer awake.
pub const WAIT_LIMIT: u64 = 30 * 60;

pub fn dir(root: &Path) -> PathBuf {
    root.join("agent-events")
}

fn clean(s: &str, max: usize) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(max)
        .collect()
}

/// The hook side (`nocturnal event <agent>`): quick, quiet, and never fails loudly. `procs` is a process snapshot,
/// used to find the agent process above the hook.
pub fn record(root: &Path, agent: &str, input: &str, now: u64, procs: &[Proc], me: u32) {
    if agent.is_empty() || agent.len() > 32 || clean(agent, 32) != agent {
        return;
    }
    let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(input) else {
        return;
    };
    let session = clean(obj.get("session_id").and_then(Value::as_str).unwrap_or("unknown"), 64);
    if session.is_empty() {
        return;
    }
    let path = dir(root).join(format!("{agent}-{session}.json"));
    let previous: Option<AgentEvent> = std::fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());
    let event = obj.get("hook_event_name").and_then(Value::as_str).unwrap_or("");
    let mut at = now;
    let mut detail = None;
    let state = match event {
        "UserPromptSubmit" => AgentState::Working,
        "Stop" => AgentState::Finished,
        "SessionStart" => {
            // An automatic compaction restarts the session in the middle of a turn: not a change of state.
            if obj.get("source").and_then(Value::as_str) == Some("compact") {
                return;
            }
            AgentState::Idle
        }
        "SessionEnd" => {
            let _ = std::fs::remove_file(&path);
            return;
        }
        "Notification" => {
            let kind = obj
                .get("notification_type")
                .or_else(|| obj.get("matcher"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let message = obj
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_lowercase();
            if matches!(kind, "permission_prompt" | "elicitation_dialog" | "agent_needs_input")
                || (kind.is_empty() && (message.contains("permission") || message.contains("approve")))
            {
                detail = Some(if kind.is_empty() { "permission_prompt".to_string() } else { kind.to_string() });
                AgentState::Waiting
            } else if kind == "idle_prompt" || (kind.is_empty() && message.contains("waiting for your input")) {
                // Sent about a minute after the turn ended. Keep the real end time if we have it.
                at = match &previous {
                    Some(p) if p.state == AgentState::Finished => p.at,
                    _ => now.saturating_sub(60),
                };
                AgentState::Finished
            } else {
                return;
            }
        }
        _ => return,
    };
    let found = agent_process(agent, procs, me);
    let e = AgentEvent {
        agent: agent.to_string(),
        session,
        state,
        at,
        pid: found.map(|p| p.0).or(previous.as_ref().and_then(|p| p.pid)),
        pid_start: match found {
            Some(p) => Some(p.1),
            None => previous.and_then(|p| p.pid_start),
        },
        detail,
    };
    let _ = std::fs::create_dir_all(dir(root));
    let _ = crate::state::write_atomic(&path, &serde_json::to_string(&e).unwrap_or_default());
}

/// The agent process above this hook (hook → maybe a shell → the agent): (pid, start).
fn agent_process(agent: &str, procs: &[Proc], me: u32) -> Option<(u32, u64)> {
    let by_pid: std::collections::HashMap<u32, &Proc> = procs.iter().map(|p| (p.pid, p)).collect();
    let mut cur = by_pid.get(&me).map(|p| p.ppid);
    for _ in 0..6 {
        let p = by_pid.get(&cur?)?;
        if crate::agents::kind_id(p).as_deref() == Some(agent) {
            return Some((p.pid, p.start));
        }
        if p.ppid == p.pid || p.ppid <= 1 {
            return None;
        }
        cur = Some(p.ppid);
    }
    None
}

/// Current sessions. Drops (and deletes) ones whose agent process has gone, or that are more than two days old.
pub fn load(root: &Path, now: u64, procs: &[Proc]) -> Vec<AgentEvent> {
    let Ok(rd) = std::fs::read_dir(dir(root)) else {
        return vec![];
    };
    let mut out = vec![];
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(e) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str::<AgentEvent>(&t).ok())
        else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        let gone = e.pid.is_some_and(|pid| {
            !procs
                .iter()
                .any(|p| p.pid == pid && e.pid_start.is_none_or(|s| s == p.start))
        });
        if gone || now.saturating_sub(e.at) > 2 * 86_400 {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        out.push(e);
    }
    out
}

/// What the agent of this kind is doing, combining its sessions: working beats waiting beats finished.
/// `last_active` is the CPU-based guess, used to spot a stuck "working" and a question answered since.
pub fn state_of(kind: &str, events: &[AgentEvent], last_active: u64, now: u64) -> Option<(AgentState, u64)> {
    let mut best: Option<(AgentState, u64)> = None;
    for e in events.iter().filter(|e| e.agent == kind) {
        let mut s = e.state;
        if s == AgentState::Working && now.saturating_sub(e.at.max(last_active)) > STUCK_AFTER {
            continue; // unknown
        }
        // Busy again after the question: it was answered (Claude Code sends no event for that).
        if s == AgentState::Waiting && last_active > e.at + 5 {
            s = AgentState::Working;
        }
        let better = match best {
            None => true,
            Some((b, bat)) => s.rank() > b.rank() || (s.rank() == b.rank() && e.at > bat),
        };
        if better {
            best = Some((s, e.at));
        }
    }
    best
}

// MARK: Claude Code hooks

pub const HOOK_EVENTS: &[&str] = &["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"];
pub const MARKER: &str = "event claude-code";

/// The hook handler for this install. On macOS and Linux a guarded shell command that does nothing if Nocturnal
/// is gone; on Windows the exec form (a program and its arguments, no shell), since the shell there may be Git
/// Bash or PowerShell. Run without its arguments by an older Claude Code, the `nocturnal` command only shows the status.
pub fn hook_handler(exe: &str) -> Value {
    if cfg!(windows) {
        json!({ "type": "command", "command": exe, "args": ["event", "claude-code"], "timeout": 10 })
    } else {
        let q = format!("'{}'", exe.replace('\'', "'\\''"));
        json!({ "type": "command", "command": format!("[ -x {q} ] && {q} {MARKER}; exit 0"), "timeout": 10 })
    }
}

pub fn is_ours(handler: &Value) -> bool {
    let cmd = handler.get("command").and_then(Value::as_str).unwrap_or("");
    let args = handler
        .get("args")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
        .unwrap_or_default();
    let all = format!("{cmd} {args}");
    all.contains(MARKER) && all.to_lowercase().contains("nocturnal")
}

/// The settings with Nocturnal's hooks removed (everything else kept), and whether anything changed.
pub fn without_hooks(settings: &Map<String, Value>) -> (Map<String, Value>, bool) {
    let mut c = settings.clone();
    let Some(Value::Object(hooks)) = c.get("hooks").cloned() else {
        return (c, false);
    };
    let mut changed = false;
    let mut out = Map::new();
    for (ev, groups) in hooks {
        let Value::Array(groups) = groups else {
            out.insert(ev, groups);
            continue;
        };
        let mut kept = vec![];
        for mut g in groups {
            let handlers = g.get("hooks").and_then(Value::as_array).cloned().unwrap_or_default();
            let rest: Vec<Value> = handlers.iter().filter(|h| !is_ours(h)).cloned().collect();
            if rest.len() != handlers.len() {
                changed = true;
            }
            if rest.is_empty() && !handlers.is_empty() {
                continue; // the group only held Nocturnal's hook
            }
            if let Some(o) = g.as_object_mut() {
                o.insert("hooks".into(), Value::Array(rest));
            }
            kept.push(g);
        }
        if !kept.is_empty() {
            out.insert(ev, Value::Array(kept));
        }
    }
    if out.is_empty() {
        c.remove("hooks");
    } else {
        c.insert("hooks".into(), Value::Object(out));
    }
    (c, changed)
}

/// The settings with Nocturnal's hooks added (any older copy replaced).
pub fn with_hooks(settings: &Map<String, Value>, exe: &str) -> Map<String, Value> {
    let (mut c, _) = without_hooks(settings);
    let mut hooks = c.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    for ev in HOOK_EVENTS {
        let mut groups = hooks.get(*ev).and_then(Value::as_array).cloned().unwrap_or_default();
        groups.push(json!({ "hooks": [hook_handler(exe)] }));
        hooks.insert(ev.to_string(), Value::Array(groups));
    }
    c.insert("hooks".into(), Value::Object(hooks));
    c
}

/// All five hooks are in place with this program.
pub fn hooks_installed(settings: &Map<String, Value>, exe: &str) -> bool {
    let want = hook_handler(exe);
    let Some(hooks) = settings.get("hooks").and_then(Value::as_object) else {
        return false;
    };
    HOOK_EVENTS.iter().all(|ev| {
        hooks
            .get(*ev)
            .and_then(Value::as_array)
            .is_some_and(|groups| {
                groups.iter().any(|g| {
                    g.get("hooks")
                        .and_then(Value::as_array)
                        .is_some_and(|hs| hs.iter().any(|h| h.get("command") == want.get("command") && h.get("args") == want.get("args")))
                })
            })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("nocturnal-events-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn p(pid: u32, ppid: u32, name: &str) -> Proc {
        Proc {
            pid,
            ppid,
            name: name.into(),
            exe: None,
            cmd: vec![name.into()],
            cpu_ns: 0,
            start: pid as u64 * 7,
            mine: true,
        }
    }

    #[test]
    fn lifecycle_of_a_turn() {
        let root = tmp("life");
        // claude (100) → sh (200) → nocturnal (300)
        let procs = vec![p(100, 1, "claude"), p(200, 100, "sh"), p(300, 200, "nocturnal")];
        let ev = |name: &str, extra: &str| format!(r#"{{"session_id":"abc-1","hook_event_name":"{name}"{extra}}}"#);
        record(&root, "claude-code", &ev("SessionStart", r#","source":"startup""#), 1000, &procs, 300);
        let l = load(&root, 1000, &procs);
        assert_eq!(l.len(), 1);
        assert_eq!(l[0].state, AgentState::Idle);
        assert_eq!(l[0].pid, Some(100), "the agent above the hook's shell");
        record(&root, "claude-code", &ev("UserPromptSubmit", ""), 1010, &procs, 300);
        assert_eq!(state_of("claude-code", &load(&root, 1010, &procs), 0, 1010), Some((AgentState::Working, 1010)));
        // Compaction mid-turn changes nothing.
        record(&root, "claude-code", &ev("SessionStart", r#","source":"compact""#), 1500, &procs, 300);
        assert_eq!(load(&root, 1500, &procs)[0].state, AgentState::Working);
        record(&root, "claude-code", &ev("Notification", r#","notification_type":"permission_prompt""#), 2000, &procs, 300);
        assert_eq!(state_of("claude-code", &load(&root, 2000, &procs), 1990, 2010), Some((AgentState::Waiting, 2000)));
        // CPU activity after the question: it was answered.
        assert_eq!(state_of("claude-code", &load(&root, 2000, &procs), 2100, 2100).map(|s| s.0), Some(AgentState::Working));
        record(&root, "claude-code", &ev("Stop", ""), 3000, &procs, 300);
        record(&root, "claude-code", &ev("Notification", r#","notification_type":"idle_prompt""#), 3060, &procs, 300);
        assert_eq!(state_of("claude-code", &load(&root, 3060, &procs), 0, 3060), Some((AgentState::Finished, 3000)), "idle_prompt keeps the real end time");
        record(&root, "claude-code", &ev("SessionEnd", ""), 3100, &procs, 300);
        assert!(load(&root, 3100, &procs).is_empty());
    }

    #[test]
    fn stuck_and_dead_sessions_are_ignored() {
        let root = tmp("stuck");
        let procs = vec![p(100, 1, "claude"), p(300, 100, "nocturnal")];
        record(&root, "claude-code", r#"{"session_id":"s","hook_event_name":"UserPromptSubmit"}"#, 1000, &procs, 300);
        let l = load(&root, 1000, &procs);
        assert_eq!(state_of("claude-code", &l, 1000, 1000 + STUCK_AFTER - 1).map(|s| s.0), Some(AgentState::Working));
        assert_eq!(state_of("claude-code", &l, 1000, 1000 + STUCK_AFTER + 1), None, "interrupted: unknown");
        // The agent process is gone (or the pid was reused): the session is dropped.
        let other = vec![Proc { start: 1, ..p(100, 1, "claude") }];
        assert!(load(&root, 1100, &other).is_empty());
        // Bad input and odd agent names do nothing.
        record(&root, "../x", r#"{"session_id":"s","hook_event_name":"Stop"}"#, 1, &procs, 300);
        record(&root, "claude-code", "not json", 1, &procs, 300);
        assert!(std::fs::read_dir(dir(&root)).unwrap().next().is_none());
    }

    #[test]
    fn hooks_are_added_next_to_others_and_removed_cleanly() {
        let mut s = Map::new();
        s.insert("model".into(), json!("opus"));
        s.insert(
            "hooks".into(),
            json!({ "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }] }),
        );
        let with = with_hooks(&s, "/usr/local/bin/nocturnal");
        assert!(hooks_installed(&with, "/usr/local/bin/nocturnal"));
        assert!(!hooks_installed(&with, "/elsewhere/nocturnal"));
        assert_eq!(with["hooks"]["Stop"].as_array().unwrap().len(), 2, "their own Stop hook kept");
        let again = with_hooks(&with, "/usr/local/bin/nocturnal");
        assert_eq!(again["hooks"]["Stop"].as_array().unwrap().len(), 2, "no duplicates");
        let (back, changed) = without_hooks(&again);
        assert!(changed);
        assert_eq!(Value::Object(back), Value::Object(s));
    }
}
