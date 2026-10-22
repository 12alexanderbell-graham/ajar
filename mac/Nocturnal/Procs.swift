import AppKit
import Darwin
import UniformTypeIdentifiers

/// Thin wrappers over libproc. Everything here is a cheap syscall; no subprocesses.
enum Procs {
    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return got > 0 ? pids.prefix(Int(got)).filter { $0 > 0 } : []
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// When the process started (microseconds since 1970). A pid with a different start time is a different
    /// process that reused the number, so every change and every undo checks this first.
    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? pid_t(info.pbsi_ppid) : nil
    }

    static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? info : nil
    }

    /// Full argv, used only for interpreter processes (node, bun, python) to tell `claude` from any other script.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        var start = i
        while i < size && args.count < argc {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper" → "/Applications/Google Chrome.app".
    /// The outermost bundle wins so every helper rolls up into the app people recognise.
    nonisolated static func bundlePath(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

/// Darwin background priority: the process keeps running but only on efficiency cores with low I/O priority.
/// Measured on an M5 Max MacBook Pro: a busy process went from 2.15 W to 0.49 W while still doing ~60% of the work.
/// Both act only if `pid` is still the process that started at `start`, and report whether the OS agreed.
enum Throttle {
    @discardableResult
    static func background(_ pid: pid_t, start: UInt64, _ on: Bool) -> Bool {
        guard pid > 1, Procs.startTime(pid) == start else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0
    }
    @discardableResult
    static func freeze(_ pid: pid_t, start: UInt64, _ on: Bool) -> Bool {
        guard pid > 1, pid != getpid(), Procs.startTime(pid) == start else { return false }
        return kill(pid, on ? SIGSTOP : SIGCONT) == 0
    }
}

struct AppUsage: Identifiable, Equatable {
    var id: String            // bundle path, or executable name for command-line tools
    var name: String
    var bundleID: String?
    var watts: Double
    /// Part of macOS (WindowServer, daemons). Their lid-closed draw is in the fixed base estimate, and most of it
    /// is display and UI work that stops when the lid shuts.
    var system = false

    static func isSystemPath(_ path: String) -> Bool {
        if path.contains("/Cryptexes/App/System/Applications/") { return false }   // Safari and friends are user apps
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }
}

/// Turns macOS's per-process energy counters into watts per app.
/// The counters are the kernel's own energy model (what Activity Monitor's Energy tab uses), not a CPU% guess.
final class EnergySampler {
    private var last: [pid_t: UInt64] = [:]
    private var lastTime: Date?
    private var pathCache: [pid_t: String] = [:]
    private var meta: [String: (name: String, bundleID: String?)] = [:]

    /// Watts per app since the previous call. The first call only primes the counters and returns [].
    func sample() -> [AppUsage] {
        let now = Date()
        var current: [pid_t: UInt64] = [:]
        var groups: [String: AppUsage] = [:]
        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        let pids = Procs.allPids()
        let alive = Set(pids)
        pathCache = pathCache.filter { alive.contains($0.key) }

        for pid in pids {
            guard let u = Procs.usage(pid) else { continue }
            current[pid] = u.ri_energy_nj
            guard dt > 0.2, let prev = last[pid], u.ri_energy_nj >= prev else { continue }
            let w = Double(u.ri_energy_nj - prev) / 1e9 / dt
            guard w < 500 else { continue }   // counter reset on exec; skip the garbage delta

            let path: String
            if let p = pathCache[pid] { path = p } else if let p = Procs.path(pid) { path = p; pathCache[pid] = p } else { continue }
            let key = Procs.bundlePath(of: path) ?? (path as NSString).lastPathComponent
            let info = describe(key)
            var g = groups[key] ?? AppUsage(id: key, name: info.name, bundleID: info.bundleID, watts: 0, system: AppUsage.isSystemPath(path))
            g.watts += w
            groups[key] = g
        }
        last = current
        lastTime = now
        return groups.values.sorted { $0.watts > $1.watts }
    }

    private func describe(_ key: String) -> (name: String, bundleID: String?) {
        if let m = meta[key] { return m }
        var m: (String, String?) = (key, nil)
        if key.hasSuffix(".app") {
            let b = Bundle(path: key)
            let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            m = (name, b?.bundleIdentifier)
        }
        meta[key] = m
        return m
    }

    static func icon(for usage: AppUsage) -> NSImage {
        usage.id.hasSuffix(".app")
            ? NSWorkspace.shared.icon(forFile: usage.id)
            : NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
