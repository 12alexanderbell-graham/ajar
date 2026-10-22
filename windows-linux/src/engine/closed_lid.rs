//! With the lid closed: what changes (power profile, other apps slowed or paused, journaled first) and putting it back.

use super::*;

impl<P: Platform> Engine<P> {
    pub(super) fn lid_changed(&mut self, closed: bool, now: u64) {
        self.lid_closed = closed;
        if closed && !self.holding {
            // The OS may sleep any moment now: have the check-in wake pending before it does.
            self.arm_before_sleep(now);
        }
        if closed {
            if self.holding {
                self.enter_closed(now);
            } else if !self.platform.sleeps_on_close_itself() {
                // The desktop leaves lid-close sleep to Nocturnal (see Platform::sleeps_on_close_itself).
                self.arm_before_sleep(now);
                self.platform.sleep_now();
            }
        } else {
            self.snoozed = false;
            self.restore_closed_state();
            if let Some(mut r) = self.receipt.take() {
                if r.opened_at.is_none() {
                    r.opened_at = Some(now);
                    if r.end_percent.is_none() {
                        r.end_percent = self.battery.as_ref().map(|b| b.percent);
                    }
                    self.finish_session(&r, now);
                    self.outbox.push(Announcement {
                        title: "While the lid was closed".into(),
                        body: receipt_line(&r),
                    });
                }
                self.receipt = Some(r);
            }
        }
    }

    pub(super) fn enter_closed(&mut self, now: u64) {
        self.receipt = Some(Receipt {
            closed_at: now,
            opened_at: None,
            sleep_requested_at: None,
            slept_at: None,
            start_percent: self.battery.as_ref().map(|b| b.percent),
            end_percent: None,
            agent: self
                .holds
                .last()
                .map(|h| h.reason.clone())
                .or_else(|| self.active_agent(now).map(|s| s.kind.name.clone())),
        });
        self.platform.screen_off(true);
        self.reapply_closed_state(None);
    }

    pub(super) fn reapply_closed_state(&mut self, forcing: Option<Preset>) {
        let p = forcing.unwrap_or(self.cfg.preset);
        if p != Preset::Speed && self.cfg.low_power_while_closed {
            self.platform.set_low_power(true, &mut self.restore);
        } else {
            self.platform.set_low_power(false, &mut self.restore);
        }
        self.save_restore();
        // Only undo what the new rules change: an app that stays paused isn't woken and frozen again.
        let protected = self.protected_pids();
        let keep = |t: &Touched| -> bool {
            if protected.contains(&t.pid) {
                return false;
            }
            match self.cfg.rule_for(&t.exe, p) {
                AppRule::Pause => t.paused,
                AppRule::Slow => !t.paused,
                AppRule::Leave => false,
            }
        };
        let (stay, undo): (Vec<Touched>, Vec<Touched>) = std::mem::take(&mut self.touched)
            .into_iter()
            .partition(|t| keep(t));
        let failed = undo_touched(&mut self.platform, undo, &self.procs);
        self.touched = stay.into_iter().chain(failed).collect();
        self.save_touched();
        self.apply_rules(Some(p));
    }

    pub(super) fn restore_closed_state(&mut self) {
        if !self.lid_closed {
            self.platform.screen_off(false);
        }
        self.restore_apps();
        self.platform.set_low_power(false, &mut self.restore);
        self.save_restore();
    }

    pub(super) fn save_restore(&self) {
        if self.restore == Restore::default() {
            state::remove(&self.path("restore.json"));
        } else {
            state::save_json(&self.path("restore.json"), &self.restore);
        }
    }

    pub(super) fn apply_rules(&mut self, preset: Option<Preset>) {
        let preset = preset.unwrap_or(if self.heat_forced {
            Preset::Longest
        } else {
            self.cfg.preset
        });
        let me = std::process::id();
        let protected = self.protected_pids();
        let targets: Vec<(u32, String, u64, AppRule)> = self
            .procs
            .iter()
            .filter(|p| p.mine && p.pid != me && !protected.contains(&p.pid))
            .filter(|p| {
                !self
                    .touched
                    .iter()
                    .any(|t| t.pid == p.pid && t.start == p.start)
            })
            .map(|p| {
                (
                    p.pid,
                    p.name.clone(),
                    p.start,
                    self.cfg.rule_for(&p.name, preset),
                )
            })
            .filter(|(_, name, _, r)| {
                *r != AppRule::Leave && !SYSTEM_NEVER.contains(&name.as_str())
            })
            .collect();
        if targets.is_empty() {
            return;
        }
        for (pid, name, start, rule) in targets {
            if rule == AppRule::Leave {
                continue;
            }
            // Journal first and only act if it's safely on disk, so a crash at any point leaves a record of
            // every app Nocturnal changed (the watchdog and the next start undo it).
            let paused = rule == AppRule::Pause;
            self.touched.push(Touched {
                pid,
                exe: name,
                start,
                paused,
                previous: state::PREVIOUS_UNKNOWN,
                unit: None,
            });
            if !self.save_touched() {
                self.touched.pop();
                continue;
            }
            let ok = if paused {
                self.platform.pause(pid, start, true)
            } else if let Some((prev, unit)) = self.platform.slow(pid, start, &protected) {
                if let Some(t) = self.touched.last_mut() {
                    t.previous = prev;
                    t.unit = unit;
                }
                true
            } else {
                false
            };
            if !ok {
                self.touched.pop();
            }
        }
        self.save_touched();
    }

    pub(super) fn restore_apps(&mut self) {
        let touched = std::mem::take(&mut self.touched);
        self.touched = undo_touched(&mut self.platform, touched, &self.procs);
        self.save_touched();
    }

    /// Apps Nocturnal changed and hasn't managed to put back yet (shown in the menu and `nocturnal doctor`).
    pub fn unrestored(&self) -> Vec<String> {
        if self.lid_closed && self.holding {
            return vec![];
        }
        self.touched
            .iter()
            .map(|t| {
                format!(
                    "{} (pid {}, {})",
                    t.exe,
                    t.pid,
                    if t.paused { "paused" } else { "slowed" }
                )
            })
            .collect()
    }

    pub(super) fn save_touched(&self) -> bool {
        if self.touched.is_empty() {
            state::remove(&self.path("touched.json"));
            true
        } else {
            state::save_json(&self.path("touched.json"), &self.touched)
        }
    }

    /// Agents, their trees and ancestors (from the watcher), plus anything a hold is tied to, its children
    /// and the apps above it.
    pub(super) fn protected_pids(&self) -> std::collections::HashSet<u32> {
        let mut protect = self.watcher.protected.clone();
        let hold_pids: Vec<u32> = self.holds.iter().filter_map(|h| h.pid).collect();
        if hold_pids.is_empty() {
            return protect;
        }
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        let mut parent: HashMap<u32, u32> = HashMap::new();
        for p in &self.procs {
            children.entry(p.ppid).or_default().push(p.pid);
            parent.insert(p.pid, p.ppid);
        }
        for root in hold_pids {
            let mut stack = vec![root];
            while let Some(p) = stack.pop() {
                if protect.insert(p) {
                    if let Some(c) = children.get(&p) {
                        stack.extend(c);
                    }
                }
            }
            let mut up = parent.get(&root).copied();
            let mut hops = 0;
            while let Some(c) = up {
                if c <= 1 || hops > 64 {
                    break;
                }
                protect.insert(c);
                up = parent.get(&c).copied();
                hops += 1;
            }
        }
        protect
    }
}
