import AppKit
import IOKit.pwr_mgt
import Observation
import ServiceManagement

/// Session record shown after the lid opens again.
struct Receipt: Equatable {
    var closedAt: Date
    var openedAt: Date?
    /// When Nocturnal asked the Mac to sleep.
    var sleepRequestedAt: Date?
    /// Set only when macOS actually went to sleep (its own will-sleep notification), never on request alone.
    var sleptAt: Date?
    var startPercent: Int?
    var endPercent: Int?
    var agentName: String?
    /// Time the Mac had no internet while the lid was shut (it stayed awake, but agents couldn't reach anything).
    var offlineSeconds: Double = 0
    var offlineSince: Date?
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

    func apply(_ c: Config, save: Bool) {
        guard c != config else { return }
        let old = config
        config = c
        if old.mode != c.mode && c.mode != .on { config.alwaysUntil = nil; config.modeBeforeAlways = nil }
        if save && !previewOnly {
            try? config.encoded().write(to: Config.url, options: .atomic)
            if old.heatGuard != config.heatGuard || old.batteryFloor != config.batteryFloor || old.onlyOnPower != config.onlyOnPower {
                Safety(heatGuard: config.heatGuard, batteryFloor: config.batteryFloor, onlyOnPower: config.onlyOnPower).save()
            }
        }
        if old.watchedApps != c.watchedApps || old.countRequests != c.countRequests || old.customAgents != c.customAgents { sampleWatchers() }
        // Screen choice changed with the lid already shut: switch to the new behaviour now, not at the next close.
        if old.lockOnClose != c.lockOnClose && lidClosed && holding && !previewOnly {
            if c.lockOnClose {
                if screenOff { DisplayPower.restoreBuiltIn(); screenOff = false }
                holdDisplayAwake(false)
                Shell.run("/usr/bin/pmset", ["displaysleepnow"])
            } else {
                holdDisplayAwake(true)
                Brightness.dimForClosedLid()
                if c.screenOffNoLock { switchScreenOff() }
            }
        }
        if old.screenOffNoLock != c.screenOffNoLock && old.lockOnClose == c.lockOnClose && lidClosed && holding && !c.lockOnClose {
            if c.screenOffNoLock { switchScreenOff() } else { DisplayPower.restoreBuiltIn(); screenOff = false }
        }
        if (old.preset != c.preset || old.appRules != c.appRules || old.lowPowerWhileClosed != c.lowPowerWhileClosed
            || old.pauseSimulators != c.pauseSimulators || old.pauseBackgroundAudio != c.pauseBackgroundAudio
            || old.shutDownSimulators != c.shutDownSimulators || old.pauseTimeMachine != c.pauseTimeMachine) && lidClosed && holding && !powerTestRunning {
            reapplyClosedState(forcing: effectivePreset)
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
    /// Set while a check-in wake keeps the Mac up for a few seconds to read the phone's commands.
    var checkInUntil: Date?
    var checkInActivity: NSObjectProtocol?
    var powerEvents: PowerEvents?
    /// The sudoers entry has every command this version uses (scheduled wakes, Time Machine, the watchdog's clean-up).
    var wakeReady = Setup.wakeReady
    /// The phone listener reconnects at once on a check-in (wired by RemoteControl).
    var onCheckIn: (() -> Void)?
    private(set) var holdReason: String?
    private(set) var blockedReason: String?
    var sessions: [AgentSession] = []
    var blockers: [SleepBlocker] = []
    private(set) var apps: [AppUsage] = []
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    var receipt: Receipt?
    let net = NetWatch()
    /// On an iPhone's Personal Hotspot right now (see NetWatch for why that matters with the lid shut).
    private(set) var onHotspot = NetWatch.inIPhoneHotspotRange
    /// Previews only: show the panel as if on an iPhone hotspot (a preview engine never touches the system).
    func previewOnHotspot() { if previewOnly { onHotspot = true } }
    private(set) var fullWh: Double = UserDefaults.standard.double(forKey: "fullWh") > 20 ? UserDefaults.standard.double(forKey: "fullWh") : 70
    var panelOpen = false { didSet { if panelOpen && !oldValue { refreshFast() } } }

    // Savings
    var stats = SavingsStats.load()
    /// Watts being saved right now by slowing/pausing apps (lid closed), measured.
    var liveSavingW = 0.0
    var sessionWh = 0.0
    var lastTest: SavingsTest?
    var measuring = false
    var targeted: [String: AppRule] = [:]        // bundle path → rule currently applied
    var baseline: [String: Double] = [:]         // bundle path → watts when running normally
    var lastSavingSample: Date?
    var sleepInfo: (at: Date, watts: Double)?
    /// What the Mac draws with the lid open on battery (smoothed).
    private(set) var openDraw: Double? = UserDefaults.standard.object(forKey: "openDraw") as? Double
    /// Whole-Mac watts from the battery controller (on battery or charger), averaged between readings.
    private(set) var systemWatts: Double?
    var lastPowerSample: PowerSample?
    /// What the Mac draws with the lid closed while Nocturnal holds it, learned from real readings.
    private(set) var closedDraw: Double? = UserDefaults.standard.object(forKey: "closedDraw") as? Double
    /// The lid-shut figures the panel and phone show, averaged over a few minutes so "hours left" doesn't swing
    /// with every reading: while shut, from the live draw (seeded with the estimate from before it closed); while
    /// open, from the estimate.
    private(set) var closedNow: Double?
    private(set) var closedForecast: Double?
    private var smoothedAt = Date()
    /// Simulators, previews and audio holders found on the last lid-closed pass.
    var background = BackgroundWork.Found()
    var lidWatcher: LidWatcher?
    /// Watts each saving is worth, from `nocturnal power test` (step → watts saved).
    var powerEffects: [String: Double] = (UserDefaults.standard.dictionary(forKey: "powerEffects2") as? [String: Double]) ?? [:]
    var powerTestRunning = false
    var powerTestProgress: String?
    /// Savings the last test couldn't pin down (the Mac's own load moved too much while measuring).
    var powerUnclear = Set(UserDefaults.standard.stringArray(forKey: "powerUnclear") ?? [])

    /// Fired on changes worth announcing in the notch: (title, subtitle).
    var onAnnounce: ((String, String) -> Void)?

    let watcher = AgentWatcher()
    let sampler = EnergySampler()
    var timer: Timer?
    var configWatcher: ConfigWatcher?
    var ticks = 0
    /// Apps Nocturnal slowed or paused, mirrored to touched.json before each change (see Journal).
    var touched: [Touched] = []
    /// Last time a counted agent was busy / was running at all. The quiet countdown runs from these, so it
    /// survives the agent's process exiting.
    var lastWork: (at: Date, name: String)?
    var lastSeen: (at: Date, name: String)?
    /// "Let it sleep now": agents don't keep the Mac awake until the lid next opens or the Mac wakes.
    private(set) var snoozed = false
    /// Something about the watchdog or a hold that the person should know.
    var warning: String?
    var sleepRetries = 0
    var floorLatched = false
    /// The person chose "Keep Going" below the battery limit. Lasts until the Mac charges.
    private(set) var floorOverride = false

    /// Something (mode, a hold, an agent) wants the Mac awake, before the safety limits are applied.
    private(set) var wantsHold = false

    /// True when the battery limit is what's stopping Nocturnal, so offering "Keep Going" makes sense.
    var blockedByFloor: Bool {
        guard wantsHold, config.batteryFloor > 0, let b = battery, b.discharging || !b.onAC, !floorOverride else { return false }
        // Same 3% band `evaluate` uses, so the button stays while the limit is still what's stopping Nocturnal.
        return b.percent <= config.batteryFloor + (floorLatched ? 3 : 0)
    }

    func overrideFloor(_ on: Bool = true) {
        floorOverride = on
        if on { floorLatched = false }
        evaluate()
    }
    var lastOnAC: Bool?
    var previewOnly = false

    init(passive: Bool = false) {
        previewOnly = passive
        if !passive {
            if let broken = Config.setAsideIfBroken() {
                pendingNotes.append(("Settings file couldn't be read", "Nocturnal is using its defaults. Your file was kept as \(broken)."))
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
            // Also fires for dark wakes (lid shut, screen off), which is what a scheduled wake usually is.
            powerEvents = PowerEvents { [weak self] in
                MainActor.assumeIsolated { self?.poweredOn() }
            }
            // A hook just reported something: look again now rather than at the next sample.
            DistributedNotificationCenter.default().addObserver(forName: AgentEvents.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleWatchers(); self?.evaluate() }
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

    func reloadConfigFromDisk() {
        // A partial edit changes only the keys it names: the rest keep their current values, not the defaults.
        guard let data = try? Data(contentsOf: Config.url),
              let edited = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = (try? JSONSerialization.jsonObject(with: config.encoded())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: current.merging(edited) { _, new in new }),
              var c = try? JSONDecoder().decode(Config.self, from: merged) else { return }
        // Safety is checked before anything is applied, so a loosened limit never takes effect, not even for a tick.
        let undone = Self.keepSafety(&c)
        apply(c, save: false)
        if undone.isEmpty { enforceSafety() } else { saveAndExplain(undone) }   // a tightened limit is recorded
    }

    /// Notes waiting to be shown (from startup, before notifications are wired).
    var pendingNotes: [(String, String)] = []

    /// Undoes any loosening of the heat guard or battery limit that didn't come from Nocturnal's own UI.
    func enforceSafety() {
        guard !previewOnly else { return }
        var c = config
        let undone = Self.keepSafety(&c)
        guard !undone.isEmpty else {
            let mine = Safety(heatGuard: c.heatGuard, batteryFloor: c.batteryFloor, onlyOnPower: c.onlyOnPower)
            if Safety.load() != mine { mine.save() }
            return
        }
        config = c
        saveAndExplain(undone)
    }

    /// Puts back the safety settings recorded by Nocturnal's own UI wherever `c` loosens them; says what it undid.
    static func keepSafety(_ c: inout Config) -> [String] {
        guard let s = Safety.load() else { return [] }
        var undone: [String] = []
        if s.heatGuard && !c.heatGuard { c.heatGuard = true; undone.append("the heat guard stays on") }
        if c.batteryFloor < s.batteryFloor { c.batteryFloor = s.batteryFloor; undone.append("the battery limit stays at \(s.batteryFloor)%") }
        if s.onlyOnPower == true && !c.onlyOnPower { c.onlyOnPower = true; undone.append("it still only stays awake on power") }
        return undone
    }

    private func saveAndExplain(_ undone: [String]) {
        try? config.encoded().write(to: Config.url, options: .atomic)
        let note = ("Settings file change ignored", "Safety settings can only be loosened in Nocturnal itself: " + undone.joined(separator: " and ") + ".")
        if let n = onNote { n(note.0, note.1) } else { pendingNotes.append(note) }
    }

    /// Shown as a notification (wired by Notifier).
    var onNote: ((String, String) -> Void)?

    // MARK: Loop

    func tick() {
        ticks += 1
        Heartbeat.beat()
        // Asked to sleep a minute ago, lid still shut, still running: ask again (up to 3 times).
        if let asked = receipt?.sleepRequestedAt, receipt?.sleptAt == nil, receipt?.openedAt == nil, lidClosed, !holding,
           sleepRetries < 3, Date().timeIntervalSince(asked) >= 60 * Double(sleepRetries + 1) {
            sleepRetries += 1
            Shell.pmsetRoot(["sleepnow"])
        }
        let lid = Registry.lidClosed
        if lid != lidClosed { lidChanged(to: lid) }
        trackOffline()
        if ticks % 5 == 0 { let h = net.onPhoneHotspot; if h != onHotspot { onHotspot = h } }

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
        if !touched.isEmpty && !(lidClosed && holding) && !measuring && ticks % 5 == 0 { restoreApps() }
        // Screen and brightness that couldn't be put back when the lid opened (the panel can come back a moment
        // later than the lid event): keep trying while the lid is open.
        if !lidClosed && ticks % 2 == 0 {
            if StateFiles.exists(DisplayPower.marker) { DisplayPower.restoreBuiltIn() }
            if StateFiles.exists(Brightness.restoreFile) { Brightness.restore() }
        }
        if holding { StateFiles.touch(StateFiles.hold) }
        // Holding, but sleep is back on: the watchdog took over during a stall, or another program switched it.
        // Switch it off again (the hold is still wanted: evaluate decided so, within the limits).
        if holding, ticks % 5 == 0, !previewOnly, !Registry.sleepDisabled {
            StateFiles.remove(SleepSwitch.marker)   // no longer switched off by someone else: Nocturnal's from here
            if Shell.pmsetRoot(["-a", "disablesleep", "1"]) { StateFiles.touch(StateFiles.hold) }
            else { warning = "Sleep was switched back on by something else and Nocturnal couldn't switch it off again." }
        }
        if ticks % 150 == 3 { checkWatchdog() }
        if pendingRelease, SleepSwitch.release() {
            pendingRelease = false
            if warning == "Couldn't switch sleep back on yet; Nocturnal keeps trying." { warning = nil }
            if lidClosed && !holding { Shell.pmsetRoot(["sleepnow"]) }   // the sleep retries may have run out meanwhile
        }
        if ticks % 5 == 0 { reloadConfigIfEdited() }
        if ticks % 5 == 0 { checkScheduledWake(); reassertSleep(); checkApprove() }
        evaluate()
        settleAdoptedHold()
    }

    /// "Approve everything" turns itself off when the work finishes or its time is up, and keeps retrying if
    /// something couldn't be put back.
    func checkApprove() {
        approveChanged()   // also picks up a change made elsewhere (the CLI's uninstall, a second copy)
        guard !previewOnly, AutoApprove.isOn else { return }
        // Agent work only: Always, timers and terminal holds don't count as "the work".
        let working = workReason() != nil
        if working, AutoApprove.load()?.sawWork != true { AutoApprove.markWork(); approveChanged() }
        guard let why = AutoApprove.expiry(holdingForWork: working) else { return }
        let ok = (try? AutoApprove.turnOff()) != nil
        approveChanged()
        guard why != "retry" || ok else { return }
        onNote?("Approve everything is off", ok
            ? "\(why), so Claude Code and Codex ask before acting again."
            : "Couldn't put your Claude Code and Codex settings back yet; Nocturnal keeps trying.")
    }

    /// Approve everything as last read from its journal, for the panel and Settings (observable, unlike the file).
    private(set) var approve = AutoApprove.Status.read()
    func approveChanged() { let s = AutoApprove.Status.read(); if s != approve { approve = s } }

    /// Sleep is Nocturnal's switch: Nocturnal's sudoers entry lets any program of this user run `pmset -a disablesleep 1`,
    /// so an agent could keep the Mac up past the battery limit or the heat guard. Whenever Nocturnal isn't holding
    /// (or checking in, or still settling a hold it adopted), sleep goes back on.
    func reassertSleep() {
        guard !previewOnly, setupReady, !holding, checkInUntil == nil, adoptedHoldUntil == nil, !pendingRelease else { return }
        // Sleep was off before Nocturnal (the person's own `pmset disablesleep 1`): leave it, until they switch it back.
        if SleepSwitch.notOurs {
            if !Registry.sleepDisabled { StateFiles.remove(SleepSwitch.marker) }
            return
        }
        guard Registry.sleepDisabled else { return }
        if SleepSwitch.release(), lidClosed { Shell.pmsetRoot(["sleepnow"]) }
    }

    /// Sleep is switched off outside Nocturnal (it was off before Nocturnal needed it), so the Mac never sleeps
    /// with the lid closed, whatever Nocturnal decides. Shown in the panel with a way to switch it back on.
    var sleepOffOutside: Bool { SleepSwitch.notOurs && Registry.sleepDisabled && !holding }

    func switchSleepBackOn() {
        guard SleepSwitch.forceOn() else { warning = "Couldn't switch sleep back on. Run: sudo pmset -a disablesleep 0"; return }
        evaluate()
    }

    /// Catches in-place edits (nano, `echo >`) that the folder watcher can miss.
    var configMTime: Date?
    func reloadConfigIfEdited() {
        let m = (try? FileManager.default.attributesOfItem(atPath: Config.url.path)[.modificationDate]) as? Date
        if let m, let old = configMTime, m > old { reloadConfigFromDisk() }
        configMTime = m
    }

    /// What agents report through their own hooks (see AgentEvents), laid over the power-based guess: working
    /// keeps the Mac awake however quiet the work is, a question waiting for an answer keeps it awake for a while
    /// (and says so on the phone), and a finished turn starts the quiet countdown even if a helper keeps ticking.
    var agentEvents: [AgentEvent] = []
    var announcedWaits = Set<String>()

    /// An agent is asking the person something (a permission prompt) while the lid is shut: (agent name).
    var onNeedsYou: ((String) -> Void)?

    /// Launchd still has the watchdog loaded; if not, reinstall it once, then warn.
    var watchdogRepairTried = false
    static let watchdogWarning = "The safety watchdog isn't running, so a crash wouldn't be cleaned up automatically. Run Set Up again in Settings › General."
    func checkWatchdog() {
        guard !previewOnly, setupReady else { return }
        let repair = !watchdogRepairTried
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var loaded = Setup.watchdogLoaded
            if !loaded && repair {
                try? Setup.installWatchdog()
                loaded = Setup.watchdogLoaded
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if repair && !loaded { self.watchdogRepairTried = true }
                if loaded { if self.warning == Self.watchdogWarning { self.warning = nil } }
                else if self.warning == nil { self.warning = Self.watchdogWarning }
            }
        }
    }

    // MARK: State used by Engine+Agents.swift ("finished" alerts)

    /// Session id → when it started working, for sessions working at the last sample.
    var workingSince: [String: Date] = [:]
    /// Went quiet: (busy since, quiet since). Announced only if still quiet 2 minutes later.
    var idlePending: [String: (since: Date, quietAt: Date)] = [:]
    var finishedNames: [String: String] = [:]
    /// Called with (agent name, minutes it was busy, whether its process is gone, what its hooks last reported) once
    /// an agent that was busy for at least a minute has been quiet for 2 minutes. Without hooks Nocturnal can't tell
    /// success from a crash or a question waiting for an answer, so it only says "finished" when the agent did.
    var onFinished: ((String, Double, Bool, AgentState?) -> Void)?

    // MARK: Sampling

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

    func readBattery() {
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
        smoothClosedFigures()
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

    /// Exponential average with a 3-minute time constant, whatever the gap between readings.
    private func smoothClosedFigures() {
        let now = Date()
        let a = 1 - exp(-max(0, now.timeIntervalSince(smoothedAt)) / 180)
        smoothedAt = now
        if lidClosed && holding && !powerTestRunning, let w = systemWatts ?? drawNow {
            closedNow = closedNow.map { $0 + (w - $0) * a } ?? closedForecast ?? w
        } else if !lidClosed {
            closedNow = nil
            let f = closedModel
            closedForecast = closedForecast.map { $0 + (f - $0) * a } ?? f
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
            if a.state == .waiting && isWorking(a) { return "\(name) is waiting for you" }
            if isWorking(a) { return a.toolRunning && a.watts < a.kind.idleWatts ? "\(name) is running a command" : Self.describe(a) }
            if !config.sleepWhenDone { return "\(name) is open" }
            let left = window - Date().timeIntervalSince(a.lastActive)
            let what = a.state == .finished ? "finished" : (a.state == .waiting ? "is still waiting" : "went idle")
            return "\(name) \(what) · sleeps in \(PanelFormat.minutes(max(60, left)))"
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
            // Holds are explicit requests (a timer, `nocturnal run`, a Shortcut), so they work even when Nocturnal is off.
            if let h = holds.last { want = true; reason = h.reason }
        case .on: want = true; reason = onUntil.map { "Awake until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Always awake"
        case .auto:
            if let h = holds.last { want = true; reason = h.reason }
            else if snoozed { }   // "Let it sleep now": agents wait until the lid opens again
            else if let r = workReason() { want = true; reason = r }
        }

        wantsHold = want
        if !want && holdFailedAt != nil { holdFailedAt = nil; warning = nil }   // nothing to hold any more
        blockedReason = nil
        // "On power" means the charger is covering the load, not just plugged in.
        if want && config.onlyOnPower && onBattery { want = false; blockedReason = "Only on power" }
        // Battery limit. 0 means "never stop for battery"; "Keep Going" (override) skips it until the charger
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
        else if !want && holding { endHold(because: blockedReason ?? endReason) }

        // Heat guard: switch to the strictest rules once when it gets hot, and back once it cools.
        let hot = holding && lidClosed && config.heatGuard && thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if hot && !heatForced && config.preset != .longest { heatForced = true; reapplyClosedState(forcing: .longest) }
        else if !hot && heatForced { heatForced = false; if holding && lidClosed { reapplyClosedState() } }
    }

    /// Why a hold just ended, for the receipt and the notification.
    var endReason: String {
        if config.mode == .off { return "Turned off" }
        if snoozed { return "Put to sleep" }
        if let w = config.sleepWhenDone ? lastWork : lastSeen { return "\(w.name) finished" }
        return "Nothing left to wait for"
    }

    var heatForced = false
    /// When it got hot (serious or worse) with the lid shut.
    var hotSince: Date?
    /// How long "serious" heat with the lid shut is tolerated before the Mac is put to sleep.
    static let hotGrace: TimeInterval = 300
    var pendingRelease = false
    var holdFailedAt: Date?
    var holdFailing: Bool { holdFailedAt != nil }
    var activity: NSObjectProtocol?

    static func describe(_ s: AgentSession) -> String {
        if s.kind.isRequest { return "\(s.kind.name) asked to stay awake" }
        return s.kind.isAI ? "\(s.kind.name) is working" : "\(s.kind.name) is busy"
    }

    func isWorking(_ s: AgentSession) -> Bool { Date().timeIntervalSince(s.lastActive) < 20 }

    /// One line for tooltips, the notch and `nocturnal status`.
    var statusLine: String {
        if !setupReady { return "Needs a one-time setup" }
        if let b = blockedReason { return "\(b), sleeps when closed" }
        switch config.mode {
        case .off:
            if holding, let r = holdReason { return "\(r) · stays awake closed" }
            return "Sleeps normally"
        case .on:
            guard let u = onUntil else { return "Awake until you turn it off" }
            return "Awake until \(u.formatted(date: .omitted, time: .shortened)) · \(PanelFormat.hm(max(0, u.timeIntervalSinceNow) / 3600)) left"
        case .auto:
            if holding, let r = holdReason { return "\(r) · stays awake closed" }
            if snoozed { return "Sleeping until the lid opens" }
            return "Nothing running · sleeps when closed"
        }
    }

    var menuBarTitle: String {
        switch config.menuBarText {
        case .none: return ""
        case .battery: return battery.map { "\($0.percent)%" } ?? ""
        case .watts: return (systemWatts ?? drawNow).map { String(format: "%.1fW", $0) } ?? ""
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

    // MARK: Runtime state that must survive a relaunch

    /// Holds survive a relaunch. (The Always timer lives in config.json next to the mode it belongs to.)
    struct Runtime: Codable { var holds: [Hold] }
    static var runtimeURL: URL { StateFiles.dir.appendingPathComponent("runtime.json") }

    func saveRuntime() {
        guard !previewOnly else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(Runtime(holds: holds)).write(to: Self.runtimeURL, options: .atomic)
    }

    func restoreRuntime() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: Self.runtimeURL), let r = try? dec.decode(Runtime.self, from: d) else { return }
        holds = r.holds.filter(\.isAlive)
    }

    // MARK: Holds (from the CLI, MCP or Shortcuts)

    @discardableResult
    func addHold(reason: String, minutes: Double?, pid: Int32?, owner: Int32? = nil) -> Hold {
        var h = Hold(id: String(UUID().uuidString.prefix(8)).lowercased(), reason: reason,
                     until: minutes.map { Date().addingTimeInterval($0 * 60) }, pid: pid, pidStart: pid.flatMap { Procs.startTime($0) })
        h.owner = owner
        holds.append(h)
        saveRuntime()
        evaluate()
        announce(reason, minutes.map { "Staying awake for \(Self.formatMinutes($0))" } ?? "Staying awake")
        return h
    }

    /// MCP: an agent session may only end holds it made itself (tied to its own pid).
    func releaseHolds(ownedBy pid: Int32, id: String? = nil) -> Int {
        let before = holds.count
        holds.removeAll { ($0.owner == pid || $0.pid == pid) && (id == nil || $0.id == id) }
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

    static func preview(setupReady: Bool = true) -> Engine {
        let e = Engine(passive: true)
        e.setupReady = setupReady
        Thread.sleep(forTimeInterval: 1.2)
        e.apps = Array(e.sampler.sample().prefix(40))
        e.sampleWatchers()
        e.evaluate()
        return e
    }

    // MARK: Holding the Mac awake

    func startHold(reason: String?) {
        if previewOnly { holding = true; return }
        if let last = holdFailedAt, Date().timeIntervalSince(last) < 30 { return }   // don't spawn sudo every 2 s
        // Already off and not by Nocturnal: note it, so it's left that way when the hold ends.
        SleepSwitch.noteOwner()
        // Marker first: if Nocturnal dies right after pmset, the watchdog knows to switch sleep back on.
        StateFiles.touch(StateFiles.hold)
        guard StateFiles.exists(StateFiles.hold) else { setupError = "Nocturnal couldn't write to its folder, so it won't switch sleep off"; return }
        guard Shell.pmsetRoot(["-a", "disablesleep", "1"]) else {
            if !pendingRelease { StateFiles.remove(StateFiles.hold) }
            holdFailedAt = Date()
            warning = "macOS refused to switch sleep off, so closing the lid would sleep the Mac. Run Set Up again in Settings › General."
            let ready = Setup.isReady
            if ready != setupReady { setupReady = ready }
            return
        }
        if holdFailedAt != nil { holdFailedAt = nil; warning = nil }
        holding = true
        pendingRelease = false
        // Keep App Nap from stretching Nocturnal's 2-second loop while the lid is shut and nothing is on screen;
        // a late heartbeat would make the watchdog undo a hold that's still wanted.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Supervising a lid-closed session")
        if lidClosed { enterClosed() }
        announce(reason ?? "Staying awake", "Keeps working with the lid closed")
    }

    func endHold(because why: String) {
        if previewOnly { holding = false; return }
        let wasClosed = lidClosed
        if wasClosed { accumulateSavings() }
        if wasClosed { restoreClosedState() }
        if !SleepSwitch.release() {
            // Keep the hold file so the watchdog also retries, and retry every tick ourselves.
            pendingRelease = true
            warning = "Couldn't switch sleep back on yet; Nocturnal keeps trying."
        }
        holding = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if wasClosed {
            sleepInfo = (Date(), drawNow ?? 0)   // on the charger, sleeping saves no battery, so it counts as 0
            receipt?.sleepRequestedAt = Date()
            receipt?.endPercent = battery?.percent
            sleepRetries = 0
            // macOS only sleeps on the lid-close edge; it's already shut, so ask directly. Confirmed (or retried)
            // from macOS's own will-sleep notification.
            Shell.pmsetRoot(["sleepnow"])
        } else {
            announce(why, "Sleeps normally again")
        }
    }

    func announce(_ title: String, _ subtitle: String) {
        guard !previewOnly, !lidClosed else { return }
        onAnnounce?(title, subtitle)
    }

    // MARK: Lid

    func lidChanged(to closed: Bool) {
        lidClosed = closed
        if closed {
            if holding { enterClosed() }
        } else {
            snoozed = false
            sleepRetries = 0
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

    /// Counts the minutes without internet during a lid-closed session, for the receipt.
    func trackOffline() {
        guard var r = receipt else { return }
        let end = r.openedAt ?? (lidClosed ? nil : Date())
        if let since = r.offlineSince, net.online || end != nil {
            r.offlineSeconds += (end ?? Date()).timeIntervalSince(since)
            r.offlineSince = nil
        } else if r.offlineSince == nil, !net.online, end == nil, r.sleptAt == nil {
            r.offlineSince = Date()
        }
        if r != receipt { receipt = r }
    }

    static func receiptLine(_ r: Receipt) -> String {
        let end = r.sleptAt ?? r.sleepRequestedAt ?? r.openedAt ?? Date()
        let mins = Int(end.timeIntervalSince(r.closedAt) / 60)
        let dur = mins < 60 ? "\(max(1, mins)) min" : "\(mins / 60) h \(mins % 60) min"
        var s = r.sleptAt != nil ? "Ran \(dur), then slept" : (r.sleepRequestedAt != nil ? "Ran \(dur), then asked it to sleep" : "Stayed awake \(dur)")
        if let a = r.startPercent, let b = r.endPercent, a >= b { s += " · used \(a - b)%" }
        if r.offlineSeconds >= 60 { s += " · no internet for \(Int(r.offlineSeconds / 60)) min" }
        return s
    }

    // MARK: State used by Engine+ClosedLid.swift

    var displayAssertion: IOPMAssertionID = 0

    var lidPoll: Timer?
    /// The built-in display is configured off right now (screen_off).
    var screenOff = false

    // MARK: Crash recovery and shutdown

    /// If a previous run died mid-hold, undo what it left behind before doing anything else.
    func recoverFromCrash() {
        Journal.undoLegacyFiles()
        // Anything that can't be put back stays in the journal and is retried every few ticks.
        touched = Journal.undo(Journal.load())
        Journal.save(touched)
        restorePowerMode()
        TimeMachine.resume()
        DisplayPower.restoreBuiltIn()
        Brightness.restore()
        SleepSwitch.noteOwner()   // off with no hold marker: not Nocturnal's doing
        if Registry.sleepDisabled && StateFiles.exists(StateFiles.hold) {
            // Take the previous run's hold over instead of releasing it first (see adoptedHoldUntil).
            adoptedHoldUntil = Date().addingTimeInterval(30)
        } else {
            StateFiles.remove(StateFiles.hold)
        }
    }

    /// Set when Nocturnal starts and finds sleep still switched off by a previous run (a crash, a forced quit, an update).
    /// Releasing that hold first and taking it again a moment later would let a Mac with its lid shut fall asleep
    /// in between, so the new run keeps it. If nothing wants it, it's released after 30 s (agents need a few
    /// samples to show up as working), or at once when a limit says sleep (battery, heat, setup, Off).
    var adoptedHoldUntil: Date?

    func settleAdoptedHold() {
        guard let until = adoptedHoldUntil else { return }
        if holding { adoptedHoldUntil = nil; return }
        let mustSleep = !setupReady || blockedReason != nil || (config.mode == .off && holds.isEmpty)
        guard mustSleep || Date() > until else { return }
        adoptedHoldUntil = nil
        if !SleepSwitch.release() { pendingRelease = true }
        if lidClosed { Shell.pmsetRoot(["sleepnow"]) }   // macOS only sleeps on the lid-close edge; it's already shut
    }

    func shutdown() {
        guard !previewOnly else { return }
        restoreClosedState()
        if holding || pendingRelease || adoptedHoldUntil != nil || checkInUntil != nil {
            // If this fails the hold file stays, so the watchdog keeps trying after we're gone.
            SleepSwitch.release()
        } else {
            StateFiles.remove(StateFiles.hold)
        }
        holding = false
        // Nothing will be watching for the work to finish or the time to run out once Nocturnal has quit.
        AutoApprove.endUnwatched()
        // Everything is back: no heartbeat means the watchdog has nothing to check after we're gone.
        if Watchdog.systemChanges().isEmpty { StateFiles.remove(StateFiles.alive) }
    }

    // MARK: State used by Engine+Savings.swift

    var screenStepRan = false

    /// How the last power test ended: nil when it finished, otherwise why it stopped.
    var powerTestAborted: String?

    // MARK: Setup and misc

    /// Puts everything back and removes the sudoers entry, watchdog and CLI link.
    func uninstallHelper() throws {
        // Approve everything goes back first (it's a change to other apps' settings, and nobody would see it was on).
        try AutoApprove.turnOff()
        update { $0.mode = .off }
        _ = releaseHold(nil)
        shutdown()
        // The sudoers entry and the watchdog are the only ways to switch sleep back on without a password, so
        // they're removed only once nothing Nocturnal changed is left.
        let left = Watchdog.outstanding()
        guard left.isEmpty else {
            throw SetupError(message: "Not removed yet: \(left.joined(separator: ", ")). Nocturnal keeps its helper so it can keep trying; try again in a minute.")
        }
        AIConnect.disconnectAll()
        try Setup.uninstall()
        setupReady = Setup.isReady
    }

    func runSetup() {
        holdFailedAt = nil
        // Run from Downloads or a disk image, macOS gives the app a temporary path that disappears; the
        // `nocturnal` command and the Claude config would point at nothing.
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"), !path.contains("AppTranslocation") else {
            setupError = "Move Nocturnal to your Applications folder first, then open it from there."
            return
        }
        do { try Setup.install(); setupError = nil } catch { setupError = error.localizedDescription }
        setupReady = Setup.isReady
        wakeReady = Setup.wakeReady
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

    // MARK: Sleep now and Always

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

    func stayAwake(for minutes: Int?) {
        let before = config.mode
        // Mode and end time are written together in one file, so they can't disagree after a crash.
        update { c in
            if before != .on { c.modeBeforeAlways = before }
            c.mode = .on
            c.alwaysUntil = minutes.map { Date().addingTimeInterval(TimeInterval(min($0, 7 * 24 * 60) * 60)).timeIntervalSince1970 }
        }
        evaluate()
        announce(minutes.map { "Awake for \(Self.formatMinutes(Double($0)))" } ?? "Always awake", "Keeps working with the lid closed")
    }
}
