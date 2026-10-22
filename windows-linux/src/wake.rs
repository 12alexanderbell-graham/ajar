//! Waking a sleeping laptop: a scheduled wake at a clock time, and lid-closed check-ins that pick up a "wake"
//! sent from the phone (it waits at the relay while the laptop sleeps). A laptop that's shut down can't be woken.
//!
//! The OS keeps one wake timer, re-armed about once a minute while the lid is shut, so whenever the laptop falls
//! asleep a wake is due at most `step` seconds later. Only fixed steps are used (the Linux helper's sudoers entry
//! lists them), so a wake at a clock time is reached in steps; every step is also a check-in.

pub const STEPS: [u64; 5] = [3600, 1800, 900, 300, 60];
pub const CHECK_IN_CHOICES: [u32; 4] = [0, 15, 30, 60];
/// How long a check-in keeps the laptop up to read the phone's commands.
pub const CHECK_IN_SECS: u64 = 25;
/// Phone "wake" commands are honoured this long after they were sent.
pub const WAKE_MAX_AGE: u64 = 3 * 3600;

/// Seconds until the next wake to ask for, or None. `until_wake`: seconds left to a scheduled wake (negative =
/// overdue); `check_in_minutes` 0 means no check-ins.
pub fn next_step(until_wake: Option<i64>, check_in_minutes: u32) -> Option<u64> {
    let mut target: Option<i64> = None;
    if check_in_minutes > 0 {
        target = Some(check_in_minutes as i64 * 60);
    }
    if let Some(w) = until_wake {
        let w = w.max(60);
        target = Some(target.map_or(w, |t| t.min(w)));
    }
    let t = target?;
    Some(
        STEPS
            .iter()
            .copied()
            .find(|&s| (s as i64) <= t + 30)
            .unwrap_or(60),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steps_never_overshoot_and_check_ins_use_their_interval() {
        assert_eq!(next_step(None, 0), None);
        assert_eq!(next_step(None, 15), Some(900));
        assert_eq!(next_step(None, 30), Some(1800));
        assert_eq!(next_step(None, 60), Some(3600));
        assert_eq!(next_step(Some(7 * 3600), 0), Some(3600));
        assert_eq!(next_step(Some(25 * 60), 0), Some(900));
        assert_eq!(next_step(Some(25 * 60), 15), Some(900));
        assert_eq!(next_step(Some(100), 30), Some(60));
        assert_eq!(
            next_step(Some(-500), 0),
            Some(60),
            "overdue wakes come as soon as possible"
        );
    }
}
