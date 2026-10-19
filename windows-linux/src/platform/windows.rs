//! Windows 10 and 11.
//!
//! Keeping awake = power requests (SystemRequired + ExecutionRequired, and DisplayRequired on Modern Standby
//! laptops, which sleep whenever the screen goes off). They show up in `powercfg /requests` with Ajar's reason
//! and die with the process. Windows sleeps on lid close regardless of power requests, so while holding Ajar
//! sets the plan's "When I close the lid" to "Do nothing" and puts the old value back afterwards; that change
//! persists if Ajar is killed, so it is recorded in restore.json and the watchdog task restores it within a
//! minute of Ajar disappearing.
//!
//! Lid state comes from GUID_LIDSWITCH_STATE_CHANGE notifications on a hidden window. There is no public
//! temperature API without admin rights, so the heat guard reports Unknown here.

use super::{Battery, Platform, Thermal};
use crate::state::{Restore, Touched};
use std::collections::HashSet;
use std::os::windows::process::CommandExt;
use std::sync::atomic::{AtomicI8, AtomicIsize, Ordering};
use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::Power::*;
use windows_sys::Win32::System::Registry::{RegDeleteKeyValueW, RegDeleteTreeW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ};
use windows_sys::Win32::System::SystemServices::{GUID_LIDCLOSE_ACTION, GUID_LIDSWITCH_STATE_CHANGE, GUID_SYSTEM_BUTTON_SUBGROUP};
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const AUMID: &str = "Ajar.App";
const TASK: &str = "Ajar Watchdog";

/// -1 unknown, 0 closed, 1 open. Written by the hidden window's thread.
static LID: AtomicI8 = AtomicI8::new(-1);
static POWER_HWND: AtomicIsize = AtomicIsize::new(0);

#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtSuspendProcess(h: HANDLE) -> i32;
    fn NtResumeProcess(h: HANDLE) -> i32;
}

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

pub fn same(a: &GUID, b: &GUID) -> bool {
    a.data1 == b.data1 && a.data2 == b.data2 && a.data3 == b.data3 && a.data4 == b.data4
}

pub fn guid_string(g: &GUID) -> String {
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        g.data1, g.data2, g.data3, g.data4[0], g.data4[1], g.data4[2], g.data4[3], g.data4[4], g.data4[5], g.data4[6], g.data4[7]
    )
}

pub fn parse_guid(s: &str) -> Option<GUID> {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 32 || s.len() > 38 {
        return None;
    }
    Some(GUID::from_u128(u128::from_str_radix(&hex, 16).ok()?))
}

struct Caps {
    lid: bool,
    modern_standby: bool,
}

fn caps() -> Caps {
    unsafe {
        let mut c: SYSTEM_POWER_CAPABILITIES = std::mem::zeroed();
        let st = CallNtPowerInformation(SystemPowerCapabilities, std::ptr::null(), 0, &mut c as *mut _ as *mut _, std::mem::size_of::<SYSTEM_POWER_CAPABILITIES>() as u32);
        if st != 0 {
            return Caps { lid: false, modern_standby: false };
        }
        Caps { lid: c.LidPresent, modern_standby: c.AoAc }
    }
}

fn active_scheme() -> Option<GUID> {
    unsafe {
        let mut p: *mut GUID = std::ptr::null_mut();
        if PowerGetActiveScheme(std::ptr::null_mut(), &mut p) != 0 || p.is_null() {
            return None;
        }
        let g = *p;
        windows_sys::Win32::Foundation::LocalFree(p as _);
        Some(g)
    }
}

fn read_lid_action(scheme: &GUID) -> Option<(u32, u32)> {
    unsafe {
        let (mut ac, mut dc) = (0u32, 0u32);
        let a = PowerReadACValueIndex(std::ptr::null_mut(), scheme, &GUID_SYSTEM_BUTTON_SUBGROUP, &GUID_LIDCLOSE_ACTION, &mut ac);
        let d = PowerReadDCValueIndex(std::ptr::null_mut(), scheme, &GUID_SYSTEM_BUTTON_SUBGROUP, &GUID_LIDCLOSE_ACTION, &mut dc);
        (a == 0 && d == 0).then_some((ac, dc))
    }
}

fn write_lid_action(scheme: &GUID, ac: u32, dc: u32) -> bool {
    unsafe {
        let a = PowerWriteACValueIndex(std::ptr::null_mut(), scheme, &GUID_SYSTEM_BUTTON_SUBGROUP, &GUID_LIDCLOSE_ACTION, ac);
        let d = PowerWriteDCValueIndex(std::ptr::null_mut(), scheme, &GUID_SYSTEM_BUTTON_SUBGROUP, &GUID_LIDCLOSE_ACTION, dc);
        // Re-applying the active plan makes the new values take effect immediately.
        if let Some(active) = active_scheme() {
            if same(&active, scheme) {
                PowerSetActiveScheme(std::ptr::null_mut(), scheme);
            }
        }
        a == 0 && d == 0
    }
}

type GetOverlay = unsafe extern "system" fn(*mut GUID) -> u32;
type SetOverlay = unsafe extern "system" fn(GUID) -> u32;

/// The undocumented-but-stable overlay functions behind the "Power mode" slider (Windows 10 1709+).
fn overlay_fns() -> Option<(GetOverlay, SetOverlay)> {
    use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
    unsafe {
        let m = LoadLibraryW(wide("powrprof.dll").as_ptr());
        if m.is_null() {
            return None;
        }
        let g = GetProcAddress(m, c"PowerGetActualOverlayScheme".as_ptr().cast())?;
        let s = GetProcAddress(m, c"PowerSetActiveOverlayScheme".as_ptr().cast())?;
        type Farproc = unsafe extern "system" fn() -> isize;
        Some((std::mem::transmute::<Farproc, GetOverlay>(g), std::mem::transmute::<Farproc, SetOverlay>(s)))
    }
}

/// "Best power efficiency" overlay.
const OVERLAY_EFFICIENCY: GUID = GUID::from_u128(0x961cc777_2547_4f9d_8174_7d86181b8a7a);

/// Puts the lid setting back straight from the journal. Used when Windows is logging off or shutting down,
/// which can end Ajar without its normal shutdown; the watchdog doesn't run while nobody is logged in.
pub fn restore_lid_from_journal() {
    let path = crate::state::file("restore.json");
    let Some(mut r) = crate::state::load_json::<Restore>(&path) else { return };
    let mut plans: Vec<(String, u32, u32)> = std::mem::take(&mut r.lid_more);
    if let (Some((ac, dc)), Some(s)) = (r.lid_action.take(), r.lid_scheme.take()) {
        plans.push((s, ac, dc));
    }
    for (s, ac, dc) in plans {
        if let Some(g) = parse_guid(&s) {
            if read_lid_action(&g).is_none_or(|cur| cur == (0, 0)) {
                write_lid_action(&g, ac, dc);
            }
        }
    }
    crate::state::save_json(&path, &r);
}

/// The process's creation time read through the same handle that will be acted on, so a reused pid is caught.
fn handle_start(h: HANDLE) -> Option<u64> {
    use windows_sys::Win32::Foundation::FILETIME;
    unsafe {
        let (mut c, mut e, mut k, mut u): (FILETIME, FILETIME, FILETIME, FILETIME) = std::mem::zeroed();
        if GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u) == 0 {
            return None;
        }
        Some(((c.dwHighDateTime as u64) << 32) | c.dwLowDateTime as u64)
    }
}

/// Lets this process call SetSuspendState (it needs the shutdown privilege enabled, not just held).
fn enable_shutdown_privilege() {
    use windows_sys::Win32::Foundation::LUID;
    use windows_sys::Win32::Security::{AdjustTokenPrivileges, LookupPrivilegeValueW, LUID_AND_ATTRIBUTES, SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY};
    unsafe {
        let mut tok: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut tok) == 0 {
            return;
        }
        let mut luid: LUID = std::mem::zeroed();
        if LookupPrivilegeValueW(std::ptr::null(), wide("SeShutdownPrivilege").as_ptr(), &mut luid) != 0 {
            let tp = TOKEN_PRIVILEGES { PrivilegeCount: 1, Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }] };
            AdjustTokenPrivileges(tok, 0, &tp, 0, std::ptr::null_mut(), std::ptr::null_mut());
        }
        CloseHandle(tok);
    }
}

/// An external display is active (the laptop is being used at a desk with the lid shut).
fn external_display_active() -> bool {
    use windows_sys::Win32::Devices::Display::*;
    unsafe {
        let (mut np, mut nm) = (0u32, 0u32);
        if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut np, &mut nm) != 0 || np == 0 {
            return false;
        }
        let mut paths: Vec<DISPLAYCONFIG_PATH_INFO> = vec![std::mem::zeroed(); np as usize];
        let mut modes: Vec<DISPLAYCONFIG_MODE_INFO> = vec![std::mem::zeroed(); nm as usize];
        if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut np, paths.as_mut_ptr(), &mut nm, modes.as_mut_ptr(), std::ptr::null_mut()) != 0 {
            return false;
        }
        paths.truncate(np as usize);
        paths.iter().any(|p| {
            let t = p.targetInfo.outputTechnology;
            t != DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL
                && t != DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
                && t != DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED
                && t != DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS
        })
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_QUERYENDSESSION {
        return 1;
    }
    if msg == WM_ENDSESSION && wp != 0 {
        restore_lid_from_journal();
        return 0;
    }
    if msg == WM_POWERBROADCAST && wp == PBT_POWERSETTINGCHANGE as usize && lp != 0 {
        let s = &*(lp as *const POWERBROADCAST_SETTING);
        if same(&s.PowerSetting, &GUID_LIDSWITCH_STATE_CHANGE) && s.DataLength >= 1 {
            let open = *s.Data.as_ptr();
            LID.store(if open == 0 { 0 } else { 1 }, Ordering::SeqCst);
        }
        return 1;
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

/// A never-shown window on its own thread that receives lid notifications (and handles "screen off").
fn start_power_window() {
    if POWER_HWND.load(Ordering::SeqCst) != 0 {
        return;
    }
    std::thread::Builder::new()
        .name("ajar-power".into())
        .spawn(|| unsafe {
            let class = wide("AjarPowerWindow");
            let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(0, class.as_ptr(), wide("Ajar").as_ptr(), 0, 0, 0, 0, 0, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null());
            if hwnd.is_null() {
                return;
            }
            POWER_HWND.store(hwnd as isize, Ordering::SeqCst);
            // Windows sends the current state right after registering.
            RegisterPowerSettingNotification(hwnd as HANDLE, &GUID_LIDSWITCH_STATE_CHANGE, DEVICE_NOTIFY_WINDOW_HANDLE);
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                DispatchMessageW(&msg);
            }
        })
        .ok();
}

pub struct Win {
    /// The person's own lid setting is already "Do nothing": Ajar changes nothing and never sleeps it after.
    user_do_nothing: bool,
    request: HANDLE,
    /// Fallback when power requests aren't available: the older thread execution state (always called from
    /// the engine thread, which lives as long as the app).
    exec_state: bool,
    reason: Vec<u16>,
    caps: Caps,
}

impl Win {
    pub fn new() -> Win {
        start_power_window();
        Win { user_do_nothing: false, request: std::ptr::null_mut(), exec_state: false, reason: vec![], caps: caps() }
    }

    fn release_request(&mut self) {
        unsafe {
            if !self.request.is_null() {
                CloseHandle(self.request);
                self.request = std::ptr::null_mut();
            }
            if self.exec_state {
                SetThreadExecutionState(ES_CONTINUOUS);
                self.exec_state = false;
            }
        }
    }

    /// Sets "Do nothing" in one plan, journaling the original first. Rolls back a half-done write.
    fn take_over_lid(scheme: &GUID, restore: &mut Restore, primary: bool) -> Result<(), String> {
        let current = read_lid_action(scheme).ok_or("Couldn't read what closing the lid does")?;
        if current == (0, 0) {
            return Ok(());
        }
        let id = guid_string(scheme);
        if primary {
            restore.lid_action = Some(current);
            restore.lid_scheme = Some(id.clone());
        } else {
            restore.lid_more.push((id.clone(), current.0, current.1));
        }
        let undo = |r: &mut Restore| {
            if primary {
                r.lid_action = None;
                r.lid_scheme = None;
            } else {
                r.lid_more.retain(|m| m.0 != id);
            }
        };
        if !crate::state::save_json(&crate::state::file("restore.json"), restore) {
            undo(restore);
            return Err("Ajar couldn't save its recovery record (is the disk full?), so it won't change what closing the lid does".into());
        }
        if !write_lid_action(scheme, 0, 0) {
            write_lid_action(scheme, current.0, current.1); // AC may have changed before DC failed
            undo(restore);
            crate::state::save_json(&crate::state::file("restore.json"), restore);
            return Err("Windows didn't let Ajar change what closing the lid does (a work or school policy may block it)".into());
        }
        Ok(())
    }

    fn open(pid: u32, access: u32) -> Option<HANDLE> {
        let h = unsafe { OpenProcess(access, 0, pid) };
        (!h.is_null()).then_some(h)
    }
}

impl Default for Win {
    fn default() -> Self {
        Win::new()
    }
}

impl Drop for Win {
    fn drop(&mut self) {
        if !self.request.is_null() {
            unsafe { CloseHandle(self.request) };
        }
    }
}

fn run_hidden(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = std::process::Command::new(cmd).args(args).creation_flags(CREATE_NO_WINDOW).output().map_err(|e| format!("{cmd}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Err(format!("{cmd}: {}{}", String::from_utf8_lossy(&out.stderr).trim(), String::from_utf8_lossy(&out.stdout).trim()))
    }
}

fn reg_set(subkey: &str, name: &str, value: &str) -> bool {
    let data = wide(value);
    unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, wide(subkey).as_ptr(), wide(name).as_ptr(), REG_SZ, data.as_ptr() as _, (data.len() * 2) as u32) == 0 }
}

pub fn app_exe() -> Result<std::path::PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    let sibling = me.with_file_name("ajar-app.exe");
    Ok(if sibling.exists() { sibling } else { me })
}

pub fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

/// Task Scheduler definition: every minute, forever, on battery too (schtasks' own defaults stop on battery,
/// which is exactly when the watchdog matters).
pub fn task_xml(exe: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Puts apps and power settings back if Ajar stops unexpectedly.</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>2025-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>{}</Command><Arguments>watchdog</Arguments></Exec></Actions>
</Task>
"#,
        xml_escape(exe)
    )
}

impl Platform for Win {
    fn name(&self) -> &'static str {
        "windows"
    }

    fn ready(&mut self) -> Result<(), String> {
        Ok(())
    }

    fn has_lid(&mut self) -> bool {
        self.caps.lid
    }

    fn lid_closed(&mut self) -> bool {
        LID.load(Ordering::SeqCst) == 0
    }

    fn battery(&mut self) -> Option<Battery> {
        unsafe {
            let mut s: SYSTEM_POWER_STATUS = std::mem::zeroed();
            if GetSystemPowerStatus(&mut s) == 0 || s.BatteryFlag & 128 != 0 || s.BatteryFlag == 255 {
                return None;
            }
            let mut b: SYSTEM_BATTERY_STATE = std::mem::zeroed();
            let ok = CallNtPowerInformation(SystemBatteryState, std::ptr::null(), 0, &mut b as *mut _ as *mut _, std::mem::size_of::<SYSTEM_BATTERY_STATE>() as u32) == 0;
            if ok && !b.BatteryPresent {
                return None;
            }
            let percent = if s.BatteryLifePercent <= 100 {
                s.BatteryLifePercent as u32
            } else if ok && b.MaxCapacity > 0 {
                (b.RemainingCapacity as f64 / b.MaxCapacity as f64 * 100.0).round().min(100.0) as u32
            } else {
                return None;
            };
            // Rate is mW, negative while discharging (the field is declared unsigned).
            let rate = b.Rate as i32;
            let charging = ok && b.Charging;
            let watts = if ok && rate < 0 && rate != i32::MIN { -rate as f64 / 1000.0 } else { 0.0 };
            Some(Battery {
                percent,
                watts: if charging { 0.0 } else { watts },
                on_ac: s.ACLineStatus == 1,
                charging,
                full_wh: (ok && b.MaxCapacity > 0 && b.MaxCapacity != u32::MAX).then(|| b.MaxCapacity as f64 / 1000.0),
            })
        }
    }

    fn thermal(&mut self) -> Thermal {
        Thermal::Unknown
    }

    fn begin_hold(&mut self, reason: &str, restore: &mut Restore) -> Result<(), String> {
        unsafe {
            if self.request.is_null() && !self.exec_state {
                self.reason = wide(&format!("Ajar: {reason}"));
                let ctx = REASON_CONTEXT {
                    Version: 0, // POWER_REQUEST_CONTEXT_VERSION
                    Flags: POWER_REQUEST_CONTEXT_SIMPLE_STRING,
                    Reason: REASON_CONTEXT_0 { SimpleReasonString: self.reason.as_mut_ptr() },
                };
                let h = PowerCreateRequest(&ctx);
                let created = !h.is_null() && h != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
                if created && PowerSetRequest(h, PowerRequestSystemRequired) != 0 {
                    PowerSetRequest(h, PowerRequestExecutionRequired);
                    if self.caps.modern_standby {
                        // Modern Standby laptops go to sleep whenever the screen turns off.
                        PowerSetRequest(h, PowerRequestDisplayRequired);
                    }
                    self.request = h;
                } else {
                    if created {
                        CloseHandle(h);
                    }
                    if !self.exec_state {
                        let mut flags = ES_CONTINUOUS | ES_SYSTEM_REQUIRED;
                        if self.caps.modern_standby {
                            flags |= ES_DISPLAY_REQUIRED;
                        }
                        if SetThreadExecutionState(flags) == 0 {
                            return Err("Windows refused Ajar's request to stay awake".into());
                        }
                        self.exec_state = true;
                    }
                }
            }
        }
        if self.caps.lid && restore.lid_action.is_none() {
            let result = active_scheme().ok_or_else(|| "Couldn't read the active power plan".to_string()).and_then(|scheme| {
                self.user_do_nothing = read_lid_action(&scheme) == Some((0, 0));
                Win::take_over_lid(&scheme, restore, true)
            });
            if let Err(e) = result {
                // Don't leave the keep-awake request behind when the hold as a whole failed.
                self.release_request();
                return Err(e);
            }
        }
        Ok(())
    }

    fn end_hold(&mut self, restore: &mut Restore) -> Result<(), String> {
        self.release_request();
        let mut failed = false;
        restore.lid_more.retain(|(s, ac, dc)| {
            let Some(g) = parse_guid(s) else { return false };
            let still_ours = read_lid_action(&g).is_none_or(|cur| cur == (0, 0));
            let ok = !still_ours || write_lid_action(&g, *ac, *dc);
            failed |= !ok;
            !ok
        });
        if failed {
            return Err("Couldn't put back what closing the lid does in every power plan".into());
        }
        if let Some((ac, dc)) = restore.lid_action {
            let scheme = restore.lid_scheme.as_deref().and_then(parse_guid).or_else(active_scheme).ok_or("Couldn't find the power plan")?;
            // Only undo Ajar's own change: if the value is no longer "Do nothing", someone set it deliberately.
            let still_ours = read_lid_action(&scheme).is_none_or(|cur| cur == (0, 0));
            if still_ours && !write_lid_action(&scheme, ac, dc) {
                return Err("Couldn't put back what closing the lid does".into());
            }
            restore.lid_action = None;
            restore.lid_scheme = None;
        }
        Ok(())
    }

    fn sleep_now(&mut self) {
        let hwnd = POWER_HWND.load(Ordering::SeqCst) as HWND;
        let screen_off = || unsafe {
            if !hwnd.is_null() {
                // Handled by DefWindowProc: turns the displays off, which sends Modern Standby laptops to sleep.
                PostMessageW(hwnd, WM_SYSCOMMAND, SC_MONITORPOWER as usize, 2);
            }
        };
        if self.caps.modern_standby {
            screen_off();
        } else {
            enable_shutdown_privilege();
            if !unsafe { SetSuspendState(false, false, false) } {
                screen_off();
            }
        }
    }

    fn set_low_power(&mut self, on: bool, restore: &mut Restore) -> bool {
        let Some((get, set)) = overlay_fns() else { return false };
        unsafe {
            let mut cur: GUID = std::mem::zeroed();
            if get(&mut cur) != 0 {
                return false;
            }
            if on {
                if same(&cur, &OVERLAY_EFFICIENCY) {
                    return true;
                }
                if restore.power_overlay.is_none() {
                    restore.power_overlay = Some(guid_string(&cur));
                }
                set(OVERLAY_EFFICIENCY) == 0
            } else {
                match restore.power_overlay.take().and_then(|s| parse_guid(&s)) {
                    // Only if it's still Ajar's choice; the person may have moved the slider since.
                    Some(prev) if same(&cur, &OVERLAY_EFFICIENCY) => set(prev) == 0,
                    _ => true,
                }
            }
        }
    }

    fn restore_settings(&mut self, restore: &mut Restore) {
        let _ = self.end_hold(restore);
        self.set_low_power(false, restore);
        if restore.lid_action.is_none() && restore.lid_more.is_empty() {
            *restore = Restore::default();
        }
    }

    fn slow(&mut self, pid: u32, start: u64, protected: &HashSet<u32>) -> Option<(i64, Option<String>)> {
        if protected.contains(&pid) {
            return None;
        }
        let h = Win::open(pid, PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION)?;
        unsafe {
            if handle_start(h) != Some(start) {
                CloseHandle(h);
                return None;
            }
            let prev = GetPriorityClass(h);
            let ok = prev != 0 && SetPriorityClass(h, IDLE_PRIORITY_CLASS) != 0;
            if ok {
                // Efficiency mode (EcoQoS): runs it on efficient cores at low clocks.
                let s = PROCESS_POWER_THROTTLING_STATE { Version: PROCESS_POWER_THROTTLING_CURRENT_VERSION, ControlMask: PROCESS_POWER_THROTTLING_EXECUTION_SPEED, StateMask: PROCESS_POWER_THROTTLING_EXECUTION_SPEED };
                SetProcessInformation(h, ProcessPowerThrottling, &s as *const _ as _, std::mem::size_of_val(&s) as u32);
            }
            CloseHandle(h);
            ok.then_some((prev as i64, None))
        }
    }

    fn unslow(&mut self, t: &Touched) -> bool {
        let Some(h) = Win::open(t.pid, PROCESS_SET_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION) else { return false };
        unsafe {
            if handle_start(h) != Some(t.start) {
                CloseHandle(h);
                return false;
            }
            let prev = if t.previous > 0 && t.previous <= u32::MAX as i64 { t.previous as u32 } else { NORMAL_PRIORITY_CLASS };
            let ok = SetPriorityClass(h, prev) != 0;
            // Hand throttling back to Windows' own heuristics.
            let s = PROCESS_POWER_THROTTLING_STATE { Version: PROCESS_POWER_THROTTLING_CURRENT_VERSION, ControlMask: 0, StateMask: 0 };
            SetProcessInformation(h, ProcessPowerThrottling, &s as *const _ as _, std::mem::size_of_val(&s) as u32);
            CloseHandle(h);
            ok
        }
    }

    fn docked(&mut self) -> bool {
        external_display_active()
    }

    fn sleep_after_hold(&mut self) -> bool {
        !self.user_do_nothing
    }

    fn verify_hold(&mut self, restore: &mut Restore) -> Result<(), String> {
        if self.request.is_null() && !self.exec_state {
            return Err("Ajar lost its keep-awake request".into());
        }
        if restore.lid_action.is_some() {
            let scheme = restore.lid_scheme.as_deref().and_then(parse_guid).or_else(active_scheme).ok_or("Couldn't read the power plan")?;
            if let Some(cur) = read_lid_action(&scheme) {
                if cur != (0, 0) {
                    // Something changed "When I close the lid" during the hold. Holding is the explicit intent,
                    // so set it back, and say so.
                    write_lid_action(&scheme, 0, 0);
                    return Err("Something changed what closing the lid does while Ajar was keeping it awake; Ajar set it back to \"Do nothing\" for now".into());
                }
            }
            // Another plan became active (OEM tools switch plans on plug/unplug): take it over too.
            if let Some(active) = active_scheme() {
                let id = guid_string(&active);
                if !same(&active, &scheme) && !restore.lid_more.iter().any(|m| m.0 == id) {
                    Win::take_over_lid(&active, restore, false)?;
                }
            }
        }
        Ok(())
    }

    fn watchdog_installed(&mut self) -> Option<bool> {
        Some(run_hidden("schtasks.exe", &["/Query", "/TN", TASK]).is_ok())
    }

    fn pause(&mut self, pid: u32, start: u64, on: bool) -> bool {
        if pid <= 4 || pid == std::process::id() {
            return false;
        }
        let Some(h) = Win::open(pid, PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION) else { return false };
        let st = unsafe {
            if handle_start(h) != Some(start) {
                CloseHandle(h);
                return false;
            }
            if on { NtSuspendProcess(h) } else { NtResumeProcess(h) }
        };
        unsafe { CloseHandle(h) };
        st >= 0
    }

    fn notify(&mut self, title: &str, body: &str) {
        // Registering an AppUserModelID makes toasts say "Ajar" with its icon instead of "Windows PowerShell".
        let icon = crate::state::file("icon.png");
        if !icon.exists() {
            let _ = std::fs::write(&icon, crate::icon::png(128, &crate::icon::app(128)));
        }
        let key = format!("Software\\Classes\\AppUserModelId\\{AUMID}");
        reg_set(&key, "DisplayName", "Ajar");
        reg_set(&key, "IconUri", &icon.to_string_lossy());
        let _ = notify_rust::Notification::new().app_id(AUMID).summary(title).body(body).show();
    }

    fn set_open_at_login(&mut self, on: bool) -> Result<(), String> {
        let run = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        if on {
            let exe = app_exe()?;
            if reg_set(run, "Ajar", &format!("\"{}\"", exe.display())) {
                Ok(())
            } else {
                Err("Couldn't add Ajar to startup apps".into())
            }
        } else {
            unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, wide(run).as_ptr(), wide("Ajar").as_ptr()) };
            Ok(())
        }
    }

    fn install_watchdog(&mut self) -> Result<(), String> {
        let exe = app_exe()?;
        let xml = task_xml(&exe.to_string_lossy());
        let path = std::env::temp_dir().join(format!("ajar-task-{}.xml", std::process::id()));
        let mut bytes = vec![0xFF, 0xFE];
        for u in xml.encode_utf16() {
            bytes.extend(u.to_le_bytes());
        }
        std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
        let r = run_hidden("schtasks.exe", &["/Create", "/F", "/TN", TASK, "/XML", &path.to_string_lossy()]);
        let _ = std::fs::remove_file(&path);
        r.map(|_| ())
    }

    fn uninstall(&mut self) -> Result<(), String> {
        let _ = run_hidden("schtasks.exe", &["/Delete", "/F", "/TN", TASK]);
        unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, wide(&format!("Software\\Classes\\AppUserModelId\\{AUMID}")).as_ptr()) };
        self.set_open_at_login(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guid_round_trip() {
        let s = guid_string(&OVERLAY_EFFICIENCY);
        assert_eq!(s, "961cc777-2547-4f9d-8174-7d86181b8a7a");
        assert!(same(&parse_guid(&s).unwrap(), &OVERLAY_EFFICIENCY));
        assert!(same(&parse_guid("{961CC777-2547-4F9D-8174-7D86181B8A7A}").unwrap(), &OVERLAY_EFFICIENCY));
        assert!(parse_guid("nope").is_none());
    }

    #[test]
    fn task_xml_escapes_the_path_and_runs_on_battery() {
        let x = task_xml(r"C:\Users\A&B\Ajar\ajar-app.exe");
        assert!(x.contains(r"C:\Users\A&amp;B\Ajar\ajar-app.exe"));
        assert!(x.contains("<DisallowStartIfOnBatteries>false"));
        assert!(x.contains("<StopIfGoingOnBatteries>false"));
    }
}
