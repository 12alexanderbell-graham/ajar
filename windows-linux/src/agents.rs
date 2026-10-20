//! Finds running AI agents (and apps the person added) and decides whether each is actually working.
//!
//! Working = the whole process tree used more CPU than the agent's idle threshold since the last sample, or
//! the agent just wrote to its transcript folder. Same idea as the macOS app, which uses the kernel's energy
//! counters; Windows and Linux have no per-process energy counter, so CPU time is the signal here.

use crate::config::{exe_key, Config};
use crate::procs::Proc;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::SystemTime;

#[derive(Clone, Debug, PartialEq)]
pub struct Kind {
    pub id: String,
    pub name: String,
    pub executables: Vec<String>,
    /// Substrings of the command line that identify it when it runs under node, bun or python.
    pub hints: Vec<String>,
    /// Folders under the home folder that it writes transcripts to.
    pub transcripts: Vec<String>,
    /// CPU % of one core, whole tree, below which it counts as idle.
    pub idle_cpu: f64,
}

impl Kind {
    fn new(id: &str, name: &str, exes: &[&str], hints: &[&str], transcripts: &[&str], idle_cpu: f64) -> Kind {
        Kind {
            id: id.into(),
            name: name.into(),
            executables: exes.iter().map(|s| s.to_string()).collect(),
            hints: hints.iter().map(|s| s.to_string()).collect(),
            transcripts: transcripts.iter().map(|s| s.to_string()).collect(),
            idle_cpu,
        }
    }
    pub fn is_watched_app(&self) -> bool {
        self.id.starts_with("app:")
    }
    pub fn is_claude_app(&self) -> bool {
        self.id == "claude-app"
    }
}

pub fn known() -> Vec<Kind> {
    vec![
        Kind::new("claude-code", "Claude Code", &["claude"], &["@anthropic-ai/claude-code", "claude-code"], &[".claude/projects"], 1.0),
        Kind::new("codex", "Codex", &["codex"], &["@openai/codex"], &[".codex/sessions"], 1.0),
        Kind::new("gemini", "Gemini CLI", &["gemini"], &["@google/gemini-cli"], &[".gemini/tmp"], 1.0),
        Kind::new("cursor-agent", "Cursor Agent", &["cursor-agent"], &["cursor-agent"], &[], 1.0),
        Kind::new("opencode", "OpenCode", &["opencode"], &["opencode-ai"], &[], 1.0),
        Kind::new("aider", "Aider", &["aider"], &["aider-chat", "/bin/aider"], &[], 1.0),
        Kind::new("copilot", "Copilot CLI", &[], &["@github/copilot"], &[], 1.0),
        Kind::new("amp", "Amp", &[], &["@sourcegraph/amp"], &[], 1.0),
        Kind::new("goose", "Goose", &["goose"], &[], &[], 1.0),
        Kind::new("ollama", "Ollama", &["ollama", "ollama app"], &[], &[], 8.0),
    ]
}

fn claude_app() -> Kind {
    Kind::new("claude-app", "Claude app", &[], &[], &[], 4.0)
}

/// The Claude desktop app shares the `claude` executable name with Claude Code on Windows; its install path
/// tells them apart.
fn is_claude_desktop(p: &Proc) -> bool {
    let exe = p.exe.as_deref().unwrap_or("").to_lowercase().replace('\\', "/");
    exe.contains("/anthropicclaude/") || exe.contains("/claude-desktop") || exe.contains("/claude desktop/")
}

const INTERPRETERS: &[&str] = &["node", "bun", "deno", "python", "python3", "pythonw"];

pub fn is_interpreter(name: &str) -> bool {
    INTERPRETERS.contains(&name)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub kind: Kind,
    pub pid: u32,
    pub cpu: f64,
    pub last_active: u64,
    pub project: Option<String>,
    /// A command the agent started is still running (a build, a test run, a long download), even if it's
    /// using no CPU right now. Counts as working, for up to `TOOL_MAX_AGE`.
    pub tool_running: bool,
    /// How many separate instances of this agent are running.
    pub instances: usize,
}

/// A command started by an agent counts as work for at most this long (so a dev server left running in the
/// background doesn't keep the laptop awake forever).
pub const TOOL_MAX_AGE: u64 = 60 * 60;
/// Children started this soon after the agent itself are its own helpers (MCP servers, a shell), not commands.
pub const HELPER_WINDOW: u64 = 30;

impl Session {
    pub fn working(&self, now: u64) -> bool {
        self.last_active > 0 && now.saturating_sub(self.last_active) < 20
    }
}

#[derive(Default)]
pub struct Watcher {
    last_cpu: HashMap<u32, (u64, u64)>, // pid -> (start, cpu_ns)
    last_sample: Option<std::time::Instant>,
    transcript_mtime: HashMap<String, SystemTime>,
    last_active: HashMap<String, u64>, // kind id -> last busy time
    pub sessions: Vec<Session>,
    /// Agent trees, their ancestors, and everything holds depend on: never slowed or paused.
    pub protected: HashSet<u32>,
    /// CPU % of one core per executable over the last sample, for the energy list.
    pub cpu_by_app: Vec<(String, f64)>,
    /// Tests can fix the process clock; otherwise the OS clock is read each sample.
    pub clock: Option<(u64, u64)>,
}

impl Watcher {
    pub fn sample(&mut self, procs: &[Proc], cfg: &Config, now: u64) {
        let dt = self.last_sample.map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0);
        self.last_sample = Some(std::time::Instant::now());

        // CPU % per pid since the last sample (100 = one full core). A pid whose start time changed was reused.
        let mut cpu: HashMap<u32, f64> = HashMap::new();
        let mut next_cpu = HashMap::new();
        for p in procs {
            if let (Some((start, prev)), true) = (self.last_cpu.get(&p.pid), dt > 0.2) {
                if *start == p.start && p.cpu_ns >= *prev {
                    cpu.insert(p.pid, (p.cpu_ns - prev) as f64 / 1e9 / dt * 100.0);
                }
            }
            next_cpu.insert(p.pid, (p.start, p.cpu_ns));
        }
        self.last_cpu = next_cpu;

        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        let mut parent: HashMap<u32, u32> = HashMap::new();
        for p in procs {
            if p.ppid != p.pid {
                children.entry(p.ppid).or_default().push(p.pid);
                parent.insert(p.pid, p.ppid);
            }
        }
        let tree = |root: u32| -> Vec<u32> {
            let mut out = vec![];
            let mut stack = vec![root];
            let mut seen = HashSet::new();
            while let Some(p) = stack.pop() {
                if !seen.insert(p) {
                    continue;
                }
                out.push(p);
                if let Some(c) = children.get(&p) {
                    stack.extend(c);
                }
            }
            out
        };

        // Which kind each process is.
        let mut kinds = known();
        for c in &cfg.custom_agents {
            kinds.push(Kind {
                id: format!("custom:{}", c.name),
                name: c.name.clone(),
                executables: c.executables.clone(),
                hints: vec![],
                transcripts: vec![],
                idle_cpu: c.idle_cpu.unwrap_or(1.0),
            });
        }
        for w in &cfg.watched_apps {
            kinds.push(Kind { id: format!("app:{}", w.id), name: w.name.clone(), executables: vec![w.id.clone()], hints: vec![], transcripts: vec![], idle_cpu: 2.0 });
        }
        let mut found: Vec<(u32, Kind)> = vec![];
        for p in procs.iter().filter(|p| p.mine) {
            let k = if is_claude_desktop(p) {
                if cfg.count_claude_app { Some(claude_app()) } else { None }
            } else if let Some(k) = kinds.iter().find(|k| k.executables.contains(&p.name)) {
                Some(k.clone())
            } else if INTERPRETERS.contains(&p.name.as_str()) {
                let args = p.cmd.iter().take(4).cloned().collect::<Vec<_>>().join(" ");
                kinds.iter().find(|k| k.hints.iter().any(|h| args.contains(h.as_str()))).cloned()
            } else {
                None
            };
            if let Some(k) = k {
                found.push((p.pid, k));
            }
        }
        // Roots only: drop a process whose ancestor is the same kind (an agent and its own helpers count once).
        let kind_of: HashMap<u32, String> = found.iter().map(|(p, k)| (*p, k.id.clone())).collect();
        let roots: Vec<(u32, Kind)> = found
            .into_iter()
            .filter(|(pid, k)| {
                let mut cur = parent.get(pid).copied();
                let mut hops = 0;
                while let Some(c) = cur {
                    // `c == *pid`: a corrupt snapshot where a process is its own ancestor.
                    if c <= 1 || c == *pid || hops > 64 {
                        break;
                    }
                    if kind_of.get(&c) == Some(&k.id) {
                        return false;
                    }
                    cur = parent.get(&c).copied();
                    hops += 1;
                }
                true
            })
            .collect();

        let home = crate::state::home();
        let clock = self.clock.or_else(crate::procs::start_clock);
        let by_pid: HashMap<u32, &Proc> = procs.iter().map(|p| (p.pid, p)).collect();
        let mut protect = HashSet::new();
        let mut merged: Vec<Session> = vec![];
        for (root, kind) in roots {
            let members = tree(root);
            protect.extend(members.iter().copied());
            let mut cur = parent.get(&root).copied();
            let mut hops = 0;
            while let Some(c) = cur {
                if c <= 1 || hops > 64 {
                    break;
                }
                protect.insert(c);
                cur = parent.get(&c).copied();
                hops += 1;
            }
            let tree_cpu: f64 = members.iter().filter_map(|m| cpu.get(m)).sum();
            let fresh = self.transcripts_changed(&home, &kind);
            let tool_running = match (clock, by_pid.get(&root)) {
                (Some(c), Some(r)) => members.iter().filter(|m| **m != root).filter_map(|m| by_pid.get(m)).any(|p| {
                    let started_after = crate::procs::age_secs(r.start, c).zip(crate::procs::age_secs(p.start, c)).map(|(ra, pa)| ra.saturating_sub(pa));
                    let age = crate::procs::age_secs(p.start, c);
                    started_after.is_some_and(|d| d > HELPER_WINDOW) && age.is_some_and(|a| a < TOOL_MAX_AGE) && kind_of.get(&p.pid) != Some(&kind.id)
                }),
                _ => false,
            };
            if tree_cpu > kind.idle_cpu || fresh || tool_running {
                self.last_active.insert(kind.id.clone(), now);
            }
            let last_active = self.last_active.get(&kind.id).copied().unwrap_or(0);
            if let Some(s) = merged.iter_mut().find(|s| s.kind.id == kind.id) {
                s.cpu += tree_cpu;
                s.tool_running |= tool_running;
                s.instances += 1;
            } else {
                merged.push(Session { project: crate::procs::cwd_name(root), kind, pid: root, cpu: tree_cpu, last_active, tool_running, instances: 1 });
            }
        }
        merged.sort_by_key(|s| std::cmp::Reverse(s.last_active));
        self.sessions = merged;
        self.protected = protect;

        // Energy list: CPU per executable among the person's own processes.
        let mut by_app: HashMap<String, f64> = HashMap::new();
        for p in procs.iter().filter(|p| p.mine) {
            if let Some(c) = cpu.get(&p.pid) {
                *by_app.entry(p.name.clone()).or_default() += c;
            }
        }
        let mut v: Vec<(String, f64)> = by_app.into_iter().filter(|(_, c)| *c >= 0.05).collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        v.truncate(40);
        self.cpu_by_app = v;
    }

    fn transcripts_changed(&mut self, home: &Path, kind: &Kind) -> bool {
        let mut changed = false;
        for dir in &kind.transcripts {
            let newest = newest_mtime(&home.join(dir), 5);
            if let Some(n) = newest {
                if let Some(old) = self.transcript_mtime.get(dir) {
                    if n > *old {
                        changed = true;
                    }
                }
                self.transcript_mtime.insert(dir.clone(), n);
            }
        }
        changed
    }
}

/// Newest modification time a few levels down. Every folder is opened: appending to a file doesn't change its
/// folder's time, so skipping "old" folders would miss a long session writing to an old project folder. The
/// walk is capped at 20 000 entries (a few milliseconds of stat calls).
pub fn newest_mtime(path: &Path, depth: u32) -> Option<SystemTime> {
    let mut budget = 20_000usize;
    walk_newest(path, depth, &mut budget)
}

fn walk_newest(path: &Path, depth: u32, budget: &mut usize) -> Option<SystemTime> {
    let entries = std::fs::read_dir(path).ok()?;
    let mut newest: Option<SystemTime> = None;
    for e in entries.flatten() {
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        if e.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        // Don't follow symlinks: a link back up the tree must not loop.
        let Ok(ft) = e.file_type() else { continue };
        let Ok(meta) = e.metadata() else { continue };
        let Ok(m) = meta.modified() else { continue };
        if newest.is_none_or(|n| m > n) {
            newest = Some(m);
        }
        if depth > 1 && ft.is_dir() {
            if let Some(inner) = walk_newest(&e.path(), depth - 1, budget) {
                if newest.is_none_or(|n| inner > n) {
                    newest = Some(inner);
                }
            }
        }
    }
    newest
}

/// Executable key helper re-exported for callers matching apps by name.
pub fn key(name: &str) -> String {
    exe_key(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: u32, ppid: u32, name: &str, cpu_ns: u64) -> Proc {
        Proc { pid, ppid, name: name.into(), cpu_ns, start: 1, mine: true, ..Default::default() }
    }

    #[test]
    fn agent_and_its_helpers_count_once_and_ancestors_are_protected() {
        let mut w = Watcher::default();
        let cfg = Config::default();
        let procs = vec![p(10, 1, "terminal", 0), p(20, 10, "zsh", 0), p(30, 20, "claude", 0), p(31, 30, "claude", 0), p(32, 30, "rg", 0)];
        w.sample(&procs, &cfg, 1000);
        assert_eq!(w.sessions.len(), 1);
        assert_eq!(w.sessions[0].kind.id, "claude-code");
        for pid in [10, 20, 30, 31, 32] {
            assert!(w.protected.contains(&pid), "pid {pid} should be protected");
        }
    }

    #[test]
    fn node_scripts_are_recognised_by_command_line() {
        let mut w = Watcher::default();
        let mut node = p(40, 1, "node", 0);
        node.cmd = vec!["node".into(), "/usr/lib/node_modules/@openai/codex/bin/codex.js".into()];
        w.sample(&[node], &Config::default(), 1000);
        assert_eq!(w.sessions.first().map(|s| s.kind.id.as_str()), Some("codex"));
    }

    #[test]
    fn busy_needs_cpu_above_threshold_and_pid_reuse_is_ignored() {
        let mut w = Watcher::default();
        let cfg = Config::default();
        w.sample(&[p(50, 1, "codex", 0)], &cfg, 1000);
        std::thread::sleep(std::time::Duration::from_millis(300));
        // 0.3 s of CPU in ~0.3 s ≈ 100% of a core: working.
        w.sample(&[p(50, 1, "codex", 300_000_000)], &cfg, 1001);
        assert!(w.sessions[0].working(1001));
        // Same pid, different start time (reused): no delta, so no false activity.
        let mut reused = p(50, 1, "codex", 900_000_000);
        reused.start = 2;
        w.last_active.clear();
        std::thread::sleep(std::time::Duration::from_millis(300));
        w.sample(&[reused], &cfg, 1100);
        assert!(!w.sessions[0].working(1100));
    }

    #[test]
    fn other_users_processes_are_ignored() {
        let mut w = Watcher::default();
        let mut other = p(60, 1, "claude", 0);
        other.mine = false;
        w.sample(&[other], &Config::default(), 1000);
        assert!(w.sessions.is_empty());
    }

    #[test]
    fn claude_desktop_is_not_mistaken_for_claude_code() {
        let mut w = Watcher::default();
        let mut app = p(70, 1, "claude", 0);
        app.exe = Some(r"C:\Users\a\AppData\Local\AnthropicClaude\app-1.0\claude.exe".into());
        w.sample(&[app.clone()], &Config::default(), 1000);
        assert_eq!(w.sessions[0].kind.id, "claude-app");
        let cfg = Config { count_claude_app: false, ..Default::default() };
        let mut w2 = Watcher::default();
        w2.sample(&[app], &cfg, 1000);
        assert!(w2.sessions.is_empty());
    }

    #[test]
    fn parent_cycles_do_not_hang() {
        let mut w = Watcher::default();
        // Corrupt snapshot: 80 and 81 claim each other as parents.
        w.sample(&[p(80, 81, "claude", 0), p(81, 80, "zsh", 0)], &Config::default(), 1000);
        assert_eq!(w.sessions.len(), 1);
    }

    #[test]
    fn a_running_command_counts_as_work_but_helpers_and_old_servers_do_not() {
        // Clock: now = 10 000 s, 1 unit per second. Agent started at 1000.
        let mk = |pid, ppid, name: &str, start| Proc { pid, ppid, name: name.to_string(), start, mine: true, ..Default::default() };
        let cfg = Config::default();
        let mut w = Watcher { clock: Some((10_000, 1)), ..Default::default() };
        // An MCP server started 5 s after the agent: a helper, not work.
        w.sample(&[mk(10, 1, "claude", 1000), mk(11, 10, "node", 1005)], &cfg, 50);
        assert!(!w.sessions[0].tool_running);
        // `npm test` started 5 minutes ago: work, even at 0% CPU.
        w.sample(&[mk(10, 1, "claude", 1000), mk(11, 10, "node", 1005), mk(12, 10, "npm", 9_700)], &cfg, 60);
        assert!(w.sessions[0].tool_running && w.sessions[0].working(60));
        // A dev server started 2 hours ago: no longer counts.
        let mut w2 = Watcher { clock: Some((10_000, 1)), ..Default::default() };
        w2.sample(&[mk(10, 1, "claude", 1000), mk(13, 10, "vite", 2_000)], &cfg, 70);
        assert!(!w2.sessions[0].tool_running);
    }

    /// Windows can only open a folder (to set its time) with backup semantics and write access.
    fn set_dir_mtime(dir: &std::path::Path, t: SystemTime) {
        #[cfg(windows)]
        let f = {
            use std::os::windows::fs::OpenOptionsExt;
            std::fs::File::options().write(true).custom_flags(0x0200_0000).open(dir).unwrap()
        };
        #[cfg(not(windows))]
        let f = std::fs::File::open(dir).unwrap();
        f.set_modified(t).unwrap();
    }

    #[test]
    fn appends_inside_old_folders_are_seen() {
        let root = std::env::temp_dir().join(format!("ajar-transcripts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let proj = root.join("old-project");
        std::fs::create_dir_all(&proj).unwrap();
        let f = proj.join("session.jsonl");
        std::fs::write(&f, "{}\n").unwrap();
        let old = SystemTime::now() - std::time::Duration::from_secs(48 * 3600);
        std::fs::File::options().write(true).open(&f).unwrap().set_modified(old).unwrap();
        set_dir_mtime(&proj, old);
        let before = newest_mtime(&root, 3).unwrap();
        // Append to the file: the folder's own time doesn't change.
        use std::io::Write;
        std::fs::File::options().append(true).open(&f).unwrap().write_all(b"{}\n").unwrap();
        set_dir_mtime(&proj, old);
        let after = newest_mtime(&root, 3).unwrap();
        assert!(after > before, "append in a 2-day-old folder must be noticed");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn two_instances_are_counted() {
        let mut w = Watcher::default();
        w.sample(&[p(90, 1, "codex", 0), p(91, 1, "codex", 0)], &Config::default(), 1000);
        assert_eq!(w.sessions.len(), 1);
        assert_eq!(w.sessions[0].instances, 2);
    }
}
