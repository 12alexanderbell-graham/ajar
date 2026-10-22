//! Everything that touches the operating system, behind one trait so the engine can be tested with a mock.

use crate::state::{Restore, Touched};
use std::collections::HashSet;

#[cfg(target_os = "linux")]
pub mod linux;
pub mod mock;
#[cfg(windows)]
pub mod windows;

#[derive(Clone, Debug, PartialEq)]
pub struct Battery {
    pub percent: u32,
    /// Power leaving the battery, in watts; 0 when not discharging.
    pub watts: f64,
    pub on_ac: bool,
    pub charging: bool,
    /// Full-charge capacity in watt-hours, when the battery reports it.
    pub full_wh: Option<f64>,
}

impl Battery {
    /// Energy is leaving the battery: on battery, or on a charger too weak to keep up.
    pub fn discharging(&self) -> bool {
        self.watts > 0.3 && !self.charging
    }
    /// The battery is what's running the machine (decides between ∞ and an hours figure).
    pub fn on_battery(&self) -> bool {
        self.discharging() || !self.on_ac
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Thermal {
    Unknown,
    Normal,
    Serious,
    Critical,
}

pub trait Platform {
    fn name(&self) -> &'static str;
    /// Whether Nocturnal can keep this machine awake (Err explains why not, in words for the person).
    fn ready(&mut self) -> Result<(), String>;
    fn has_lid(&mut self) -> bool;
    fn lid_closed(&mut self) -> bool;
    fn battery(&mut self) -> Option<Battery>;
    fn thermal(&mut self) -> Thermal;

    /// Start keeping the machine awake, including with the lid closed. Must be crash-safe: if Nocturnal dies, the
    /// machine must be able to sleep again without Nocturnal's help (or with the watchdog's).
    fn begin_hold(&mut self, reason: &str, restore: &mut Restore) -> Result<(), String>;
    fn end_hold(&mut self, restore: &mut Restore) -> Result<(), String>;
    /// Put the machine to sleep now (the lid is already shut and the work is done).
    fn sleep_now(&mut self);

    /// Low power on (saving the previous setting into `restore`) or back to what it was.
    fn set_low_power(&mut self, on: bool, restore: &mut Restore) -> bool;
    /// Undo every system setting recorded in `restore` (used at startup and by the watchdog after a crash).
    fn restore_settings(&mut self, restore: &mut Restore);

    /// Slow a process (efficiency mode / lowest priority), but only if `pid` still has start time `start`.
    /// Returns its previous priority and, on Linux, the systemd unit used. Never acts on anything in
    /// `protected` (on Linux a unit shared with a protected process is refused).
    fn slow(
        &mut self,
        pid: u32,
        start: u64,
        protected: &HashSet<u32>,
    ) -> Option<(i64, Option<String>)>;
    /// Put a slowed process back. False if the OS refused (the journal entry is kept and retried).
    fn unslow(&mut self, t: &Touched) -> bool;
    /// Pause or resume, only if `pid` is still the process that started at `start` (checked on the same
    /// handle the signal goes through, so a reused pid is never frozen).
    fn pause(&mut self, pid: u32, start: u64, on: bool) -> bool;

    fn notify(&mut self, title: &str, body: &str);
    fn set_open_at_login(&mut self, on: bool) -> Result<(), String>;
    fn install_watchdog(&mut self) -> Result<(), String>;
    /// Remove the watchdog and the login item (the app's own folder is left for the person to delete).
    fn uninstall(&mut self) -> Result<(), String> {
        Ok(())
    }

    /// False when the desktop leaves lid-close sleep to Nocturnal (KDE with "Do nothing"): then Nocturnal sleeps the
    /// machine itself when the lid closes and nothing is working.
    fn sleeps_on_close_itself(&mut self) -> bool {
        true
    }
    /// Something about this machine's setup that stops lid-closed work, in words for the person.
    fn lid_warning(&mut self) -> Option<String> {
        None
    }
    /// Lid shut but an external display is in use (docked / clamshell desk use): treated like an open lid.
    fn docked(&mut self) -> bool {
        false
    }
    /// After a lid-closed session ends, put the machine to sleep? False when the person's own setting is to
    /// keep running with the lid shut.
    fn sleep_after_hold(&mut self) -> bool {
        true
    }
    /// While holding: is what Nocturnal set still in place? (Err describes what changed.)
    fn verify_hold(&mut self, _restore: &mut Restore) -> Result<(), String> {
        Ok(())
    }
    /// Whether the watchdog is registered with the OS scheduler (None = can't tell).
    fn watchdog_installed(&mut self) -> Option<bool> {
        None
    }
    /// Lid shut during a hold: turn the built-in screen off (some desktops leave it lit under the lid when lid
    /// handling is inhibited). `false` when the lid opens. Input wakes it anyway, so a crash can't leave it dark.
    fn screen_off(&mut self, _on: bool) {}
    /// Ask the OS to wake the machine `secs` seconds from now if it's asleep then (replaces an earlier request).
    /// False if this machine or setup can't (no helper installed, wake timers disallowed).
    fn arm_wake(&mut self, _secs: u64) -> bool {
        false
    }
    fn disarm_wake(&mut self) {}
}

/// Puts back one setting recorded in `restore.json`. The record is cleared only once that worked, or when there
/// is nothing to do because the setting is no longer Nocturnal's (`still_ours` false); after a failure it's kept, to
/// be retried (by the next tick, the next start or the watchdog).
pub fn put_back<T>(record: &mut Option<T>, still_ours: bool, set: impl FnOnce(&T) -> bool) -> bool {
    let done = match record.as_ref() {
        Some(prev) if still_ours => set(prev),
        _ => true,
    };
    if done {
        *record = None;
    }
    done
}

/// Persistence filter for heat readings: a hot level counts only once every one of the last `N` samples was at
/// least that hot, so a momentary dip in a clock limit isn't read as heat.
#[derive(Debug, Default)]
pub struct Sustained<const N: usize> {
    last: std::collections::VecDeque<Thermal>,
}

impl<const N: usize> Sustained<N> {
    pub fn feed(&mut self, t: Thermal) -> Thermal {
        if self.last.len() == N {
            self.last.pop_front();
        }
        self.last.push_back(t);
        let coolest = self.last.iter().copied().min().unwrap_or(Thermal::Unknown);
        if self.last.len() < N {
            coolest.min(Thermal::Normal)
        } else {
            coolest
        }
    }
    pub fn clear(&mut self) {
        self.last.clear();
    }
}

#[cfg(target_os = "linux")]
pub fn native() -> linux::Linux {
    linux::Linux::new()
}

#[cfg(windows)]
pub fn native() -> windows::Win {
    windows::Win::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_record_is_kept_until_its_restore_works() {
        let mut r = Some("balanced".to_string());
        assert!(!put_back(&mut r, true, |_| false));
        assert_eq!(
            r.as_deref(),
            Some("balanced"),
            "a failed restore keeps the record for a retry"
        );
        let mut asked = None;
        assert!(put_back(&mut r, true, |p| {
            asked = Some(p.clone());
            true
        }));
        assert_eq!((r, asked.as_deref()), (None, Some("balanced")));
        let mut changed = Some("balanced".to_string());
        assert!(put_back(&mut changed, false, |_| panic!(
            "not Nocturnal's setting any more: left alone"
        )));
        assert!(changed.is_none());
        assert!(
            put_back(&mut None::<String>, true, |_| false),
            "nothing recorded: nothing to do"
        );
    }

    #[test]
    fn heat_counts_only_when_it_lasts() {
        let mut h = Sustained::<3>::default();
        assert_eq!(h.feed(Thermal::Critical), Thermal::Normal);
        assert_eq!(h.feed(Thermal::Critical), Thermal::Normal);
        assert_eq!(h.feed(Thermal::Critical), Thermal::Critical);
        assert_eq!(h.feed(Thermal::Serious), Thermal::Serious);
        assert_eq!(h.feed(Thermal::Normal), Thermal::Normal);
        assert_eq!(
            h.feed(Thermal::Critical),
            Thermal::Normal,
            "one hot sample among cool ones isn't heat"
        );
        assert_eq!(h.feed(Thermal::Unknown), Thermal::Unknown);
        h.clear();
        assert_eq!(h.feed(Thermal::Unknown), Thermal::Unknown);
    }
}
