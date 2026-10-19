//! A snapshot of running processes with CPU time, from `/proc` on Linux and the Toolhelp/process APIs on
//! Windows. No subprocesses, no third-party crates.

use crate::config::exe_key;

#[derive(Clone, Debug, Default)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    /// Executable name as Ajar compares it (lowercase, no `.exe`).
    pub name: String,
    /// Full executable path when readable (own-user processes).
    pub exe: Option<String>,
    /// Command line, used to recognise agents that run under node, bun or python.
    pub cmd: Vec<String>,
    /// Total CPU time used so far, in nanoseconds.
    pub cpu_ns: u64,
    /// When the process started (platform units, only compared for equality to detect pid reuse).
    pub start: u64,
    /// Owned by the current user, so Ajar may read and adjust it.
    pub mine: bool,
}

pub fn snapshot() -> Vec<Proc> {
    imp::snapshot()
}

/// The start-time token for one pid, or None if it isn't running.
pub fn start_time(pid: u32) -> Option<u64> {
    imp::start_time(pid)
}

pub fn alive(pid: u32) -> bool {
    imp::start_time(pid).is_some()
}

/// The current working folder's name for a process (shown as the agent's project). Linux only.
pub fn cwd_name(pid: u32) -> Option<String> {
    imp::cwd_name(pid)
}

pub fn exe_path(pid: u32) -> Option<String> {
    imp::exe_path(pid)
}

/// (now, units per second) in the same units as `Proc::start`, so the age of a process can be computed.
pub fn start_clock() -> Option<(u64, u64)> {
    imp::start_clock()
}

/// Seconds since a process started, from its start token.
pub fn age_secs(start: u64, clock: (u64, u64)) -> Option<u64> {
    let (now, per_sec) = clock;
    (per_sec > 0 && now >= start).then(|| (now - start) / per_sec)
}

/// The comparable executable name of one running process (same rule as `Proc::name`).
pub fn name_of(pid: u32) -> Option<String> {
    imp::exe_path(pid).map(|p| exe_key(&p))
}

#[cfg(target_os = "linux")]
mod imp {
    use super::*;
    use std::fs;

    fn ticks_per_sec() -> u64 {
        let t = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if t > 0 { t as u64 } else { 100 }
    }

    /// Fields after the command name in /proc/<pid>/stat. The name is in parentheses and may contain
    /// spaces or ')' itself, so split at the LAST ')'.
    fn stat_fields(pid: u32) -> Option<(String, Vec<String>)> {
        let s = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let open = s.find('(')?;
        let close = s.rfind(')')?;
        let comm = s.get(open + 1..close)?.to_string();
        let rest: Vec<String> = s.get(close + 2..)?.split_whitespace().map(str::to_string).collect();
        Some((comm, rest))
    }

    pub fn start_clock() -> Option<(u64, u64)> {
        let up: f64 = fs::read_to_string("/proc/uptime").ok()?.split_whitespace().next()?.parse().ok()?;
        let tps = ticks_per_sec();
        Some(((up * tps as f64) as u64, tps))
    }

    pub fn start_time(pid: u32) -> Option<u64> {
        // Field 22 (starttime) is index 19 after the name.
        stat_fields(pid)?.1.get(19)?.parse().ok()
    }

    pub fn exe_path(pid: u32) -> Option<String> {
        fs::read_link(format!("/proc/{pid}/exe")).ok().map(|p| p.to_string_lossy().trim_end_matches(" (deleted)").to_string())
    }

    pub fn cwd_name(pid: u32) -> Option<String> {
        let p = fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
        let home = crate::state::home();
        if p == home {
            return Some("~".into());
        }
        if p.as_os_str() == "/" {
            return None;
        }
        p.file_name().map(|n| n.to_string_lossy().to_string())
    }

    pub fn snapshot() -> Vec<Proc> {
        let my_uid = unsafe { libc::getuid() };
        let ns_per_tick = 1_000_000_000 / ticks_per_sec();
        let mut out = Vec::new();
        let Ok(entries) = fs::read_dir("/proc") else { return out };
        for e in entries.flatten() {
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
            let Some((comm, f)) = stat_fields(pid) else { continue };
            // Kernel threads have no command line and no executable; skip them.
            let cmd: Vec<String> = fs::read(format!("/proc/{pid}/cmdline"))
                .map(|b| b.split(|c| *c == 0).filter(|s| !s.is_empty()).map(|s| String::from_utf8_lossy(s).into_owned()).collect())
                .unwrap_or_default();
            if cmd.is_empty() {
                continue;
            }
            let ppid = f.get(1).and_then(|x| x.parse().ok()).unwrap_or(0);
            let utime: u64 = f.get(11).and_then(|x| x.parse().ok()).unwrap_or(0);
            let stime: u64 = f.get(12).and_then(|x| x.parse().ok()).unwrap_or(0);
            let start = f.get(19).and_then(|x| x.parse().ok()).unwrap_or(0);
            let mine = {
                use std::os::unix::fs::MetadataExt;
                fs::metadata(format!("/proc/{pid}")).map(|m| m.uid() == my_uid).unwrap_or(false)
            };
            let exe = if mine { exe_path(pid) } else { None };
            // comm is truncated to 15 chars; prefer the executable's real name.
            let name = exe.as_deref().map(exe_key).unwrap_or_else(|| exe_key(&comm));
            out.push(Proc { pid, ppid, name, exe, cmd, cpu_ns: (utime + stime) * ns_per_tick, start, mine });
        }
        out
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcessId, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;

    #[link(name = "ntdll")]
    unsafe extern "system" {
        fn NtQueryInformationProcess(h: HANDLE, class: u32, info: *mut core::ffi::c_void, len: u32, ret: *mut u32) -> i32;
    }
    const PROCESS_COMMAND_LINE_INFORMATION: u32 = 60;

    pub fn ft_pub(f: FILETIME) -> u64 {
        ft(f)
    }

    fn ft(f: FILETIME) -> u64 {
        ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64
    }

    fn open(pid: u32) -> Option<HANDLE> {
        let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if h.is_null() { None } else { Some(h) }
    }

    fn times(h: HANDLE) -> Option<(u64, u64)> {
        unsafe {
            let (mut c, mut e, mut k, mut u): (FILETIME, FILETIME, FILETIME, FILETIME) = (zeroed(), zeroed(), zeroed(), zeroed());
            if GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u) == 0 {
                return None;
            }
            // FILETIME ticks are 100 ns.
            Some((ft(c), (ft(k) + ft(u)) * 100))
        }
    }

    fn image(h: HANDLE) -> Option<String> {
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        if unsafe { QueryFullProcessImageNameW(h, 0, buf.as_mut_ptr(), &mut len) } == 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }

    /// The command line via NtQueryInformationProcess(ProcessCommandLineInformation), Windows 8.1+.
    fn command_line(h: HANDLE) -> Vec<String> {
        let mut buf = vec![0u8; 8192];
        let mut ret = 0u32;
        let status = unsafe { NtQueryInformationProcess(h, PROCESS_COMMAND_LINE_INFORMATION, buf.as_mut_ptr().cast(), buf.len() as u32, &mut ret) };
        if status < 0 || (ret as usize) < 16 {
            return vec![];
        }
        // Result is a UNICODE_STRING { Length: u16, MaximumLength: u16, (pad), Buffer: *u16 } pointing into buf.
        let len = u16::from_le_bytes([buf[0], buf[1]]) as usize / 2;
        let ptr = usize::from_le_bytes(buf[8..16].try_into().unwrap_or([0; 8])) as *const u16;
        let base = buf.as_ptr() as usize;
        if ptr.is_null() || (ptr as usize) < base || (ptr as usize) + len * 2 > base + buf.len() {
            return vec![];
        }
        let wide = unsafe { std::slice::from_raw_parts(ptr, len) };
        String::from_utf16_lossy(wide).split_whitespace().map(|s| s.trim_matches('"').to_string()).collect()
    }

    pub fn start_clock() -> Option<(u64, u64)> {
        let mut ft: FILETIME = unsafe { zeroed() };
        unsafe { windows_sys::Win32::System::SystemInformation::GetSystemTimeAsFileTime(&mut ft) };
        Some((ft_pub(ft), 10_000_000))
    }

    pub fn start_time(pid: u32) -> Option<u64> {
        let h = open(pid)?;
        let t = times(h).map(|t| t.0);
        unsafe { CloseHandle(h) };
        t
    }

    pub fn exe_path(pid: u32) -> Option<String> {
        let h = open(pid)?;
        let p = image(h);
        unsafe { CloseHandle(h) };
        p
    }

    pub fn cwd_name(_pid: u32) -> Option<String> {
        None
    }

    pub fn snapshot() -> Vec<Proc> {
        let mut out = Vec::new();
        unsafe {
            let mut my_session = 0u32;
            ProcessIdToSessionId(GetCurrentProcessId(), &mut my_session);
            let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snap == INVALID_HANDLE_VALUE {
                return out;
            }
            let mut e: PROCESSENTRY32W = zeroed();
            e.dwSize = size_of::<PROCESSENTRY32W>() as u32;
            let mut ok = Process32FirstW(snap, &mut e) != 0;
            while ok {
                let pid = e.th32ProcessID;
                if pid > 4 {
                    let end = e.szExeFile.iter().position(|c| *c == 0).unwrap_or(e.szExeFile.len());
                    let raw = String::from_utf16_lossy(&e.szExeFile[..end]);
                    let mut session = u32::MAX;
                    ProcessIdToSessionId(pid, &mut session);
                    let mine = session == my_session;
                    let mut p = Proc { pid, ppid: e.th32ParentProcessID, name: exe_key(&raw), mine, ..Default::default() };
                    if let Some(h) = open(pid) {
                        if let Some((start, cpu)) = times(h) {
                            p.start = start;
                            p.cpu_ns = cpu;
                        }
                        if mine {
                            p.exe = image(h);
                            if matches!(p.name.as_str(), "node" | "bun" | "deno" | "python" | "python3" | "pythonw") {
                                p.cmd = command_line(h);
                            }
                        }
                        CloseHandle(h);
                    }
                    out.push(p);
                }
                ok = Process32NextW(snap, &mut e) != 0;
            }
            CloseHandle(snap);
        }
        out
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod imp {
    use super::*;
    pub fn snapshot() -> Vec<Proc> { vec![] }
    pub fn start_clock() -> Option<(u64, u64)> { None }
    pub fn start_time(_pid: u32) -> Option<u64> { None }
    pub fn cwd_name(_pid: u32) -> Option<String> { None }
    pub fn exe_path(_pid: u32) -> Option<String> { None }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn sees_itself_with_cpu_time_and_start() {
        let me = std::process::id();
        let all = snapshot();
        let p = all.iter().find(|p| p.pid == me).expect("own process listed");
        assert!(p.mine);
        assert!(p.start > 0);
        assert_eq!(start_time(me), Some(p.start));
    }

    #[test]
    fn dead_pid_is_not_alive() {
        assert!(!alive(4_000_000));
    }
}
