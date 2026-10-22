//! Agents: their own hook reports laid over the CPU guess, "finished" alerts, and the apps the person added.

use super::*;

impl<P: Platform> Engine<P> {
    /// What agents report through their own hooks (see events.rs), laid over the CPU guess: working keeps the
    /// computer awake however quiet the work is, a question waiting for an answer keeps it awake for a while (and
    /// says so on the phone), and a finished turn starts the quiet countdown even if a helper keeps ticking.
    pub(super) fn apply_agent_events(&mut self, now: u64) {
        self.agent_events = crate::events::load(&self.root, now, &self.procs);
        if self.agent_events.is_empty() {
            return;
        }
        let mut waits = vec![];
        for s in self.watcher.sessions.iter_mut() {
            let Some((st, at)) =
                crate::events::state_of(&s.kind.id, &self.agent_events, s.last_active, now)
            else {
                continue;
            };
            s.state = Some(st);
            s.state_since = Some(at);
            use crate::events::AgentState::*;
            match st {
                Working => s.last_active = now,
                Waiting => {
                    if now.saturating_sub(at) < crate::events::WAIT_LIMIT {
                        s.last_active = now;
                    }
                    let key = format!("{}@{at}", s.kind.id);
                    if self.announced_waits.insert(key) {
                        waits.push(s.kind.name.clone());
                    }
                }
                // A command it left running in the background still counts; otherwise the turn's end is the last work.
                Finished | Idle => {
                    if !s.tool_running {
                        s.last_active = at;
                    }
                }
            }
        }
        if self.announced_waits.len() > 50 {
            self.announced_waits.clear();
        }
        // Only worth a push while the person is away from the screen.
        if self.lid_closed || self.holding {
            for name in waits {
                self.outbox.push(Announcement {
                    title: format!("{name} is waiting for you"),
                    body: format!(
                        "It asked for your approval. It stays awake for up to {} min.",
                        crate::events::WAIT_LIMIT / 60
                    ),
                });
            }
        }
    }

    /// "Claude Code went idle": an agent that was busy for at least a minute has been quiet for 2 minutes.
    /// Nocturnal can't tell success from a crash or a question waiting for an answer, so it never says "finished".
    pub(super) fn detect_finished(&mut self, now: u64) {
        let mut current: HashMap<String, (u64, String)> = HashMap::new();
        let present: HashSet<String> = self
            .watcher
            .sessions
            .iter()
            .map(|s| s.kind.id.clone())
            .collect();
        for s in &self.watcher.sessions {
            if s.kind.is_claude_app() && !self.cfg.count_claude_app {
                continue;
            }
            if s.working(now) {
                // Busy again within the 2-minute wait: same stretch of work, no notification.
                let since = self
                    .working_since
                    .get(&s.kind.id)
                    .map(|x| x.0)
                    .or_else(|| self.idle_pending.remove(&s.kind.id).map(|p| p.0))
                    .unwrap_or(now);
                current.insert(s.kind.id.clone(), (since, s.kind.name.clone()));
            }
        }
        for (id, (since, name)) in self.working_since.iter() {
            if !current.contains_key(id) {
                self.idle_pending
                    .insert(id.clone(), (*since, name.clone(), now));
            }
        }
        self.working_since = current;
        let due: Vec<String> = self
            .idle_pending
            .iter()
            .filter(|(_, p)| now.saturating_sub(p.2) >= 120)
            .map(|(id, _)| id.clone())
            .collect();
        for id in due {
            let Some((since, name, idle_at)) = self.idle_pending.remove(&id) else {
                continue;
            };
            let minutes = idle_at.saturating_sub(since) as f64 / 60.0;
            if minutes < 1.0 || !self.cfg.notify_done {
                continue;
            }
            let state = self
                .watcher
                .sessions
                .iter()
                .find(|s| s.kind.id == id)
                .and_then(|s| s.state);
            let title = if present.contains(&id) {
                match state {
                    Some(crate::events::AgentState::Finished) => format!("{name} finished"),
                    _ => format!("{name} went idle"),
                }
            } else {
                format!("{name} closed")
            };
            let mut body = format!("Busy for {}", crate::format::minutes(minutes));
            if self.lid_closed {
                body.push_str(" with the lid closed");
            }
            if let Some(b) = &self.battery {
                body.push_str(&format!(" · battery {}%", b.percent));
            }
            self.outbox.push(Announcement { title, body });
        }
    }

    pub fn toggle_watch_key(&mut self, key: &str) {
        let name = self
            .watch_candidates()
            .into_iter()
            .find(|c| c.0 == key)
            .map(|c| c.1)
            .unwrap_or_else(|| key.to_string());
        self.toggle_watch(key, &name);
    }

    pub fn toggle_watch(&mut self, key: &str, name: &str) {
        let (key, name) = (exe_key(key), name.to_string());
        if key.is_empty() {
            return;
        }
        self.update(|c| {
            if c.watched_apps.iter().any(|w| w.id == key) {
                c.watched_apps.retain(|w| w.id != key);
            } else {
                c.watched_apps.push(crate::config::WatchedApp {
                    id: key.clone(),
                    name,
                });
            }
        });
    }

    pub(super) fn refresh_watch_offer(&mut self) {
        let running: HashSet<&str> = self
            .procs
            .iter()
            .filter(|p| p.mine)
            .map(|p| p.name.as_str())
            .collect();
        self.watch_offer
            .retain(|(k, _)| running.contains(k.as_str()));
        let agents: HashSet<String> = crate::agents::known()
            .into_iter()
            .flat_map(|k| k.executables)
            .collect();
        for (name, cpu) in &self.watcher.cpu_by_app {
            if self.watch_offer.len() >= 8 {
                break;
            }
            let key = exe_key(name);
            if *cpu < 1.0
                || agents.contains(&key)
                || SYSTEM_NEVER.contains(&key.as_str())
                || self.watch_offer.iter().any(|o| o.0 == key)
            {
                continue;
            }
            self.watch_offer.push((key, name.clone()));
        }
    }

    /// Apps that could be added to "keep awake while these run": the ones already added, then busy running
    /// apps that aren't agents or part of the system.
    pub fn watch_candidates(&self) -> Vec<(String, String, bool)> {
        let mut out: Vec<(String, String, bool)> = self
            .cfg
            .watched_apps
            .iter()
            .map(|w| (w.id.clone(), w.name.clone(), true))
            .collect();
        for (key, name) in &self.watch_offer {
            if !out.iter().any(|o| o.0 == *key) {
                out.push((key.clone(), name.clone(), false));
            }
        }
        out
    }

    pub fn toggle_track_only(&mut self, kind_id: &str) {
        let keeps = self.cfg.track_only.iter().any(|x| x == kind_id);
        self.set_keeps(kind_id, keeps);
    }

    /// Whether an agent's work keeps the machine awake (false = only tracked).
    pub fn set_keeps(&mut self, kind_id: &str, keeps: bool) {
        let id = kind_id.to_string();
        self.update(|c| {
            c.track_only.retain(|x| *x != id);
            if !keeps {
                c.track_only.push(id);
            }
        });
    }
}
