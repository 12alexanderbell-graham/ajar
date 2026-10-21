//! Linux: systemd-logind for sleep and the lid, sysfs for battery and heat, power-profiles-daemon for low
//! power, the systemd user manager to slow apps, signals to pause them.
//!
//! Keeping awake = a logind inhibitor lock ("sleep:idle:handle-lid-switch", block mode) held as a file
//! descriptor. The kernel closes it when Ajar exits for any reason, so a crash can never leave the machine
//! unable to sleep. GNOME and KDE also get their own session inhibitors (their automatic suspend doesn't
//! always look at logind's), tied to Ajar's D-Bus connection, which also dies with the process.

use super::{Battery, Platform, Thermal};
use crate::state::{Restore, Touched};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedFd, OwnedValue, Value};

const LOGIND: &str = "org.freedesktop.login1";
const LOGIND_PATH: &str = "/org/freedesktop/login1";
const LOGIND_IFACE: &str = "org.freedesktop.login1.Manager";
/// `previous` value meaning "slowed through the app's systemd unit", not by nice value.
pub const UNIT_MARK: i64 = i64::MIN;

pub struct Linux {
    system: Option<Connection>,
    session: Option<Connection>,
    inhibitor: Option<OwnedFd>,
    gnome_cookie: Option<u32>,
    pm_cookie: Option<u32>,
    sys: PathBuf,
    throttled: HashSet<String>,
    lid_known: Option<bool>,
}

impl Linux {
    pub fn new() -> Linux {
        Linux {
            system: Connection::system().ok(),
            session: Connection::session().ok(),
            inhibitor: None,
            gnome_cookie: None,
            pm_cookie: None,
            // Test hook: point at a fake sysfs tree (battery, chassis, thermal) in integration tests.
            sys: std::env::var_os("AJAR_SYSFS_ROOT").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/sys")),
            throttled: HashSet::new(),
            lid_known: None,
        }
    }

    fn logind_property(&self, name: &str) -> Option<OwnedValue> {
        get_property(self.system.as_ref()?, LOGIND, LOGIND_PATH, LOGIND_IFACE, name)
    }

    fn power_profile(&self) -> Option<(&'static str, &'static str, String)> {
        let sys = self.system.as_ref()?;
        for (dest, path) in [("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles"), ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles")] {
            if let Some(v) = get_property(sys, dest, path, dest, "ActiveProfile") {
                if let Ok(s) = String::try_from(v) {
                    return Some((dest, path, s));
                }
            }
        }
        None
    }

    fn set_power_profile(&self, dest: &str, path: &str, profile: &str) -> bool {
        let Some(sys) = self.system.as_ref() else { return false };
        sys.call_method(Some(dest), path, Some("org.freedesktop.DBus.Properties"), "Set", &(dest, "ActiveProfile", Value::from(profile))).is_ok()
    }

    /// The app's own systemd unit (`app-…firefox….scope`), if the process has one to itself.
    fn app_unit(&self, pid: u32) -> Option<String> {
        let uid = unsafe { libc::getuid() };
        let text = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
        let cg = cgroup_v2_path(&text)?;
        let unit = app_unit_name(&cg, uid)?;
        let name = crate::procs::name_of(pid)?;
        // Only when the unit is clearly this app: named after it, or every process in it is the same program.
        let named = unit.to_lowercase().replace(['_', '.'], "-").contains(&crate::config::exe_key(&name).replace(['_', '.'], "-"));
        if !named {
            let procs = fs::read_to_string(self.sys.join("fs/cgroup").join(cg.trim_start_matches('/')).join("cgroup.procs")).ok()?;
            let all_same = procs.lines().filter_map(|l| l.trim().parse::<u32>().ok()).all(|p| crate::procs::name_of(p).as_deref() == Some(name.as_str()));
            if !all_same {
                return None;
            }
        }
        // The user manager must have the cpu controller, or the property would be accepted and do nothing.
        let controllers = fs::read_to_string(self.sys.join(format!("fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service/cgroup.controllers"))).unwrap_or_default();
        controllers.split_whitespace().any(|c| c == "cpu").then_some(unit)
    }

    /// Every pid in the same cgroup as `pid`.
    fn unit_pids(&self, pid: u32) -> Vec<u32> {
        let Some(cg) = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok().and_then(|t| cgroup_v2_path(&t)) else { return vec![] };
        fs::read_to_string(self.sys.join("fs/cgroup").join(cg.trim_start_matches('/')).join("cgroup.procs"))
            .map(|t| t.lines().filter_map(|l| l.trim().parse().ok()).collect())
            .unwrap_or_default()
    }

    fn set_unit_cpu(&self, unit: &str, slow: bool) -> bool {
        let Some(s) = self.session.as_ref() else { return false };
        // u64::MAX = "not set" for both properties, i.e. back to normal.
        let (weight, quota) = if slow { (1u64, 250_000u64) } else { (u64::MAX, u64::MAX) };
        let props: Vec<(&str, Value)> = vec![("CPUWeight", Value::from(weight)), ("CPUQuotaPerSecUSec", Value::from(quota))];
        s.call_method(Some("org.freedesktop.systemd1"), "/org/freedesktop/systemd1", Some("org.freedesktop.systemd1.Manager"), "SetUnitProperties", &(unit, true, props))
            .is_ok()
    }

    fn kde(&self) -> bool {
        std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_uppercase().contains("KDE")
    }

    fn on_ac(&mut self) -> bool {
        self.battery().is_none_or(|b| b.on_ac)
    }
}

impl Default for Linux {
    fn default() -> Self {
        Linux::new()
    }
}

fn get_property(c: &Connection, dest: &str, path: &str, iface: &str, name: &str) -> Option<OwnedValue> {
    let reply = c.call_method(Some(dest), path, Some("org.freedesktop.DBus.Properties"), "Get", &(iface, name)).ok()?;
    reply.body().deserialize::<OwnedValue>().ok()
}

impl Platform for Linux {
    fn name(&self) -> &'static str {
        "linux"
    }

    fn ready(&mut self) -> Result<(), String> {
        if self.system.is_none() {
            self.system = Connection::system().ok();
        }
        if self.logind_property("LidClosed").is_none() {
            return Err("Ajar needs systemd-logind to keep this machine awake, and it isn't available here".into());
        }
        Ok(())
    }

    fn has_lid(&mut self) -> bool {
        let chassis = fs::read_to_string(self.sys.join("class/dmi/id/chassis_type")).ok().and_then(|s| s.trim().parse::<u32>().ok());
        let portable = matches!(chassis, Some(8 | 9 | 10 | 14 | 30 | 31 | 32));
        let acpi_lid = fs::read_dir("/proc/acpi/button/lid").map(|mut d| d.next().is_some()).unwrap_or(false);
        portable || acpi_lid
    }

    fn lid_closed(&mut self) -> bool {
        if let Some(v) = self.logind_property("LidClosed").and_then(|v| bool::try_from(v).ok()) {
            self.lid_known = Some(v);
            return v;
        }
        if let Ok(dir) = fs::read_dir("/proc/acpi/button/lid") {
            for e in dir.flatten() {
                if let Ok(s) = fs::read_to_string(e.path().join("state")) {
                    return s.contains("closed");
                }
            }
        }
        self.lid_known.unwrap_or(false)
    }

    fn battery(&mut self) -> Option<Battery> {
        read_battery(&self.sys.join("class/power_supply"))
    }

    fn thermal(&mut self) -> Thermal {
        read_thermal(&self.sys.join("class/thermal"))
    }

    fn begin_hold(&mut self, reason: &str, _restore: &mut Restore) -> Result<(), String> {
        if self.inhibitor.is_none() {
            let sys = self.system.as_ref().ok_or("Can't reach systemd-logind")?;
            let reply = sys
                .call_method(Some(LOGIND), LOGIND_PATH, Some(LOGIND_IFACE), "Inhibit", &("sleep:idle:handle-lid-switch", "Ajar", reason, "block"))
                .map_err(|e| format!("logind refused to keep the machine awake: {e}"))?;
            let fd: OwnedFd = reply.body().deserialize().map_err(|e| format!("unexpected reply from logind: {e}"))?;
            self.inhibitor = Some(fd);
        }
        if let Some(s) = self.session.as_ref() {
            if self.gnome_cookie.is_none() {
                // Flag 4 = suspend: stops GNOME's automatic suspend, still lets the screen blank.
                self.gnome_cookie = s
                    .call_method(Some("org.gnome.SessionManager"), "/org/gnome/SessionManager", Some("org.gnome.SessionManager"), "Inhibit", &("ajar", 0u32, reason, 4u32))
                    .ok()
                    .and_then(|m| m.body().deserialize::<u32>().ok());
            }
            if self.pm_cookie.is_none() {
                self.pm_cookie = s
                    .call_method(Some("org.freedesktop.PowerManagement"), "/org/freedesktop/PowerManagement/Inhibit", Some("org.freedesktop.PowerManagement.Inhibit"), "Inhibit", &("Ajar", reason))
                    .ok()
                    .and_then(|m| m.body().deserialize::<u32>().ok());
            }
        }
        Ok(())
    }

    fn end_hold(&mut self, _restore: &mut Restore) -> Result<(), String> {
        self.inhibitor = None; // dropping the descriptor releases the lock
        if let Some(s) = self.session.as_ref() {
            if let Some(c) = self.gnome_cookie.take() {
                let _ = s.call_method(Some("org.gnome.SessionManager"), "/org/gnome/SessionManager", Some("org.gnome.SessionManager"), "Uninhibit", &(c,));
            }
            if let Some(c) = self.pm_cookie.take() {
                let _ = s.call_method(Some("org.freedesktop.PowerManagement"), "/org/freedesktop/PowerManagement/Inhibit", Some("org.freedesktop.PowerManagement.Inhibit"), "UnInhibit", &(c,));
            }
        }
        Ok(())
    }

    fn sleep_now(&mut self) {
        if let Some(sys) = self.system.as_ref() {
            let _ = sys.call_method(Some(LOGIND), LOGIND_PATH, Some(LOGIND_IFACE), "Suspend", &(false,));
        }
    }

    fn sleeps_on_close_itself(&mut self) -> bool {
        // KDE handles the lid itself. With its lid action set to "Do nothing", Ajar does the sleeping, unless an
        // external display is connected (a docked laptop should keep running).
        if !self.kde() {
            return true;
        }
        let ac = self.on_ac();
        !(kde_lid_action(ac) == Some(0) && !external_display(&self.sys.join("class/drm")))
    }

    fn lid_warning(&mut self) -> Option<String> {
        if self.kde() {
            let ac = self.on_ac();
            if kde_lid_action(ac) != Some(0) {
                return Some("KDE may still sleep when the lid closes. In System Settings › Power Management, set \"When laptop lid closed\" to \"Do nothing\"; Ajar then sleeps it on close whenever nothing is working.".into());
            }
        }
        None
    }

    fn screen_off(&mut self, on: bool) {
        if self.kde() {
            // Plasma (Wayland and X11): kscreen-doctor ships with Plasma.
            let _ = std::process::Command::new("kscreen-doctor").args(["--dpms", if on { "off" } else { "on" }])
                .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
            return;
        }
        // GNOME (Mutter): PowerSaveMode 3 = off, 0 = on. Other desktops don't have this service; nothing happens.
        if let Some(s) = self.session.as_ref() {
            let mode: i32 = if on { 3 } else { 0 };
            let _ = s.call_method(
                Some("org.gnome.Mutter.DisplayConfig"),
                "/org/gnome/Mutter/DisplayConfig",
                Some("org.freedesktop.DBus.Properties"),
                "Set",
                &("org.gnome.Mutter.DisplayConfig", "PowerSaveMode", Value::from(mode)),
            );
        }
    }

    fn arm_wake(&mut self, secs: u64) -> bool {
        crate::wake::STEPS.contains(&secs) && power_helper_args(&["wake", &secs.to_string()])
    }

    fn disarm_wake(&mut self) {
        power_helper_args(&["wake", "off"]);
    }

    fn set_low_power(&mut self, on: bool, restore: &mut Restore) -> bool {
        // The optional root helper (installed by install.sh if the person agreed): turbo off and the kernel's
        // power saving while closed. sudo -n: never prompts; if it isn't installed, nothing happens.
        if on && !restore.linux_tuned {
            if power_helper("apply") {
                restore.linux_tuned = true;
            }
        } else if !on && restore.linux_tuned && power_helper("restore") {
            restore.linux_tuned = false;
        }
        let Some((dest, path, current)) = self.power_profile() else { return false };
        if on {
            if current == "power-saver" {
                return true;
            }
            if restore.power_profile.is_none() {
                restore.power_profile = Some(current);
            }
            self.set_power_profile(dest, path, "power-saver")
        } else {
            // Only put it back if it's still the profile Ajar chose (the person may have changed it since).
            super::put_back(&mut restore.power_profile, current == "power-saver", |prev| self.set_power_profile(dest, path, prev))
        }
    }

    fn restore_settings(&mut self, restore: &mut Restore) {
        // A profile that couldn't be put back stays recorded, to be retried.
        self.set_low_power(false, restore);
        if restore.power_profile.is_none() && !restore.linux_tuned {
            *restore = Restore::default();
        }
    }

    fn slow(&mut self, pid: u32, start: u64, protected: &HashSet<u32>) -> Option<(i64, Option<String>)> {
        if pid <= 1 || protected.contains(&pid) || crate::procs::start_time(pid) != Some(start) {
            return None;
        }
        if let Some(unit) = self.app_unit(pid) {
            // The CPU limit applies to the whole unit, so never use it if anything protected (an agent, its
            // helpers, a hold's process) lives in the same unit.
            let shares_protected = self.unit_pids(pid).iter().any(|p| protected.contains(p));
            if !shares_protected && (self.throttled.contains(&unit) || self.set_unit_cpu(&unit, true)) {
                self.throttled.insert(unit.clone());
                return Some((UNIT_MARK, Some(unit)));
            }
        }
        // Fallback: nice, but only when it can be undone. Without privileges Linux only lets a process be made
        // nicer, never less nice, so a slowed app would stay slow for the rest of its life.
        unsafe {
            *libc::__errno_location() = 0;
            let prev = libc::getpriority(libc::PRIO_PROCESS, pid);
            if *libc::__errno_location() != 0 {
                return None;
            }
            let mut lim: libc::rlimit = std::mem::zeroed();
            libc::getrlimit(libc::RLIMIT_NICE, &mut lim);
            let lowest_allowed = 20 - lim.rlim_cur.min(40) as i32;
            let root = libc::geteuid() == 0;
            if !root && prev < lowest_allowed {
                return None;
            }
            if libc::setpriority(libc::PRIO_PROCESS, pid, 19) == 0 {
                Some((prev as i64, None))
            } else {
                None
            }
        }
    }

    fn unslow(&mut self, t: &Touched) -> bool {
        // Slowed through a unit: reset exactly that unit, no re-checks (they could fail and strand it).
        if let Some(unit) = &t.unit {
            let ok = self.set_unit_cpu(unit, false);
            if ok {
                self.throttled.remove(unit);
            }
            return ok;
        }
        if t.previous == UNIT_MARK || t.previous == crate::state::PREVIOUS_UNKNOWN {
            // Journal written before the change finished: find the unit the same way it was chosen.
            let Some(unit) = self.app_unit(t.pid) else {
                return t.previous == crate::state::PREVIOUS_UNKNOWN;
            };
            let ok = self.set_unit_cpu(&unit, false);
            if ok {
                self.throttled.remove(&unit);
            }
            ok
        } else {
            if crate::procs::start_time(t.pid) != Some(t.start) {
                return false;
            }
            unsafe { libc::setpriority(libc::PRIO_PROCESS, t.pid, t.previous.clamp(-20, 19) as i32) == 0 }
        }
    }

    fn verify_hold(&mut self, _restore: &mut Restore) -> Result<(), String> {
        if self.inhibitor.is_none() {
            return Err("Ajar lost its keep-awake lock".into());
        }
        Ok(())
    }

    fn watchdog_installed(&mut self) -> Option<bool> {
        let out = std::process::Command::new("systemctl").args(["--user", "is-enabled", "ajar-watchdog.timer"]).output().ok()?;
        Some(String::from_utf8_lossy(&out.stdout).trim() == "enabled")
    }

    fn pause(&mut self, pid: u32, start: u64, on: bool) -> bool {
        if pid <= 1 || pid == std::process::id() {
            return false;
        }
        signal_if_same(pid, start, if on { libc::SIGSTOP } else { libc::SIGCONT })
    }

    fn docked(&mut self) -> bool {
        // logind's Docked: an external display or a dock is connected.
        self.logind_property("Docked").and_then(|v| bool::try_from(v).ok()).unwrap_or(false) || external_display(&self.sys.join("class/drm"))
    }

    fn sleep_after_hold(&mut self) -> bool {
        if self.kde() {
            return true; // KDE's own lid action is "Do nothing" on Ajar's advice; Ajar does the sleeping
        }
        // The person set logind to ignore the lid: they want it running with the lid shut.
        let on_ac = self.on_ac();
        let key = if on_ac { "HandleLidSwitchExternalPower" } else { "HandleLidSwitch" };
        let action = self.logind_property(key).and_then(|v| String::try_from(v).ok()).unwrap_or_default();
        action != "ignore"
    }

    fn notify(&mut self, title: &str, body: &str) {
        let icon = crate::state::dir().join("icon.png");
        if !icon.exists() {
            let _ = fs::write(&icon, crate::icon::png(128, &crate::icon::app(128)));
        }
        let _ = notify_rust::Notification::new().appname("Ajar").summary(title).body(body).icon(&icon.to_string_lossy()).show();
    }

    fn set_open_at_login(&mut self, on: bool) -> Result<(), String> {
        let dir = crate::state::home().join(".config/autostart");
        let file = dir.join("ajar.desktop");
        if !on {
            crate::state::remove(&file);
            return Ok(());
        }
        let exe = app_exe()?;
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        fs::write(&file, desktop_entry(&exe, true)).map_err(|e| format!("couldn't write {}: {e}", file.display()))
    }

    fn install_watchdog(&mut self) -> Result<(), String> {
        let exe = app_exe()?;
        let dir = crate::state::home().join(".config/systemd/user");
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let service = format!(
            "[Unit]\nDescription=Ajar watchdog: puts apps and settings back if Ajar stops unexpectedly\n\n[Service]\nType=oneshot\nExecStart={} watchdog\n",
            systemd_quote(&exe.to_string_lossy())
        );
        let timer = "[Unit]\nDescription=Run the Ajar watchdog every minute\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\nAccuracySec=10s\n\n[Install]\nWantedBy=timers.target\n";
        fs::write(dir.join("ajar-watchdog.service"), service).map_err(|e| e.to_string())?;
        fs::write(dir.join("ajar-watchdog.timer"), timer).map_err(|e| e.to_string())?;
        run("systemctl", &["--user", "daemon-reload"])?;
        run("systemctl", &["--user", "enable", "--now", "ajar-watchdog.timer"])
    }

    fn uninstall(&mut self) -> Result<(), String> {
        let _ = run("systemctl", &["--user", "disable", "--now", "ajar-watchdog.timer"]);
        let dir = crate::state::home().join(".config/systemd/user");
        crate::state::remove(&dir.join("ajar-watchdog.service"));
        crate::state::remove(&dir.join("ajar-watchdog.timer"));
        let _ = run("systemctl", &["--user", "daemon-reload"]);
        self.set_open_at_login(false)
    }
}

/// Sends a signal only if `pid` is still the process that started at `start`. With a pidfd (Linux 5.3+) the
/// check and the signal refer to the same process even if the pid is reused in between.
pub const POWER_HELPER: &str = "/usr/local/libexec/ajar-power";

fn power_helper(action: &str) -> bool {
    power_helper_args(&[action])
}

fn power_helper_args(args: &[&str]) -> bool {
    Path::new(POWER_HELPER).exists()
        && std::process::Command::new("sudo")
            .arg("-n")
            .arg(POWER_HELPER)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
}

pub fn signal_if_same(pid: u32, start: u64, sig: i32) -> bool {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::c_int, 0) };
    if fd >= 0 {
        let fd = unsafe { OwnedFd::from_raw_fd(fd as i32) };
        if crate::procs::start_time(pid) != Some(start) {
            return false;
        }
        let r = unsafe { libc::syscall(libc::SYS_pidfd_send_signal, fd.as_raw_fd(), sig, std::ptr::null::<libc::siginfo_t>(), 0) };
        return r == 0;
    }
    // Older kernels: check, then signal (a tiny window remains).
    crate::procs::start_time(pid) == Some(start) && unsafe { libc::kill(pid as i32, sig) == 0 }
}

fn run(cmd: &str, args: &[&str]) -> Result<(), String> {
    let out = std::process::Command::new(cmd).args(args).output().map_err(|e| format!("{cmd}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("{cmd} {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

/// The tray app's executable (the watchdog and autostart both run it).
pub fn app_exe() -> Result<PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let sibling = me.with_file_name("ajar-app");
    Ok(if sibling.exists() { sibling } else { me })
}

/// Quotes a path for a systemd Exec line.
pub fn systemd_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('%', "%%").replace('$', "$$"))
}

/// A freedesktop .desktop entry (autostart when `hidden_start`, otherwise the app launcher entry).
pub fn desktop_entry(exe: &Path, autostart: bool) -> String {
    let p = exe.to_string_lossy();
    let quoted = format!("\"{}\"", p.replace('\\', "\\\\").replace('"', "\\\"").replace('`', "\\`").replace('$', "\\$"));
    let mut s = format!(
        "[Desktop Entry]\nType=Application\nName=Ajar\nComment=Keep the laptop awake with the lid closed while AI agents work\nExec={quoted}\nIcon=ajar\nTerminal=false\nCategories=Utility;\nStartupNotify=false\n"
    );
    if autostart {
        s.push_str("X-GNOME-Autostart-enabled=true\n");
    }
    s
}

/// The cgroup v2 path from /proc/<pid>/cgroup ("0::/user.slice/...").
pub fn cgroup_v2_path(text: &str) -> Option<String> {
    text.lines().find_map(|l| l.strip_prefix("0::")).map(|p| p.trim().to_string()).filter(|p| p.starts_with('/'))
}

/// The leaf unit, only when it's an app unit inside this user's own systemd manager (never the session
/// scope, the terminal's shared unit or anything system-wide).
pub fn app_unit_name(cgroup: &str, uid: u32) -> Option<String> {
    let marker = format!("/user@{uid}.service/");
    let rest = &cgroup[cgroup.find(&marker)? + marker.len()..];
    let leaf = rest.rsplit('/').next()?;
    let is_app = rest.starts_with("app.slice/") && leaf.starts_with("app-") && (leaf.ends_with(".scope") || leaf.ends_with(".service"));
    (is_app && !leaf.contains("terminal") && !leaf.contains("konsole") && !leaf.contains("vte-spawn")).then(|| leaf.to_string())
}

fn read(p: &Path) -> Option<String> {
    fs::read_to_string(p).ok().map(|s| s.trim().to_string())
}
fn num(p: &Path) -> Option<f64> {
    read(p)?.parse::<f64>().ok().filter(|x| x.is_finite())
}

/// Reads every system battery and charger under /sys/class/power_supply (peripheral batteries skipped).
pub fn read_battery(root: &Path) -> Option<Battery> {
    let mut found = false;
    let (mut now_wh, mut full_wh, mut watts) = (0.0, 0.0, 0.0);
    let mut caps = vec![];
    let mut charging = false;
    let mut discharging = false;
    let mut mains: Option<bool> = None;
    let mut entries: Vec<_> = fs::read_dir(root).ok()?.flatten().map(|e| e.path()).collect();
    entries.sort();
    for d in entries {
        let kind = read(&d.join("type")).unwrap_or_default();
        match kind.as_str() {
            "Mains" | "USB" | "USB_C" | "USB_PD" => {
                let online = read(&d.join("online")).as_deref() == Some("1");
                mains = Some(mains.unwrap_or(false) || online);
            }
            "Battery" => {
                if read(&d.join("scope")).as_deref() == Some("Device") || read(&d.join("present")).as_deref() == Some("0") {
                    continue;
                }
                found = true;
                let status = read(&d.join("status")).unwrap_or_default();
                charging |= status == "Charging";
                let dis = status == "Discharging";
                discharging |= dis;
                let volts = num(&d.join("voltage_now")).map(|v| v / 1e6);
                let design_v = num(&d.join("voltage_min_design")).map(|v| v / 1e6).or(volts);
                let w = num(&d.join("power_now")).map(|p| p / 1e6).or_else(|| Some(num(&d.join("current_now"))? / 1e6 * volts?));
                if dis {
                    watts += w.unwrap_or(0.0).abs();
                }
                let full = num(&d.join("energy_full")).map(|e| e / 1e6).or_else(|| Some(num(&d.join("charge_full"))? / 1e6 * design_v?));
                let now = num(&d.join("energy_now")).map(|e| e / 1e6).or_else(|| Some(num(&d.join("charge_now"))? / 1e6 * design_v?));
                if let (Some(f), Some(n)) = (full, now) {
                    if f > 0.0 {
                        full_wh += f;
                        now_wh += n;
                    }
                }
                if let Some(c) = num(&d.join("capacity")) {
                    caps.push(c);
                }
            }
            _ => {}
        }
    }
    if !found {
        return None;
    }
    let percent = if full_wh > 0.0 && caps.len() != 1 {
        now_wh / full_wh * 100.0
    } else if !caps.is_empty() {
        caps.iter().sum::<f64>() / caps.len() as f64
    } else if full_wh > 0.0 {
        now_wh / full_wh * 100.0
    } else {
        return None;
    };
    let on_ac = mains.unwrap_or(!discharging);
    Some(Battery {
        percent: percent.round().clamp(0.0, 100.0) as u32,
        watts: if charging { 0.0 } else { watts },
        on_ac,
        charging,
        full_wh: (full_wh > 0.0).then_some(full_wh),
    })
}

/// Hottest sensor relative to its own critical point (105 °C when it doesn't say). Bogus readings ignored.
pub fn read_thermal(root: &Path) -> Thermal {
    let Ok(dir) = fs::read_dir(root) else { return Thermal::Unknown };
    let mut worst = Thermal::Unknown;
    for e in dir.flatten() {
        let z = e.path();
        if !e.file_name().to_string_lossy().starts_with("thermal_zone") {
            continue;
        }
        let Some(t) = num(&z.join("temp")).map(|t| t / 1000.0) else { continue };
        if t <= 0.0 || t > 150.0 {
            continue;
        }
        let mut crit: Option<f64> = None;
        for i in 0..16 {
            match read(&z.join(format!("trip_point_{i}_type"))) {
                Some(kind) if kind == "critical" => crit = num(&z.join(format!("trip_point_{i}_temp"))).map(|t| t / 1000.0).filter(|c| *c > 60.0 && *c < 150.0),
                Some(_) => {}
                None => break,
            }
        }
        let c = crit.unwrap_or(105.0);
        let state = if t >= c - 5.0 {
            Thermal::Critical
        } else if t >= c - 15.0 {
            Thermal::Serious
        } else {
            Thermal::Normal
        };
        worst = worst.max(state);
    }
    worst
}

/// An external monitor is plugged in (any connected connector that isn't the built-in panel).
pub fn external_display(drm: &Path) -> bool {
    let Ok(dir) = fs::read_dir(drm) else { return false };
    dir.flatten().any(|e| {
        let name = e.file_name().to_string_lossy().to_string();
        let Some((_, conn)) = name.split_once('-') else { return false };
        let internal = conn.starts_with("eDP") || conn.starts_with("LVDS") || conn.starts_with("DSI");
        !internal && read(&e.path().join("status")).as_deref() == Some("connected")
    })
}

/// KDE's lid-close action for the current power source (0 = do nothing, 1 = sleep, …). Plasma 6 then 5.
pub fn kde_lid_action(on_ac: bool) -> Option<u32> {
    let cfg = crate::state::home().join(".config");
    let profile = if on_ac { "AC" } else { "Battery" };
    if let Some(t) = read(&cfg.join("powerdevilrc")) {
        if let Some(v) = ini_value(&t, &format!("[{profile}][SuspendAndShutdown]"), "LidAction") {
            return v.parse().ok();
        }
        if t.contains("[SuspendAndShutdown]") || std::env::var("KDE_SESSION_VERSION").as_deref() == Ok("6") {
            return Some(1); // Plasma 6 default: sleep
        }
    }
    if let Some(t) = read(&cfg.join("powermanagementprofilesrc")) {
        if let Some(v) = ini_value(&t, &format!("[{profile}][HandleButtonEvents]"), "lidAction") {
            return v.parse().ok();
        }
    }
    Some(1)
}

pub fn ini_value(text: &str, section: &str, key: &str) -> Option<String> {
    let mut inside = false;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            inside = line == section;
        } else if inside {
            if let Some((k, v)) = line.split_once('=') {
                if k.trim() == key {
                    return Some(v.trim().to_string());
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(name: &str, files: &[(&str, &str)]) -> PathBuf {
        let root = std::env::temp_dir().join(format!("ajar-linux-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for (path, contents) in files {
            let p = root.join(path);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, format!("{contents}\n")).unwrap();
        }
        root
    }

    #[test]
    fn battery_discharging_with_power_now() {
        let r = tree("bat1", &[
            ("AC/type", "Mains"), ("AC/online", "0"),
            ("BAT0/type", "Battery"), ("BAT0/status", "Discharging"), ("BAT0/capacity", "64"),
            ("BAT0/power_now", "7500000"), ("BAT0/energy_full", "52000000"), ("BAT0/energy_now", "33280000"),
            // A wireless mouse: must not count.
            ("hidpp_battery_0/type", "Battery"), ("hidpp_battery_0/scope", "Device"), ("hidpp_battery_0/capacity", "5"),
        ]);
        let b = read_battery(&r).unwrap();
        assert_eq!(b.percent, 64);
        assert!((b.watts - 7.5).abs() < 1e-9);
        assert!(!b.on_ac && b.discharging() && b.on_battery());
        assert!((b.full_wh.unwrap() - 52.0).abs() < 1e-9);
        let _ = fs::remove_dir_all(&r);
    }

    #[test]
    fn battery_charge_units_and_charging() {
        let r = tree("bat2", &[
            ("ADP1/type", "Mains"), ("ADP1/online", "1"),
            ("BAT1/type", "Battery"), ("BAT1/status", "Charging"), ("BAT1/capacity", "41"),
            ("BAT1/current_now", "1500000"), ("BAT1/voltage_now", "12000000"),
            ("BAT1/charge_full", "4000000"), ("BAT1/charge_now", "1640000"), ("BAT1/voltage_min_design", "11400000"),
        ]);
        let b = read_battery(&r).unwrap();
        assert_eq!(b.percent, 41);
        assert_eq!(b.watts, 0.0, "watts only count while discharging");
        assert!(b.on_ac && b.charging && !b.on_battery());
        assert!((b.full_wh.unwrap() - 45.6).abs() < 1e-6);
        let _ = fs::remove_dir_all(&r);
    }

    #[test]
    fn two_batteries_are_combined_by_energy() {
        let r = tree("bat3", &[
            ("BAT0/type", "Battery"), ("BAT0/status", "Discharging"), ("BAT0/capacity", "100"),
            ("BAT0/energy_full", "20000000"), ("BAT0/energy_now", "20000000"), ("BAT0/power_now", "3000000"),
            ("BAT1/type", "Battery"), ("BAT1/status", "Discharging"), ("BAT1/capacity", "0"),
            ("BAT1/energy_full", "60000000"), ("BAT1/energy_now", "0"), ("BAT1/power_now", "0"),
        ]);
        let b = read_battery(&r).unwrap();
        assert_eq!(b.percent, 25);
        assert!(!b.on_ac, "no charger listed and discharging: on battery");
        let _ = fs::remove_dir_all(&r);
    }

    #[test]
    fn desktop_has_no_battery() {
        let r = tree("bat4", &[("AC/type", "Mains"), ("AC/online", "1")]);
        assert!(read_battery(&r).is_none());
        let _ = fs::remove_dir_all(&r);
    }

    #[test]
    fn thermal_uses_each_zones_critical_point_and_ignores_garbage() {
        let r = tree("th", &[
            ("thermal_zone0/type", "x86_pkg_temp"), ("thermal_zone0/temp", "93000"),
            ("thermal_zone0/trip_point_0_type", "passive"), ("thermal_zone0/trip_point_0_temp", "95000"),
            ("thermal_zone0/trip_point_1_type", "critical"), ("thermal_zone0/trip_point_1_temp", "105000"),
            ("thermal_zone1/type", "acpitz"), ("thermal_zone1/temp", "255000"),
            ("cooling_device0/type", "Fan"),
        ]);
        assert_eq!(read_thermal(&r), Thermal::Serious);
        fs::write(r.join("thermal_zone0/temp"), "101000").unwrap();
        assert_eq!(read_thermal(&r), Thermal::Critical);
        fs::write(r.join("thermal_zone0/temp"), "60000").unwrap();
        assert_eq!(read_thermal(&r), Thermal::Normal);
        let _ = fs::remove_dir_all(&r);
        assert_eq!(read_thermal(Path::new("/nonexistent")), Thermal::Unknown);
    }

    #[test]
    fn only_the_apps_own_unit_is_ever_throttled() {
        let uid = 1000;
        assert_eq!(app_unit_name("/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-firefox-4211.scope", uid).as_deref(), Some("app-gnome-firefox-4211.scope"));
        assert_eq!(app_unit_name("/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.kde.konsole-1.scope", uid), None);
        assert_eq!(app_unit_name("/user.slice/user-1000.slice/session-2.scope", uid), None);
        assert_eq!(app_unit_name("/user.slice/user-1000.slice/user@1000.service/session.slice/org.gnome.Shell@wayland.service", uid), None);
        assert_eq!(app_unit_name("/user.slice/user-1001.slice/user@1001.service/app.slice/app-x.scope", uid), None);
        assert_eq!(app_unit_name("/system.slice/docker.service", uid), None);
        assert_eq!(cgroup_v2_path("12:cpu:/x\n0::/user.slice/a.scope\n").as_deref(), Some("/user.slice/a.scope"));
        assert_eq!(cgroup_v2_path("12:cpu:/x\n"), None);
    }

    #[test]
    fn external_monitor_detection() {
        let r = tree("drm", &[("card1-eDP-1/status", "connected"), ("card1-HDMI-A-1/status", "disconnected")]);
        assert!(!external_display(&r));
        fs::write(r.join("card1-HDMI-A-1/status"), "connected").unwrap();
        assert!(external_display(&r));
        let _ = fs::remove_dir_all(&r);
    }

    #[test]
    fn ini_lookup_respects_sections() {
        let t = "[AC][SuspendAndShutdown]\nLidAction=0\n\n[Battery][SuspendAndShutdown]\nLidAction=1\n";
        assert_eq!(ini_value(t, "[AC][SuspendAndShutdown]", "LidAction").as_deref(), Some("0"));
        assert_eq!(ini_value(t, "[Battery][SuspendAndShutdown]", "LidAction").as_deref(), Some("1"));
        assert_eq!(ini_value(t, "[LowBattery][SuspendAndShutdown]", "LidAction"), None);
    }

    #[test]
    fn exec_lines_are_quoted() {
        assert_eq!(systemd_quote("/opt/My Apps/ajar-app"), "\"/opt/My Apps/ajar-app\"");
        assert_eq!(systemd_quote("/a/100%/$x"), "\"/a/100%%/$$x\"");
        assert!(desktop_entry(Path::new("/opt/a b/ajar-app"), true).contains("Exec=\"/opt/a b/ajar-app\""));
    }
}
