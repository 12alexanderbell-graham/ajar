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
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

mod agents;
mod closed_lid;
mod commands;
mod figures;
mod wake;

pub use closed_lid::BusyApp;

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
            return self.pid_start.is_some() && procs::start_time(pid) == self.pid_start;
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
/// as the same user could also edit this file or stop Nocturnal.
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
    /// When Nocturnal asked the machine to sleep.
    pub sleep_requested_at: Option<u64>,
    /// Set only once a sleep actually happened (seen as a gap in Nocturnal's own ticks), never on request alone.
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
    /// While the lid is shut: the running lid-shut draw estimate (watts) and when it was last updated.
    closed_avg: Option<(f64, u64)>,
    pub outbox: Vec<Announcement>,
    /// Sessions agents reported through their hooks, from the last sample.
    pub agent_events: Vec<crate::events::AgentEvent>,
    announced_waits: HashSet<String>,
    ticks: u64,
    config_mtime: Option<std::time::SystemTime>,
}

pub const DEFAULT_FULL_WH: f64 = 55.0;
pub const DEFAULT_CLOSED_W: f64 = 3.0;

impl<P: Platform> Engine<P> {
    /// `root` is Nocturnal's folder (tests pass a temporary one).
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
                    "Nocturnal is using its defaults. Your file was saved as {}",
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
            closed_avg: None,
            outbox: vec![],
            agent_events: vec![],
            announced_waits: Default::default(),
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
                "Safety settings can only be loosened from the Nocturnal menu: {}.",
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
        // A long gap between ticks means the machine was asleep: that confirms a sleep Nocturnal asked for.
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
            self.learn_draw(&b, now);
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
            self.apply_agent_events(now);
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

    // MARK: battery

    fn learn_draw(&mut self, b: &Battery, now: u64) {
        if !b.discharging() || !b.watts.is_finite() || b.watts <= 0.3 || b.watts > 200.0 {
            return;
        }
        if self.lid_closed && self.holding {
            // Work comes in bursts, so the live reading can swing between 3 W and 25 W from one minute to the
            // next. The estimate follows it slowly, and the learned figure keeps that average, not the last burst.
            let (avg, since) = self.closed_avg.unwrap_or((self.closed_watts(), now));
            let avg = time_average(avg, since, b.watts, now);
            self.closed_avg = Some((avg, now));
            self.closed_draw = Some(avg);
        } else if !self.lid_closed {
            self.open_draw = Some(
                self.open_draw
                    .map_or(b.watts, |w| w * 0.85 + b.watts * 0.15),
            );
        } else {
            return;
        }
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
            if busy && a.state == Some(crate::events::AgentState::Waiting) {
                return Some(format!("{name} is waiting for you"));
            }
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
            let what = match a.state {
                Some(crate::events::AgentState::Finished) => "finished",
                Some(crate::events::AgentState::Waiting) => "is still waiting",
                _ => "went idle",
            };
            return Some(format!(
                "{name} {what} · sleeps in {}",
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
                self.watchdog_warning = Some("The safety watchdog isn't installed, so a crash wouldn't be cleaned up automatically. Run `nocturnal install`.".into());
            }
            _ => self.watchdog_warning = None,
        }
    }

    pub fn active_agent(&self, now: u64) -> Option<&Session> {
        let window = self.cfg.quiet_minutes as u64 * 60;
        self.watcher.sessions.iter().find(|s| {
            self.counts(s)
                && (!self.cfg.sleep_when_done
                    || s.last_active > 0 && now.saturating_sub(s.last_active) < window)
        })
    }

    pub fn evaluate(&mut self, now: u64) {
        match self.platform.ready() {
            Ok(()) => self.setup_error = None,
            Err(e) => {
                self.setup_error = Some(e);
                if self.holding {
                    self.end_hold(now);
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
            // Holds are explicit requests (a timer, `nocturnal run`, MCP), so they work in any mode.
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
            self.end_hold(now);
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

    fn end_hold(&mut self, now: u64) {
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
        }
    }

    // MARK: sessions

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

    /// Ends one hold by id, or all of them. Returns how many ended.
    pub fn release_hold(&mut self, id: Option<&str>) -> usize {
        self.end_holds_where(|h| id.is_none_or(|id| h.id == id))
    }

    pub(super) fn end_holds_where(&mut self, ends: impl Fn(&Hold) -> bool) -> usize {
        let before = self.holds.len();
        self.holds.retain(|h| !ends(h));
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
            "numbers": self.phone_numbers(),
            "lidClosed": self.lid_closed,
            "mode": self.cfg.mode,
            "alwaysUntil": self.on_until().map(crate::format::clock),
            "preset": self.cfg.preset,
            "snoozed": self.snoozed,
            "holds": self.holds.iter().map(|h| h.reason.clone()).collect::<Vec<_>>(),
            // The phone lists these and can end each one.
            "holdList": self.holds.iter().map(|h| json!({
                "id": h.id, "reason": h.reason.chars().take(60).collect::<String>(),
                "until": h.until.map(crate::format::clock),
            })).collect::<Vec<_>>(),
            "agents": self.watcher.sessions.iter().map(|s| {
                let mut a = json!({
                    "id": s.kind.id, "name": s.kind.name, "working": s.working(now),
                    "keeps": !self.cfg.track_only.contains(&s.kind.id), "instances": s.instances,
                    "state": s.state.map(|x| x.as_str()),
                });
                if let Some(left) = self.sleeps_in(s, now) {
                    a["sleepsIn"] = json!(left.div_ceil(60));
                }
                a
            }).collect::<Vec<_>>(),
            "watch": self.watch_candidates().into_iter().map(|(id, name, on)| json!({ "id": id, "name": name, "on": on })).collect::<Vec<_>>(),
            // The phone's Apps tab: busy apps with their lid-shut rule, which it can change.
            "apps": self.busy_apps(8).into_iter().map(|a| json!({
                "id": a.id, "name": a.name, "w": a.watts.map(|w| (w * 10.0).round() / 10.0),
                "rule": a.rule, "custom": a.custom,
            })).collect::<Vec<_>>(),
            "sessions": self.stats.sessions.iter().rev().take(5).map(|r| json!({
                "when": match &r.agent {
                    Some(a) => format!("{} · {a}", crate::format::when(r.date, now)),
                    None => crate::format::when(r.date, now),
                },
                "line": session_line(r),
            })).collect::<Vec<_>>(),
            "warnings": warnings,
            "host": hostname(),
            "checkIn": self.cfg.check_in_minutes,
            "wakeAt": self.cfg.wake_at.map(crate::format::clock),
            "wakeFor": self.cfg.wake_for_minutes,
        })
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
}

/// How long "serious" heat with the lid shut is tolerated before the laptop is put to sleep.
pub const HOT_GRACE_SECS: u64 = 300;

/// Time constant of the lid-shut draw estimate, in seconds.
const CLOSED_DRAW_TAU: f64 = 180.0;

/// One step of an exponential average weighted by the time since the last step.
fn time_average(avg: f64, since: u64, reading: f64, now: u64) -> f64 {
    // A long gap (the machine slept) counts as one minute, not as hours that agreed with this one reading.
    let dt = now.saturating_sub(since).min(60) as f64;
    avg + (1.0 - (-dt / CLOSED_DRAW_TAU).exp()) * (reading - avg)
}

/// Processes Nocturnal never slows or pauses, whatever the rules say: the desktop, audio, input and Nocturnal itself.
pub const SYSTEM_NEVER: &[&str] = &[
    "nocturnal",
    "nocturnal-app",
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
            "Ran {}, then Nocturnal asked it to sleep",
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

/// One past lid-shut session for the menu's Recent list and the phone: "1 h 05 min closed · used 12% · then slept".
pub fn session_line(r: &SessionRecord) -> String {
    let mut s = format!("{} closed", crate::format::minutes(r.closed_minutes));
    if let (Some(a), Some(b)) = (r.start_percent, r.end_percent) {
        if a >= b {
            s.push_str(&format!(" · used {}%", a - b));
        }
    }
    if r.slept {
        s.push_str(" · then slept");
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
    // The app is gone, so nothing will end Approve everything when the work finishes or its time is up.
    crate::approve::end_unwatched(&crate::approve::Paths::new(root));
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
mod tests;
