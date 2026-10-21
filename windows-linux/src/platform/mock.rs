//! A scriptable platform for tests: records every call and lets a test set battery, lid and heat.

use super::{Battery, Platform, Thermal};
use crate::state::{Restore, Touched};
use std::collections::HashSet;

#[derive(Default, Debug)]
pub struct Mock {
    pub ready_error: Option<String>,
    pub lid: bool,
    pub has_lid: bool,
    pub battery: Option<Battery>,
    pub thermal: Option<Thermal>,
    pub holding: bool,
    pub fail_begin: bool,
    pub fail_end: bool,
    pub slept: u32,
    pub low_power: bool,
    pub slowed: Vec<u32>,
    pub paused: Vec<u32>,
    pub notes: Vec<(String, String)>,
    pub log: Vec<String>,
    pub desktop_sleeps_on_close: Option<bool>,
    /// Make every restore (resume / un-slow) fail, as if the OS refused.
    pub fail_restore: bool,
    /// Make putting the power profile back fail (the record must then be kept).
    pub fail_low_power_off: bool,
    pub hold_drift: Option<String>,
    pub docked: bool,
    pub user_keeps_awake_on_close: bool,
    /// Last wake timer asked for (seconds), None when disarmed; `can_wake` false = unsupported.
    pub wake_armed: Option<u64>,
    pub can_wake: bool,
}

impl Mock {
    pub fn laptop() -> Mock {
        Mock { has_lid: true, battery: Some(Battery { percent: 80, watts: 8.0, on_ac: false, charging: false, full_wh: Some(60.0) }), ..Default::default() }
    }
}

impl Platform for Mock {
    fn name(&self) -> &'static str { "mock" }
    fn ready(&mut self) -> Result<(), String> {
        match &self.ready_error { Some(e) => Err(e.clone()), None => Ok(()) }
    }
    fn has_lid(&mut self) -> bool { self.has_lid }
    fn lid_closed(&mut self) -> bool { self.lid }
    fn battery(&mut self) -> Option<Battery> { self.battery.clone() }
    fn thermal(&mut self) -> Thermal { self.thermal.unwrap_or(Thermal::Normal) }
    fn begin_hold(&mut self, reason: &str, _r: &mut Restore) -> Result<(), String> {
        self.log.push(format!("begin {reason}"));
        if self.fail_begin { return Err("can't".into()); }
        self.holding = true;
        Ok(())
    }
    fn end_hold(&mut self, _r: &mut Restore) -> Result<(), String> {
        self.log.push("end".into());
        if self.fail_end { return Err("can't".into()); }
        self.holding = false;
        Ok(())
    }
    fn sleep_now(&mut self) { self.slept += 1; self.log.push("sleep".into()); }
    fn set_low_power(&mut self, on: bool, r: &mut Restore) -> bool {
        if on && !self.low_power { r.power_profile = Some("balanced".into()); }
        if !on && self.fail_low_power_off && r.power_profile.is_some() { return false; }
        if !on { r.power_profile = None; }
        self.low_power = on;
        true
    }
    fn restore_settings(&mut self, r: &mut Restore) { self.low_power = false; *r = Restore::default(); }
    fn slow(&mut self, pid: u32, _start: u64, protected: &HashSet<u32>) -> Option<(i64, Option<String>)> {
        if protected.contains(&pid) { return None; }
        self.slowed.push(pid);
        Some((0, None))
    }
    fn unslow(&mut self, t: &Touched) -> bool {
        if self.fail_restore { return false; }
        self.slowed.retain(|p| *p != t.pid);
        true
    }
    fn docked(&mut self) -> bool { self.docked }
    fn sleep_after_hold(&mut self) -> bool { !self.user_keeps_awake_on_close }
    fn pause(&mut self, pid: u32, _start: u64, on: bool) -> bool {
        if !on && self.fail_restore { return false; }
        self.log.push(format!("{} {pid}", if on { "pause" } else { "resume" }));
        if on { self.paused.push(pid) } else { self.paused.retain(|p| *p != pid) }
        true
    }
    fn verify_hold(&mut self, _r: &mut Restore) -> Result<(), String> {
        match self.hold_drift.take() { Some(e) => Err(e), None => Ok(()) }
    }
    fn notify(&mut self, title: &str, body: &str) { self.notes.push((title.into(), body.into())); }
    fn set_open_at_login(&mut self, _on: bool) -> Result<(), String> { Ok(()) }
    fn install_watchdog(&mut self) -> Result<(), String> { Ok(()) }
    fn sleeps_on_close_itself(&mut self) -> bool { self.desktop_sleeps_on_close.unwrap_or(true) }
    fn arm_wake(&mut self, secs: u64) -> bool {
        if !self.can_wake { return false; }
        self.wake_armed = Some(secs);
        true
    }
    fn disarm_wake(&mut self) { self.wake_armed = None; }
}
