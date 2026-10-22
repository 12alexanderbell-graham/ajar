//! Waking while asleep (see wake.rs): scheduled wakes, check-ins for the phone, and noticing a resume.

use super::*;

impl<P: Platform> Engine<P> {
    /// A scheduled wake whose time came while the machine was already up: with the lid shut it starts the
    /// stay-awake time now; either way it's used up, so it never lingers as a time in the past.
    pub(super) fn check_scheduled_wake(&mut self, now: u64) {
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

    /// Keeps one OS wake timer pending while it could be needed, re-armed about once a minute so it's due at most
    /// a step after the machine falls asleep. Check-ins only with the lid shut (with it open a wake may light the
    /// screen); a scheduled wake always.
    pub(super) fn keep_wake_armed(&mut self, now: u64) {
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

    /// Asks for the wake right before Nocturnal itself puts the machine to sleep (the minute timer may be stale).
    pub(super) fn arm_before_sleep(&mut self, now: u64) {
        self.wake_armed_at = None;
        self.keep_wake_armed(now);
    }

    /// Back from sleep. With the lid open someone is there: nothing to do. With it shut and nothing holding the
    /// machine, this was a scheduled wake or a check-in.
    pub(super) fn resumed(&mut self, now: u64) {
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

    pub(super) fn check_in_tick(&mut self, now: u64) {
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
}
