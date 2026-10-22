import Foundation

/// An app Nocturnal slowed or paused. Written to disk *before* the change is made, so a crash at any moment leaves
/// a record of everything Nocturnal touched. Undo checks pid, start time and executable path, so a reused pid is
/// never touched.
struct Touched: Codable, Equatable {
    var pid: Int32
    var start: UInt64
    var path: String
    var paused: Bool

    /// Still the very process Nocturnal changed.
    var isSameProcess: Bool { Procs.startTime(pid) == start && Procs.path(pid) == path }
}

enum Journal {
    static var url: URL { StateFiles.dir.appendingPathComponent("touched.json") }

    static func load() -> [Touched] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Touched].self, from: d)) ?? []
    }

    /// Paused processes as plain "pid<TAB>path" lines, for the watchdog script: it can resume them even if the app
    /// itself has been deleted.
    static var resumeList: URL { StateFiles.dir.appendingPathComponent("resume-pids") }

    /// True only once the list is safely on disk (temp file, flushed, renamed). Empty removes the file.
    @discardableResult
    static func save(_ list: [Touched]) -> Bool {
        let paused = list.filter(\.paused).map { "\($0.pid)\t\($0.path)\n" }.joined()
        if paused.isEmpty { StateFiles.remove(resumeList) } else { _ = StateFiles.writeDurably(Data(paused.utf8), to: resumeList) }
        if list.isEmpty { StateFiles.remove(url); return !StateFiles.exists(url) }
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return StateFiles.writeDurably(data, to: url)
    }

    /// Puts each entry back. Returns the ones the OS refused that still belong to the same process (they stay
    /// in the journal and are retried). An entry whose process has exited needs nothing and is dropped.
    static func undo(_ list: [Touched]) -> [Touched] {
        var left: [Touched] = []
        for t in list where t.isSameProcess {
            let ok = t.paused ? Throttle.freeze(t.pid, start: t.start, false) : Throttle.background(t.pid, start: t.start, false)
            if !ok && t.isSameProcess { left.append(t) }
        }
        return left
    }

    /// Before this version the journal was two text files ("pid<TAB>path" per line). Undo those once.
    static func undoLegacyFiles() {
        for (url, paused) in [(StateFiles.paused, true), (StateFiles.slowed, false)] {
            guard let text = StateFiles.read(url) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {   // handles a missing final newline
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let pid = pid_t(parts[0]), Procs.path(pid) == parts[1], let start = Procs.startTime(pid) else { continue }
                _ = paused ? Throttle.freeze(pid, start: start, false) : Throttle.background(pid, start: start, false)
            }
            StateFiles.remove(url)
        }
    }
}

/// The app's sign of life for the watchdog: "unix-time pid start-time", rewritten every tick.
enum Heartbeat {
    static func beat() {
        let pid = getpid()
        let s = "\(Int(Date().timeIntervalSince1970)) \(pid) \(Procs.startTime(pid) ?? 0)"
        StateFiles.write(s, to: StateFiles.alive)   // atomic: the watchdog never reads a half-written file
    }

    /// How long the app can go without a heartbeat before it counts as hung. It beats every 2 seconds, and while
    /// it holds the Mac awake App Nap is switched off for it, so two minutes of silence means it's stuck.
    static let hungAfter: TimeInterval = 120

    /// The app that wrote the heartbeat is still running (same process) and checked in within two minutes. Right
    /// after the Mac wakes the watchdog can run before the app's first tick, so a wake in the last three minutes
    /// counts as alive. A dead app is noticed at once, a hung one within about three minutes. An old-style
    /// heartbeat (no pid) gets 90 seconds.
    static func appIsAlive() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: StateFiles.alive.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let f = (StateFiles.read(StateFiles.alive) ?? "").split(separator: " ").compactMap { UInt64($0) }
        if f.count == 3 {
            let age = Date().timeIntervalSince1970 - Double(f[0])
            let pid = pid_t(truncatingIfNeeded: f[1])
            guard f[2] != 0, Procs.startTime(pid) == f[2] else { return false }
            if age < hungAfter { return true }
            if let woke = lastWake, Date().timeIntervalSince(woke) < 180 { return true }
            return false
        }
        return Date().timeIntervalSince(mtime) < 90
    }

    /// When the Mac last woke from sleep.
    static var lastWake: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

/// The person's safety settings as last set in Nocturnal's own UI. Edits to config.json (by hand, a script or an
/// agent) can make them stricter, never weaker. This stops accidental and agent-driven loosening; a program
/// running as the same user could still edit this file too, so it isn't a defence against deliberate attacks.
struct Safety: Codable, Equatable {
    var heatGuard: Bool
    var batteryFloor: Int
    var onlyOnPower: Bool? = nil
    static var url: URL { StateFiles.dir.appendingPathComponent("safety.json") }
    static func load() -> Safety? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Safety.self, from: $0) } }
    func save() { _ = StateFiles.writeDurably((try? JSONEncoder().encode(self)) ?? Data(), to: Self.url) }
}

/// Runs every minute from launchd (`Nocturnal cli watchdog`). If the app has died or hung, put back everything it
/// changed. Pure Swift with the same checks the app uses; no shell parsing.
enum Watchdog {
    static func run(force: Bool) -> String {
        if !force && Heartbeat.appIsAlive() { return "alive" }
        Journal.undoLegacyFiles()
        let left = Journal.undo(Journal.load())
        Journal.save(left)
        var ok = left.isEmpty
        if !DisplayPower.restoreBuiltIn() { ok = false }
        Brightness.restore()
        if StateFiles.exists(Brightness.restoreFile) { ok = false }
        if let saved = StateFiles.read(StateFiles.modeRestore) {
            let parts = saved.split(separator: " ").map(String.init)
            // Changed by the person since: theirs now, leave it.
            if let cur = PowerMode.battery(), cur.value != 1 { StateFiles.remove(StateFiles.modeRestore) }
            else if parts.count != 2 || Shell.pmsetRoot(["-b", parts[0], parts[1]]) { StateFiles.remove(StateFiles.modeRestore) } else { ok = false }
        }
        var released = false
        if StateFiles.exists(StateFiles.hold) {
            if !Registry.sleepDisabled || SleepSwitch.notOurs { StateFiles.remove(StateFiles.hold) }   // off before Nocturnal: left as it was
            else if Shell.pmsetRoot(["-a", "disablesleep", "0"]) { StateFiles.remove(StateFiles.hold); released = true }
            else { ok = false }
        }
        if !TimeMachine.resume() { ok = false }
        // macOS only sleeps on the lid-close edge. If the lid is already shut, ask for sleep directly, or a
        // crashed session would leave the Mac running in a bag until the battery runs out.
        if released && Registry.lidClosed { Shell.pmsetRoot(["sleepnow"]) }
        // Nothing left to undo: drop the stale heartbeat so the every-minute job stops launching this binary.
        if ok && !Heartbeat.appIsAlive() { StateFiles.remove(StateFiles.alive) }
        return ok ? "restored" : "partly restored"
    }

    /// Plain-language list of what Nocturnal has changed right now (for `nocturnal doctor` and `nocturnal rescue`).
    static func outstanding() -> [String] {
        systemChanges() + (AutoApprove.isOn ? ["Approve everything is on: Claude Code and Codex run without asking (turn off in Settings › Agents)"] : [])
    }

    /// Changes to the Mac itself that must be undone (Approve everything is a setting the person chose, not one).
    static func systemChanges() -> [String] {
        var out = Journal.load().map { "\($0.paused ? "paused" : "slowed") \(($0.path as NSString).lastPathComponent) (pid \($0.pid))" }
        if StateFiles.exists(StateFiles.hold) || (Registry.sleepDisabled && !SleepSwitch.notOurs) {
            out.append(Registry.sleepDisabled ? "sleep is switched off (pmset disablesleep 1)" : "hold marker present")
        }
        if StateFiles.exists(StateFiles.modeRestore) { out.append("Low Power Mode changed") }
        if TimeMachine.paused { out.append("Time Machine automatic backups paused") }
        if StateFiles.exists(Brightness.restoreFile) { out.append("screen dimmed to zero") }
        if StateFiles.exists(DisplayPower.marker) { out.append("built-in screen switched off") }
        return out
    }
}
