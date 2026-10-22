import AppKit
import IOKit.pwr_mgt

/// With the lid closed: the dark or switched-off screen, Low Power Mode, and slowing or pausing other apps
/// (journaled first, put back when the lid opens).
extension Engine {
    func enterClosed() {
        // A new hold while the lid stayed shut (an agent resumed, a wake): close the books on the last one first.
        if let r = receipt, r.openedAt == nil, !previewOnly { finishSession(openedAt: Date()) }
        receipt = Receipt(closedAt: Date(), startPercent: battery?.percent, agentName: activeAgent?.kind.name ?? holds.last?.reason)
        sessionWh = 0
        sleepInfo = nil
        lastSavingSample = Date()
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
        if config.shutDownSimulators && config.preset != .speed && !background.simulatorsInUse && background.simulatorDevices > 0 {
            DispatchQueue.global(qos: .utility).async { _ = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"]) }
        }
    }

    func holdDisplayAwake(_ on: Bool) {
        if on, displayAssertion == 0, !previewOnly {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Nocturnal: lid-closed session (no lock screen on reopen)" as CFString, &id) == kIOReturnSuccess {
                displayAssertion = id
            }
        } else if !on, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    func reapplyClosedState(forcing: Preset? = nil) {
        let p = forcing ?? config.preset
        if p != .speed && config.lowPowerWhileClosed { setLowPower() } else { restorePowerMode() }
        if config.pauseTimeMachine && p != .speed { TimeMachine.pause() } else { TimeMachine.resume() }
        applyClosedTargets(preset: p)
    }

    /// The preset in force: the heat guard can tighten it while the Mac is hot.
    var effectivePreset: Preset { heatForced ? .longest : config.preset }

    /// Screen fully off without a sleep. On some Macs macOS locks the session anyway when its only display
    /// goes off (its "require password after the display is turned off" rule). Nocturnal can't prevent that, so if
    /// the session locks within a few seconds it puts the screen back, switches to the dark screen for good
    /// and says why, so it's at most one surprise password prompt.
    func switchScreenOff() {
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
                self.warning = "macOS locks this Mac when its screen is switched fully off, so Nocturnal went back to the dark screen (no lock screen)."
            }
        }
    }

    func restoreClosedState() {
        lidPoll?.invalidate()
        lidPoll = nil
        if !DisplayPower.restoreBuiltIn() { warning = "Couldn't switch the built-in screen back on. Log out and in to bring it back." }
        screenOff = false
        Brightness.restore()
        holdDisplayAwake(false)
        restoreApps()
        restorePowerMode()
        if !TimeMachine.resume() { warning = "Couldn't switch Time Machine's automatic backups back on. Run: sudo tmutil enable" }
    }

    /// Nocturnal has Low Power Mode switched on right now (and will put the person's setting back).
    var lowPowerSet: Bool { StateFiles.exists(StateFiles.modeRestore) }

    func setLowPower() {
        guard !StateFiles.exists(StateFiles.modeRestore), let cur = PowerMode.battery(), cur.value != 1 else { return }
        StateFiles.write("\(cur.key) \(cur.value)", to: StateFiles.modeRestore)
        if !Shell.pmsetRoot(["-b", cur.key, "1"]) { StateFiles.remove(StateFiles.modeRestore) }
    }

    func restorePowerMode() {
        guard let saved = StateFiles.read(StateFiles.modeRestore) else { return }
        // Changed by the person (or another app) since Nocturnal turned it on: theirs now, leave it.
        if let cur = PowerMode.battery(), cur.value != 1 { StateFiles.remove(StateFiles.modeRestore); return }
        let parts = saved.split(separator: " ").map(String.init)
        // Keep the file if pmset fails, so this (and the watchdog) tries again instead of leaving Low Power Mode on.
        if parts.count != 2 || Shell.pmsetRoot(["-b", parts[0], parts[1]]) { StateFiles.remove(StateFiles.modeRestore) }
    }

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

    /// macOS internals Nocturnal never touches. Safari and other apps shipped in the app cryptex are user apps.
    func isSystemApp(_ path: String) -> Bool {
        if path.contains("/Cryptexes/App/System/Applications/") || path.hasPrefix("/System/Applications/") { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
    }

    /// Pids that must never be slowed: agents and their trees/ancestors (from the watcher), plus anything a
    /// hold is tied to (`nocturnal run`, `nocturnal hold --pid`), its children and the apps above it.
    func protectedPidSet(allPids: [pid_t]) -> Set<pid_t> {
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

    struct ClosedTarget {
        var rule: AppRule
        var start: UInt64
        var path: String
        var bundle: String?
    }

    /// Everything that should be slowed or paused right now with the lid shut, by pid: other apps under the
    /// preset and per-app rules, plus booted simulators, Xcode previews and background audio holders. Never
    /// agents, their process trees and ancestors, anything a hold is tied to, Nocturnal, or macOS itself.
    /// `skip` leaves a category out ("apps", "simulators", "audio"), for measuring what each one is worth.
    func closedTargets(preset p: Preset, skip: Set<String> = []) -> [pid_t: ClosedTarget] {
        let mine = getpid()
        let all = Procs.allPids()
        let protectedPids = protectedPidSet(allPids: all)
        let protectedBundles = watcher.protectedBundles.union(protectedPids.compactMap { Procs.path($0).flatMap(Procs.bundlePath(of:)) })
        let running = NSWorkspace.shared.runningApplications
        let regularPaths = Set(running.filter { $0.activationPolicy == .regular }.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        let found = p == .speed ? BackgroundWork.Found() : BackgroundWork.scan(all: all)
        background = found
        // Xcode and the Simulator app stay untouched while an agent may be using them.
        var inUse: Set<String> = []
        if found.agentUsesXcode { inUse.insert("com.apple.dt.Xcode") }
        if found.simulatorsInUse { inUse.insert("com.apple.iphonesimulator") }
        var bundles: [String: AppRule] = [:]
        if !skip.contains("apps") {
            for app in running where app.activationPolicy == .regular && !inUse.contains(app.bundleIdentifier ?? "") {
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
        if config.slowBuildsWhileClosed && !skip.contains("builds") {
            // The agent's own build tools: inside its process tree, so the protection above skips them on purpose.
            for pid in all where protectedPids.contains(pid) && pid != mine {
                guard let path = Procs.path(pid), BuildTools.names.contains((path as NSString).lastPathComponent),
                      let start = Procs.startTime(pid) else { continue }
                out[pid] = ClosedTarget(rule: .slow, start: start, path: path, bundle: nil)
            }
        }
        guard p != .speed else { return out }
        if config.pauseSimulators && !found.simulatorsInUse && !skip.contains("simulators") {
            // With "shut them down instead", simulators are shut down on close (frozen ones can't shut down).
            for pid in (config.shutDownSimulators ? [] : found.simulators) + found.previews { add(pid, .pause, bundle: nil) }
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
    /// so a crash at any point leaves a record of every process Nocturnal changed.
    func applyClosedTargets(preset: Preset? = nil, skip: Set<String> = []) {
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

    func restoreApps() {
        touched = Journal.undo(touched)   // keeps anything the OS refused; retried every few ticks
        Journal.save(touched)
        if touched.isEmpty { targeted.removeAll() }
        liveSavingW = 0
    }

    /// Apps Nocturnal changed and couldn't put back yet (shown in the panel with a retry).
    var unrestored: [String] {
        guard !(lidClosed && holding) else { return [] }
        return touched.map { ($0.path as NSString).lastPathComponent }
    }

    func retryRestore() { if !(lidClosed && holding) { restoreApps() } }

    /// Apps a person would recognise (no macOS internals, not Nocturnal itself), most power-hungry first.
    var userApps: [AppUsage] {
        apps.filter { a in
            a.id.hasSuffix(".app") && a.bundleID != Bundle.main.bundleIdentifier
                && !a.id.hasPrefix("/System/Library/") && !a.id.hasPrefix("/System/Cryptexes/") && !a.id.hasPrefix("/Library/Apple/")
                && !a.id.contains("/CoreSimulator/") && !a.id.contains(".simruntime/")
        }
    }
}
