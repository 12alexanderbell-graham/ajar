//! The figures the menu and phone show: battery estimates, the outcome line, the mode line.

use super::*;

impl<P: Platform> Engine<P> {
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
        let sleeps = if self.has_lid && self.lid_closed {
            "Going to sleep"
        } else {
            "Sleeps normally"
        };
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
            Mode::Off => "Nocturnal is off".to_string(),
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

    /// The three numbers on the phone's status card, as numbers (the phone formats and animates them): battery
    /// percent, whole-laptop draw now in watts, and hours left on battery with the lid closed (to 5 minutes).
    pub fn phone_numbers(&self) -> Value {
        let Some(b) = self.battery.as_ref() else {
            return Value::Null;
        };
        let hours = if self.has_lid {
            self.hours_left(self.closed_watts())
                .map(|h| (h * 12.0).round() / 12.0)
                .filter(|h| *h > 0.0)
        } else {
            None
        };
        json!({
            "pct": b.percent,
            "w": b.discharging().then(|| (b.watts * 10.0).round() / 10.0),
            "h": hours,
            "plugged": !b.on_battery(),
            "charging": b.charging,
            "guess": self.closed_draw_is_guess(),
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
}
