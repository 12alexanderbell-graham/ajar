//! The decision-maker. Platform-free: it reads the platform through the `Platform` trait and gets process
//! snapshots passed in, so every rule here is covered by tests with a mock platform and fake processes.
//!
//! One `tick` (every ~2 s from the app):
//!  1. read lid and battery; react to the lid opening or closing
//!  2. sample agents (CPU per process tree + transcript writes)
//!  3. decide: should the machine be held awake, and if not, why not
//!  4. start or end the hold; while closed, apply power rules to other apps; heartbeat for the watchdog

use crate::agents::{Session, Watcher};
use crate::config::{exe_key, AppRule, Config, Mode, Preset};
use crate::platform::{Battery, Platform, Thermal};
use crate::procs::{self, Proc};
use crate::state::{self, Restore, Touched};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Hold {
    pub id: String,
    pub reason: String,
    pub until: Option<u64>,
    pub pid: Option<u32>,
    /// Start time of `pid` when the hold was made; the hold ends if the pid is gone or now belongs to
    /// a different process (pid reuse after a restart or a long run).
    pub pid_start: Option<u64>,
    pub created: u64,
}

impl Hold {
    pub fn alive(&self, now: u64) -> bool {
        if let Some(u) = self.until {
            if now > u {
                return false;
            }
        }
        if let Some(pid) = self.pid {
            return procs::start_time(pid).is_some() && procs::start_time(pid) == self.pid_start;
        }
        true
    }
}

/// Holds survive a restart. (The Always timer lives in config.json next to the mode it belongs to.)
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct Runtime {
    holds: Vec<Hold>,
}

/// The person's safety settings as last set from the menu. A settings-file edit (by hand, a script or an
/// agent) can make these stricter but not weaker; weakening needs the menu. This raises the bar against
/// accidental or agent-driven edits; it can't stop a program determined to defeat it, since anything running
/// as the same user could also edit this file or stop Ajar.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
struct Safety {
    heat_guard: bool,
    battery_floor: u32,
    #[serde(default)]
    only_on_power: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SessionRecord {
    pub date: u64,
    pub closed_minutes: f64,
    pub start_percent: Option<u32>,
    pub end_percent: Option<u32>,
    pub agent: Option<String>,
    pub slept: bool,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Stats {
    pub sessions: Vec<SessionRecord>,
}

#[derive(Clone, Debug)]
pub struct Receipt {
    pub closed_at: u64,
    pub opened_at: Option<u64>,
    /// When Ajar asked the machine to sleep.
    pub sleep_requested_at: Option<u64>,
    /// Set only once a sleep actually happened (seen as a gap in Ajar's own ticks), never on request alone.
    pub slept_at: Option<u64>,
    pub start_percent: Option<u32>,
    pub end_percent: Option<u32>,
    pub agent: Option<String>,
}

/// Something worth telling the person (shown as a notification and optionally pushed to a phone).
#[derive(Clone, Debug, PartialEq)]
pub struct Announcement {
    pub title: String,
    pub body: String,
}

pub struct Engine<P: Platform> {
    pub platform: P,
    pub cfg: Config,
    root: PathBuf,
    pub watcher: Watcher,
    pub procs: Vec<Proc>,
    pub holds: Vec<Hold>,
    pub holding: bool,
    pub hold_reason: Option<String>,
    pub blocked: Option<String>,
    pub setup_error: Option<String>,
    pub lid_warning: Option<String>,
    pub lid_closed: bool,
    pub has_lid: bool,
    pub battery: Option<Battery>,
    pub thermal: Thermal,
    floor_latched: bool,
    pub floor_override: bool,
    heat_forced: bool,
    /// When it got hot (serious or worse) with the lid shut.
    hot_since: Option<u64>,
    pending_release: bool,
    touched: Vec<Touched>,
    restore: Restore,
    pub stats: Stats,
    pub receipt: Option<Receipt>,
    working_since: HashMap<String, (u64, String)>,
    /// Agents that stopped being busy: (busy since, name, idle since). Announced only if still idle 2 min later.
    idle_pending: HashMap<String, (u64, String, u64)>,
    /// Last time a counted agent was busy / was running at all. The quiet countdown runs from these, so it
    /// survives the agent's process exiting.
    pub last_work: Option<(u64, String)>,
    pub last_seen: Option<(u64, String)>,
    last_tick_at: u64,
    /// How many wakes from sleep (gaps in the ticks) this run has seen; the app reconnects phone control on one.
    wakes: u64,
    /// A check-in wake is keeping the machine up until then (Unix seconds) to read the phone's commands.
    checkin_until: Option<u64>,
    /// When the OS wake timer was last armed (None = not armed).
    wake_armed_at: Option<u64>,
    sleep_retries: u32,
    pub hold_warning: Option<String>,
    pub watchdog_warning: Option<String>,
    watchdog_repair_tried: bool,
    /// Busy apps offered in "Also while these run": refreshed once a minute and kept in a stable order, so the
    /// menu doesn't rebuild (and close under the pointer) every time CPU use shifts.
    watch_offer: Vec<(String, String)>,
    /// "Sleep now" from the phone or menu: agents don't keep it awake until the lid next opens.
    pub snoozed: bool,
    /// Phone control status for the menu (set by the app's relay thread).
    pub remote_status: Option<String>,
    /// Learned draw with the lid open and closed (watts), smoothed.
    pub open_draw: Option<f64>,
    pub closed_draw: Option<f64>,
    pub outbox: Vec<Announcement>,
    ticks: u64,
    config_mtime: Option<std::time::SystemTime>,
}

pub const DEFAULT_FULL_WH: f64 = 55.0;
pub const DEFAULT_CLOSED_W: f64 = 3.0;

impl<P: Platform> Engine<P> {
    /// `root` is Ajar's folder (tests pass a temporary one).
    pub fn new(platform: P, root: PathBuf, procs_now: Vec<Proc>) -> Self {
        state::ensure_private_dir(&root);
        let text = state::read(&root.join("config.json"));
        let parsed = text.as_deref().and_then(Config::parse);
        let mut corrupt_note = None;
        if text.is_some() && parsed.is_none() {
            // Keep the broken file for the person instead of silently overwriting it with defaults.
            let backup = root.join(format!("config.broken-{}.json", crate::now()));
            let _ = std::fs::copy(root.join("config.json"), &backup);
            corrupt_note = Some(Announcement {
                title: "Settings file couldn't be read".into(),
                body: format!(
                    "Ajar is using its defaults. Your file was saved as {}",
                    backup
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default()
                ),
            });
        }
        let cfg = parsed.unwrap_or_default();
        let mut e = Engine {
            platform,
            cfg,
            root,
            watcher: Watcher::default(),
            procs: procs_now,
            holds: vec![],
            holding: false,
            hold_reason: None,
            blocked: None,
            setup_error: None,
            lid_warning: None,
            lid_closed: false,
            has_lid: false,
            battery: None,
            thermal: Thermal::Unknown,
            floor_latched: false,
            floor_override: false,
            heat_forced: false,
            hot_since: None,
            pending_release: false,
            touched: vec![],
            restore: Restore::default(),
            stats: Stats::default(),
            receipt: None,
            working_since: HashMap::new(),
            idle_pending: HashMap::new(),
            last_work: None,
            last_seen: None,
            last_tick_at: 0,
            wakes: 0,
            checkin_until: None,
            wake_armed_at: None,
            sleep_retries: 0,
            hold_warning: None,
            watchdog_warning: None,
            watchdog_repair_tried: false,
            snoozed: false,
            remote_status: None,
            watch_offer: vec![],
            open_draw: None,
            closed_draw: None,
            outbox: vec![],
            ticks: 0,
            config_mtime: None,
        };
        if let Some(n) = corrupt_note {
            e.outbox.push(n);
            e.save_config();
        }
        if !e.root.join("config.json").exists() {
            e.save_config();
        }
        e.enforce_safety_floor();
        e.stats = state::load_json(&e.root.join("stats.json")).unwrap_or_default();
        let learned: Option<(Option<f64>, Option<f64>)> =
            state::load_json(&e.root.join("learned.json"));
        if let Some((o, c)) = learned {
            e.open_draw = o.filter(|w| w.is_finite() && *w > 0.0 && *w < 200.0);
            e.closed_draw = c.filter(|w| w.is_finite() && *w > 0.0 && *w < 200.0);
        }
        e.recover_from_crash();
        e.restore_runtime(crate::now());
        e.has_lid = e.platform.has_lid();
        e.lid_closed = e.has_lid && e.platform.lid_closed();
        e.battery = e.platform.battery();
        e
    }

    pub fn ticks(&self) -> u64 {
        self.ticks
    }

    pub fn wakes(&self) -> u64 {
        self.wakes
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    // MARK: settings

    pub fn update(&mut self, change: impl FnOnce(&mut Config)) {
        let old = self.cfg.clone();
        change(&mut self.cfg);
        if self.cfg == old {
            return;
        }
        if old.mode != self.cfg.mode && self.cfg.mode != Mode::On {
            self.cfg.always_until = None;
            self.cfg.mode_before_always = None;
        }
        self.save_config();
        if old.heat_guard != self.cfg.heat_guard
            || old.battery_floor != self.cfg.battery_floor
            || old.only_on_power != self.cfg.only_on_power
        {
            self.save_safety();
        }
        if old.open_at_login != self.cfg.open_at_login {
            let _ = self.platform.set_open_at_login(self.cfg.open_at_login);
        }
        if (old.preset != self.cfg.preset
            || old.app_rules != self.cfg.app_rules
            || old.low_power_while_closed != self.cfg.low_power_while_closed)
            && self.lid_closed
            && self.holding
        {
            self.reapply_closed_state(None);
        }
        self.evaluate(crate::now());
    }

    fn save_safety(&self) {
        state::save_json(
            &self.path("safety.json"),
            &Safety {
                heat_guard: self.cfg.heat_guard,
                battery_floor: self.cfg.battery_floor,
                only_on_power: self.cfg.only_on_power,
            },
        );
    }

    /// Undo any weakening of the safety settings that didn't come from the menu (see `Safety`).
    fn enforce_safety_floor(&mut self) {
        let Some(s) = state::load_json::<Safety>(&self.path("safety.json")) else {
            self.save_safety();
            return;
        };
        let mut undone = vec![];
        if s.heat_guard && !self.cfg.heat_guard {
            self.cfg.heat_guard = true;
            undone.push("the heat guard stays on".to_string());
        }
        if self.cfg.battery_floor < s.battery_floor {
            self.cfg.battery_floor = s.battery_floor;
            undone.push(format!("the battery limit stays at {}%", s.battery_floor));
        }
        if s.only_on_power && !self.cfg.only_on_power {
            self.cfg.only_on_power = true;
            undone.push("it still only stays awake on power".to_string());
        }
        if undone.is_empty() {
            if self.cfg.heat_guard != s.heat_guard
                || self.cfg.battery_floor != s.battery_floor
                || self.cfg.only_on_power != s.only_on_power
            {
                self.save_safety(); // stricter edits are accepted and become the new baseline
            }
            return;
        }
        self.save_config();
        self.outbox.push(Announcement {
            title: "Settings file change ignored".into(),
            body: format!(
                "Safety settings can only be loosened from the Ajar menu: {}.",
                undone.join(" and ")
            ),
        });
    }

    pub fn on_until(&self) -> Option<u64> {
        if self.cfg.mode == Mode::On {
            self.cfg.always_until
        } else {
            None
        }
    }

    fn save_config(&mut self) {
        let _ = state::write_atomic(&self.path("config.json"), &self.cfg.to_json());
        self.config_mtime = std::fs::metadata(self.path("config.json"))
            .and_then(|m| m.modified())
            .ok();
    }

    /// Picks up edits to config.json made by hand, a script or Claude.
    fn reload_config_if_edited(&mut self) {
        let m = std::fs::metadata(self.path("config.json"))
            .and_then(|m| m.modified())
            .ok();
        if m.is_some() && m != self.config_mtime {
            self.config_mtime = m;
            if let Some(c) = state::read(&self.path("config.json")).and_then(|t| Config::parse(&t))
            {
                if c != self.cfg {
                    let closed_rules_changed =
                        c.preset != self.cfg.preset || c.app_rules != self.cfg.app_rules;
                    self.cfg = c;
                    self.enforce_safety_floor();
                    if closed_rules_changed && self.lid_closed && self.holding {
                        self.reapply_closed_state(None);
                    }
                }
            }
        }
    }

    // MARK: runtime persistence

    fn save_runtime(&self) {
        state::save_json(
            &self.path("runtime.json"),
            &Runtime {
                holds: self.holds.clone(),
            },
        );
    }

    fn restore_runtime(&mut self, now: u64) {
        let Some(r) = state::load_json::<Runtime>(&self.path("runtime.json")) else {
            return;
        };
        self.holds = r.holds.into_iter().filter(|h| h.alive(now)).collect();
    }

    // MARK: crash recovery

    /// If a previous run died while holding or with apps slowed, undo what it left behind first.
    fn recover_from_crash(&mut self) {
        let touched: Vec<Touched> =
            state::load_json(&self.path("touched.json")).unwrap_or_default();
        // Anything that couldn't be put back stays in the journal and is retried every tick.
        self.touched = undo_touched(&mut self.platform, touched, &[]);
        self.save_touched();
        let mut r: Restore = state::load_json(&self.path("restore.json")).unwrap_or_default();
        if r != Restore::default() {
            self.platform.restore_settings(&mut r);
        }
        self.restore = r;
        self.save_restore();
        state::remove(&self.path("hold"));
    }

    // MARK: the loop

    pub fn tick(&mut self, now: u64, procs_now: Option<Vec<Proc>>) {
        self.ticks += 1;
        // A long gap between ticks means the machine was asleep: that confirms a sleep Ajar asked for.
        let gap = self.last_tick_at > 0 && now.saturating_sub(self.last_tick_at) > 45;
        self.last_tick_at = now;
        if gap {
            // Woke from sleep: a "sleep now" has done its job (covers waking from the keyboard or no lid).
            self.snoozed = false;
            self.wakes += 1;
        }
        if let Some(r) = &mut self.receipt {
            if let (Some(asked), None) = (r.sleep_requested_at, r.slept_at) {
                if gap {
                    r.slept_at = Some(asked);
                    self.sleep_retries = 0;
                } else if self.lid_closed
                    && !self.holding
                    && self.platform.sleep_after_hold()
                    && now.saturating_sub(asked) >= 60 * (self.sleep_retries as u64 + 1)
                    && self.sleep_retries < 3
                {
                    // Asked to sleep a minute ago, lid still shut, still running: ask again (up to 3 times).
                    self.sleep_retries += 1;
                    self.platform.sleep_now();
                }
            }
        }
        // Battery before the lid, so a lid-open receipt reports the battery as it is now.
        if let Some(b) = self.platform.battery() {
            self.learn_draw(&b);
            if b.charging {
                self.floor_override = false;
            }
            self.battery = Some(b);
        } else {
            self.battery = None;
        }
        self.thermal = self.platform.thermal();
        if self.has_lid {
            // Shut but driving an external display (a desk setup): treated as open. Nothing is slowed or paused
            // and the machine isn't put to sleep under someone using it.
            let closed = self.platform.lid_closed() && !self.platform.docked();
            if closed != self.lid_closed {
                self.lid_changed(closed, now);
            }
        }
        if gap {
            self.resumed(now);
        }
        self.check_in_tick(now);
        if let Some(p) = procs_now {
            self.procs = p;
            self.watcher.sample(&self.procs, &self.cfg, now);
            let mut seen = None;
            let mut work = None;
            for s in self.watcher.sessions.iter().filter(|s| self.counts(s)) {
                seen = Some((now, s.kind.name.clone()));
                if s.working(now) {
                    work = Some((
                        s.last_active.max(now.saturating_sub(20)),
                        s.kind.name.clone(),
                    ));
                }
            }
            if seen.is_some() {
                self.last_seen = seen;
            }
            if work.is_some() {
                self.last_work = work;
            }
            self.detect_finished(now);
            // From the second sample on (the first has no CPU figures yet), then once a minute.
            if self.ticks % 30 == 2 {
                self.refresh_watch_offer();
            }
            if self.lid_closed && self.holding {
                self.apply_rules(None); // catch apps launched while closed
            }
        }
        if self.ticks.is_multiple_of(5) {
            self.reload_config_if_edited();
        }
        if self.has_lid && self.ticks % 15 == 1 {
            self.lid_warning = self.platform.lid_warning().or_else(|| {
                self.battery.is_none().then(|| {
                    "Can't read the battery, so the battery limit can't stop it".to_string()
                })
            });
        }
        if self.holding && self.ticks % 15 == 7 {
            self.hold_warning = self.platform.verify_hold(&mut self.restore).err();
            self.save_restore();
        } else if !self.holding {
            self.hold_warning = None;
        }
        if self.ticks % 150 == 3 {
            self.check_watchdog();
        }
        // Retry anything that couldn't be put back earlier.
        if !self.touched.is_empty() && !(self.lid_closed && self.holding) {
            self.restore_apps();
        }
        if self.ticks % 15 == 11
            && !(self.lid_closed && self.holding)
            && (self.restore.power_profile.is_some()
                || self.restore.power_overlay.is_some()
                || self.restore.boost_dc.is_some()
                || self.restore.linux_tuned)
        {
            self.platform.set_low_power(false, &mut self.restore);
            self.save_restore();
        }
        if self.pending_release && self.platform.end_hold(&mut self.restore).is_ok() {
            self.pending_release = false;
            state::remove(&self.path("hold"));
            self.save_restore();
        }
        state::heartbeat(&self.path("alive"));
        self.check_scheduled_wake(now);
        self.evaluate(now);
        self.keep_wake_armed(now);
    }

    /// A scheduled wake whose time came while the machine was already up: with the lid shut it starts the
    /// stay-awake time now; either way it's used up, so it never lingers as a time in the past.
    fn check_scheduled_wake(&mut self, now: u64) {
        let Some(at) = self.cfg.wake_at else { return };
        if now < at {
            return;
        }
        let minutes = self.cfg.wake_for_minutes;
        self.update(|c| c.wake_at = None);
        if self.lid_closed && !self.holding {
            let _ = self.add_hold("Scheduled wake", Some(minutes as f64), None);
        }
    }

    // MARK: waking while asleep (see wake.rs)

    /// Keeps one OS wake timer pending while it could be needed, re-armed about once a minute so it's due at most
    /// a step after the machine falls asleep. Check-ins only with the lid shut (with it open a wake may light the
    /// screen); a scheduled wake always.
    fn keep_wake_armed(&mut self, now: u64) {
        let check_in = if self.lid_closed {
            self.cfg.check_in_minutes
        } else {
            0
        };
        let until = self.cfg.wake_at.map(|at| at as i64 - now as i64);
        let step = if self.holding || self.checkin_until.is_some() {
            None
        } else {
            crate::wake::next_step(until, check_in)
        };
        match step {
            // Re-armed often enough that it's never due while awake, not every minute (each arm can cost a
            // privileged call): a quarter of the step, at least 50 s.
            Some(s)
                if self
                    .wake_armed_at
                    .is_none_or(|t| now.saturating_sub(t) >= (s / 4).max(50)) =>
            {
                self.wake_armed_at = self.platform.arm_wake(s).then_some(now);
            }
            Some(_) => {}
            None if self.wake_armed_at.is_some() => {
                self.platform.disarm_wake();
                self.wake_armed_at = None;
            }
            None => {}
        }
    }

    /// Asks for the wake right before Ajar itself puts the machine to sleep (the minute timer may be stale).
    fn arm_before_sleep(&mut self, now: u64) {
        self.wake_armed_at = None;
        self.keep_wake_armed(now);
    }

    /// Back from sleep. With the lid open someone is there: nothing to do. With it shut and nothing holding the
    /// machine, this was a scheduled wake or a check-in.
    fn resumed(&mut self, now: u64) {
        // Whatever woke it, a leftover timer has no purpose now; the next one is armed from here.
        if self.wake_armed_at.take().is_some() {
            self.platform.disarm_wake();
        }
        if !self.lid_closed || self.holding || self.checkin_until.is_some() {
            return;
        }
        if let Some(at) = self.cfg.wake_at {
            if now + 90 >= at {
                let minutes = self.cfg.wake_for_minutes;
                self.update(|c| c.wake_at = None);
                let _ = self.add_hold("Scheduled wake", Some(minutes as f64), None);
                return;
            }
        }
        if self.cfg.check_in_minutes == 0 && self.cfg.wake_at.is_none() {
            return;
        }
        // Stay up a few seconds (journaled like a hold, so the watchdog can undo it) while the app reconnects
        // to the relay and reads what the phone sent while the machine slept.
        if self
            .platform
            .begin_hold("Checking for phone commands", &mut self.restore)
            .is_ok()
        {
            self.save_restore();
            state::touch(&self.path("hold"));
            self.checkin_until = Some(now + crate::wake::CHECK_IN_SECS);
        }
    }

    fn check_in_tick(&mut self, now: u64) {
        let Some(until) = self.checkin_until else {
            return;
        };
        if self.holding {
            self.checkin_until = None; // a phone command or an agent took over; the hold owns sleep now
            return;
        }
        if now < until {
            return;
        }
        self.checkin_until = None;
        match self.platform.end_hold(&mut self.restore) {
            Ok(()) => state::remove(&self.path("hold")),
            Err(_) => self.pending_release = true,
        }
        self.save_restore();
        if self.lid_closed {
            self.arm_before_sleep(now);
            self.platform.sleep_now();
        }
    }

    /// "Wake at 7:00" (None = off), staying awake `minutes` after.
    pub fn set_wake(&mut self, at: Option<u64>, minutes: Option<u32>) {
        self.update(|c| {
            c.wake_at = at;
            if let Some(m) = minutes {
                c.wake_for_minutes = m.clamp(5, 24 * 60);
            }
        });
    }

    fn learn_draw(&mut self, b: &Battery) {
        if !b.discharging() || !b.watts.is_finite() || b.watts <= 0.3 || b.watts > 200.0 {
            return;
        }
        let slot = if self.lid_closed && self.holding {
            &mut self.closed_draw
        } else if !self.lid_closed {
            &mut self.open_draw
        } else {
            return;
        };
        *slot = Some(slot.map_or(b.watts, |w| w * 0.85 + b.watts * 0.15));
        if self.ticks.is_multiple_of(30) {
            state::save_json(
                &self.path("learned.json"),
                &(self.open_draw, self.closed_draw),
            );
        }
    }

    // MARK: decision

    fn counts(&self, s: &Session) -> bool {
        !self.cfg.track_only.contains(&s.kind.id)
            && !(s.kind.is_claude_app() && !self.cfg.count_claude_app)
    }

    fn quiet_window(&self) -> u64 {
        if self.cfg.sleep_when_done {
            self.cfg.quiet_minutes as u64 * 60
        } else {
            120
        }
    }

    /// Why an agent is keeping it awake right now, with the countdown when it's winding down.
    pub fn work_reason(&self, now: u64) -> Option<String> {
        let window = self.quiet_window();
        if let Some(a) = self.active_agent(now) {
            let busy = a.working(now);
            let name = if a.instances > 1 {
                format!("{} ×{}", a.kind.name, a.instances)
            } else {
                a.kind.name.clone()
            };
            if busy {
                return Some(if a.tool_running && a.cpu < a.kind.idle_cpu {
                    format!("{name} is running a command")
                } else {
                    format!("{name} is working")
                });
            }
            if !self.cfg.sleep_when_done {
                return Some(format!("{name} is open"));
            }
            let left = window.saturating_sub(now.saturating_sub(a.last_active));
            return Some(format!(
                "{name} went idle · sleeps in {}",
                crate::format::minutes((left as f64 / 60.0).ceil())
            ));
        }
        // The agent's process is gone: the countdown still runs from its last activity.
        let (t, name) = if self.cfg.sleep_when_done {
            self.last_work.clone()?
        } else {
            self.last_seen.clone()?
        };
        let left = window.saturating_sub(now.saturating_sub(t));
        (left > 0).then(|| {
            format!(
                "{name} stopped · sleeps in {}",
                crate::format::minutes((left as f64 / 60.0).ceil())
            )
        })
    }

    fn check_watchdog(&mut self) {
        match self.platform.watchdog_installed() {
            Some(false) => {
                if !self.watchdog_repair_tried {
                    self.watchdog_repair_tried = true;
                    if self.platform.install_watchdog().is_ok()
                        && self.platform.watchdog_installed() == Some(true)
                    {
                        self.watchdog_warning = None;
                        return;
                    }
                }
                self.watchdog_warning = Some("The safety watchdog isn't installed, so a crash wouldn't be cleaned up automatically. Run `ajar install`.".into());
            }
            _ => self.watchdog_warning = None,
        }
    }

    pub fn active_agent(&self, now: u64) -> Option<&Session> {
        let window = self.cfg.quiet_minutes as u64 * 60;
        self.watcher.sessions.iter().find(|s| {
            if self.cfg.track_only.contains(&s.kind.id) {
                return false;
            }
            if s.kind.is_claude_app() && !self.cfg.count_claude_app {
                return false;
            }
            if self.cfg.sleep_when_done {
                s.last_active > 0 && now.saturating_sub(s.last_active) < window
            } else {
                true
            }
        })
    }

    pub fn evaluate(&mut self, now: u64) {
        match self.platform.ready() {
            Ok(()) => self.setup_error = None,
            Err(e) => {
                self.setup_error = Some(e);
                if self.holding {
                    self.end_hold("Ajar can't control sleep on this machine", now);
                }
                return;
            }
        }
        if self.cfg.mode == Mode::On {
            if let Some(u) = self.cfg.always_until {
                if now > u {
                    self.cfg.mode = self.cfg.mode_before_always.take().unwrap_or(Mode::Auto);
                    self.cfg.always_until = None;
                    self.save_config();
                }
            }
        }
        let before = self.holds.len();
        self.holds.retain(|h| h.alive(now));
        if self.holds.len() != before {
            self.save_runtime();
        }

        let mut want = false;
        let mut reason = None;
        match self.cfg.mode {
            // Holds are explicit requests (a timer, `ajar run`, MCP), so they work in any mode.
            Mode::Off => {
                if let Some(h) = self.holds.last() {
                    want = true;
                    reason = Some(h.reason.clone());
                }
            }
            Mode::On => {
                want = true;
                reason = Some(match self.cfg.always_until {
                    Some(u) => format!("Awake until {}", crate::format::clock(u)),
                    None => "Always awake".into(),
                });
            }
            Mode::Auto => {
                if let Some(h) = self.holds.last() {
                    want = true;
                    reason = Some(h.reason.clone());
                } else if self.snoozed {
                    // Asked to sleep now: agents wait until the lid opens again.
                } else if let Some(r) = self.work_reason(now) {
                    want = true;
                    reason = Some(r);
                }
            }
        }

        self.blocked = None;
        if let Some(b) = self.battery.clone() {
            // "On the charger" means the charger is covering the load, not just plugged in.
            if want && self.cfg.only_on_power && b.on_battery() {
                want = false;
                self.blocked = Some("Only stays awake on the charger".into());
            }
            // Battery limit with a 3% band so it doesn't flap at the edge. 0 = never stop for battery.
            if want && self.cfg.battery_floor > 0 && !self.floor_override && b.on_battery() {
                let floor = self.cfg.battery_floor;
                if b.percent <= floor {
                    self.floor_latched = true;
                }
                if self.floor_latched && b.percent <= floor + 3 {
                    want = false;
                    self.blocked = Some(format!(
                        "Battery at {}%, below your {}% limit",
                        b.percent, floor
                    ));
                } else if b.percent > floor + 3 {
                    self.floor_latched = false;
                }
            } else if b.charging {
                self.floor_latched = false;
            }
        }
        // Hot with the lid shut (a bag, a sofa): sleep at critical at once, and after 5 minutes of "serious" even
        // with the strictest rules applied, because a closed laptop can't cool itself much.
        if self.lid_closed && self.thermal >= Thermal::Serious {
            self.hot_since.get_or_insert(now);
        } else {
            self.hot_since = None;
        }
        let hot_too_long = self
            .hot_since
            .is_some_and(|t| now.saturating_sub(t) >= HOT_GRACE_SECS);
        if want && self.cfg.heat_guard && (self.thermal == Thermal::Critical || hot_too_long) {
            want = false;
            self.blocked = Some("Too hot, letting it cool down".into());
        }

        self.hold_reason = reason.clone();
        if want && !self.holding {
            self.start_hold(reason.as_deref().unwrap_or("Staying awake"), now);
        } else if !want && self.holding {
            let why = self.blocked.clone().unwrap_or_else(|| {
                if self.cfg.mode == Mode::Off {
                    "Turned off".into()
                } else {
                    "Work finished".into()
                }
            });
            self.end_hold(&why, now);
        }

        // Heat guard: strictest rules once it gets hot with the lid closed, back once it cools.
        let hot = self.holding
            && self.lid_closed
            && self.cfg.heat_guard
            && self.thermal >= Thermal::Serious;
        if hot && !self.heat_forced && self.cfg.preset != Preset::Longest {
            self.heat_forced = true;
            self.reapply_closed_state(Some(Preset::Longest));
        } else if !hot && self.heat_forced {
            self.heat_forced = false;
            if self.holding && self.lid_closed {
                self.reapply_closed_state(None);
            }
        }
    }

    pub fn blocked_by_floor(&self) -> bool {
        let Some(b) = &self.battery else { return false };
        if self.cfg.battery_floor == 0 || self.floor_override || !b.on_battery() {
            return false;
        }
        b.percent <= self.cfg.battery_floor + if self.floor_latched { 3 } else { 0 }
    }

    pub fn override_floor(&mut self, on: bool) {
        self.floor_override = on;
        if on {
            self.floor_latched = false;
        }
        self.evaluate(crate::now());
    }

    // MARK: holding

    fn start_hold(&mut self, reason: &str, now: u64) {
        if let Err(e) = self.platform.begin_hold(reason, &mut self.restore) {
            self.setup_error = Some(e);
            return;
        }
        self.save_restore();
        self.holding = true;
        self.pending_release = false;
        state::touch(&self.path("hold"));
        if self.lid_closed {
            self.enter_closed(now);
        }
    }

    fn end_hold(&mut self, why: &str, now: u64) {
        let was_closed = self.lid_closed;
        if was_closed {
            self.restore_closed_state();
        }
        match self.platform.end_hold(&mut self.restore) {
            Ok(()) => state::remove(&self.path("hold")),
            Err(_) => self.pending_release = true, // retried every tick; the watchdog also retries
        }
        self.save_restore();
        self.holding = false;
        if was_closed {
            if let Some(r) = &mut self.receipt {
                r.sleep_requested_at = Some(now);
                r.end_percent = self.battery.as_ref().map(|b| b.percent);
            }
            self.sleep_retries = 0;
            // The lid is already shut, so the OS won't sleep on its own (it only sleeps on the close edge),
            // unless the person's own setting is to keep running with the lid shut.
            if self.platform.sleep_after_hold() {
                self.arm_before_sleep(now);
                self.platform.sleep_now();
            } else if let Some(r) = &mut self.receipt {
                r.sleep_requested_at = None;
            }
        } else {
            let _ = why;
        }
    }

    // MARK: lid

    fn lid_changed(&mut self, closed: bool, now: u64) {
        self.lid_closed = closed;
        if closed && !self.holding {
            // The OS may sleep any moment now: have the check-in wake pending before it does.
            self.arm_before_sleep(now);
        }
        if closed {
            if self.holding {
                self.enter_closed(now);
            } else if !self.platform.sleeps_on_close_itself() {
                // The desktop leaves lid-close sleep to Ajar (see Platform::sleeps_on_close_itself).
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

    fn enter_closed(&mut self, now: u64) {
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

    fn reapply_closed_state(&mut self, forcing: Option<Preset>) {
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

    fn restore_closed_state(&mut self) {
        if !self.lid_closed {
            self.platform.screen_off(false);
        }
        self.restore_apps();
        self.platform.set_low_power(false, &mut self.restore);
        self.save_restore();
    }

    fn save_restore(&self) {
        if self.restore == Restore::default() {
            state::remove(&self.path("restore.json"));
        } else {
            state::save_json(&self.path("restore.json"), &self.restore);
        }
    }

    fn apply_rules(&mut self, preset: Option<Preset>) {
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
            // every app Ajar changed (the watchdog and the next start undo it).
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

    fn restore_apps(&mut self) {
        let touched = std::mem::take(&mut self.touched);
        self.touched = undo_touched(&mut self.platform, touched, &self.procs);
        self.save_touched();
    }

    /// Apps Ajar changed and hasn't managed to put back yet (shown in the menu and `ajar doctor`).
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

    fn save_touched(&self) -> bool {
        if self.touched.is_empty() {
            state::remove(&self.path("touched.json"));
            true
        } else {
            state::save_json(&self.path("touched.json"), &self.touched)
        }
    }

    /// Agents, their trees and ancestors (from the watcher), plus anything a hold is tied to, its children
    /// and the apps above it.
    fn protected_pids(&self) -> std::collections::HashSet<u32> {
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

    // MARK: sessions and announcements

    fn finish_session(&mut self, r: &Receipt, opened: u64) {
        let end = r.slept_at.unwrap_or(opened);
        let minutes = end.saturating_sub(r.closed_at) as f64 / 60.0;
        if minutes < 0.5 {
            return;
        }
        self.stats.sessions.push(SessionRecord {
            date: r.closed_at,
            closed_minutes: minutes,
            start_percent: r.start_percent,
            end_percent: r.end_percent,
            agent: r.agent.clone(),
            slept: r.slept_at.is_some(), // confirmed sleeps only
        });
        if self.stats.sessions.len() > 400 {
            let extra = self.stats.sessions.len() - 400;
            self.stats.sessions.drain(..extra);
        }
        state::save_json(&self.path("stats.json"), &self.stats);
    }

    /// "Claude Code went idle": an agent that was busy for at least a minute has been quiet for 2 minutes.
    /// Ajar can't tell success from a crash or a question waiting for an answer, so it never says "finished".
    fn detect_finished(&mut self, now: u64) {
        let mut current: HashMap<String, (u64, String)> = HashMap::new();
        let present: std::collections::HashSet<String> = self
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
            let title = if present.contains(&id) {
                format!("{name} went idle")
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

    // MARK: actions

    pub fn set_mode(&mut self, m: Mode) {
        if m == Mode::On {
            self.stay_awake(None);
        } else {
            self.update(|c| c.mode = m);
        }
    }

    pub fn stay_awake(&mut self, minutes: Option<u64>) {
        if self.cfg.mode != Mode::On {
            self.cfg.mode_before_always = Some(self.cfg.mode);
        }
        self.cfg.mode = Mode::On;
        // Mode and end time are written together in one file, so they can't disagree after a crash.
        self.cfg.always_until = minutes.map(|m| crate::now() + m.clamp(1, 7 * 24 * 60) * 60);
        self.save_config();
        self.evaluate(crate::now());
    }

    pub fn add_hold(
        &mut self,
        reason: &str,
        minutes: Option<f64>,
        pid: Option<u32>,
    ) -> Result<Hold, String> {
        let now = crate::now();
        let pid_start = match pid {
            Some(p) => {
                Some(procs::start_time(p).ok_or_else(|| format!("process {p} isn't running"))?)
            }
            None => None,
        };
        let id: String = format!(
            "{:08x}",
            (now ^ (std::process::id() as u64).rotate_left(17) ^ (self.holds.len() as u64 * 7919))
                & 0xffff_ffff
        );
        let h = Hold {
            id,
            reason: reason.chars().take(80).collect(),
            until: minutes
                .filter(|m| m.is_finite() && *m > 0.0)
                .map(|m| now + (m.min(7.0 * 24.0 * 60.0) * 60.0) as u64),
            pid,
            pid_start,
            created: now,
        };
        self.holds.push(h.clone());
        self.save_runtime();
        self.evaluate(now);
        Ok(h)
    }

    pub fn release_hold(&mut self, id: Option<&str>) -> usize {
        let before = self.holds.len();
        match id {
            Some(id) => self.holds.retain(|h| h.id != id),
            None => self.holds.clear(),
        }
        self.save_runtime();
        self.evaluate(crate::now());
        before - self.holds.len()
    }

    /// Try again to put back apps that couldn't be restored earlier.
    pub fn retry_restore(&mut self) {
        if !(self.lid_closed && self.holding) {
            self.restore_apps();
        }
    }

    /// Let it sleep now: ends holds and timers, and agents don't keep it awake until the lid next opens.
    pub fn sleep_now(&mut self) {
        self.holds.clear();
        self.save_runtime();
        if self.cfg.mode == Mode::On {
            let back = self.cfg.mode_before_always.unwrap_or(Mode::Auto);
            self.update(|c| c.mode = back);
        }
        self.snoozed = true;
        self.evaluate(crate::now());
        if !self.lid_closed && !self.holding {
            self.platform.sleep_now();
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

    fn refresh_watch_offer(&mut self) {
        let running: std::collections::HashSet<&str> = self
            .procs
            .iter()
            .filter(|p| p.mine)
            .map(|p| p.name.as_str())
            .collect();
        self.watch_offer
            .retain(|(k, _)| running.contains(k.as_str()));
        let agents: std::collections::HashSet<String> = crate::agents::known()
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

    /// Everything the phone panel shows, in one reply.
    pub fn panel_json(&self, now: u64) -> Value {
        let (keeps, head, detail) = self.outcome();
        let warnings: Vec<&String> = [
            &self.hold_warning,
            &self.lid_warning,
            &self.watchdog_warning,
        ]
        .into_iter()
        .flatten()
        .collect();
        json!({
            "ok": true,
            "keeps": keeps,
            "holding": self.holding,
            "headline": head,
            "detail": detail,
            "battery": self.battery_line_rounded(5.0),
            "modeLine": self.mode_line(),
            "batteryLine": self.battery_summary(),
            "lidClosed": self.lid_closed,
            "mode": self.cfg.mode,
            "alwaysUntil": self.on_until().map(crate::format::clock),
            "preset": self.cfg.preset,
            "snoozed": self.snoozed,
            "holds": self.holds.iter().map(|h| h.reason.clone()).collect::<Vec<_>>(),
            "agents": self.watcher.sessions.iter().map(|s| json!({
                "id": s.kind.id, "name": s.kind.name, "working": s.working(now),
                "keeps": !self.cfg.track_only.contains(&s.kind.id), "instances": s.instances,
            })).collect::<Vec<_>>(),
            "watch": self.watch_candidates().into_iter().map(|(id, name, on)| json!({ "id": id, "name": name, "on": on })).collect::<Vec<_>>(),
            "warnings": warnings,
            "host": hostname(),
            "checkIn": self.cfg.check_in_minutes,
            "wakeAt": self.cfg.wake_at.map(crate::format::clock),
        })
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

    /// Put everything back before quitting.
    pub fn shutdown(&mut self) {
        self.restore_closed_state();
        if (self.holding || self.pending_release)
            && self.platform.end_hold(&mut self.restore).is_ok()
        {
            state::remove(&self.path("hold"));
        }
        self.save_restore();
        self.holding = false;
        state::save_json(
            &self.path("learned.json"),
            &(self.open_draw, self.closed_draw),
        );
    }

    // MARK: figures

    pub fn full_wh(&self) -> f64 {
        self.battery
            .as_ref()
            .and_then(|b| b.full_wh)
            .filter(|w| *w > 5.0 && *w < 200.0)
            .unwrap_or(DEFAULT_FULL_WH)
    }

    /// Hours left down to the battery limit at a given draw.
    pub fn hours_left(&self, watts: f64) -> Option<f64> {
        let b = self.battery.as_ref()?;
        if !watts.is_finite() || watts < 0.1 {
            return None;
        }
        let usable =
            (b.percent.saturating_sub(self.cfg.battery_floor)) as f64 / 100.0 * self.full_wh();
        Some(usable / watts)
    }

    /// Lid-closed draw: the smoothed figure learned on this machine, else the live reading while closed, else a
    /// conservative default (flagged by `closed_draw_is_guess`).
    pub fn closed_watts(&self) -> f64 {
        if let Some(w) = self.closed_draw {
            return w;
        }
        if self.lid_closed && self.holding {
            if let Some(b) = &self.battery {
                if b.discharging() {
                    return b.watts;
                }
            }
        }
        DEFAULT_CLOSED_W
    }

    pub fn closed_draw_is_guess(&self) -> bool {
        self.closed_draw.is_none()
            && !(self.lid_closed
                && self.holding
                && self.battery.as_ref().is_some_and(|b| b.discharging()))
    }

    pub fn open_watts(&self) -> Option<f64> {
        match &self.battery {
            Some(b) if !self.lid_closed && b.discharging() => Some(b.watts),
            _ => self.open_draw,
        }
    }

    /// What the laptop is doing, in plain words: it keeps working, or it sleeps. Same words on the phone and the Mac.
    pub fn outcome(&self) -> (bool, String, String) {
        let keeps = "Keeps working";
        let sleeps = if self.has_lid && self.lid_closed { "Going to sleep" } else { "Sleeps normally" };
        if let Some(e) = &self.setup_error {
            return (false, sleeps.into(), e.clone());
        }
        if let Some(b) = &self.blocked {
            return (false, sleeps.into(), b.clone());
        }
        if self.holding {
            return (
                true,
                keeps.into(),
                self.hold_reason
                    .clone()
                    .unwrap_or_else(|| "Staying awake".into()),
            );
        }
        let detail = match self.cfg.mode {
            Mode::Off => "Ajar is off".to_string(),
            Mode::Auto if self.snoozed => "Sleeping until you open the lid".to_string(),
            Mode::Auto => "No agent is working right now".to_string(),
            Mode::On => "Starting…".to_string(),
        };
        (false, sleeps.into(), detail)
    }

    /// What the selected mode does, in one sentence (menu and phone, worded as on the Mac).
    pub fn mode_line(&self) -> String {
        match self.cfg.mode {
            Mode::Off => "Sleeps like any laptop.".into(),
            Mode::Auto => "Stays awake while your AI agents work, then sleeps.".into(),
            Mode::On => match self.on_until() {
                Some(u) => format!("Stays awake until {}.", crate::format::clock(u)),
                None => "Stays awake until you turn it off.".into(),
            },
        }
    }

    /// One plain line about the battery (menu and phone, worded as on the Mac): "64% · about 6 h 05 min with
    /// the lid closed". Hours are rounded to 5 minutes so the menu doesn't flicker; just the percent when there's
    /// no estimate (or no lid).
    pub fn battery_summary(&self) -> Option<String> {
        let b = self.battery.as_ref()?;
        let hours = if self.has_lid {
            self.hours_left(self.closed_watts())
                .map(|h| (h * 12.0).round() / 12.0)
                .filter(|h| *h > 0.0)
        } else {
            None
        };
        Some(match hours {
            Some(h) => format!(
                "{}% · about {} with the lid closed",
                b.percent,
                crate::format::hm(h)
            ),
            None if b.charging => format!("{}% · charging", b.percent),
            None => format!("{}%", b.percent),
        })
    }

    pub fn battery_line(&self) -> Option<String> {
        self.battery_line_rounded(1.0)
    }

    /// Battery line with the hours estimate rounded to `step` minutes (the menu uses 5 so it doesn't flicker).
    pub fn battery_line_rounded(&self, step: f64) -> Option<String> {
        let b = self.battery.as_ref()?;
        let per_hour = 60.0 / step.max(1.0);
        let closed = self
            .hours_left(self.closed_watts())
            .map(|h| (h * per_hour).round() / per_hour);
        Some(if !b.on_battery() {
            match closed {
                Some(h) => format!(
                    "{}% · ∞ plugged in (≈{} if unplugged, lid closed)",
                    b.percent,
                    crate::format::hm(h)
                ),
                None => format!("{}% · ∞ plugged in", b.percent),
            }
        } else {
            match closed {
                Some(h) if self.closed_draw_is_guess() => format!(
                    "{}% · ≈{} left with the lid closed (rough until measured)",
                    b.percent,
                    crate::format::hm(h)
                ),
                Some(h) => format!(
                    "{}% · ≈{} left with the lid closed",
                    b.percent,
                    crate::format::hm(h)
                ),
                None => format!("{}%", b.percent),
            }
        })
    }

    // MARK: command surface (CLI, MCP)

    pub fn handle(&mut self, cmd: &str, a: &Value) -> Value {
        let s = |k: &str| a.get(k).and_then(Value::as_str).map(str::to_string);
        let num = |k: &str, cap: f64| -> Option<f64> {
            let v = a.get(k)?;
            let n = v
                .as_f64()
                .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))?;
            (n.is_finite() && n >= 0.0).then(|| n.min(cap))
        };
        let boolean = |k: &str| -> Option<bool> {
            let v = a.get(k)?;
            v.as_bool()
                .or_else(|| match v.as_str()?.to_lowercase().as_str() {
                    "on" | "true" | "yes" | "1" => Some(true),
                    "off" | "false" | "no" | "0" => Some(false),
                    _ => None,
                })
        };
        let fail = |m: String| json!({ "ok": false, "error": m });
        match cmd {
            "status" => self.status_json(),
            "energy" => json!({ "ok": true, "apps": self.energy_json(15) }),
            "mode" => {
                let Some(m) = s("mode").as_deref().and_then(Mode::parse) else {
                    return fail("mode must be off, auto (when busy) or always".into());
                };
                if m == Mode::On {
                    // "until_hour": the next time this laptop's clock reads that hour (the phone may be in
                    // another time zone).
                    let until = num("until_hour", 23.0).map(|h| {
                        let now = crate::now();
                        crate::format::next_local_hour(now, h as u32)
                            .saturating_sub(now)
                            .div_ceil(60)
                    });
                    let minutes = until
                        .or_else(|| num("minutes", 7.0 * 24.0 * 60.0).map(|m| m.max(1.0) as u64));
                    self.stay_awake(minutes);
                } else {
                    self.set_mode(m);
                }
                self.ok()
            }
            "hold" => {
                let pid = match a.get("pid") {
                    None | Some(Value::Null) => None,
                    Some(_) => match num("pid", u32::MAX as f64)
                        .map(|p| p as u32)
                        .filter(|p| *p > 1)
                    {
                        Some(p) => Some(p),
                        None => return fail("pid must be a running process id".into()),
                    },
                };
                let reason = s("reason").unwrap_or_else(|| "Asked to stay awake".into());
                match self.add_hold(&reason, num("minutes", 7.0 * 24.0 * 60.0), pid) {
                    Ok(h) => {
                        let mut r = self.ok();
                        r["hold"] = serde_json::to_value(&h).unwrap_or(Value::Null);
                        r
                    }
                    Err(e) => fail(e),
                }
            }
            "wake" => {
                // From the phone while asleep (picked up at the next check-in), or any time: stay awake a while.
                // One that waited at the relay and arrives with the lid open is stale: someone opened the laptop
                // in the meantime, and a surprise hour awake after they close it again would be wrong.
                if !self.lid_closed && num("_age", f64::MAX).unwrap_or(0.0) > 300.0 {
                    let mut r = self.ok();
                    r["skipped"] = json!("already awake");
                    return r;
                }
                let minutes = num("minutes", 24.0 * 60.0)
                    .map(|m| m.max(5.0))
                    .unwrap_or(60.0);
                let reason = s("reason").unwrap_or_else(|| "Woken from your phone".into());
                match self.add_hold(&reason, Some(minutes), None) {
                    Ok(h) => {
                        let mut r = self.ok();
                        r["hold"] = serde_json::to_value(&h).unwrap_or(Value::Null);
                        r
                    }
                    Err(e) => fail(e),
                }
            }
            "wake_at" => {
                // "07:00" (the next time the clock shows it), "off", or Unix seconds; optional minutes awake after.
                let t = s("time")
                    .or_else(|| a.get("time").and_then(Value::as_u64).map(|n| n.to_string()))
                    .unwrap_or_default();
                if ["off", "none", "cancel"].contains(&t.to_lowercase().as_str()) {
                    self.set_wake(None, None);
                    let mut r = self.ok();
                    r["wakeAt"] = Value::Null;
                    return r;
                }
                let now = crate::now();
                let Some(at) = crate::format::parse_wake_time(&t, now) else {
                    return fail("time: HH:MM (24-hour), off, or Unix seconds".into());
                };
                self.set_wake(Some(at), num("minutes", 24.0 * 60.0).map(|m| m as u32));
                let mut r = self.ok();
                r["wakeAt"] = json!(crate::format::clock(at));
                r
            }
            "release" => {
                // One hold by id, or all of them only when asked in so many words (`ajar release` with no id).
                if s("id").is_none() && boolean("all") != Some(true) {
                    return fail("needs id (see ajar status), or all: true".into());
                }
                let n = self.release_hold(s("id").as_deref());
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "release_own" => {
                // MCP: an agent may only end holds its own session made.
                let (Some(id), Some(pid)) =
                    (s("id"), num("pid", u32::MAX as f64).map(|p| p as u32))
                else {
                    return fail("needs id and pid".into());
                };
                let before = self.holds.len();
                self.holds.retain(|h| !(h.id == id && h.pid == Some(pid)));
                let n = before - self.holds.len();
                self.save_runtime();
                self.evaluate(crate::now());
                if n == 0 {
                    return fail(format!("no hold {id} made by this session"));
                }
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "release_pid" => {
                let Some(pid) = num("pid", u32::MAX as f64).map(|p| p as u32) else {
                    return fail("needs pid".into());
                };
                let before = self.holds.len();
                self.holds.retain(|h| h.pid != Some(pid));
                let n = before - self.holds.len();
                self.save_runtime();
                self.evaluate(crate::now());
                let mut r = self.ok();
                r["released"] = json!(n);
                r
            }
            "panel" => self.panel_json(crate::now()),
            "track" => {
                let Some(id) = s("agent") else {
                    return fail("needs agent".into());
                };
                if !self.watcher.sessions.iter().any(|x| x.kind.id == id)
                    && !self.cfg.track_only.contains(&id)
                {
                    return fail(format!("no agent {id:?} is running"));
                }
                match boolean("keeps") {
                    Some(keeps) => self.set_keeps(&id, keeps),
                    None => self.toggle_track_only(&id), // older phone pages only toggle
                }
                self.ok()
            }
            "sleep_now" => {
                self.sleep_now();
                self.ok()
            }
            "preset" => {
                let Some(p) = s("preset").as_deref().and_then(Preset::parse) else {
                    return fail("preset must be max_battery, balanced or full_speed".into());
                };
                self.update(|c| c.preset = p);
                self.ok()
            }
            "rule" => {
                let (Some(app), Some(rule)) = (s("app"), s("rule")) else {
                    return fail("needs app and rule".into());
                };
                let key = exe_key(app.trim());
                if key.is_empty() || key.len() > 64 {
                    return fail("app must be an executable name like chrome or spotify".into());
                }
                if matches!(rule.to_lowercase().as_str(), "default" | "reset") {
                    self.update(|c| {
                        c.app_rules.remove(&key);
                    });
                } else {
                    let Some(r) = AppRule::parse(&rule) else {
                        return fail("rule must be leave, slow, pause or default".into());
                    };
                    if SYSTEM_NEVER.contains(&key.as_str()) {
                        return fail(format!(
                            "{key} is part of the system and is never slowed or paused"
                        ));
                    }
                    self.update(|c| {
                        c.app_rules.insert(key.clone(), r);
                    });
                }
                let mut out = self.ok();
                out["app"] = json!(key);
                out
            }
            "watch" => {
                let Some(q) = s("app")
                    .map(|x| x.trim().to_string())
                    .filter(|x| !x.is_empty())
                else {
                    return fail("needs app".into());
                };
                let key = exe_key(&q);
                if key.is_empty() || key.len() > 64 {
                    return fail("app must be an executable name".into());
                }
                let remove = boolean("remove") == Some(true);
                // The phone sends the id: keep the display name already known for it.
                let name = self
                    .watch_candidates()
                    .into_iter()
                    .find(|c| c.0 == key)
                    .map_or(q, |c| c.1);
                self.update(|c| {
                    c.watched_apps.retain(|w| w.id != key);
                    if !remove {
                        c.watched_apps.push(crate::config::WatchedApp {
                            id: key.clone(),
                            name: name.clone(),
                        });
                    }
                });
                let mut out = self.ok();
                out["watch_list"] = json!(self
                    .cfg
                    .watched_apps
                    .iter()
                    .map(|w| w.name.clone())
                    .collect::<Vec<_>>());
                out
            }
            "agent" => {
                let (Some(name), Some(exe)) = (s("name"), s("executable")) else {
                    return fail("needs name and executable".into());
                };
                let name: String = name.chars().take(64).collect();
                let remove = boolean("remove") == Some(true);
                let idle = num("idle_cpu", 400.0);
                self.update(|c| {
                    c.custom_agents.retain(|x| x.name != name);
                    if !remove {
                        c.custom_agents.push(crate::config::CustomAgent {
                            name: name.clone(),
                            executables: vec![exe_key(&exe)],
                            idle_cpu: idle,
                        });
                    }
                });
                self.ok()
            }
            "schema" => crate::ai::describe(&self.cfg, &self.path("config.json")),
            "power" => self.power_json(),
            // The phone's Measure button. Its page only shows it when the panel says `canMeasure`, which this
            // edition never sends.
            "power_test" => fail("Measuring savings is Mac-only for now".into()),
            "set" => {
                let Some(key) = s("key") else {
                    return fail("needs key".into());
                };
                // mode and preset have their own commands; accept them here too so one call can change any setting.
                match key.replace('-', "_").as_str() {
                    "mode" => {
                        return self.handle(
                            "mode",
                            &json!({ "mode": a.get("value").cloned().unwrap_or(Value::Null) }),
                        )
                    }
                    "preset" => {
                        return self.handle(
                            "preset",
                            &json!({ "preset": a.get("value").cloned().unwrap_or(Value::Null) }),
                        )
                    }
                    _ => {}
                }
                let mut bad: Option<&str> = None;
                let k = key.replace('-', "_");
                let v_num = num("value", 1e6);
                let v_bool = boolean("value");
                let v_str = s("value");
                self.update(|c| match k.as_str() {
                    // Like the heat guard: commands can raise the battery limit but only the menu can lower it.
                    "battery_floor" => match v_num {
                        Some(n) if (n as u32).min(80) >= c.battery_floor => c.battery_floor = (n as u32).min(80),
                        Some(_) => bad = Some("to be lowered from the Ajar menu (it can only be raised from here)"),
                        None => bad = Some("a number (0 = never stop for battery)"),
                    },
                    "quiet_minutes" => match v_num { Some(n) => c.quiet_minutes = (n as u32).clamp(1, 240), None => bad = Some("a number of minutes") },
                    "sleep_when_done" => match v_bool { Some(b) => c.sleep_when_done = b, None => bad = Some("on/off") },
                    "low_power" => match v_bool { Some(b) => c.low_power_while_closed = b, None => bad = Some("on/off") },
                    // The heat guard protects a laptop in a bag; only the person can turn it off (in the tray menu).
                    "heat_guard" => match v_bool { Some(true) => c.heat_guard = true, Some(false) => bad = Some("to be turned off from the Ajar menu (it can only be turned on from here)"), None => bad = Some("on/off") },
                    "only_on_power" => match v_bool { Some(b) if b || !c.only_on_power => c.only_on_power = b, Some(_) => bad = Some("to be turned off from the Ajar menu (it can only be turned on from here)"), None => bad = Some("on/off") },
                    "claude_app" => match v_bool { Some(b) => c.count_claude_app = b, None => bad = Some("on/off") },
                    "notify_done" => match v_bool { Some(b) => c.notify_done = b, None => bad = Some("on/off") },
                    "check_in_minutes" => match v_num.map(|n| n as u32).filter(|n| crate::wake::CHECK_IN_CHOICES.contains(n)) {
                        Some(n) => c.check_in_minutes = n,
                        None => bad = Some("0, 15, 30 or 60"),
                    },
                    // Alerts go wherever this topic points, so only the menu sets it; commands may turn it off.
                    "ntfy_topic" => match v_str { Some(t) if t.is_empty() => c.ntfy_topic = t, _ => bad = Some("to be set from the Ajar menu (commands can only turn it off with an empty value)") },
                    _ => bad = Some("a known key"),
                });
                if let Some(b) = bad {
                    let keys: Vec<&str> = crate::ai::SETTINGS.iter().map(|s| s.key).collect();
                    return fail(format!(
                        "{key} needs {b}. Keys: {} (ajar settings explains each)",
                        keys.join(", ")
                    ));
                }
                self.ok()
            }
            "override_floor" => {
                // Running the battery below the person's limit is their call, from the menu; commands can only
                // turn the override back off.
                if boolean("on").unwrap_or(true) {
                    return fail(
                        "Going below the battery limit can only be allowed from the Ajar menu"
                            .into(),
                    );
                }
                self.override_floor(false);
                let mut r = self.ok();
                r["below_floor_allowed"] = json!(self.floor_override);
                r
            }
            "config" => {
                json!({ "ok": true, "path": self.path("config.json").to_string_lossy(), "config": serde_json::to_value(&self.cfg).unwrap_or(Value::Null) })
            }
            _ => fail(format!("Unknown command {cmd}")),
        }
    }

    fn ok(&self) -> Value {
        json!({ "ok": true, "status": self.outcome().1 + " · " + &self.outcome().2 })
    }

    pub fn status_json(&self) -> Value {
        let now = crate::now();
        let (keeps, head, detail) = self.outcome();
        let mut d = json!({
            "ok": true,
            "status": format!("{head} · {detail}"),
            "keeping_awake": self.holding,
            "will_stay_awake_closed": keeps,
            "mode": self.cfg.mode,
            "preset": self.cfg.preset,
            "lid_closed": self.lid_closed,
            "has_lid": self.has_lid,
            "platform": self.platform.name(),
            "holds": self.holds,
            "watch_list": self.cfg.watched_apps.iter().map(|w| w.name.clone()).collect::<Vec<_>>(),
            "watching": self.watcher.sessions.iter().map(|s| json!({
                "name": s.kind.name,
                "working": s.working(now),
                "cpu_percent": (s.cpu * 10.0).round() / 10.0,
                "idle_minutes": if s.last_active == 0 { -1 } else { (now.saturating_sub(s.last_active) / 60) as i64 },
                "keeps_awake": !self.cfg.track_only.contains(&s.kind.id),
                "project": s.project.clone().unwrap_or_default(),
            })).collect::<Vec<_>>(),
            "apps_using_cpu": self.energy_json(8),
        });
        if let Some(b) = &self.battery {
            d["battery"] = json!({ "percent": b.percent, "watts": (b.watts * 10.0).round() / 10.0, "on_power": b.on_ac, "charging": b.charging });
            if b.on_battery() {
                if let Some(h) = self.hours_left(self.closed_watts()) {
                    d["hours_left_closed"] = json!((h * 10.0).round() / 10.0);
                }
            }
        }
        if let Some(b) = &self.blocked {
            d["blocked_by"] = json!(b);
        }
        if let Some(e) = &self.setup_error {
            d["setup_error"] = json!(e);
        }
        if let Some(w) = &self.lid_warning {
            d["warning"] = json!(w);
        }
        d
    }

    /// What's using power and which setting would cut it, in a shape an AI agent can act on directly.
    pub fn power_json(&self) -> Value {
        let r1 = |x: Option<f64>| x.map(|v| (v * 10.0).round() / 10.0);
        let watts = self
            .battery
            .as_ref()
            .filter(|b| b.discharging())
            .map(|b| b.watts);
        let protected = self.protected_pids();
        let busy: Vec<String> = self
            .watcher
            .cpu_by_app
            .iter()
            .filter(|(name, cpu)| {
                *cpu > 10.0
                    && !self
                        .procs
                        .iter()
                        .any(|p| p.name == **name && protected.contains(&p.pid))
            })
            .take(6)
            .map(|(name, cpu)| {
                format!(
                    "{name} {:.0}% CPU ({:?})",
                    cpu,
                    self.cfg.rule_for(name, self.cfg.preset)
                )
                .to_lowercase()
            })
            .collect();
        let preset = match self.cfg.preset {
            Preset::Longest => "max_battery",
            Preset::Balanced => "balanced",
            Preset::Speed => "full_speed",
        };
        json!({
            "ok": true,
            "system_watts": r1(watts),
            "measured": watts.is_some(),
            "source": if watts.is_some() { "battery discharge" } else { "unknown on the charger (the battery reports power only while discharging)" },
            "lid_closed": self.lid_closed,
            "keeping_awake": self.holding,
            "learned_open_watts": r1(self.open_draw),
            "learned_closed_watts": r1(self.closed_draw),
            "suspects": [
                { "id": "apps", "active": !busy.is_empty(), "title": if busy.is_empty() { "No other app is busy".to_string() } else { format!("Busy apps: {}", busy.join(", ")) },
                  "setting": "preset", "value": preset, "suggested_value": "max_battery", "per_app": "ajar rule <app> pause" },
                { "id": "low_power", "active": !self.cfg.low_power_while_closed, "title": if self.cfg.low_power_while_closed { "Power saver turns on with the lid closed" } else { "Power saver stays off with the lid closed" },
                  "setting": "low_power", "value": self.cfg.low_power_while_closed, "suggested_value": "on" },
            ],
        })
    }

    fn energy_json(&self, limit: usize) -> Value {
        let protected = self.protected_pids();
        json!(self.watcher.cpu_by_app.iter().take(limit).map(|(name, cpu)| {
            let kept = self.procs.iter().any(|p| p.name == *name && protected.contains(&p.pid));
            json!({
                "name": name,
                "cpu_percent": (cpu * 10.0).round() / 10.0,
                "while_closed": if kept { "kept (Ajar is keeping it awake)".to_string() } else { format!("{:?}", self.cfg.rule_for(name, self.cfg.preset)).to_lowercase() },
            })
        }).collect::<Vec<_>>())
    }
}

/// How long "serious" heat with the lid shut is tolerated before the laptop is put to sleep.
pub const HOT_GRACE_SECS: u64 = 300;

/// Processes Ajar never slows or pauses, whatever the rules say: the desktop, audio, input and Ajar itself.
pub const SYSTEM_NEVER: &[&str] = &[
    "ajar",
    "ajar-app",
    "explorer",
    "dwm",
    "csrss",
    "winlogon",
    "svchost",
    "sihost",
    "ctfmon",
    "taskmgr",
    "searchhost",
    "startmenuexperiencehost",
    "shellexperiencehost",
    "runtimebroker",
    "audiodg",
    "systemd",
    "gnome-shell",
    "plasmashell",
    "kwin_wayland",
    "kwin_x11",
    "xorg",
    "xwayland",
    "mutter",
    "pipewire",
    "wireplumber",
    "pulseaudio",
    "dbus-daemon",
    "dbus-broker",
    "gnome-session-binary",
    "ibus-daemon",
    "gsd-power",
    "polkitd",
    "sshd",
    "ssh-agent",
    "gpg-agent",
];

/// This computer's name, shown on the phone panel.
pub fn hostname() -> String {
    std::env::var("COMPUTERNAME")
        .ok()
        .or_else(|| {
            std::fs::read_to_string("/etc/hostname")
                .ok()
                .map(|s| s.trim().to_string())
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "this laptop".into())
}

pub fn receipt_line(r: &Receipt) -> String {
    let end = r.slept_at.or(r.opened_at).unwrap_or(r.closed_at);
    let mins = end.saturating_sub(r.closed_at) as f64 / 60.0;
    let mut s = if r.slept_at.is_some() {
        format!("Ran {}, then slept", crate::format::minutes(mins))
    } else if r.sleep_requested_at.is_some() {
        format!(
            "Ran {}, then Ajar asked it to sleep",
            crate::format::minutes(mins)
        )
    } else {
        format!("Stayed awake {}", crate::format::minutes(mins))
    };
    if let Some(a) = &r.agent {
        s = format!("{a} · {s}");
    }
    if let (Some(a), Some(b)) = (r.start_percent, r.end_percent) {
        if a >= b {
            s.push_str(&format!(" · used {}%", a - b));
        }
    }
    s
}

/// The watchdog (run every minute by the OS scheduler). If the app has stopped checking in, put every app
/// and system setting back. Keeping-awake itself is released by the OS when the app dies (Windows execution
/// state ends with the process; the Linux inhibitor is tied to the app's lifetime); the lid action on Windows
/// is a stored setting and is restored here.
pub fn run_watchdog<P: Platform>(
    platform: &mut P,
    root: &std::path::Path,
    force: bool,
) -> &'static str {
    let alive = root.join("alive");
    let age = state::age_of(&alive);
    // The app counts as alive while its process exists and has checked in within 15 minutes (the gap covers a
    // sleep/resume, when the watchdog can run before the app's first tick). A dead process is cleaned up at
    // once; a hung one after 15 minutes. Old-format heartbeats without a pid get 90 seconds.
    let alive_now = if state::heartbeat_has_pid(&alive) {
        state::heartbeat_process_alive(&alive) && age.is_some_and(|a| a < 900)
    } else {
        age.is_some_and(|a| a < 90)
    };
    if !force && alive_now {
        return "alive";
    }
    let touched: Vec<Touched> = state::load_json(&root.join("touched.json")).unwrap_or_default();
    let left = undo_touched(platform, touched, &[]);
    let mut ok = left.is_empty();
    if left.is_empty() {
        state::remove(&root.join("touched.json"));
    } else {
        state::save_json(&root.join("touched.json"), &left);
    }
    let mut r: Restore = state::load_json(&root.join("restore.json")).unwrap_or_default();
    if r != Restore::default() {
        platform.restore_settings(&mut r);
    }
    if r == Restore::default() {
        state::remove(&root.join("restore.json"));
    } else {
        ok = false;
        state::save_json(&root.join("restore.json"), &r);
    }
    state::remove(&root.join("hold"));
    if ok {
        "restored"
    } else {
        "partly restored"
    }
}

/// Puts back every journaled app that is still the same process (same pid, same start time, same program).
/// Returns the entries that couldn't be put back, to keep in the journal. A process that has exited needs
/// nothing, so it's dropped.
pub fn undo_touched<P: Platform>(
    platform: &mut P,
    touched: Vec<Touched>,
    snapshot: &[Proc],
) -> Vec<Touched> {
    let mut left = vec![];
    for t in touched {
        let same = match snapshot.iter().find(|p| p.pid == t.pid) {
            Some(p) => p.start == t.start && p.name == t.exe,
            None => {
                procs::start_time(t.pid) == Some(t.start)
                    && procs::name_of(t.pid).is_none_or(|n| n == t.exe)
            }
        };
        if !same {
            continue;
        }
        let ok = if t.paused {
            platform.pause(t.pid, t.start, false)
        } else {
            platform.unslow(&t)
        };
        if !ok && procs::start_time(t.pid) == Some(t.start) {
            left.push(t);
        }
    }
    left
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
