//! Nocturnal's folder and the small files in it. Linux: `$XDG_CONFIG_HOME/nocturnal` (usually `~/.config/nocturnal`),
//! Windows: `%APPDATA%\Nocturnal`. Created owner-only on Linux because the command inbox lives here.
//!
//! | file            | what                                                              |
//! |-----------------|-------------------------------------------------------------------|
//! | config.json     | settings                                                          |
//! | runtime.json    | holds, the Always timer, the mode to return to                    |
//! | stats.json      | lid-closed sessions                                               |
//! | alive           | heartbeat, touched every few seconds (the watchdog reads it)      |
//! | touched.json    | apps Nocturnal slowed or paused, so they can always be put back        |
//! | restore.json    | system settings Nocturnal changed (power profile, lid action)          |
//! | requests/ replies/ | command inbox and outbox for the `nocturnal` CLI and MCP server     |

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

pub fn dir() -> PathBuf {
    let base = if cfg!(windows) {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join("AppData").join("Roaming"))
    } else {
        std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home().join(".config"))
    };
    let d = base.join(if cfg!(windows) {
        "Nocturnal"
    } else {
        "nocturnal"
    });
    let fresh = !d.exists();
    ensure_private_dir(&d);
    // The app used to be called Ajar: carry its settings, history and Approve everything journal over once.
    if fresh {
        let old = base.join(if cfg!(windows) { "Ajar" } else { "ajar" });
        for f in [
            "config.json",
            "safety.json",
            "stats.json",
            "auto-approve.json",
        ] {
            let _ = std::fs::copy(old.join(f), d.join(f));
        }
    }
    d
}

pub fn home() -> PathBuf {
    let v = if cfg!(windows) {
        std::env::var_os("USERPROFILE")
    } else {
        std::env::var_os("HOME")
    };
    v.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

pub fn ensure_private_dir(d: &Path) {
    let _ = fs::create_dir_all(d);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(d, fs::Permissions::from_mode(0o700));
    }
}

pub fn file(name: &str) -> PathBuf {
    dir().join(name)
}

pub fn subdir(name: &str) -> PathBuf {
    let d = dir().join(name);
    ensure_private_dir(&d);
    d
}

/// Write via a temporary file, flush it to disk, then rename, so a crash or power loss never leaves a
/// half-written file (journals must survive exactly the moments when something goes wrong).
pub fn write_atomic(path: &Path, contents: &str) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(contents.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

pub fn read(path: &Path) -> Option<String> {
    fs::read_to_string(path).ok()
}

pub fn remove(path: &Path) {
    let _ = fs::remove_file(path);
}

pub fn touch(path: &Path) {
    let _ = fs::write(path, crate::now().to_string());
}

/// Seconds since the heartbeat file was last written, using the time inside it (immune to odd file mtimes).
pub fn age_of(path: &Path) -> Option<u64> {
    let t: u64 = read(path)?.split_whitespace().next()?.parse().ok()?;
    Some(crate::now().saturating_sub(t))
}

/// The app's heartbeat: "time pid start", so the watchdog can tell a hung app from one that was just asleep.
pub fn heartbeat(path: &Path) {
    let pid = std::process::id();
    let start = crate::procs::start_time(pid).unwrap_or(0);
    // Written to a temp file and renamed, so the watchdog never reads a half-written (empty) heartbeat and
    // mistakes a running app for a dead one. No fsync: it's rewritten every 2 seconds.
    let tmp = path.with_extension(format!("tmp{pid}"));
    if fs::write(&tmp, format!("{} {pid} {start}", crate::now())).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

/// Whether the heartbeat names its process (newer format) at all.
pub fn heartbeat_has_pid(path: &Path) -> bool {
    read(path).is_some_and(|t| t.split_whitespace().count() == 3)
}

/// Is the app that wrote the heartbeat still the same running process?
pub fn heartbeat_process_alive(path: &Path) -> bool {
    let Some(text) = read(path) else { return false };
    let f: Vec<u64> = text
        .split_whitespace()
        .filter_map(|x| x.parse().ok())
        .collect();
    match f.as_slice() {
        [_, pid, start] => {
            *pid <= u32::MAX as u64
                && crate::procs::start_time(*pid as u32) == Some(*start)
                && *start != 0
        }
        _ => false,
    }
}

pub fn load_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    serde_json::from_str(&read(path)?).ok()
}

/// True only if the file is safely on disk. Journals check this before acting.
pub fn save_json<T: Serialize>(path: &Path, v: &T) -> bool {
    match serde_json::to_string_pretty(v) {
        Ok(s) => write_atomic(path, &s).is_ok(),
        Err(_) => false,
    }
}

/// An app Nocturnal slowed or paused. Its start time is checked before undoing anything, so a reused pid is never touched.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Touched {
    pub pid: u32,
    /// Executable name, for display and as a second identity check.
    pub exe: String,
    /// Process start time when it was touched; a different start time means the pid was reused.
    pub start: u64,
    pub paused: bool,
    /// The priority it had before (Linux nice value, or Windows priority class), to put back exactly.
    /// `PREVIOUS_UNKNOWN` while the change is in flight (recorded before acting).
    pub previous: i64,
    /// Linux: the app's systemd unit, when it was slowed through it (reset directly on undo).
    #[serde(default)]
    pub unit: Option<String>,
}

/// Journal value for a slow-down recorded before it happened; restore falls back to the normal priority.
pub const PREVIOUS_UNKNOWN: i64 = i64::MIN + 1;

/// System settings Nocturnal changed and must restore. Missing fields read as "nothing to restore".
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Restore {
    /// Windows: other power plans that became active during a hold and were also set to "Do nothing":
    /// (plan GUID, AC, DC) originals.
    pub lid_more: Vec<(String, u32, u32)>,
    /// Linux: power-profiles-daemon profile before Nocturnal switched to power-saver.
    pub power_profile: Option<String>,
    /// Windows: power overlay scheme GUID before Nocturnal switched to best power efficiency.
    pub power_overlay: Option<String>,
    /// Windows: lid-close action (AC, DC) before Nocturnal set it to "do nothing".
    pub lid_action: Option<(u32, u32)>,
    /// Windows: the power plan the lid action was changed in (restored in that plan even if the active one changed).
    pub lid_scheme: Option<String>,
    /// Windows (Modern Standby): the sleep timeouts before Nocturnal set them to "never" for a hold:
    /// (plan GUID, [sleep AC, sleep DC, unattended AC, unattended DC]) in seconds.
    pub sleep_idle: Option<(String, [u32; 4])>,
    /// Windows: processor boost mode on battery (plan GUID, DC value) before Nocturnal turned turbo off while closed.
    pub boost_dc: Option<(String, u32)>,
    /// Linux: Nocturnal's root helper applied turbo-off and kernel power saving (its own file holds the old values).
    pub linux_tuned: bool,
}
