//! Turning numbers into the short phrases the menu shows. Concrete figures, never "a while".

/// "45 min", "1 h 05 min", "12 h". Under a minute reads "under 1 min".
pub fn minutes(m: f64) -> String {
    if !m.is_finite() || m < 0.0 {
        return "–".into();
    }
    if m < 1.0 {
        return "under 1 min".into();
    }
    let total = m.round() as u64;
    let (h, mm) = (total / 60, total % 60);
    match (h, mm) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m:02} min"),
    }
}

/// Hours as "3 h 20 min". Anything past 99 hours reads "99+ h" (the estimate isn't that precise).
pub fn hm(hours: f64) -> String {
    if !hours.is_finite() || hours < 0.0 {
        return "–".into();
    }
    if hours >= 99.0 {
        return "99+ h".into();
    }
    minutes(hours * 60.0)
}

/// Local wall-clock time of a Unix timestamp, 24-hour: "07:00", "19:05".
pub fn clock(t: u64) -> String {
    let local = t as i64 + local_offset(t);
    let secs = local.rem_euclid(86_400);
    format!("{:02}:{:02}", secs / 3600, (secs % 3600) / 60)
}

/// The next time the local clock reads `hour`:00, as a Unix timestamp (for "Until 07:00").
pub fn next_local_hour(now: u64, hour: u32) -> u64 {
    next_local_time(now, hour, 0)
}

/// "7:00" / "07:00" / "19:30" → the next time the local clock shows it; or Unix seconds within the next week.
pub fn parse_wake_time(t: &str, now: u64) -> Option<u64> {
    let t = t.trim();
    if let Ok(secs) = t.parse::<u64>() {
        return (secs > now + 60 && secs < now + 7 * 86_400).then_some(secs);
    }
    let (h, m) = t.split_once(':')?;
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    if h > 23 || m > 59 {
        return None;
    }
    Some(next_local_time(now, h, m))
}

/// The next time, more than a minute from now, that the local clock reads `hour:minute`.
fn next_local_time(now: u64, hour: u32, minute: u32) -> u64 {
    let off = local_offset(now);
    let local = now as i64 + off;
    let midnight = local - local.rem_euclid(86_400);
    let mut target = midnight + hour as i64 * 3600 + minute as i64 * 60;
    if target <= local + 60 {
        target += 86_400;
    }
    // Re-check the offset at the target in case a daylight-saving change falls in between.
    let off2 = local_offset((target - off).max(0) as u64);
    (target - off2).max(0) as u64
}

/// "Today 14:05", "Yesterday 09:30", "3 days ago" for the recent-sessions list.
pub fn when(t: u64, now: u64) -> String {
    let day = |x: u64| (x as i64 + local_offset(x)).div_euclid(86_400);
    match day(now) - day(t) {
        0 => format!("Today {}", clock(t)),
        1 => format!("Yesterday {}", clock(t)),
        d if d > 1 => format!("{d} days ago"),
        _ => clock(t),
    }
}

/// Percent-encodes text for a URL query value.
pub fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Seconds east of UTC for the local time zone at time `t`.
#[cfg(unix)]
pub fn local_offset(t: u64) -> i64 {
    let tt = t as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let ok = unsafe { !libc::localtime_r(&tt, &mut tm).is_null() };
    if ok {
        tm.tm_gmtoff
    } else {
        0
    }
}

#[cfg(windows)]
pub fn local_offset(t: u64) -> i64 {
    use windows_sys::Win32::Foundation::{FILETIME, SYSTEMTIME};
    use windows_sys::Win32::System::Time::{
        FileTimeToSystemTime, SystemTimeToFileTime, SystemTimeToTzSpecificLocalTime,
    };
    // Unix seconds → FILETIME (100 ns ticks since 1601), → local SYSTEMTIME via the current zone's rules.
    let ticks = (t + 11_644_473_600) * 10_000_000;
    let ft = FILETIME {
        dwLowDateTime: ticks as u32,
        dwHighDateTime: (ticks >> 32) as u32,
    };
    unsafe {
        let mut utc: SYSTEMTIME = std::mem::zeroed();
        let mut local: SYSTEMTIME = std::mem::zeroed();
        if FileTimeToSystemTime(&ft, &mut utc) == 0
            || SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc, &mut local) == 0
        {
            return 0;
        }
        let mut lft: FILETIME = std::mem::zeroed();
        if SystemTimeToFileTime(&local, &mut lft) == 0 {
            return 0;
        }
        let lticks = ((lft.dwHighDateTime as u64) << 32) | lft.dwLowDateTime as u64;
        (lticks as i64 - ticks as i64) / 10_000_000
    }
}

#[cfg(not(any(unix, windows)))]
pub fn local_offset(_t: u64) -> i64 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minutes_read_naturally() {
        assert_eq!(minutes(0.2), "under 1 min");
        assert_eq!(minutes(45.4), "45 min");
        assert_eq!(minutes(59.6), "1 h");
        assert_eq!(minutes(65.0), "1 h 05 min");
        assert_eq!(minutes(f64::NAN), "–");
        assert_eq!(minutes(-3.0), "–");
    }

    #[test]
    fn hours_cap_and_reject_garbage() {
        assert_eq!(hm(3.0 + 20.0 / 60.0), "3 h 20 min");
        assert_eq!(hm(500.0), "99+ h");
        assert_eq!(hm(f64::INFINITY), "–");
    }

    #[test]
    fn relative_days_and_url_encoding() {
        let now = crate::now();
        assert!(when(now, now).starts_with("Today"));
        assert!(when(now - 86_400, now).starts_with("Yesterday"));
        assert_eq!(when(now - 5 * 86_400, now), "5 days ago");
        assert_eq!(
            url_encode("Claude Code · done"),
            "Claude%20Code%20%C2%B7%20done"
        );
    }

    #[test]
    fn next_hour_is_in_the_future_and_on_the_hour() {
        let now = crate::now();
        for h in [0, 7, 23] {
            let t = next_local_hour(now, h);
            assert!(t > now && t <= now + 25 * 3600, "hour {h}");
            assert_eq!(clock(t), format!("{h:02}:00"));
        }
    }
}
