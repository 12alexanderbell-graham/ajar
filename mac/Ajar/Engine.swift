import AppKit
import IOKit.pwr_mgt
import Observation
import ServiceManagement

/// Session record shown after the lid opens again.
struct Receipt: Equatable {
    var closedAt: Date
    var openedAt: Date?
    /// When Ajar asked the Mac to sleep.
    var sleepRequestedAt: Date?
    /// Set only when macOS actually went to sleep (its own will-sleep notification), never on request alone.
    var sleptAt: Date?
    var sleptBecause: String?
    var startPercent: Int?
    var endPercent: Int?
    var agentName: String?
}

@MainActor
@Observable
final class Engine {
    // MARK: Settings — all in `config`, mirrored to config.json

    private(set) var config = Config.load()

    /// Change settings through here; it saves, reloads watchers and re-applies whatever needs it.
    func update(_ change: (inout Config) -> Void) {
        var c = config
        change(&c)
        apply(c, save: true)
    }

    private func apply(_ c: Config, save: Bool) {
        guard c != config else { return }
        let old = config
        config = c
        if old.mode != c.mode && c.mode != .on { config.alwaysUntil = nil; config.modeBeforeAlways = nil }
        if save && !previewOnly {
            try? config.encoded().write(to: Config.url, options: .atomic)
            if old.heatGuard != config.heatGuard || old.batteryFloor != config.batteryFloor {
                Safety(heatGuard: config.heatGuard, batteryFloor: config.batteryFloor).save()
            }
        }
        if old.watchedApps != c.watchedApps || old.countRequests != c.countRequests || old.customAgents != c.customAgents { sampleWatchers() }
        if old.screenOffNoLock != c.screenOffNoLock && lidClosed && holding && !c.lockOnClose {
            if c.screenOffNoLock { switchScreenOff() } else { DisplayPower.restoreBuiltIn(); screenOff = false }
        }
        if (old.preset != c.preset || old.appRules != c.appRules || old.lowPowerWhileClosed != c.lowPowerWhileClosed
            || old.pauseSimulators != c.pauseSimulators || old.pauseBackgroundAudio != c.pauseBackgroundAudio) && lidClosed && holding {
            reapplyClosedState()
        }
        evaluate()
    }

    var mode: Mode { get { config.mode } set { update { $0.mode = newValue } } }
    var preset: Preset { get { config.preset } set { update { $0.preset = newValue } } }
    var lowPowerWhileClosed: Bool { get { config.lowPowerWhileClosed } set { update { $0.lowPowerWhileClosed = newValue } } }
    var sleepWhenDone: Bool { get { config.sleepWhenDone } set { update { $0.sleepWhenDone = newValue } } }
    var quietMinutes: Int { get { config.quietMinutes } set { update { $0.quietMinutes = newValue } } }
    var batteryFloor: Int { get { config.batteryFloor } set { update { $0.batteryFloor = newValue } } }
    var heatGuard: Bool { get { config.heatGuard } set { update { $0.heatGuard = newValue } } }
    var onlyOnPower: Bool { get { config.onlyOnPower } set { update { $0.onlyOnPower = newValue } } }
    var countClaudeApp: Bool { get { config.countClaudeApp } set { update { $0.countClaudeApp = newValue } } }
    var countRequests: Bool { get { config.countRequests } set { update { $0.countRequests = newValue } } }
    var watchedApps: [WatchedApp] { get { config.watchedApps } set { update { $0.watchedApps = newValue } } }
    var appRules: [String: AppRule] { get { config.appRules } set { update { $0.appRules = newValue } } }
    var menuBarText: MenuBarText { get { config.menuBarText } set { update { $0.menuBarText = newValue } } }

    // MARK: Live state

    /// End of a timed Always (stored in config.json with the mode).
    var onUntil: Date? { config.mode == .on ? config.alwaysUntil.map { Date(timeIntervalSince1970: $0) } : nil }
    private(set) var holds: [Hold] = []
    private(set) var setupReady = Setup.isReady
    private(set) var setupError: String?
    private(set) var lidClosed = Registry.lidClosed
    private(set) var battery: BatteryReading? = Battery.read()
    private(set) var holding = false
    private(set) var holdReason: String?
    private(set) var blockedReason: String?
    private(set) var sessions: [AgentSession] = []
    private(set) var blockers: [SleepBlocker] = []
    private(set) var apps: [AppUsage] = []
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var receipt: Receipt?
    private(set) var fullWh: Double = UserDefaults.standard.double(forKey: "fullWh") > 20 ? UserDefaults.standard.double(forKey: "fullWh") : 70
    var panelOpen = false { didSet { if panelOpen && !oldValue { refreshFast() } } }

    // Savings
    private(set) var stats = SavingsStats.load()
    /// Watts being saved right now by slowing/pausing apps (lid closed), measured.
    private(set) var liveSavingW = 0.0
    private(set) var sessionWh = 0.0
    private(set) var lastTest: SavingsTest?
    private(set) var measuring = false
    private var targeted: [String: AppRule] = [:]        // bundle path → rule currently applied
    private var baseline: [String: Double] = [:]         // bundle path → watts when running normally
    private var lastSavingSample: Date?
    private var sleepInfo: (at: Date, watts: Double)?
    /// What the Mac draws with the lid open on battery (smoothed), and the value captured as the lid closed.
    private(set) var openDraw: Double? = UserDefaults.standard.object(forKey: "openDraw") as? Double
    private var openDrawAtClose: Double?
    /// Whole-Mac watts from the battery controller (on battery or charger), averaged between readings.
    private(set) var systemWatts: Double?
    private var lastPowerSample: PowerSample?
    /// What the Mac draws with the lid closed while Ajar holds it, learned from real readings.
    private(set) var closedDraw: Double? = UserDefaults.standard.object(forKey: "closedDraw") as? Double
    /// Simulators, previews and audio holders found on the last lid-closed pass.
    private(set) var background = BackgroundWork.Found()
    private var lidWatcher: LidWatcher?
    /// Watts each saving is worth, from `ajar power test` (step → watts saved).
    private(set) var powerEffects: [String: Double] = (UserDefaults.standard.dictionary(forKey: "powerEffects2") as? [String: Double]) ?? [:]
    private(set) var powerTestRunning = false
    private(set) var powerTestProgress: String?
    /// Savings the last test couldn't pin down (the Mac's own load moved too much while measuring).
    private(set) var powerUnclear = Set(UserDefaults.standard.stringArray(forKey: "powerUnclear") ?? [])

    struct Outlook {
        var percentSaved: Double     // 0…1, closed-with-Ajar vs. open
        var extraHours: Double
        var totalHours: Double       // with the lid closed, down to the battery limit
        var measured: Bool           // true while closed (both sides measured)
    }

    /// "Saving X%, runs Y longer": closed with Ajar versus leaving the lid open doing the same work.
    var outlook: Outlook? {
        guard let b = battery else { return nil }
        let closed = (lidClosed ? (systemWatts ?? drawNow) : nil) ?? closedEstimate
        let open = lidClosed ? (openDrawAtClose ?? openDraw) : (drawNow ?? openDraw)
        guard let base = open, base > closed + 0.2, closed > 0.3 else { return nil }
        let usable = Double(max(0, b.percent - config.batteryFloor)) / 100 * fullWh
        return Outlook(percentSaved: 1 - closed / base, extraHours: usable / closed - usable / base,
                       totalHours: usable / closed, measured: lidClosed && holding)
    }

    /// Fired on changes worth announcing in the notch: (title, subtitle).
    var onAnnounce: ((String, String) -> Void)?

    private let watcher = AgentWatcher()
    private let sampler = EnergySampler()
    private var timer: Timer?
    private var configWatcher: ConfigWatcher?
    private var ticks = 0
    /// Apps Ajar slowed or paused, mirrored to touched.json before each change (see Journal).
    private var touched: [Touched] = []
    /// Last time a counted agent was busy / was running at all. The quiet countdown runs from these, so it
    /// survives the agent's process exiting.
    private(set) var lastWork: (at: Date, name: String)?
    private(set) var lastSeen: (at: Date, name: String)?
    /// "Let it sleep now": agents don't keep the Mac awake until the lid next opens or the Mac wakes.
    private(set) var snoozed = false
    /// Something about the watchdog or a hold that the person should know.
    private(set) var warning: String?
    /// Phone control status, set by the relay.
    var remoteStatus: String?
    private var sleepRetries = 0
    private var floorLatched = false
    /// The person chose "Keep Awake Anyway" below the battery limit. Lasts until the charger is connected.
    private(set) var floorOverride = false

    /// True when the battery limit is what's stopping Ajar, so offering "Stay Awake" makes sense.
    var blockedByFloor: Bool {
        guard config.batteryFloor > 0, let b = battery, b.discharging || !b.onAC, !floorOverride else { return false }
        // Same 3% band `evaluate` uses, so the button stays while the limit is still what's stopping Ajar.
        return b.percent <= config.batteryFloor + (floorLatched ? 3 : 0)
    }

    func overrideFloor(_ on: Bool = true) {
        floorOverride = on
        if on { floorLatched = false }
        evaluate()
    }
    private var lastOnAC: Bool?
    private var previewOnly = false

    init(passive: Bool = false) {
        previewOnly = passive
        if !passive {
            if let broken = Config.setAsideIfBroken() {
                pendingNotes.append(("Settings file couldn't be read", "Ajar is using its defaults. Your file was kept as \(broken)."))
                try? config.encoded().write(to: Config.url, options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: Config.url.path) { try? config.encoded().write(to: Config.url, options: .atomic) }
            enforceSafety()
            Setup.refreshWatchdogScript()
            recoverFromCrash()
            restoreRuntime()
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.macWillSleep() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.snoozed = false; self?.evaluate() }
            }
            configWatcher = ConfigWatcher { [weak self] in
                MainActor.assumeIsolated { self?.reloadConfigFromDisk() }
            }
            // Lid events instead of polling; the main loop still checks every few seconds as a backstop.
            lidWatcher = LidWatcher { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let lid = Registry.lidClosed
                    if lid != self.lidClosed { self.lidChanged(to: lid) }
                }
            }
        }
        _ = sampler.sample()
        sampleWatchers()
        evaluate()
        guard !passive else { return }
        settleAdoptedHold()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermal = ProcessInfo.processInfo.thermalState; self?.evaluate() }
        }
    }

    private func reloadConfigFromDisk() {
        guard let data = try? Data(contentsOf: Config.url), let c = try? JSONDecoder().decode(Config.self, from: data) else { return }
        apply(c, save: false)
        enforceSafety()
    }

    /// Notes waiting to be shown (from startup, before notifications are wired).
    var pendingNotes: [(String, String)] = []

    /// Undoes any loosening of the heat guard or battery limit that didn't come from Ajar's own UI.
    private func enforceSafety() {
        guard !previewOnly else { return }
        guard let s = Safety.load() else { Safety(heatGuard: config.heatGuard, batteryFloor: config.batteryFloor).save(); return }
        var undone: [String] = []
        var c = config
        if s.heatGuard && !c.heatGuard { c.heatGuard = true; undone.append("the heat guard stays on") }
        if c.batteryFloor < s.batteryFloor { c.batteryFloor = s.batteryFloor; undone.append("the battery limit stays at \(s.batteryFloor)%") }
        if undone.isEmpty {
            if c.heatGuard != s.heatGuard || c.batteryFloor != s.batteryFloor { Safety(heatGuard: c.heatGuard, batteryFloor: c.batteryFloor).save() }
            return
        }
        config = c
        try? c.encoded().write(to: Config.url, options: .atomic)
        let note = ("Settings file change ignored", "Safety settings can only be loosened in Ajar itself: " + undone.joined(separator: " and ") + ".")
        if let n = onNote { n(note.0, note.1) } else { pendingNotes.append(note) }
    }

    /// Shown as a notification (wired by Notifier).
    var onNote: ((String, String) -> Void)?

    // MARK: Loop

    private func tick() {
        ticks += 1
        Heartbeat.beat()
        // Asked to sleep a minute ago, lid still shut, still running: ask again (up to 3 times).
        if let asked = receipt?.sleepRequestedAt, receipt?.sleptAt == nil, lidClosed, !holding,
           sleepRetries < 3, Date().timeIntervalSince(asked) >= 60 * Double(sleepRetries + 1) {
            sleepRetries += 1
            Shell.pmsetRoot(["sleepnow"])
        }
        let lid = Registry.lidClosed
        if lid != lidClosed { lidChanged(to: lid) }

        if ticks % (panelOpen ? 1 : 5) == 0 { readBattery() }
        let agentEvery = panelOpen ? 2 : (lidClosed ? 8 : 5)
        if ticks % agentEvery == 0 { sampleWatchers() }
        if panelOpen || ticks % 15 == 0 {
            let fresh = sampler.sample()
            if !fresh.isEmpty {   // a too-soon sample returns nothing; never treat that as "everything dropped to 0 W"
                apps = Array(fresh.prefix(60))
                updateBaseline()
                if lidClosed && holding { accumulateSavings() }
            }
        }
        if lidClosed && holding && !powerTestRunning && ticks % 15 == 0 { applyClosedTargets(preset: effectivePreset) }   // catch apps and simulators started while closed
        // Retry anything that couldn't be put back earlier.
        if !touched.isEmpty && !(lidClosed && holding) && ticks % 5 == 0 { restoreApps() }
        if holding { StateFiles.touch(StateFiles.hold) }
        if ticks % 150 == 3 { checkWatchdog() }
        if pendingRelease, Shell.pmsetRoot(["-a", "disablesleep", "0"]) {
            pendingRelease = false
            StateFiles.remove(StateFiles.hold)
        }
        if ticks % 5 == 0 { reloadConfigIfEdited() }
        evaluate()
        settleAdoptedHold()
    }

    /// Catches in-place edits (nano, `echo >`) that the folder watcher can miss.
    private var configMTime: Date?
    private func reloadConfigIfEdited() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Config.url.path)[.modificationDate]) as? Date
        if let m, let old = configMTime, m > old { reloadConfigFromDisk() }
        configMTime = m
    }

    private func sampleWatchers() {
        let extra = config.customAgents.map { AgentKind(id: "custom:" + $0.name, name: $0.name, executables: Set($0.executables),
                                                       scriptHints: [], transcriptDirs: [], idleWatts: $0.idleWatts ?? 0.05) }
        watcher.sample(custom: config.watchedApps, requests: config.countRequests, extraKinds: extra)
        sessions = watcher.sessions
        blockers = watcher.blockers
        let now = Date()
        for s in sessions where counts(s) {
            lastSeen = (now, s.kind.name)
            if isWorking(s) { lastWork = (max(s.lastActive, now.addingTimeInterval(-20)), s.kind.name) }
        }
        detectFinished()
    }

    private func counts(_ s: AgentSession) -> Bool {
        !s.kind.isRequest && !config.trackOnly.contains(s.kind.id) && !(s.kind == AgentKind.claudeApp && !config.countClaudeApp)
    }

    /// Launchd still has the watchdog loaded; if not, reinstall it once, then warn.
    private var watchdogRepairTried = false
    private func checkWatchdog() {
        guard !previewOnly, setupReady else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = Setup.watchdogLoaded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if loaded { self.warning = nil; return }
                if !self.watchdogRepairTried { self.watchdogRepairTried = true; try? Setup.installWatchdog(); if Setup.watchdogLoaded { self.warning = nil; return } }
                self.warning = "The safety watchdog isn't running, so a crash wouldn't be cleaned up automatically. Run Set Up again in Settings."
            }
        }
    }

    // MARK: "Finished" alerts

    /// Session id → when it started working, for sessions working at the last sample.
    private var workingSince: [String: Date] = [:]
    /// Went quiet: (busy since, quiet since). Announced only if still quiet 2 minutes later.
    private var idlePending: [String: (since: Date, quietAt: Date)] = [:]
    private var finishedNames: [String: String] = [:]
    /// Called with (agent name, minutes it was busy, whether its process is gone) once an agent that was busy
    /// for at least a minute has been quiet for 2 minutes. Ajar can't tell success from a crash or a question
    /// waiting for an answer, so this is "went idle", never "finished".
    var onFinished: ((String, Double, Bool) -> Void)?

    private func detectFinished() {
        let now = Date()
        var working: [String: Date] = [:]
        for s in sessions where !s.kind.isRequest && isWorking(s) {
            if s.kind == AgentKind.claudeApp && !config.countClaudeApp { continue }
            // Keyed by kind: sessions of one kind are merged under whichever pid comes first, which can change.
            // Busy again within the 2-minute wait: same stretch of work.
            working[s.kind.id] = workingSince[s.kind.id] ?? idlePending.removeValue(forKey: s.kind.id)?.since ?? now
        }
        for (id, since) in workingSince where working[id] == nil { idlePending[id] = (since, now) }
        workingSince = working
        for (id, p) in idlePending where now.timeIntervalSince(p.quietAt) >= 120 {
            idlePending[id] = nil
            let minutes = p.quietAt.timeIntervalSince(p.since) / 60
            guard minutes >= 1, !previewOnly else { continue }
            let present = sessions.first { $0.kind.id == id }
            onFinished?(present?.kind.name ?? finishedNames[id] ?? "Agent", minutes, present == nil)
        }
        for s in sessions { finishedNames[s.kind.id] = s.kind.name }
    }

    func refreshFast() {
        readBattery()
        sampleWatchers()
        let fresh = sampler.sample()
        if !fresh.isEmpty { apps = Array(fresh.prefix(60)) }   // too soon after the last sample returns nothing
        guard !previewOnly else { return }
        // `sudo -l` launches a process: check off the main thread so opening the panel never stutters.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = Setup.isReady
            DispatchQueue.main.async { [weak self] in
                guard let self, self.setupReady != ready else { return }
                self.setupReady = ready
                self.evaluate()
            }
        }
    }

    /// A fresh energy sample over one second, for callers outside the panel (CLI, MCP). Uses its own sampler
    /// so it never steals the interval the 2-second loop is measuring.
    func sampleEnergyNow(then done: @escaping () -> Void) {
        let probe = EnergySampler()
        _ = probe.sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let fresh = probe.sample()
            if !fresh.isEmpty { self.apps = Array(fresh.prefix(60)) }
            done()
        }
    }

    private func readBattery() {
        guard let b = Battery.read() else { return }
        if let last = lastOnAC, last != b.onAC, holding {   // unplug/replug: re-assert, and say so if it didn't hold
            if !Shell.pmsetRoot(["-a", "disablesleep", "1"]) || !Registry.sleepDisabled { warning = "macOS didn't keep sleep switched off after the power change" }
        }
        lastOnAC = b.onAC
        battery = b
        if b.charging { floorOverride = false }
        // Whole-Mac power from the battery controller: works on the charger too, and includes the display, memory
        // and radios that per-app counters can't see. Without it, fall back to battery discharge.
        if let s = PowerSensor.sample() {
            systemWatts = lastPowerSample.flatMap { PowerSensor.average($0, s) } ?? s.watts
            lastPowerSample = s
        } else {
            systemWatts = b.discharging ? b.watts : nil
        }
        if let w = systemWatts, w > 0.3 {
            if !lidClosed {
                openDraw = openDraw.map { $0 * 0.85 + w * 0.15 } ?? w
                if ticks % 30 == 0 { UserDefaults.standard.set(openDraw, forKey: "openDraw") }
            } else if holding && !powerTestRunning {
                closedDraw = closedDraw.map { $0 * 0.9 + w * 0.1 } ?? w
                if ticks % 30 == 0 { UserDefaults.standard.set(closedDraw, forKey: "closedDraw") }
            }
        }
        // Learn the pack's real size from macOS's own time estimate: Wh left = W × h left.
        if let m = b.minutesLeft, b.watts > 1, b.percent > 5 {
            let wh = b.watts * Double(m) / 60 / (Double(b.percent) / 100)
            if wh > 20 && wh < 140 { fullWh = fullWh * 0.8 + wh * 0.2; UserDefaults.standard.set(fullWh, forKey: "fullWh") }
        }
    }

    // MARK: Decision

    var activeAgent: AgentSession? {
        let window = TimeInterval(config.quietMinutes * 60)
        return sessions.first { s in
            if s.kind == AgentKind.claudeApp && !config.countClaudeApp { return false }
            if config.trackOnly.contains(s.kind.id) { return false }
            return config.sleepWhenDone ? Date().timeIntervalSince(s.lastActive) < window : true
        }
    }

    /// Why an agent is keeping the Mac awake, with the countdown once it's winding down. Survives the agent's
    /// process exiting: the quiet time still runs out before the Mac sleeps.
    func workReason() -> String? {
        let window = config.sleepWhenDone ? TimeInterval(config.quietMinutes * 60) : 120
        if let a = activeAgent {
            if a.kind.isRequest { return Self.describe(a) }
            let name = a.instances > 1 ? "\(a.kind.name) ×\(a.instances)" : a.kind.name
            if isWorking(a) { return a.toolRunning && a.watts < a.kind.idleWatts ? "\(name) is running a command" : Self.describe(a) }
            if !config.sleepWhenDone { return "\(name) is open" }
            let left = window - Date().timeIntervalSince(a.lastActive)
            return "\(name) went idle · sleeps in \(PanelFormat.minutes(max(60, left)))"
        }
        guard let last = config.sleepWhenDone ? lastWork : lastSeen else { return nil }
        let left = window - Date().timeIntervalSince(last.at)
        return left > 0 ? "\(last.name) stopped · sleeps in \(PanelFormat.minutes(left))" : nil
    }

    func evaluate() {
        // Without working permissions nothing can be held; never leave a hold running unsupervised.
        guard setupReady else { if holding { endHold(because: "Setup needs repair") }; return }
        if config.mode == .on, let until = onUntil, Date() > until {
            let back = config.modeBeforeAlways ?? .auto
            update { $0.mode = back; $0.alwaysUntil = nil; $0.modeBeforeAlways = nil }
            return
        }
        let before = holds.count
        holds.removeAll { !$0.isAlive }
        if holds.count != before { saveRuntime() }

        var want = false
        var reason: String?
        switch config.mode {
        case .off:
            // Holds are explicit requests (a timer, `ajar run`, a Shortcut), so they work even when Ajar is off.
            if let h = holds.last { want = true; reason = h.reason }
        case .on: want = true; reason = onUntil.map { "Awake until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Always awake"
        case .auto:
            if let h = holds.last { want = true; reason = h.reason }
            else if snoozed { }   // "Let it sleep now": agents wait until the lid opens again
            else if let r = workReason() { want = true; reason = r }
        }

        blockedReason = nil
        // "On power" means the charger is covering the load, not just plugged in.
        if want && config.onlyOnPower && onBattery { want = false; blockedReason = "Only on power" }
        // Battery limit. 0 means "never stop for battery"; "Stay Awake" (override) skips it until the charger
        // is connected. With sleep disabled macOS won't sleep on its own near empty, so going below the limit
        // can end in an abrupt shutdown; that's the person's call, made explicitly.
        if want, config.batteryFloor > 0, !floorOverride, let b = battery, b.discharging || !b.onAC {
            if b.percent <= config.batteryFloor { floorLatched = true }
            if floorLatched && b.percent <= config.batteryFloor + 3 {
                want = false; blockedReason = "Battery at \(b.percent)%"
            } else if b.percent > config.batteryFloor + 3 { floorLatched = false }
        } else if battery?.charging == true { floorLatched = false }
        // Hot with the lid shut (a bag, a sofa): sleep at critical at once, and after 5 minutes of "serious" even with
        // the strictest rules applied, because a closed laptop can barely cool itself.
        if lidClosed && thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { if hotSince == nil { hotSince = Date() } } else { hotSince = nil }
        let hotTooLong = hotSince.map { Date().timeIntervalSince($0) >= Self.hotGrace } ?? false
        if want && config.heatGuard && (thermal == .critical || hotTooLong) { want = false; blockedReason = "Too hot" }

        holdReason = reason
        if want && !holding { startHold(reason: reason) }
        else if !want && holding { endHold(because: blockedReason ?? (config.mode == .off ? "Turned off" : "\(sessions.first?.kind.name ?? "Work") finished")) }

        // Heat guard: switch to the strictest rules once when it gets hot, and back once it cools.
        let hot = holding && lidClosed && config.heatGuard && thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if hot && !heatForced && config.preset != .longest { heatForced = true; reapplyClosedState(forcing: .longest) }
        else if !hot && heatForced { heatForced = false; if holding && lidClosed { reapplyClosedState() } }
    }

    private var heatForced = false
    /// When it got hot (serious or worse) with the lid shut.
    private var hotSince: Date?
    /// How long "serious" heat with the lid shut is tolerated before the Mac is put to sleep.
    static let hotGrace: TimeInterval = 300
    private var pendingRelease = false
    private var activity: NSObjectProtocol?

    static func describe(_ s: AgentSession) -> String {
        if s.kind.isRequest { return "\(s.kind.name) asked to stay awake" }
        return s.kind.isAI ? "\(s.kind.name) is working" : "\(s.kind.name) is busy"
    }

    func isWorking(_ s: AgentSession) -> Bool { Date().timeIntervalSince(s.lastActive) < 20 }

    /// One line for tooltips, the notch and `ajar status`.
    var statusLine: String {
        if !setupReady { return "Needs a one-time setup" }
        if let b = blockedReason { return "\(b), sleeps when closed" }
        switch config.mode {
        case .off:
            if holding, let r = holdReason { return "\(r) · stays awake closed" }
            return "Sleeps when you close the lid"
        case .on:
            guard let u = onUntil else { return "Awake until you turn it off" }
            return "Awake until \(u.formatted(date: .omitted, time: .shortened)) · \(PanelFormat.hm(max(0, u.timeIntervalSinceNow) / 3600)) left"
        case .auto:
            if holding, let r = holdReason { return "\(r) · stays awake closed" }
            return "Nothing running · sleeps when closed"
        }
    }

    var menuBarTitle: String {
        switch config.menuBarText {
        case .none: return ""
        case .battery: return battery.map { "\($0.percent)%" } ?? ""
        case .watts: return drawNow.map { String(format: "%.1fW", $0) } ?? ""
        case .timeLeft:
            guard battery != nil else { return "" }
            if !onBattery { return "∞" }
            guard let h = hoursLeft(at: closedEstimate) else { return "" }
            return h >= 1 ? String(format: "%.0fh", h) : String(format: "%.0fm", h * 60)
        case .timer:
            guard config.mode == .on, let u = onUntil else { return "" }
            let m = max(0, Int(u.timeIntervalSinceNow / 60))
            return String(format: "%d:%02d", m / 60, m % 60)
        }
    }

    // MARK: Savings

    /// Remember what each app draws when Ajar isn't touching it, so savings are measured against reality.
    private func updateBaseline() {
        for a in apps where targeted[a.id] == nil && a.id.hasSuffix(".app") {
            baseline[a.id] = baseline[a.id].map { $0 * 0.7 + a.watts * 0.3 } ?? a.watts
        }
    }

    private func accumulateSavings() {
        let now = Date()
        var rate = 0.0
        if PowerSensor.isMeasured, let open = openDrawAtClose, let closed = systemWatts {
            // Measured: what the whole Mac draws now versus what it drew with the lid open. Net, so it can be negative.
            rate = open - closed
        } else {
            for (id, _) in targeted {
                // An app that quit, or has no baseline yet, isn't counted either way. A slowed app that uses more
                // than before counts against the total: the figure is net, not only the good news.
                guard let actual = apps.first(where: { $0.id == id })?.watts, let base = baseline[id] else { continue }
                rate += base - actual
            }
        }
        if let last = lastSavingSample { sessionWh += rate * now.timeIntervalSince(last) / 3600 }
        lastSavingSample = now
        liveSavingW = rate
    }

    /// What the current rules would save with the lid closed, from live per-app readings (slow ≈ −77%, measured).
    var potentialSavingW: Double {
        userApps.reduce(0) { sum, a in
            guard !isProtected(a) else { return sum }
            switch rule(for: a.bundleID) { case .leave: return sum; case .slow: return sum + a.watts * 0.77; case .pause: return sum + a.watts }
        }
    }

    func percent(ofWh wh: Double) -> Double { wh / max(fullWh, 1) * 100 }

    private func finishSession(openedAt: Date) {
        guard let r = receipt else { return }
        let closedEnd = sleepInfo?.at ?? openedAt
        let closedMin = closedEnd.timeIntervalSince(r.closedAt) / 60
        var sleptMin = 0.0, avoided = 0.0
        if let s = sleepInfo, r.sleptAt != nil {   // only a sleep macOS confirmed counts
            sleptMin = openedAt.timeIntervalSince(s.at) / 60
            // Can't have saved more than the battery had left when it went to sleep.
            let left = Double(r.endPercent ?? battery?.percent ?? 0) / 100 * fullWh
            avoided = min(s.watts * sleptMin / 60, left)
        }
        if closedMin > 0.5 || sleptMin > 0.5 {
            stats.add(.init(date: r.closedAt, closedMinutes: closedMin, whSaved: sessionWh, sleptMinutes: sleptMin,
                            whAvoided: avoided, startPercent: r.startPercent, endPercent: battery?.percent, agent: r.agentName))
        }
        sleepInfo = nil
        sessionWh = 0
        liveSavingW = 0
    }

    /// "Measure": apply the closed-lid rules for a few seconds with the lid open and read the real difference.
    func measureSavings() {
        guard !measuring, !(lidClosed && holding) else { return }
        measuring = true
        let probe = EnergySampler()
        _ = probe.sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let before = Dictionary(probe.sample().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.applyClosedTargets(preset: self.config.preset, skip: ["simulators", "audio"])
            let applied = self.targeted
            _ = probe.sample()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                let after = Dictionary(probe.sample().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if !(self.lidClosed && self.holding) { self.restoreApps() }
                // An app missing from either sample is left out, never counted as 0 W (which would look like 100% saved).
                let rows = applied.keys.compactMap { id -> (String, Double, Double)? in
                    guard let b = before[id], let a = after[id] else { return nil }
                    return (b.name, b.watts, a.watts)
                }.sorted { $0.1 > $1.1 }
                self.lastTest = SavingsTest(before: rows.reduce(0) { $0 + $1.1 }, after: rows.reduce(0) { $0 + $1.2 },
                                            apps: rows.map { (name: $0.0, before: $0.1, after: $0.2) })
                self.measuring = false
            }
        }
    }

    // MARK: Watched apps

    func addWatched(_ app: WatchedApp) {
        guard !config.watchedApps.contains(app) else { return }
        update { $0.watchedApps.append(app) }
    }

    func removeWatched(_ app: WatchedApp) { update { $0.watchedApps.removeAll { $0 == app } } }

    /// Running apps that could be added to the watch list, most power-hungry first.
    var addableApps: [WatchedApp] {
        let taken = Set(config.watchedApps.map(\.id))
        let regular = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a -> WatchedApp? in
                guard let path = a.bundleURL?.path else { return nil }
                return WatchedApp(id: path, name: a.localizedName ?? (path as NSString).lastPathComponent)
            }
        let order = Dictionary(apps.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return regular.filter { !taken.contains($0.id) }.sorted { (order[$0.id] ?? 999) < (order[$1.id] ?? 999) }
    }

    // MARK: Runtime state that must survive a relaunch

    /// Holds survive a relaunch. (The Always timer lives in config.json next to the mode it belongs to.)
    private struct Runtime: Codable { var holds: [Hold] }
    private static var runtimeURL: URL { StateFiles.dir.appendingPathComponent("runtime.json") }

    private func saveRuntime() {
        guard !previewOnly else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Runtime(holds: holds)).write(to: Self.runtimeURL, options: .atomic)
    }

    private func restoreRuntime() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: Self.runtimeURL), let r = try? dec.decode(Runtime.self, from: d) else { return }
        holds = r.holds.filter(\.isAlive)
    }

    // MARK: Holds (from the CLI, MCP or Shortcuts)

    @discardableResult
    func addHold(reason: String, minutes: Double?, pid: Int32?) -> Hold {
        let h = Hold(id: String(UUID().uuidString.prefix(8)).lowercased(), reason: reason,
                     until: minutes.map { Date().addingTimeInterval($0 * 60) }, pid: pid, pidStart: pid.flatMap { Procs.startTime($0) })
        holds.append(h)
        saveRuntime()
        evaluate()
        announce(reason, minutes.map { "Staying awake for \(Self.formatMinutes($0))" } ?? "Staying awake")
        return h
    }

    /// MCP: an agent session may only end holds it made itself (tied to its own pid).
    func releaseHolds(ownedBy pid: Int32, id: String? = nil) -> Int {
        let before = holds.count
        holds.removeAll { $0.pid == pid && (id == nil || $0.id == id) }
        saveRuntime()
        evaluate()
        return before - holds.count
    }

    func releaseHold(_ id: String?) -> Int {
        let before = holds.count
        if let id { holds.removeAll { $0.id == id } } else { holds.removeAll() }
        saveRuntime()
        evaluate()
        return before - holds.count
    }

    static func formatMinutes(_ m: Double) -> String {
        m >= 90 ? String(format: "%.1f hours", m / 60).replacingOccurrences(of: ".0 ", with: " ") : "\(Int(m)) min"
    }

    // MARK: Previews

    static func preview(lidClosed: Bool = false) -> Engine {
        let e = Engine(passive: true)
        e.setupReady = true
        Thread.sleep(forTimeInterval: 1.2)
        e.apps = Array(e.sampler.sample().prefix(40))
        e.sampleWatchers()
        e.lidClosed = lidClosed
        e.evaluate()
        return e
    }

    // MARK: Holding the Mac awake

    private func startHold(reason: String?) {
        if previewOnly { holding = true; return }
        // Marker first: if Ajar dies right after pmset, the watchdog knows to switch sleep back on.
        StateFiles.touch(StateFiles.hold)
        guard StateFiles.exists(StateFiles.hold) else { setupError = "Ajar couldn't write to its folder, so it won't switch sleep off"; return }
        guard Shell.pmsetRoot(["-a", "disablesleep", "1"]) else {
            if !pendingRelease { StateFiles.remove(StateFiles.hold) }
            setupReady = Setup.isReady
            return
        }
        holding = true
        pendingRelease = false
        // Keep App Nap from stretching Ajar's 2-second loop while the lid is shut and nothing is on screen;
        // a late heartbeat would make the watchdog undo a hold that's still wanted.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Supervising a lid-closed session")
        if lidClosed { enterClosed() }
        announce(reason ?? "Staying awake", "Close the lid, it keeps going")
    }

    private func endHold(because why: String) {
        if previewOnly { holding = false; return }
        let wasClosed = lidClosed
        if wasClosed { restoreClosedState() }
        if Shell.pmsetRoot(["-a", "disablesleep", "0"]) {
            StateFiles.remove(StateFiles.hold)
        } else {
            // Keep the hold file so the watchdog also retries, and retry every tick ourselves.
            pendingRelease = true
        }
        holding = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if wasClosed {
            sleepInfo = (Date(), drawNow ?? 0)   // on the charger, sleeping saves no battery, so it counts as 0
            receipt?.sleepRequestedAt = Date()
            receipt?.sleptBecause = why
            receipt?.endPercent = battery?.percent
            sleepRetries = 0
            // macOS only sleeps on the lid-close edge; it's already shut, so ask directly. Confirmed (or retried)
            // from macOS's own will-sleep notification.
            Shell.pmsetRoot(["sleepnow"])
        } else {
            announce(why, "Sleeps normally again")
        }
    }

    private func announce(_ title: String, _ subtitle: String) {
        guard !previewOnly, !lidClosed else { return }
        onAnnounce?(title, subtitle)
    }

    // MARK: Lid

    private func lidChanged(to closed: Bool) {
        lidClosed = closed
        if closed {
            if holding { enterClosed() }
        } else {
            snoozed = false
            if holding { accumulateSavings() }
            restoreClosedState()
            if var r = receipt, r.openedAt == nil {
                r.openedAt = Date()
                if r.endPercent == nil { r.endPercent = battery?.percent }
                receipt = r
                finishSession(openedAt: r.openedAt!)
                onAnnounce?("Welcome back", Self.receiptLine(r))
            }
        }
    }

    static func receiptLine(_ r: Receipt) -> String {
        let end = r.sleptAt ?? r.sleepRequestedAt ?? r.openedAt ?? Date()
        let mins = Int(end.timeIntervalSince(r.closedAt) / 60)
        let dur = mins < 60 ? "\(max(1, mins)) min" : "\(mins / 60) h \(mins % 60) min"
        var s = r.sleptAt != nil ? "Ran \(dur), then slept" : (r.sleepRequestedAt != nil ? "Ran \(dur), then asked it to sleep" : "Stayed awake \(dur)")
        if let a = r.startPercent, let b = r.endPercent, a >= b { s += " · used \(a - b)%" }
        return s
    }

    private func enterClosed() {
        receipt = Receipt(closedAt: Date(), startPercent: battery?.percent, agentName: activeAgent?.kind.name ?? holds.last?.reason)
        sessionWh = 0
        sleepInfo = nil
        lastSavingSample = Date()
        openDrawAtClose = openDraw
        if config.lockOnClose {
            // The person chose a locked Mac: turn the screen off now, and macOS locks per its own setting.
            Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        } else {
            // A display sleep is what makes macOS show the lock screen on reopen, so the display stays awake
            // (which also stops the person's own display-sleep timer from locking partway through) and goes
            // to zero brightness instead, for power and heat. Both come back when the lid opens.
            holdDisplayAwake(true)
            Brightness.dimForClosedLid()
            // Fully off without a sleep (no lock screen), when chosen and macOS allows it; otherwise stays dark.
            if config.screenOffNoLock { switchScreenOff() }
            // Lid events bring the brightness back the moment it opens. Only if they're unavailable, poll
            // (twice a second) so the screen isn't dark for up to 2 s after opening.
            lidPoll?.invalidate()
            if lidWatcher == nil {
                let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.lidClosed, !Registry.lidClosed else { return }
                        self.lidChanged(to: false)
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                lidPoll = t
            }
        }
        reapplyClosedState()
        if config.shutDownSimulators && config.preset != .speed && !background.testsRunning && background.simulatorDevices > 0 {
            DispatchQueue.global(qos: .utility).async { _ = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"]) }
        }
    }

    private var displayAssertion: IOPMAssertionID = 0

    private func holdDisplayAwake(_ on: Bool) {
        if on, displayAssertion == 0, !previewOnly {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Ajar: lid-closed session (no lock screen on reopen)" as CFString, &id) == kIOReturnSuccess {
                displayAssertion = id
            }
        } else if !on, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    private func reapplyClosedState(forcing: Preset? = nil) {
        let p = forcing ?? config.preset
        if p != .speed && config.lowPowerWhileClosed { setLowPower() } else { restorePowerMode() }
        applyClosedTargets(preset: p)
    }

    /// The preset in force: the heat guard can tighten it while the Mac is hot.
    private var effectivePreset: Preset { heatForced ? .longest : config.preset }

    private var lidPoll: Timer?
    /// The built-in display is configured off right now (screen_off).
    private(set) var screenOff = false

    /// Screen fully off without a sleep. On some Macs macOS locks the session anyway when its only display
    /// goes off (its "require password after the display is turned off" rule). Ajar can't prevent that, so if
    /// the session locks within a few seconds it puts the screen back, switches to the dark screen for good
    /// and says why, so it's at most one surprise password prompt.
    private func switchScreenOff() {
        let wasLocked = DisplayPower.sessionLocked
        screenOff = DisplayPower.turnOffBuiltIn()
        guard screenOff, !wasLocked else { return }
        for delay in [2.0, 6.0, 12.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.screenOff, self.config.screenOffNoLock, DisplayPower.sessionLocked else { return }
                DisplayPower.restoreBuiltIn()
                self.screenOff = false
                Brightness.dimForClosedLid()
                self.update { $0.screenOffNoLock = false }
                self.warning = "macOS locks this Mac when its screen is switched fully off, so Ajar went back to the dark screen (no lock screen)."
            }
        }
    }

    private func restoreClosedState() {
        lidPoll?.invalidate()
        lidPoll = nil
        if !DisplayPower.restoreBuiltIn() { warning = "Couldn't switch the built-in screen back on. Log out and in to bring it back." }
        screenOff = false
        Brightness.restore()
        holdDisplayAwake(false)
        restoreApps()
        restorePowerMode()
    }

    // MARK: Low Power Mode

    private func setLowPower() {
        guard !StateFiles.exists(StateFiles.modeRestore), let cur = PowerMode.battery(), cur.value != 1 else { return }
        StateFiles.write("\(cur.key) \(cur.value)", to: StateFiles.modeRestore)
        if !Shell.pmsetRoot(["-b", cur.key, "1"]) { StateFiles.remove(StateFiles.modeRestore) }
    }

    private func restorePowerMode() {
        guard let saved = StateFiles.read(StateFiles.modeRestore) else { return }
        let parts = saved.split(separator: " ").map(String.init)
        // Keep the file if pmset fails, so this (and the watchdog) tries again instead of leaving Low Power Mode on.
        if parts.count != 2 || Shell.pmsetRoot(["-b", parts[0], parts[1]]) { StateFiles.remove(StateFiles.modeRestore) }
    }

    // MARK: Other apps

    func rule(for bundleID: String?) -> AppRule { rule(for: bundleID, preset: config.preset) }

    func rule(for bundleID: String?, preset p: Preset) -> AppRule {
        if let id = bundleID, let r = config.appRules[id] { return r }
        switch p {
        case .speed: return .leave
        case .balanced: return .slow
        case .longest:
            guard let id = bundleID else { return .slow }
            if AppClasses.mediaAndCalls.contains(id) { return .leave }
            return AppClasses.agentServices.contains(id) ? .slow : .pause
        }
    }

    func setRule(_ r: AppRule, for bundleID: String) { update { $0.appRules[bundleID] = r } }

    func isProtected(_ app: AppUsage) -> Bool {
        app.bundleID == Bundle.main.bundleIdentifier || app.bundleID == AgentKind.claudeAppBundleID
            || watcher.protectedBundles.contains(app.id) || !app.id.hasSuffix(".app") || isSystemApp(app.id)
    }

    /// macOS internals Ajar never touches. Safari and other apps shipped in the app cryptex are user apps.
    private func isSystemApp(_ path: String) -> Bool {
        if path.contains("/Cryptexes/App/System/Applications/") || path.hasPrefix("/System/Applications/") { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
    }

    /// Pids that must never be slowed: agents and their trees/ancestors (from the watcher), plus anything a
    /// hold is tied to (`ajar run`, `ajar hold --pid`), its children and the apps above it.
    private func protectedPidSet(allPids: [pid_t]) -> Set<pid_t> {
        var protect = watcher.protectedPids
        let holdPids = holds.compactMap(\.pid)
        guard !holdPids.isEmpty else { return protect }
        var children: [pid_t: [pid_t]] = [:]
        var parent: [pid_t: pid_t] = [:]
        for p in allPids { if let pp = Procs.parent(p) { parent[p] = pp; children[pp, default: []].append(p) } }
        for root in holdPids {
            var stack = [root]
            while let p = stack.popLast() { if protect.insert(p).inserted { stack.append(contentsOf: children[p] ?? []) } }
            var up = parent[root]
            while let cur = up, cur > 1 { protect.insert(cur); up = parent[cur] }
        }
        return protect
    }

    private struct ClosedTarget {
        var rule: AppRule
        var start: UInt64
        var path: String
        var bundle: String?
    }

    /// Everything that should be slowed or paused right now with the lid shut, by pid: other apps under the
    /// preset and per-app rules, plus booted simulators, Xcode previews and background audio holders. Never
    /// agents, their process trees and ancestors, anything a hold is tied to, Ajar, or macOS itself.
    /// `skip` leaves a category out ("apps", "simulators", "audio"), for measuring what each one is worth.
    private func closedTargets(preset p: Preset, skip: Set<String> = []) -> [pid_t: ClosedTarget] {
        let mine = getpid()
        let all = Procs.allPids()
        let protectedPids = protectedPidSet(allPids: all)
        let protectedBundles = watcher.protectedBundles.union(protectedPids.compactMap { Procs.path($0).flatMap(Procs.bundlePath(of:)) })
        let running = NSWorkspace.shared.runningApplications
        let regularPaths = Set(running.filter { $0.activationPolicy == .regular }.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        var bundles: [String: AppRule] = [:]
        if !skip.contains("apps") {
            for app in running where app.activationPolicy == .regular {
                // Resolve symlinks so /Applications/Safari.app matches the cryptex path its processes report.
                guard let url = app.bundleURL?.resolvingSymlinksInPath(), app.processIdentifier != mine,
                      app.bundleIdentifier != AgentKind.claudeAppBundleID, app.bundleIdentifier != Bundle.main.bundleIdentifier,
                      !protectedBundles.contains(url.path), !isSystemApp(url.path) else { continue }
                var r = rule(for: app.bundleIdentifier, preset: p)
                // Services agents talk to (containers, local models, databases) are slowed, never paused, unless the
                // person set a rule for them.
                if r == .pause, config.appRules[app.bundleIdentifier ?? ""] == nil, AppClasses.isAgentService(name: app.localizedName ?? "") { r = .slow }
                if r != .leave { bundles[url.path] = r }
            }
        }
        var out: [pid_t: ClosedTarget] = [:]
        func add(_ pid: pid_t, _ r: AppRule, bundle: String?) {
            guard pid > 1, pid != mine, !protectedPids.contains(pid), let path = Procs.path(pid), let start = Procs.startTime(pid) else { return }
            out[pid] = ClosedTarget(rule: r, start: start, path: path, bundle: bundle)
        }
        if !bundles.isEmpty {
            for pid in all {
                guard let path = Procs.path(pid), let b = Procs.bundlePath(of: path), let r = bundles[b] else { continue }
                add(pid, r, bundle: b)
            }
        }
        guard p != .speed else { background = BackgroundWork.Found(); return out }
        let found = BackgroundWork.scan(all: all)
        background = found
        if config.pauseSimulators && !found.testsRunning && !skip.contains("simulators") {
            for pid in found.simulators + found.previews { add(pid, .pause, bundle: nil) }
        }
        if config.pauseBackgroundAudio && !skip.contains("audio") {
            for pid in found.audio.keys {
                guard let path = Procs.path(pid), !AppUsage.isSystemPath(path) else { continue }
                if let b = Procs.bundlePath(of: path), regularPaths.contains(b) { continue }   // apps follow their app rule
                add(pid, .pause, bundle: nil)
            }
        }
        return out
    }

    /// Brings the slowed/paused set in line with `closedTargets`: puts back what no longer belongs, then journals and
    /// applies the rest. Journal first, in one durable write for the whole batch, and act only once it's on disk,
    /// so a crash at any point leaves a record of every process Ajar changed.
    private func applyClosedTargets(preset: Preset? = nil, skip: Set<String> = []) {
        let desired = closedTargets(preset: preset ?? effectivePreset, skip: skip)
        var keep: [Touched] = [], undo: [Touched] = []
        for t in touched {
            if let d = desired[t.pid], d.start == t.start, (d.rule == .pause) == t.paused { keep.append(t) } else { undo.append(t) }
        }
        if !undo.isEmpty { touched = keep + Journal.undo(undo); Journal.save(touched) }
        targeted = Dictionary(desired.values.compactMap { d in d.bundle.map { ($0, d.rule) } }, uniquingKeysWith: { a, _ in a })
        let have = Set(touched.map { "\($0.pid):\($0.start)" })
        let entries = desired.filter { !have.contains("\($0.key):\($0.value.start)") }
            .map { Touched(pid: $0.key, start: $0.value.start, path: $0.value.path, paused: $0.value.rule == .pause) }
        guard !entries.isEmpty else { return }
        touched += entries
        guard Journal.save(touched) else { touched.removeLast(entries.count); return }
        var failed = Set<String>()
        for e in entries {
            let ok = e.paused ? Throttle.freeze(e.pid, start: e.start, true) : Throttle.background(e.pid, start: e.start, true)
            if !ok { failed.insert("\(e.pid):\(e.start)") }
        }
        if !failed.isEmpty {
            touched.removeAll { failed.contains("\($0.pid):\($0.start)") }
            Journal.save(touched)
        }
    }

    private func restoreApps() {
        touched = Journal.undo(touched)   // keeps anything the OS refused; retried every few ticks
        Journal.save(touched)
        if touched.isEmpty { targeted.removeAll() }
        liveSavingW = 0
    }

    /// Apps Ajar changed and couldn't put back yet (shown in the panel with a retry).
    var unrestored: [String] {
        guard !(lidClosed && holding) else { return [] }
        return touched.map { ($0.path as NSString).lastPathComponent }
    }

    func retryRestore() { if !(lidClosed && holding) { restoreApps() } }

    /// If a previous run died mid-hold, undo what it left behind before doing anything else.
    private func recoverFromCrash() {
        Journal.undoLegacyFiles()
        // Anything that can't be put back stays in the journal and is retried every few ticks.
        touched = Journal.undo(Journal.load())
        Journal.save(touched)
        restorePowerMode()
        DisplayPower.restoreBuiltIn()
        Brightness.restore()
        if Registry.sleepDisabled && StateFiles.exists(StateFiles.hold) {
            // Take the previous run's hold over instead of releasing it first (see adoptedHoldUntil).
            adoptedHoldUntil = Date().addingTimeInterval(30)
        } else {
            StateFiles.remove(StateFiles.hold)
        }
    }

    /// Set when Ajar starts and finds sleep still switched off by a previous run (a crash, a forced quit, an update).
    /// Releasing that hold first and taking it again a moment later would let a Mac with its lid shut fall asleep
    /// in between, so the new run keeps it. If nothing wants it, it's released after 30 s (agents need a few
    /// samples to show up as working), or at once when a limit says sleep (battery, heat, setup, Off).
    private var adoptedHoldUntil: Date?

    private func settleAdoptedHold() {
        guard let until = adoptedHoldUntil else { return }
        if holding { adoptedHoldUntil = nil; return }
        let mustSleep = !setupReady || blockedReason != nil || (config.mode == .off && holds.isEmpty)
        guard mustSleep || Date() > until else { return }
        adoptedHoldUntil = nil
        if Shell.pmsetRoot(["-a", "disablesleep", "0"]) { StateFiles.remove(StateFiles.hold) } else { pendingRelease = true }
        if lidClosed { Shell.pmsetRoot(["sleepnow"]) }   // macOS only sleeps on the lid-close edge; it's already shut
    }

    func shutdown() {
        guard !previewOnly else { return }
        restoreClosedState()
        if holding || pendingRelease || adoptedHoldUntil != nil {
            // If this fails the hold file stays, so the watchdog keeps trying after we're gone.
            if Shell.pmsetRoot(["-a", "disablesleep", "0"]) { StateFiles.remove(StateFiles.hold) }
        } else {
            StateFiles.remove(StateFiles.hold)
        }
        holding = false
    }

    /// Apps a person would recognise (no macOS internals, not Ajar itself), most power-hungry first.
    var userApps: [AppUsage] {
        apps.filter { a in
            a.id.hasSuffix(".app") && a.bundleID != Bundle.main.bundleIdentifier
                && !a.id.hasPrefix("/System/Library/") && !a.id.hasPrefix("/System/Cryptexes/") && !a.id.hasPrefix("/Library/Apple/")
                && !a.id.contains("/CoreSimulator/") && !a.id.contains(".simruntime/")
        }
    }

    // MARK: Power diagnosis and measured savings

    /// What's using power and which setting would cut it, in a shape an AI agent can act on directly.
    func powerReport() -> [String: Any] {
        let found = (lidClosed && holding) ? background : BackgroundWork.scan(all: Procs.allPids())
        func r1(_ x: Double?) -> Any { x.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
        var suspects: [[String: Any]] = []
        if Registry.hasLid {
            let dark = !config.lockOnClose && !(config.screenOffNoLock && (screenOff || !lidClosed))
            suspects.append(["id": "screen", "active": dark,
                             "title": config.lockOnClose ? "Screen sleeps with the lid closed (locks)" : (config.screenOffNoLock ? (screenOff || !lidClosed ? "Screen switches fully off with the lid closed, no lock screen" : "Screen off was refused by macOS; it stays dark instead") : "Screen stays on at zero brightness with the lid closed"),
                             "why": "A dark screen still keeps the display hardware and window server running.",
                             "setting": "screen_off", "suggested_value": "on",
                             "tradeoff": "Experimental: switches the built-in display off without sleeping it (no lock screen). Alternative: lock_on_close on (locks on reopen).",
                             "measured_saving_watts": r1(powerEffects["screen_off"] ?? powerEffects["screen"])])
        }
        let simCount = found.simulators.count + found.previews.count
        suspects.append(["id": "simulators", "active": simCount > 0 && !(config.pauseSimulators && lidClosed && holding),
                         "title": simCount > 0 ? "\(found.simulatorDevices) booted simulator(s) and \(found.previews.count) preview process(es): \(simCount) processes" : "No simulators or previews running",
                         "setting": "pause_simulators", "value": config.pauseSimulators, "suggested_value": "on",
                         "note": found.testsRunning ? "Tests are running, so simulators are left alone." : "", "measured_saving_watts": r1(powerEffects["simulators"])])
        suspects.append(["id": "background_audio", "active": !found.audio.isEmpty,
                         "title": found.audio.isEmpty ? "Nothing holding the speakers open" : "Holding the speakers open: " + found.audio.values.sorted().joined(separator: ", "),
                         "setting": "pause_background_audio", "value": config.pauseBackgroundAudio, "suggested_value": "on",
                         "measured_saving_watts": r1(powerEffects["audio"])])
        let busy = userApps.filter { !isProtected($0) && $0.watts > 0.2 }.prefix(6)
        suspects.append(["id": "apps", "active": !busy.isEmpty, "title": busy.isEmpty ? "No other app is busy" : "Busy apps: " + busy.map { "\($0.name) \(String(format: "%.1f", $0.watts)) W (\(rule(for: $0.bundleID).rawValue))" }.joined(separator: ", "),
                         "setting": "preset", "value": ["longest": "max_battery", "balanced": "balanced", "speed": "full_speed"][config.preset.rawValue] ?? "", "suggested_value": "max_battery",
                         "per_app": "ajar rule <app> pause", "measured_saving_watts": r1(powerEffects["apps"])])
        suspects.append(["id": "low_power", "active": !config.lowPowerWhileClosed, "title": config.lowPowerWhileClosed ? "Low Power Mode turns on with the lid closed" : "Low Power Mode stays off with the lid closed",
                         "setting": "low_power", "value": config.lowPowerWhileClosed, "suggested_value": "on", "measured_saving_watts": r1(powerEffects["low_power"])])
        return [
            "ok": true,
            "system_watts": r1(systemWatts), "measured": PowerSensor.isMeasured,
            "source": PowerSensor.isMeasured ? "battery controller (whole Mac, works on the charger)" : "battery discharge (only on battery)",
            "lid_closed": lidClosed, "keeping_awake": holding,
            "learned_open_watts": r1(openDraw), "learned_closed_watts": r1(closedDraw),
            "apps_total_watts": r1(apps.reduce(0) { $0 + $1.watts }),
            "suspects": suspects,
            "power_test": powerTestRunning ? (powerTestProgress ?? "running") : (powerEffects.isEmpty ? "not run yet" : "done"),
            "how_to_measure": "ajar power test (lid closed, takes about 4 minutes): switches each saving off and on twice and reports what each is worth (or unclear when the Mac's own load moved too much). Add --screen to include the screen (that locks the Mac).",
        ]
    }

    /// With the lid closed, switches each saving off and back on and measures the whole-Mac difference, so the
    /// numbers shown are real for this Mac. About 30 s per step; agents keep running throughout.
    func startPowerTest(includeScreen: Bool) -> String? {
        guard lidClosed && holding else { return "Close the lid first (with Ajar keeping the Mac awake): the test measures lid-closed savings" }
        guard !powerTestRunning else { return "A power test is already running" }
        guard PowerSensor.isMeasured else { return "This Mac doesn't report whole-system power, so savings can't be measured" }
        powerTestRunning = true
        var steps = ["apps", "simulators", "audio", "low_power"]
        // Switching the display off locks Macs set to ask for the password immediately, so it's only measured
        // there when the person already chose it.
        if DisplayPower.available && !config.lockOnClose && (config.screenOffNoLock || LockSetting.gracePeriod() != 0) { steps.append("screen_off") }
        if includeScreen && !config.lockOnClose { steps.append("screen") }
        runPowerStep(steps[...])
        return nil
    }

    /// Whether a saving is in force under the current settings.
    private func savingOn(_ step: String) -> Bool {
        switch step {
        case "apps": return config.preset != .speed
        case "simulators": return config.pauseSimulators && config.preset != .speed
        case "audio": return config.pauseBackgroundAudio && config.preset != .speed
        case "low_power": return config.lowPowerWhileClosed && config.preset != .speed
        case "screen": return config.lockOnClose
        case "screen_off": return screenOff
        default: return false
        }
    }

    private func setSaving(_ step: String, _ on: Bool) {
        switch step {
        case "apps", "simulators", "audio":
            // Applying with the category skipped puts that category back to normal; everything else stays applied.
            applyClosedTargets(preset: effectivePreset == .speed ? .balanced : effectivePreset, skip: on ? [] : [step])
        case "low_power": if on { setLowPower() } else { restorePowerMode() }
        case "screen_off":
            if on { switchScreenOff() } else { DisplayPower.restoreBuiltIn(); screenOff = false; Brightness.dimForClosedLid() }
        case "screen":
            if on { Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
            else { Shell.run("/usr/bin/caffeinate", ["-u", "-t", "2"]) }   // declares activity: the display comes back on
        default: break
        }
    }

    private func powerWindow(_ seconds: Double, _ done: @escaping (Double?) -> Void) {
        let a = PowerSensor.sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let b = PowerSensor.sample()
            done(a.flatMap { a in b.flatMap { PowerSensor.average(a, $0) } })
        }
    }

    /// Measures one saving as off, on, off, on in 8 s windows (each after 3 s to settle) and compares the pairs.
    /// One A/B pair was too easy to fool: an agent's burst of work or apps catching up after a pause landed in
    /// one window and showed savings bigger than the whole Mac draws. Now the smaller of the two differences
    /// counts, and if the pairs disagree the result is reported as unclear instead of as a number.
    private func runPowerStep(_ steps: ArraySlice<String>) {
        guard let step = steps.first, lidClosed, holding else {
            powerTestRunning = false
            powerTestProgress = nil
            UserDefaults.standard.set(powerEffects, forKey: "powerEffects2")
            UserDefaults.standard.set(Array(powerUnclear), forKey: "powerUnclear")
            if lidClosed && holding { reapplyClosedState() } else if !lidClosed { restoreClosedState() }
            announce("Power test done", powerEffects.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.1f", $0.value)) W" }.joined(separator: " · "))
            return
        }
        let wasOn = savingOn(step)
        // Nothing to measure: no simulators or audio holders right now.
        if (step == "simulators" && background.simulators.isEmpty && background.previews.isEmpty) || (step == "audio" && background.audio.isEmpty) {
            powerEffects[step] = nil; powerUnclear.remove(step)
            return runPowerStep(steps.dropFirst())
        }
        var readings: [Double?] = []
        let pattern = [false, true, false, true]   // saving off, on, off, on
        func next(_ i: Int) {
            guard i < pattern.count, lidClosed, holding else { return finish() }
            powerTestProgress = "Measuring \(Self.stepName(step)) (\(i + 1) of 4)…"
            setSaving(step, pattern[i])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.powerWindow(8) { w in readings.append(w); next(i + 1) }
            }
        }
        func finish() {
            setSaving(step, wasOn)
            if readings.count == 4, let off1 = readings[0], let on1 = readings[1], let off2 = readings[2], let on2 = readings[3] {
                let d1 = off1 - on1, d2 = off2 - on2
                let total = max(off1, off2)
                if abs(d1 - d2) > max(0.6, 0.5 * max(abs(d1), abs(d2))) {
                    powerEffects[step] = nil; powerUnclear.insert(step)
                } else {
                    powerEffects[step] = min(max(0, min(d1, d2)), total); powerUnclear.remove(step)
                }
            }
            runPowerStep(steps.dropFirst())
        }
        next(0)
    }

    static func stepName(_ step: String) -> String {
        ["apps": "other apps", "simulators": "simulators", "audio": "background audio", "low_power": "Low Power Mode",
         "screen_off": "screen off", "screen": "screen off (locks)"][step] ?? step
    }

    // MARK: Estimates

    /// Watts now, or nil on the charger.
    var drawNow: Double? { battery.flatMap { $0.discharging ? $0.watts : nil } }

    /// What the Mac should draw with the lid shut under the current preset. Display off, other apps
    /// slowed (≈ ¼ power, measured) or paused (0). The 1.6 W floor is SoC + Wi-Fi + memory with the lid shut.
    var closedEstimate: Double {
        if lidClosed, holding, let d = systemWatts ?? drawNow { return d }
        if let c = closedDraw { return c }
        let others = apps.reduce(0.0) { sum, a in
            if a.system { return sum }   // covered by the base figure
            if isProtected(a) { return sum + a.watts }
            switch rule(for: a.bundleID) { case .leave: return sum + a.watts; case .slow: return sum + a.watts * 0.25; case .pause: return sum }
        }
        return 1.6 + others
    }

    func hoursLeft(at watts: Double) -> Double? {
        guard let b = battery, watts > 0.1 else { return nil }
        let usable = Double(max(0, b.percent - config.batteryFloor)) / 100 * fullWh
        return usable / watts
    }

    // MARK: Setup and misc

    /// Puts everything back and removes the sudoers entry, watchdog and CLI link.
    func uninstallHelper() throws {
        update { $0.mode = .off }
        _ = releaseHold(nil)
        shutdown()
        // The sudoers entry and the watchdog are the only ways to switch sleep back on without a password, so
        // they're removed only once nothing Ajar changed is left.
        let left = Watchdog.outstanding()
        guard left.isEmpty else {
            throw SetupError(message: "Not removed yet: \(left.joined(separator: ", ")). Ajar keeps its helper so it can keep trying; try again in a minute.")
        }
        try Setup.uninstall()
        setupReady = Setup.isReady
    }

    func runSetup() {
        // Run from Downloads or a disk image, macOS gives the app a temporary path that disappears; the
        // `ajar` command and the Claude config would point at nothing.
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"), !path.contains("AppTranslocation") else {
            setupError = "Move Ajar to your Applications folder first, then open it from there."
            return
        }
        do { try Setup.install(); setupError = nil } catch { setupError = error.localizedDescription }
        setupReady = Setup.isReady
        evaluate()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    /// "Until 7:00 AM": the next time that clock time comes round.
    func stayAwake(until date: Date) {
        stayAwake(for: max(1, Int((date.timeIntervalSinceNow / 60).rounded())))
    }

    /// macOS is about to sleep: if Ajar asked for it, that confirms the sleep (receipts and savings only count
    /// confirmed sleeps).
    private func macWillSleep() {
        if receipt?.sleepRequestedAt != nil, receipt?.sleptAt == nil { receipt?.sleptAt = Date() }
        sleepRetries = 0
    }

    /// "Let it sleep now": ends holds and timers; agents don't keep the Mac awake until the lid next opens
    /// (or it wakes). With the lid open the Mac sleeps right away.
    func sleepNow() {
        holds.removeAll()
        saveRuntime()
        if config.mode == .on { let back = config.modeBeforeAlways ?? .auto; update { $0.mode = back } }
        snoozed = true
        evaluate()
        if !lidClosed && !holding && !previewOnly { Shell.pmsetRoot(["sleepnow"]) }
    }

    func toggleWatch(_ app: WatchedApp) {
        if config.watchedApps.contains(where: { $0.id == app.id }) { update { $0.watchedApps.removeAll { $0.id == app.id } } }
        else { addWatched(app) }
    }

    /// For the phone panel: apps already kept awake for, then the busiest open apps to pick from.
    var watchCandidates: [(app: WatchedApp, on: Bool)] {
        config.watchedApps.map { ($0, true) } + addableApps.prefix(8).map { ($0, false) }
    }

    /// Everything the phone panel shows, in one reply. Same shape as the Windows/Linux app.
    func panelJSON() -> [String: Any] {
        let o = lidOutcome
        var d: [String: Any] = [
            "ok": true, "keeps": o.keeps, "holding": holding, "headline": o.headline, "detail": o.detail,
            "lidClosed": lidClosed, "mode": config.mode.rawValue, "preset": config.preset.rawValue, "snoozed": snoozed,
            "holds": holds.map(\.reason),
            "agents": sessions.filter { !$0.kind.isRequest }.map { s in
                ["id": s.kind.id, "name": s.kind.name, "working": isWorking(s), "keeps": !config.trackOnly.contains(s.kind.id), "instances": s.instances] as [String: Any]
            },
            "watch": watchCandidates.map { ["id": $0.app.id, "name": $0.app.name, "on": $0.on] as [String: Any] },
            "warnings": [warning].compactMap { $0 },
            "host": Host.current().localizedName ?? "Mac",
        ]
        if let w = systemWatts { d["watts"] = (w * 10).rounded() / 10 }
        // Phone page: measure what each saving is worth (needs the lid shut and the Mac kept awake).
        d["canMeasure"] = lidClosed && holding && !powerTestRunning && PowerSensor.isMeasured
        if powerTestRunning { d["powerTest"] = powerTestProgress ?? "running" }
        if !powerEffects.isEmpty { d["savings"] = powerEffects.mapValues { ($0 * 10).rounded() / 10 } }
        if !powerUnclear.isEmpty { d["savingsUnclear"] = Array(powerUnclear) }
        d.merge(phoneFigures) { a, _ in a }
        if let u = onUntil { d["alwaysUntil"] = u.formatted(date: .omitted, time: .shortened) }
        if let b = battery {
            if !onBattery { d["battery"] = "\(b.percent)% · plugged in" + (closedHours.map { " (≈\(PanelFormat.hm($0)) on battery, lid closed)" } ?? "") }
            else { d["battery"] = "\(b.percent)%" + (closedHours.map { " · ≈\(PanelFormat.hm($0)) left with the lid closed" } ?? "") }
        }
        return d
    }

    func toggleTrackOnly(_ kindID: String) {
        update { c in
            if let i = c.trackOnly.firstIndex(of: kindID) { c.trackOnly.remove(at: i) } else { c.trackOnly.append(kindID) }
        }
    }

    func stayAwake(for minutes: Int?) {
        let before = config.mode
        // Mode and end time are written together in one file, so they can't disagree after a crash.
        update { c in
            if before != .on { c.modeBeforeAlways = before }
            c.mode = .on
            c.alwaysUntil = minutes.map { Date().addingTimeInterval(TimeInterval(min($0, 7 * 24 * 60) * 60)).timeIntervalSince1970 }
        }
        evaluate()
        announce(minutes.map { "Awake for \(Self.formatMinutes(Double($0)))" } ?? "Always awake", "Close the lid, it keeps going")
    }
}
