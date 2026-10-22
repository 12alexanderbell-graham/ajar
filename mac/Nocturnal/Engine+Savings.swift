import AppKit
import IOKit.pwr_mgt

/// Savings: what the lid-closed rules save, the power test that measures it on this Mac, the report an agent can
/// act on, and the battery estimates.
extension Engine {
    /// Remember what each app draws when Nocturnal isn't touching it, so savings are measured against reality.
    func updateBaseline() {
        for a in apps where targeted[a.id] == nil && a.id.hasSuffix(".app") {
            baseline[a.id] = baseline[a.id].map { $0 * 0.7 + a.watts * 0.3 } ?? a.watts
        }
    }

    func accumulateSavings() {
        let now = Date()
        var rate = 0.0
        if let measured = powerEffects["total"], !targeted.isEmpty || lowPowerSet {
            // What the power test measured Nocturnal's savings to be worth on this Mac, while they're applied. (Comparing
            // with the lid-open draw would credit Nocturnal with the screen being off, which happens anyway.)
            rate = measured
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

    func percent(ofWh wh: Double) -> Double { wh / max(fullWh, 1) * 100 }

    func finishSession(openedAt: Date) {
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
                         "note": found.agentUsesXcode ? "An agent is connected to Xcode, so Xcode, simulators and previews are left alone." : found.testsRunning ? "Tests are running, so simulators are left alone." : "", "measured_saving_watts": r1(powerEffects["simulators"])])
        suspects.append(["id": "background_audio", "active": !found.audio.isEmpty,
                         "title": found.audio.isEmpty ? "Nothing holding the speakers open" : "Holding the speakers open: " + found.audio.values.sorted().joined(separator: ", "),
                         "setting": "pause_background_audio", "value": config.pauseBackgroundAudio, "suggested_value": "on",
                         "measured_saving_watts": r1(powerEffects["audio"])])
        let busy = userApps.filter { !isProtected($0) && $0.watts > 0.2 }.prefix(6)
        suspects.append(["id": "apps", "active": !busy.isEmpty, "title": busy.isEmpty ? "No other app is busy" : "Busy apps: " + busy.map { "\($0.name) \(String(format: "%.1f", $0.watts)) W (\(rule(for: $0.bundleID).rawValue))" }.joined(separator: ", "),
                         "setting": "preset", "value": ["longest": "max_battery", "balanced": "balanced", "speed": "full_speed"][config.preset.rawValue] ?? "", "suggested_value": "max_battery",
                         "per_app": "nocturnal rule <app> pause", "measured_saving_watts": r1(powerEffects["apps"])])
        if Displays.externalConnected {
            suspects.append(["id": "external_display", "active": true, "title": "An external display is connected",
                             "why": "With a display attached the Mac keeps its graphics and display pipeline running, often several watts. Unplug it if nobody is using it."])
        }
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
            "power_test": powerTestRunning ? (powerTestProgress ?? "running") : powerTestAborted.map { "aborted: \($0)" } ?? (powerEffects.isEmpty && powerUnclear.isEmpty ? "not run yet" : "done"),
            "measured_total_saving_watts": powerUnclear.contains("total") ? "unclear (the Mac's own load moved too much; run it again when agents are quiet)" as Any : r1(powerEffects["total"]) as Any,
            "measured_closed_watts": ["with_savings": r1(powerEffects["closed_with"]), "without_savings": r1(powerEffects["closed_without"])],
            "how_to_measure": "nocturnal power test (lid closed, about 3-4 minutes): all savings off, on, off, on, each read over a full 30 s update of the battery controller. --detailed adds each saving on its own (about 1.5 min each). --screen includes the screen (that locks the Mac).",
        ]
    }

    /// With the lid closed, switches each saving off and back on and measures the whole-Mac difference, so the
    /// numbers shown are real for this Mac. About 30 s per step; agents keep running throughout.
    func startPowerTest(includeScreen: Bool, detailed: Bool = false) -> String? {
        guard lidClosed && holding else { return "Close the lid first (with Nocturnal keeping the Mac awake): the test measures lid-closed savings" }
        guard !powerTestRunning else { return "A power test is already running" }
        guard PowerSensor.isMeasured else { return "This Mac doesn't report whole-system power, so savings can't be measured" }
        powerTestRunning = true
        powerTestAborted = nil
        var steps = ["apps", "simulators", "audio", "low_power"]
        // Switching the display off locks Macs set to ask for the password immediately, so it's only measured
        // there when the person already chose it.
        if DisplayPower.available && !config.lockOnClose && (config.screenOffNoLock || LockSetting.gracePeriod() != 0) { steps.append("screen_off") }
        if includeScreen && !config.lockOnClose { steps.append("screen") }
        runTotalTest(steps, then: detailed ? steps : [])
        return nil
    }

    /// Whether a saving is in force under the current settings.
    func savingOn(_ step: String) -> Bool {
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

    /// Puts every listed saving in the given state at once. The app categories (apps, simulators, audio) are one
    /// set of targets, so they're applied together in a single pass: applying them one by one undid the others.
    func setSavings(_ want: [String: Bool]) {
        let appCats = ["apps", "simulators", "audio"]
        if appCats.contains(where: { want[$0] != nil }) {
            let skip = Set(appCats.filter { want[$0] == false })
            applyClosedTargets(preset: effectivePreset, skip: skip)
        }
        for (step, on) in want where !appCats.contains(step) {
            switch step {
            case "low_power": if on { setLowPower() } else { restorePowerMode() }
            case "screen_off":
                if on { if !screenOff { switchScreenOff() } } else if screenOff { DisplayPower.restoreBuiltIn(); screenOff = false; Brightness.dimForClosedLid() }
            case "screen":
                if on { Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
                else { Shell.spawn("/usr/bin/caffeinate", ["-u", "-t", "2"]) }   // declares activity: the display comes back on
            default: break
            }
        }
    }

    /// The battery controller publishes its power figures about every 30 s (an exact average of the samples it
    /// took since the last time). So a reading waits for the next update after a change (it mixes before and
    /// after), then returns the exact average over the following full period: only the state just set.
    /// Shorter windows saw no update at all and read a stale figure, which is how the first tests got nonsense.
    func cleanReading(_ done: @escaping (Double?) -> Void) {
        let start = PowerSensor.sample()?.count
        var boundary: PowerSample?
        var polls = 0
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.lidClosed, self.holding else { return done(nil) }
                polls += 1
                guard polls < 150, let s = PowerSensor.sample(), let c = s.count else { return done(nil) }
                if let b = boundary {
                    if c != b.count { return done(PowerSensor.average(b, s)) }
                } else if c != start {
                    boundary = s
                }
                poll()
            }
        }
        poll()
    }

    /// Everything off, on, off, on: what Nocturnal's savings are worth together, with the lid shut. The smaller of the
    /// two differences counts; if the pairs disagree a lot (the Mac's own load moved), it's reported as unclear.
    func runTotalTest(_ steps: [String], then detailed: [String]) {
        // The locking screen-off is only measured on its own (--detailed --screen): it's never on in the normal state.
        let was = Dictionary(uniqueKeysWithValues: steps.filter { $0 != "screen" }.map { ($0, savingOn($0)) })
        let allOff = was.mapValues { _ in false }
        var readings: [Double] = []
        let pattern = [false, true, false, true]
        func next(_ i: Int) {
            guard i < pattern.count else { return finish() }
            powerTestProgress = "Measuring, \(i + 1) of \(pattern.count + detailed.count * 2)"
            setSavings(pattern[i] ? was : allOff)
            cleanReading { [weak self] w in
                guard let self else { return }
                // Lid opened or the hold ended: stop without re-applying anything.
                guard let w else { return self.endPowerTest(aborted: self.abortReason, was: was) }
                readings.append(w); next(i + 1)
            }
        }
        func finish() {
            setSavings(was)
            let d1 = readings[0] - readings[1], d2 = readings[2] - readings[3]
            powerEffects["closed_without"] = (readings[0] + readings[2]) / 2
            powerEffects["closed_with"] = (readings[1] + readings[3]) / 2
            if abs(d1 - d2) > max(0.6, 0.35 * max(abs(d1), abs(d2))) {
                powerEffects["total"] = nil; powerUnclear.insert("total")
            } else {
                powerEffects["total"] = max(0, min(d1, d2)); powerUnclear.remove("total")
            }
            // Per-saving rows only from a breakdown run; older ones would sit next to this total as if current.
            if detailed.isEmpty {
                for k in ["apps", "simulators", "audio", "low_power", "screen_off", "screen"] { powerEffects[k] = nil; powerUnclear.remove(k) }
            }
            runDetailStep(detailed[...], was: was, done: 4, of: 4 + detailed.count * 2)
        }
        next(0)
    }

    /// Optional breakdown (nocturnal power test --detailed): each saving off, then on, one clean period each, with the
    /// others left as they were.
    func runDetailStep(_ steps: ArraySlice<String>, was: [String: Bool], done: Int, of total: Int) {
        guard let step = steps.first else { return endPowerTest(aborted: nil, was: was) }
        guard lidClosed, holding else { return endPowerTest(aborted: abortReason, was: was) }
        if (step == "simulators" && background.simulators.isEmpty && background.previews.isEmpty) || (step == "audio" && background.audio.isEmpty) {
            powerEffects[step] = nil; powerUnclear.remove(step)
            return runDetailStep(steps.dropFirst(), was: was, done: done + 2, of: total)
        }
        powerTestProgress = "Measuring \(Self.stepName(step)), \(done + 1) of \(total)"
        if step == "screen" { screenStepRan = true }
        var off = was; off[step] = false
        var on = was; on[step] = true
        setSavings(off)
        cleanReading { [weak self] offW in
            guard let self else { return }
            guard let offW else { return self.endPowerTest(aborted: self.abortReason, was: was) }
            self.setSavings(on)
            self.powerTestProgress = "Measuring \(Self.stepName(step)), \(done + 2) of \(total)"
            self.cleanReading { [weak self] onW in
                guard let self else { return }
                guard let onW else { return self.endPowerTest(aborted: self.abortReason, was: was) }
                self.setSavings(was)
                self.powerEffects[step] = max(0, offW - onW); self.powerUnclear.remove(step)
                self.runDetailStep(steps.dropFirst(), was: was, done: done + 2, of: total)
            }
        }
    }

    /// Why a reading came back empty.
    var abortReason: String {
        !lidClosed ? "the lid was opened" : (!holding ? "Nocturnal stopped keeping the Mac awake" : "the battery controller stopped reporting power")
    }

    func endPowerTest(aborted: String?, was: [String: Bool]) {
        // Screen and Low Power Mode back to how they were (the screen comes back on if the locking step ran),
        // while the lid is still shut and held; the app targets are re-applied below.
        if lidClosed && holding {
            var s = was.filter { !["apps", "simulators", "audio"].contains($0.key) }
            if screenStepRan { s["screen"] = false }
            setSavings(s)
        }
        screenStepRan = false
        powerTestRunning = false
        powerTestProgress = nil
        powerTestAborted = aborted
        if aborted == nil {
            UserDefaults.standard.set(powerEffects, forKey: "powerEffects2")
            UserDefaults.standard.set(Array(powerUnclear), forKey: "powerUnclear")
        }
        // Back to exactly what the settings (and the heat guard) call for, or everything restored if the lid opened.
        if lidClosed && holding { reapplyClosedState(forcing: heatForced ? .longest : nil) } else { restoreClosedState() }
    }

    static func stepName(_ step: String) -> String {
        ["apps": "other apps", "simulators": "simulators", "audio": "background audio", "low_power": "Low Power Mode",
         "screen_off": "screen off", "screen": "screen off (locks)"][step] ?? step
    }

    /// Watts now, or nil on the charger.
    var drawNow: Double? { battery.flatMap { $0.discharging ? $0.watts : nil } }

    /// What the Mac should draw with the lid shut under the current preset. Display off, other apps
    /// slowed (≈ ¼ power, measured) or paused (0). The 1.6 W floor is SoC + Wi-Fi + memory with the lid shut.
    var closedEstimate: Double {
        if lidClosed, holding, let d = systemWatts ?? drawNow { return d }
        let others = apps.reduce(0.0) { sum, a in
            if a.system { return sum }   // covered by the base figure
            if isProtected(a) { return sum + a.watts }
            switch rule(for: a.bundleID) { case .leave: return sum + a.watts; case .slow: return sum + a.watts * 0.25; case .pause: return sum }
        }
        let estimate = closedDraw ?? (1.6 + others)
        // Closing the lid only takes power away (screen off, apps slowed), so the estimate never exceeds what the
        // Mac draws right now with it open. (The learned figure can include heavy builds from earlier sessions.)
        if !lidClosed, let open = systemWatts ?? drawNow { return min(estimate, open) }
        return estimate
    }

    func hoursLeft(at watts: Double) -> Double? {
        guard let b = battery, watts > 0.1 else { return nil }
        let usable = Double(max(0, b.percent - config.batteryFloor)) / 100 * fullWh
        return usable / watts
    }
}
