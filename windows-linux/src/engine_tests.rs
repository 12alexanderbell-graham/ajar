//! Engine behaviour against a scripted platform: every rule, edge and failure path the macOS app's audit
//! turned up, replayed here so the Windows and Linux builds can't regress on them.

use super::*;
use crate::agents::{known, Session};
use crate::platform::mock::Mock;
use std::process::{Child, Command};

fn root(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("ajar-engine-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    d
}

fn engine(name: &str, m: Mock) -> Engine<Mock> {
    Engine::new(m, root(name), vec![])
}

fn agent(e: &mut Engine<Mock>, last_active: u64) {
    let kind = known().into_iter().find(|k| k.id == "claude-code").unwrap();
    e.watcher.sessions = vec![Session { kind, pid: 4242, cpu: 40.0, last_active, project: None, tool_running: false, instances: 1 }];
}

fn proc(pid: u32, ppid: u32, name: &str, start: u64) -> Proc {
    Proc { pid, ppid, name: name.into(), start, mine: true, ..Default::default() }
}

/// A child process that idles for ~30 s (Windows has no `sleep` command outside Git Bash).
fn sleeper() -> Child {
    #[cfg(windows)]
    let mut c = {
        let mut c = Command::new("cmd");
        c.args(["/C", "ping", "-n", "31", "127.0.0.1"]);
        c
    };
    #[cfg(not(windows))]
    let mut c = {
        let mut c = Command::new("sleep");
        c.arg("30");
        c
    };
    c.stdout(std::process::Stdio::null()).spawn().expect("spawn a sleeping child")
}

fn battery(percent: u32, on_ac: bool) -> Option<Battery> {
    Some(Battery { percent, watts: if on_ac { 0.0 } else { 8.0 }, on_ac, charging: false, full_wh: Some(60.0) })
}

#[test]
fn working_agent_holds_and_finished_agent_sleeps_a_closed_laptop() {
    let mut e = engine("finish", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(e.holding && e.platform.holding);
    e.platform.lid = true;
    e.tick(now + 2, None);
    assert!(e.receipt.is_some(), "closing while holding starts a receipt");
    // Agent quiet for longer than the 5-minute window.
    e.tick(now + 6 * 60 + 2, None);
    assert!(!e.holding && !e.platform.holding);
    assert_eq!(e.platform.slept, 1, "a closed laptop is put to sleep exactly once");
    e.tick(now + 6 * 60 + 4, None);
    assert_eq!(e.platform.slept, 1, "no repeat sleeps on later ticks");
}

#[test]
fn lid_open_ends_session_with_receipt() {
    let mut e = engine("receipt", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    e.platform.battery = battery(71, false);
    agent(&mut e, now + 1200);
    e.platform.lid = false;
    e.tick(now + 1200, None);
    assert_eq!(e.stats.sessions.len(), 1);
    assert!((e.stats.sessions[0].closed_minutes - 20.0).abs() < 0.1);
    let a = e.outbox.last().unwrap();
    assert!(a.body.contains("used 9%"), "{}", a.body);
    assert!(a.body.contains("Claude Code"), "{}", a.body);
}

#[test]
fn battery_limit_has_a_three_percent_band() {
    let mut m = Mock::laptop();
    m.battery = battery(15, false);
    let mut e = engine("floor", m);
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(!e.holding);
    assert!(e.blocked.as_deref().unwrap().contains("15%"));
    e.platform.battery = battery(17, false);
    agent(&mut e, now + 2);
    e.tick(now + 2, None);
    assert!(!e.holding, "still inside the band, no flapping");
    e.platform.battery = battery(19, false);
    agent(&mut e, now + 4);
    e.tick(now + 4, None);
    assert!(e.holding, "above floor + 3 holds again");
}

#[test]
fn floor_zero_never_stops_and_override_works_until_charging() {
    let mut m = Mock::laptop();
    m.battery = battery(3, false);
    let mut e = engine("floor0", m);
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(!e.holding);
    e.override_floor(true);
    assert!(e.holding, "override lets it continue below the limit");
    e.platform.battery = Some(Battery { percent: 4, watts: 0.0, on_ac: true, charging: true, full_wh: None });
    e.tick(now + 2, None);
    assert!(!e.floor_override, "plugging in clears the override");
    e.update(|c| c.battery_floor = 0);
    e.platform.battery = battery(2, false);
    agent(&mut e, now + 4);
    e.tick(now + 4, None);
    assert!(e.holding, "0 = never stop for battery");
}

#[test]
fn heat_forces_max_battery_then_restores_and_critical_stops() {
    let mut e = engine("heat", Mock::laptop());
    let now = crate::now();
    let spotify = sleeper();
    let sp = spotify.id();
    let start = procs::start_time(sp).unwrap();
    e.procs = vec![proc(sp, 1, "slack", start)];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.platform.slowed.contains(&sp), "Balanced slows Slack");
    assert!(!e.platform.paused.contains(&sp));
    e.platform.thermal = Some(Thermal::Serious);
    agent(&mut e, now + 2);
    e.tick(now + 2, None);
    assert!(e.platform.paused.contains(&sp), "hot: Max Battery pauses it");
    assert!(!e.platform.slowed.contains(&sp), "and the slow is undone first");
    e.platform.thermal = Some(Thermal::Normal);
    agent(&mut e, now + 4);
    e.tick(now + 4, None);
    assert!(!e.platform.paused.contains(&sp) && e.platform.slowed.contains(&sp), "cooled: back to Balanced");
    e.platform.thermal = Some(Thermal::Critical);
    agent(&mut e, now + 6);
    e.tick(now + 6, None);
    assert!(!e.holding, "critical heat stops holding");
    assert!(e.platform.slowed.is_empty() && e.platform.paused.is_empty(), "everything put back");
    assert_eq!(e.platform.slept, 1);
    drop(spotify);
}

#[test]
fn serious_heat_with_the_lid_shut_sleeps_after_five_minutes() {
    let mut e = engine("hotlong", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.holding);
    e.platform.thermal = Some(Thermal::Serious);
    agent(&mut e, now + 10);
    e.tick(now + 10, None);
    assert!(e.holding, "serious heat first tightens the rules");
    agent(&mut e, now + 10 + crate::engine::HOT_GRACE_SECS - 5);
    e.tick(now + 10 + crate::engine::HOT_GRACE_SECS - 5, None);
    assert!(e.holding, "still inside the grace period");
    agent(&mut e, now + 10 + crate::engine::HOT_GRACE_SECS);
    e.tick(now + 10 + crate::engine::HOT_GRACE_SECS, None);
    assert!(!e.holding, "hot for 5 minutes with the lid shut: sleeps");
    assert!(e.blocked.as_deref().unwrap_or("").contains("Too hot"));
}

#[test]
fn reused_pid_is_never_touched_on_restore() {
    let mut e = engine("reuse", Mock::laptop());
    let now = crate::now();
    let child = sleeper();
    let pid = child.id();
    let start = procs::start_time(pid).unwrap();
    e.update(|c| c.preset = Preset::Longest);
    e.procs = vec![proc(pid, 1, "slack", start)];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.platform.paused.contains(&pid));
    // Pretend Discord was replaced by an unrelated process with the same pid.
    e.touched[0].start = start + 1;
    e.platform.lid = false;
    e.tick(now + 2, None);
    assert!(e.platform.paused.contains(&pid), "a different process with the reused pid is left alone");
    drop(child);
}

#[test]
fn agents_their_ancestors_and_hold_targets_are_never_paused() {
    let mut e = engine("protect", Mock::laptop());
    let now = crate::now();
    e.update(|c| c.preset = Preset::Longest);
    // slack (the agent's ancestor) and discord (unrelated).
    e.procs = vec![proc(500, 1, "slack", 1), proc(501, 500, "claude", 1), proc(600, 1, "discord", 1)];
    e.watcher.protected = [500, 501].into_iter().collect();
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(!e.platform.paused.contains(&500), "agent's ancestor kept running");
    assert!(e.platform.paused.contains(&600));
}

#[test]
fn system_processes_are_never_touched_even_with_a_rule() {
    let mut e = engine("system", Mock::laptop());
    let r = e.handle("rule", &json!({ "app": "explorer.exe", "rule": "pause" }));
    assert_eq!(r["ok"], false);
    e.cfg.app_rules.insert("gnome-shell".into(), AppRule::Pause); // hand-edited config
    let now = crate::now();
    e.procs = vec![proc(700, 1, "gnome-shell", 1)];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.platform.paused.is_empty());
}

#[test]
fn failed_release_is_retried_every_tick() {
    let mut e = engine("retry", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.fail_end = true;
    e.update(|c| c.mode = Mode::Off);
    assert!(!e.holding && e.pending_release);
    e.tick(now + 2, None);
    assert!(e.pending_release, "still failing");
    e.platform.fail_end = false;
    e.tick(now + 4, None);
    assert!(!e.pending_release && !e.platform.holding, "released once the platform allows it");
}

#[test]
fn failed_begin_reports_and_does_not_pretend() {
    let mut m = Mock::laptop();
    m.fail_begin = true;
    let mut e = engine("beginfail", m);
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(!e.holding);
    assert!(e.setup_error.is_some());
    let (keeps, _, _) = e.outcome();
    assert!(!keeps, "never claims the lid is safe to close when the hold failed");
}

#[test]
fn not_ready_blocks_everything() {
    let mut m = Mock::laptop();
    m.ready_error = Some("no logind".into());
    let mut e = engine("notready", m);
    e.set_mode(Mode::On);
    assert!(!e.holding);
    assert_eq!(e.outcome().2, "no logind");
}

#[test]
fn always_with_minutes_returns_to_the_previous_mode() {
    let mut e = engine("always", Mock::laptop());
    e.update(|c| c.mode = Mode::Off);
    e.stay_awake(Some(30));
    assert!(e.holding && e.cfg.mode == Mode::On);
    let later = crate::now() + 31 * 60;
    e.tick(later, None);
    assert_eq!(e.cfg.mode, Mode::Off, "goes back to Off, not to When Busy");
    assert!(!e.holding);
}

#[test]
fn always_timer_survives_a_restart() {
    let name = "always-restart";
    let mut e = engine(name, Mock::laptop());
    e.stay_awake(Some(60));
    let until = e.on_until().unwrap();
    let e2 = Engine::new(Mock::laptop(), root_keep(name), vec![]);
    assert_eq!(e2.on_until(), Some(until));
    assert_eq!(e2.cfg.mode, Mode::On);
}

fn root_keep(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("ajar-engine-{name}-{}", std::process::id()))
}

#[test]
fn holds_work_in_off_mode_and_end_with_their_process() {
    let mut e = engine("holdpid", Mock::laptop());
    e.update(|c| c.mode = Mode::Off);
    let mut child = sleeper();
    let h = e.add_hold("Running tests", None, Some(child.id())).unwrap();
    assert!(e.holding);
    assert_eq!(e.hold_reason.as_deref(), Some("Running tests"));
    child.kill().unwrap();
    child.wait().unwrap();
    e.tick(crate::now(), None);
    assert!(!e.holding, "hold {} ended with its process", h.id);
    assert!(e.add_hold("x", None, Some(child.id())).is_err(), "can't tie a hold to a dead pid");
}

#[test]
fn timed_hold_expires() {
    let mut e = engine("holdtime", Mock::laptop());
    e.update(|c| c.mode = Mode::Off);
    e.add_hold("Build", Some(10.0), None).unwrap();
    assert!(e.holding);
    e.tick(crate::now() + 11 * 60, None);
    assert!(!e.holding);
}

#[test]
fn only_on_power() {
    let mut e = engine("onlyac", Mock::laptop());
    e.update(|c| c.only_on_power = true);
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(!e.holding);
    e.platform.battery = battery(80, true);
    agent(&mut e, now + 2);
    e.tick(now + 2, None);
    assert!(e.holding);
}

#[test]
fn track_only_agents_do_not_keep_it_awake() {
    let mut e = engine("track", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.toggle_track_only("claude-code");
    e.tick(now, None);
    assert!(!e.holding);
    e.toggle_track_only("claude-code");
    agent(&mut e, now + 2);
    e.tick(now + 2, None);
    assert!(e.holding);
}

#[test]
fn crash_recovery_resumes_paused_apps_and_restores_settings() {
    let name = "crash";
    let r = root(name);
    std::fs::create_dir_all(&r).unwrap();
    let child = sleeper();
    let pid = child.id();
    let start = procs::start_time(pid).unwrap();
    state::save_json(&r.join("touched.json"), &vec![
        Touched { pid, exe: procs::name_of(pid).unwrap_or_default(), start, paused: true, previous: 0, unit: None },
        Touched { pid: 999_999, exe: "gone".into(), start: 1, paused: true, previous: 0, unit: None },
    ]);
    state::save_json(&r.join("restore.json"), &Restore { power_profile: Some("balanced".into()), ..Default::default() });
    let mut m = Mock::laptop();
    m.paused = vec![pid];
    m.low_power = true;
    let e = Engine::new(m, r.clone(), vec![]);
    assert!(e.platform.paused.is_empty(), "the frozen app is resumed");
    assert!(!e.platform.low_power, "low power undone");
    assert!(!r.join("touched.json").exists() && !r.join("restore.json").exists());
    drop(child);
}

#[test]
fn watchdog_waits_while_alive_and_restores_when_dead() {
    let r = root("watchdog");
    std::fs::create_dir_all(&r).unwrap();
    let mut m = Mock::laptop();
    state::touch(&r.join("alive"));
    state::save_json(&r.join("restore.json"), &Restore { power_profile: Some("balanced".into()), ..Default::default() });
    m.low_power = true;
    assert_eq!(run_watchdog(&mut m, &r, false), "alive");
    assert!(m.low_power);
    // Old heartbeat from a process that is still running (machine just woke up): wait.
    let me = std::process::id();
    let my_start = procs::start_time(me).unwrap();
    std::fs::write(r.join("alive"), format!("{} {me} {my_start}", crate::now() - 300)).unwrap();
    assert_eq!(run_watchdog(&mut m, &r, false), "alive");
    // Same age, but the process is gone (or the pid now belongs to something else): restore.
    std::fs::write(r.join("alive"), format!("{} {me} {}", crate::now() - 300, my_start + 1)).unwrap();
    assert_eq!(run_watchdog(&mut m, &r, false), "restored");
    assert!(!m.low_power);
    // A hung app (same process, 20 minutes silent) is restored too.
    state::save_json(&r.join("restore.json"), &Restore { power_profile: Some("balanced".into()), ..Default::default() });
    m.low_power = true;
    std::fs::write(r.join("alive"), format!("{} {me} {my_start}", crate::now() - 1200)).unwrap();
    assert_eq!(run_watchdog(&mut m, &r, false), "restored");
}

#[test]
fn hand_edited_config_is_picked_up() {
    let mut e = engine("reload", Mock::laptop());
    std::thread::sleep(std::time::Duration::from_millis(20));
    let mut c = e.cfg.clone();
    c.battery_floor = 40;
    std::fs::write(e.path("config.json"), c.to_json()).unwrap();
    // mtime resolution can be coarse; nudge it forward.
    let f = std::fs::File::options().write(true).open(e.path("config.json")).unwrap();
    f.set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(2)).unwrap();
    for i in 0..5 {
        e.tick(crate::now() + i, None);
    }
    assert_eq!(e.cfg.battery_floor, 40);
}

#[test]
fn corrupt_files_never_crash_startup() {
    let r = root("corrupt");
    std::fs::create_dir_all(&r).unwrap();
    for f in ["config.json", "runtime.json", "stats.json", "touched.json", "restore.json", "learned.json"] {
        std::fs::write(r.join(f), "{not json").unwrap();
    }
    let e = Engine::new(Mock::laptop(), r, vec![]);
    assert_eq!(e.cfg, Config::default());
}

#[test]
fn learned_draw_rejects_garbage() {
    let r = root("learned");
    std::fs::create_dir_all(&r).unwrap();
    std::fs::write(r.join("learned.json"), "[1e9, -4]").unwrap();
    let e = Engine::new(Mock::laptop(), r, vec![]);
    assert!(e.open_draw.is_none() && e.closed_draw.is_none());
}

#[test]
fn desktop_without_lid_reads_stays_awake() {
    let mut m = Mock::laptop();
    m.has_lid = false;
    m.battery = None;
    let mut e = engine("desktop", m);
    e.set_mode(Mode::On);
    let (keeps, head, _) = e.outcome();
    assert!(keeps);
    assert_eq!(head, "Stays awake");
    assert!(e.battery_line().is_none());
}

#[test]
fn ajar_sleeps_the_machine_when_the_desktop_leaves_it_to_ajar() {
    let mut m = Mock::laptop();
    m.desktop_sleeps_on_close = Some(false);
    let mut e = engine("kde", m);
    let now = crate::now();
    e.update(|c| c.mode = Mode::Auto);
    e.platform.lid = true;
    e.tick(now, None);
    assert_eq!(e.platform.slept, 1, "nothing working: closing the lid sleeps");
    e.platform.lid = false;
    e.tick(now + 2, None);
    agent(&mut e, now + 4);
    e.tick(now + 4, None);
    e.platform.lid = true;
    e.tick(now + 6, None);
    assert_eq!(e.platform.slept, 1, "agent working: stays awake");
}

#[test]
fn infinity_on_charger_with_unplugged_estimate() {
    let mut m = Mock::laptop();
    m.battery = Some(Battery { percent: 90, watts: 0.0, on_ac: true, charging: false, full_wh: Some(60.0) });
    let mut e = engine("infinity", m);
    e.tick(crate::now(), None);
    let line = e.battery_line().unwrap();
    assert!(line.contains('∞') && line.contains("if unplugged"), "{line}");
}

#[test]
fn hours_left_respects_the_floor() {
    let mut e = engine("hours", Mock::laptop());
    e.tick(crate::now(), None);
    // 80% - 15% floor = 65% of 60 Wh = 39 Wh at 3 W = 13 h.
    assert!((e.hours_left(3.0).unwrap() - 13.0).abs() < 1e-9);
    assert!(e.hours_left(0.0).is_none());
    assert!(e.hours_left(f64::NAN).is_none());
}

#[test]
fn commands_validate_their_input() {
    let mut e = engine("commands", Mock::laptop());
    assert_eq!(e.handle("set", &json!({ "key": "heat_guard", "value": false }))["ok"], false, "heat guard can't be turned off remotely");
    assert!(e.cfg.heat_guard);
    assert_eq!(e.handle("set", &json!({ "key": "battery_floor", "value": "abc" }))["ok"], false);
    assert_eq!(e.handle("set", &json!({ "key": "battery_floor", "value": 500 }))["ok"], true);
    assert_eq!(e.cfg.battery_floor, 80, "clamped");
    assert_eq!(e.handle("set", &json!({ "key": "battery_floor", "value": 10 }))["ok"], false, "commands can't lower the limit");
    assert_eq!(e.handle("override_floor", &json!({}))["ok"], false, "commands can't go below the limit");
    assert_eq!(e.handle("override_floor", &json!({ "on": false }))["ok"], true);
    assert_eq!(e.handle("set", &json!({ "key": "ntfy_topic", "value": "../../x" }))["ok"], false);
    assert_eq!(e.handle("mode", &json!({ "mode": "sideways" }))["ok"], false);
    assert_eq!(e.handle("mode", &json!({ "mode": "always", "minutes": "nan" }))["ok"], true);
    assert!(e.on_until().is_none(), "unparseable minutes = no limit, never a NaN timer");
    assert_eq!(e.handle("hold", &json!({ "pid": -5 }))["ok"], false);
    assert_eq!(e.handle("hold", &json!({ "minutes": 1e300 }))["ok"], true);
    let h = e.holds.last().unwrap().clone();
    assert!(h.until.unwrap() <= crate::now() + 7 * 24 * 3600 + 1, "capped at 7 days");
    assert_eq!(e.handle("release", &json!({}))["released"], 1);
    assert_eq!(e.handle("rule", &json!({ "app": "C:\\Apps\\Spotify.exe", "rule": "pause" }))["app"], "spotify");
    assert_eq!(e.handle("rule", &json!({ "app": "spotify", "rule": "default" }))["ok"], true);
    assert!(e.cfg.app_rules.is_empty());
    assert_eq!(e.handle("nonsense", &json!({}))["ok"], false);
    let s = e.handle("status", &json!({}));
    assert_eq!(s["platform"], "mock");
    assert!(s["status"].as_str().unwrap().len() > 5);
}

#[test]
fn idle_notice_waits_two_minutes_and_never_says_finished() {
    let mut e = engine("done", Mock::laptop());
    let now = crate::now();
    e.working_since.insert("claude-code".into(), (now - 30, "Claude Code".into()));
    e.watcher.sessions.clear();
    e.detect_finished(now);
    e.detect_finished(now + 130);
    assert!(e.outbox.is_empty(), "30 s of work isn't worth a notification");
    e.working_since.insert("claude-code".into(), (now - 600, "Claude Code".into()));
    e.detect_finished(now);
    assert!(e.outbox.is_empty(), "not announced the moment it goes quiet");
    // Busy again within 2 minutes: same stretch of work, nothing announced.
    agent(&mut e, now + 60);
    e.detect_finished(now + 60);
    assert!(e.outbox.is_empty());
    assert_eq!(e.working_since["claude-code"].0, now - 600, "keeps the original start");
    e.watcher.sessions.clear();
    e.detect_finished(now + 80);
    e.detect_finished(now + 210);
    assert_eq!(e.outbox.len(), 1);
    assert_eq!(e.outbox[0].title, "Claude Code closed", "process gone: says closed, not finished");
    assert!(e.outbox[0].body.starts_with("Busy for 11 min"), "{}", e.outbox[0].body);
}

#[test]
fn quiet_countdown_survives_the_agent_exiting() {
    let mut e = engine("vanish", Mock::laptop());
    let now = crate::now();
    e.last_work = Some((now, "Claude Code".into()));
    e.watcher.sessions.clear();
    e.tick(now + 10, None);
    assert!(e.holding, "agent exited 10 s after working: still inside the 5 min window");
    assert!(e.hold_reason.as_deref().unwrap().contains("sleeps in 5 min"), "{:?}", e.hold_reason);
    e.tick(now + 301, None);
    assert!(!e.holding, "window over");
}

#[test]
fn failed_restores_stay_journaled_and_are_retried() {
    let mut e = engine("restorefail", Mock::laptop());
    let now = crate::now();
    let child = sleeper();
    let pid = child.id();
    let start = procs::start_time(pid).unwrap();
    e.update(|c| c.preset = Preset::Longest);
    e.procs = vec![proc(pid, 1, "slack", start)];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.platform.paused.contains(&pid));
    e.platform.fail_restore = true;
    e.platform.lid = false;
    e.tick(now + 2, None);
    assert!(e.platform.paused.contains(&pid), "resume refused");
    assert_eq!(e.unrestored().len(), 1, "kept and shown, not forgotten");
    assert!(e.path("touched.json").exists(), "still on disk for the watchdog");
    e.platform.fail_restore = false;
    e.tick(now + 4, None);
    assert!(!e.platform.paused.contains(&pid), "retried and resumed");
    assert!(e.unrestored().is_empty() && !e.path("touched.json").exists());
    drop(child);
}

#[test]
fn journal_is_written_before_the_app_is_touched() {
    let mut e = engine("writeahead", Mock::laptop());
    let now = crate::now();
    let child = sleeper();
    let pid = child.id();
    let start = procs::start_time(pid).unwrap();
    // Make the journal unwritable: Ajar must not pause anything it can't record.
    std::fs::create_dir_all(e.path("touched.json")).unwrap();
    e.update(|c| c.preset = Preset::Longest);
    e.procs = vec![proc(pid, 1, "slack", start)];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    assert!(e.platform.paused.is_empty(), "no record, no pause");
    drop(child);
}

#[test]
fn changing_preset_while_closed_only_touches_what_changes() {
    let mut e = engine("delta", Mock::laptop());
    let now = crate::now();
    let (a, b) = (sleeper(), sleeper());
    let (pa, pb) = (a.id(), b.id());
    e.update(|c| c.preset = Preset::Longest);
    e.procs = vec![proc(pa, 1, "slack", procs::start_time(pa).unwrap()), proc(pb, 1, "chrome", procs::start_time(pb).unwrap())];
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now, None);
    e.platform.log.clear();
    let slowed_before = e.platform.slowed.clone();
    e.update(|c| {
        c.app_rules.insert("slack".into(), AppRule::Pause); // same as before for slack
    });
    assert!(e.platform.paused.contains(&pa));
    assert!(!e.platform.log.iter().any(|l| l.starts_with("resume")), "slack wasn't woken and frozen again: {:?}", e.platform.log);
    assert_eq!(e.platform.slowed, slowed_before, "chrome untouched");
    drop((a, b));
}

#[test]
fn sleep_is_only_recorded_once_it_happens() {
    let mut e = engine("confirm", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    // Ticks 20 s apart (the app ticks every 2 s; a gap over 45 s means the machine slept).
    let mut t = now + 1;
    while e.platform.slept == 0 && t < now + 1000 {
        e.tick(t, None);
        t += 20;
    }
    assert_eq!(e.platform.slept, 1, "agent quiet past the window: Ajar asks to sleep");
    let asked = e.receipt.as_ref().unwrap().sleep_requested_at.unwrap();
    assert!(e.receipt.as_ref().unwrap().slept_at.is_none(), "asked, not confirmed");
    while t <= asked + 62 {
        e.tick(t, None);
        t += 20;
    }
    assert_eq!(e.platform.slept, 2, "still running a minute later with the lid shut: asks again (t-asked={}, holding={}, receipt={:?})", t - asked, e.holding, e.receipt);
    // Machine actually slept: next tick comes 2 h later.
    e.platform.lid = false;
    e.tick(t + 7200, None);
    assert!(e.stats.sessions.last().unwrap().slept, "confirmed by the gap");
}

#[test]
fn settings_file_cannot_weaken_safety() {
    let mut e = engine("safety", Mock::laptop());
    let mut c = e.cfg.clone();
    c.heat_guard = false;
    c.battery_floor = 0;
    c.preset = Preset::Speed; // a harmless change in the same edit still applies
    std::fs::write(e.path("config.json"), c.to_json()).unwrap();
    let f = std::fs::File::options().write(true).open(e.path("config.json")).unwrap();
    f.set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(5)).unwrap();
    for i in 0..5 {
        e.tick(crate::now() + i, None);
    }
    assert!(e.cfg.heat_guard);
    assert_eq!(e.cfg.battery_floor, 15);
    assert_eq!(e.cfg.preset, Preset::Speed);
    assert!(e.outbox.iter().any(|a| a.title.contains("ignored")));
    // From the menu it works.
    e.update(|c| c.heat_guard = false);
    let e2 = Engine::new(Mock::laptop(), root_keep("safety"), vec![]);
    assert!(!e2.cfg.heat_guard, "a menu change is the new baseline");
}

#[test]
fn corrupt_settings_are_kept_aside_not_overwritten() {
    let r = root("corruptcfg");
    std::fs::create_dir_all(&r).unwrap();
    std::fs::write(r.join("config.json"), "{\"mode\": \"always\",").unwrap();
    let e = Engine::new(Mock::laptop(), r.clone(), vec![]);
    assert!(std::fs::read_dir(&r).unwrap().flatten().any(|f| f.file_name().to_string_lossy().starts_with("config.broken-")));
    assert!(e.outbox.iter().any(|a| a.title.contains("couldn't be read")));
}

#[test]
fn hold_drift_is_reported() {
    let mut e = engine("drift", Mock::laptop());
    let now = crate::now();
    e.set_mode(Mode::On);
    e.platform.hold_drift = Some("lid setting changed".into());
    for i in 0..8 {
        e.tick(now + i * 2, None);
    }
    assert_eq!(e.hold_warning.as_deref(), Some("lid setting changed"));
}

#[test]
fn docked_with_the_lid_shut_counts_as_open() {
    let mut e = engine("docked", Mock::laptop());
    let now = crate::now();
    let child = sleeper();
    let pid = child.id();
    e.update(|c| c.preset = Preset::Longest);
    e.procs = vec![proc(pid, 1, "slack", procs::start_time(pid).unwrap())];
    e.platform.docked = true;
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now + 2, None);
    assert!(!e.lid_closed, "external display in use");
    assert!(e.platform.paused.is_empty(), "nothing paused under someone using the machine");
    e.update(|c| c.mode = Mode::Off);
    assert_eq!(e.platform.slept, 0, "never put to sleep while docked");
    drop(child);
}

#[test]
fn no_sleep_after_work_when_the_persons_own_setting_keeps_it_running() {
    let mut m = Mock::laptop();
    m.user_keeps_awake_on_close = true;
    let mut e = engine("userdonothing", m);
    e.set_mode(Mode::On);
    e.platform.lid = true;
    e.tick(crate::now(), None);
    e.update(|c| c.mode = Mode::Off);
    assert_eq!(e.platform.slept, 0);
}

#[test]
fn sleep_now_snooze_ends_when_the_machine_wakes() {
    let mut e = engine("snooze", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    assert!(e.holding);
    e.sleep_now();
    assert!(!e.holding && e.snoozed);
    assert_eq!(e.platform.slept, 1, "lid open: sleeps right away");
    // Woken from the keyboard an hour later, lid never closed.
    agent(&mut e, now + 3600);
    e.tick(now + 3600, None);
    assert!(!e.snoozed && e.holding, "agents count again after waking");
}

#[test]
fn an_agent_can_only_release_its_own_holds() {
    let mut e = engine("ownholds", Mock::laptop());
    e.update(|c| c.mode = Mode::Off);
    let me = std::process::id();
    let mine = e.add_hold("mine", None, Some(me)).unwrap();
    e.add_hold("the person's", None, None).unwrap();
    let other = e.holds[1].id.clone();
    assert_eq!(e.handle("release_own", &json!({ "id": other, "pid": me }))["ok"], false);
    assert_eq!(e.handle("release_own", &json!({ "id": mine.id, "pid": me }))["ok"], true);
    assert_eq!(e.holds.len(), 1);
    assert_eq!(e.handle("release_pid", &json!({ "pid": me }))["released"], 0, "release-all from an agent only covers its own");
    assert!(e.holding);
}

#[test]
fn phone_track_sets_what_it_asks_and_old_pages_still_toggle() {
    let mut e = engine("track-keeps", Mock::laptop());
    agent(&mut e, crate::now());
    let track_only = |e: &Engine<Mock>| e.cfg.track_only.contains(&"claude-code".to_string());
    for _ in 0..2 {
        assert_eq!(e.handle("track", &json!({ "agent": "claude-code", "keeps": false }))["ok"], true);
        assert!(track_only(&e), "keeps:false is a value, not a toggle");
    }
    for _ in 0..2 {
        e.handle("track", &json!({ "agent": "claude-code", "keeps": true }));
        assert!(!track_only(&e));
    }
    e.handle("track", &json!({ "agent": "claude-code" }));
    assert!(track_only(&e), "without keeps it toggles");
    e.handle("track", &json!({ "agent": "claude-code" }));
    assert!(!track_only(&e));
    assert_eq!(e.cfg.track_only.iter().filter(|x| *x == "claude-code").count(), 0);
}

#[test]
fn watching_from_the_phone_keeps_the_display_name() {
    let mut e = engine("watch-name", Mock::laptop());
    e.update(|c| c.watched_apps.push(crate::config::WatchedApp { id: "chrome".into(), name: "Google Chrome".into() }));
    e.watch_offer = vec![("spotify".into(), "Spotify".into())];
    e.handle("watch", &json!({ "app": "spotify" }));
    e.handle("watch", &json!({ "app": "chrome", "remove": true }));
    e.handle("watch", &json!({ "app": "chrome" }));
    let names: Vec<(String, String)> = e.cfg.watched_apps.iter().map(|w| (w.id.clone(), w.name.clone())).collect();
    assert!(names.contains(&("spotify".into(), "Spotify".into())), "{names:?}");
    e.update(|c| c.watched_apps.push(crate::config::WatchedApp { id: "code".into(), name: "Visual Studio Code".into() }));
    e.handle("watch", &json!({ "app": "code" }));
    assert!(e.cfg.watched_apps.iter().any(|w| w.id == "code" && w.name == "Visual Studio Code"));
    e.handle("watch", &json!({ "app": "newapp" }));
    assert!(e.cfg.watched_apps.iter().any(|w| w.id == "newapp" && w.name == "newapp"), "unknown apps fall back to what was sent");
}

#[test]
fn measuring_from_the_phone_is_answered_as_mac_only() {
    let mut e = engine("power-test", Mock::laptop());
    let r = e.handle("power_test", &json!({}));
    assert_eq!(r["ok"], false);
    assert_eq!(r["error"], "Measuring savings is Mac-only for now");
    assert!(e.panel_json(crate::now()).get("canMeasure").is_none(), "the Measure button stays hidden");
}

#[test]
fn a_power_profile_that_failed_to_go_back_stays_recorded_and_is_retried() {
    let mut e = engine("low-power-retry", Mock::laptop());
    let now = crate::now();
    agent(&mut e, now);
    e.tick(now, None);
    e.platform.lid = true;
    e.tick(now + 2, None);
    assert!(e.platform.low_power && e.restore.power_profile.is_some());
    e.platform.fail_low_power_off = true;
    e.platform.lid = false;
    e.tick(now + 4, None);
    assert!(e.restore.power_profile.is_some(), "kept after a failed restore");
    assert!(e.root.join("restore.json").exists(), "and on disk, for the next start and the watchdog");
    e.platform.fail_low_power_off = false;
    for i in 0..15 {
        agent(&mut e, now + 6 + i * 2);
        e.tick(now + 6 + i * 2, None);
    }
    assert!(e.restore.power_profile.is_none() && !e.platform.low_power, "retried once it works");
    assert!(!e.root.join("restore.json").exists());
}

#[test]
fn check_ins_arm_a_wake_only_with_the_lid_shut_and_read_the_phone_on_a_lid_closed_wake() {
    let mut m = Mock::laptop();
    m.can_wake = true;
    let mut e = engine("checkin", m);
    e.update(|c| c.check_in_minutes = 30);
    let now = crate::now();
    e.tick(now, None);
    assert_eq!(e.platform.wake_armed, None, "lid open: no check-in wake (it would light the screen)");
    e.platform.lid = true;
    e.tick(now + 2, None);
    assert_eq!(e.platform.wake_armed, Some(1800), "lid shut and asleep soon: wake in 30 min");
    // Asleep for half an hour, then the timer wakes it with the lid still shut.
    let woke = now + 2 + 1800;
    e.tick(woke, None);
    assert!(e.platform.holding, "kept up while the phone's commands are read");
    assert!(e.platform.log.iter().any(|l| l == "begin Checking for phone commands"));
    let slept = e.platform.slept;
    e.tick(woke + 10, None);
    assert!(e.platform.holding, "still within the check-in");
    e.tick(woke + 26, None);
    assert!(!e.platform.holding, "nothing asked for it: let go");
    assert_eq!(e.platform.slept, slept + 1, "and back to sleep");
    assert_eq!(e.platform.wake_armed, Some(1800), "with the next check-in pending");
}

#[test]
fn a_wake_from_the_phone_during_a_check_in_keeps_it_awake() {
    let mut m = Mock::laptop();
    m.can_wake = true;
    m.lid = true;
    let mut e = engine("checkin-wake", m);
    e.update(|c| c.check_in_minutes = 15);
    let now = crate::now();
    e.tick(now, None);
    e.tick(now + 900, None); // woke for a check-in
    let r = e.handle("wake", &json!({ "minutes": 60 }));
    assert_eq!(r["ok"], true);
    e.tick(now + 930, None);
    assert!(e.holding && e.platform.holding, "the phone's wake holds it");
    assert_eq!(e.platform.wake_armed, None, "no wake timer while it's awake anyway");
}

#[test]
fn a_scheduled_wake_holds_for_its_minutes_and_clears_itself() {
    let mut m = Mock::laptop();
    m.can_wake = true;
    m.lid = true;
    let mut e = engine("wake-at", m);
    let now = crate::now();
    e.set_wake(Some(now + 2 * 3600), Some(45));
    e.tick(now, None);
    assert_eq!(e.platform.wake_armed, Some(3600), "reached in steps");
    // (Holds run on the real clock, so the test wakes it 10 minutes out rather than 2 hours.)
    e.set_wake(Some(now + 600), Some(45));
    e.tick(now + 2, None);
    e.tick(now + 600, None);
    assert!(e.holding, "awake at the set time");
    assert_eq!(e.cfg.wake_at, None, "one-off");
    assert!(e.holds.iter().any(|h| h.reason == "Scheduled wake"));
}

#[test]
fn old_commands_are_dropped_but_a_wake_waits_up_to_three_hours() {
    let mut g = crate::remote::Guard::default();
    let now = crate::now();
    assert!(g.check_aged(now - 400, "a", now, 300).is_err());
    assert!(g.check_aged(now - 2 * 3600, "b", now, crate::wake::WAKE_MAX_AGE).is_ok());
    assert!(g.check_aged(now - 2 * 3600, "b", now, crate::wake::WAKE_MAX_AGE).is_err(), "never twice");
    assert!(crate::format::parse_wake_time("07:30", now).is_some_and(|t| t > now && t <= now + 86_400 + 3600));
    assert!(crate::format::parse_wake_time("25:00", now).is_none());
}
