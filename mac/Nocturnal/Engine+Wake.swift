import AppKit
import IOKit.pwr_mgt

/// Waking while asleep (see Wake.swift): scheduled wakes, check-ins for the phone, and the phone panel's reply.
extension Engine {
    /// A scheduled wake whose time came while the Mac was already up: with the lid shut it starts the stay-awake
    /// time now; either way it's used up, so it never lingers in Settings or on the phone as a time in the past.
    func checkScheduledWake() {
        guard !previewOnly, let at = config.wakeAt, Date().timeIntervalSince1970 >= at else { return }
        let minutes = config.wakeForMinutes
        update { $0.wakeAt = nil }
        if lidClosed && setupReady { addHold(reason: "Scheduled wake", minutes: Double(minutes), pid: nil) }
    }

    /// macOS is about to sleep: if Nocturnal asked for it, that confirms the sleep (receipts and savings only count
    /// confirmed sleeps).
    func macWillSleep() {
        if receipt?.sleepRequestedAt != nil, receipt?.sleptAt == nil { receipt?.sleptAt = Date() }
        sleepRetries = 0
        scheduleWake()
    }

    /// Just before sleep: ask macOS to wake the Mac for the next check-in or the scheduled wake. Check-ins only
    /// when the lid is shut: with it open, a wake turns the screen on.
    func scheduleWake() {
        nextWakeAt = nil
        guard !previewOnly, wakeReady else { return }
        let untilWake = config.wakeAt.map { $0 - Date().timeIntervalSince1970 }
        let checkIn = Registry.lidClosed ? config.checkInMinutes : 0
        guard let secs = WakePlan.nextStep(untilWake: untilWake, checkInMinutes: checkIn) else { return }
        if Shell.pmsetRoot(WakePlan.pmsetArgs(seconds: secs)) { nextWakeAt = Date().addingTimeInterval(TimeInterval(secs)) }
        else { wakeReady = Setup.wakeReady }
    }

    /// Any wake, dark or full. With the lid open the person is here: nothing to do. With it shut and nothing
    /// holding the Mac, this is a scheduled wake or a check-in.
    func poweredOn() {
        guard !previewOnly, !holding, checkInUntil == nil, Registry.lidClosed else { return }
        if let at = config.wakeAt, Date().timeIntervalSince1970 >= at - 90 {
            let minutes = config.wakeForMinutes
            update { $0.wakeAt = nil }
            addHold(reason: "Scheduled wake", minutes: Double(minutes), pid: nil)
            return
        }
        guard config.checkInMinutes > 0 || config.wakeAt != nil, setupReady else { return }
        // Keep it up for a few seconds (the same switch a hold uses; the marker lets the watchdog undo it if
        // Nocturnal dies), reconnect to the relay and read what the phone sent while it slept.
        SleepSwitch.noteOwner()
        StateFiles.touch(StateFiles.hold)
        guard Shell.pmsetRoot(["-a", "disablesleep", "1"]) else { StateFiles.remove(StateFiles.hold); return }
        let until = Date().addingTimeInterval(WakePlan.checkInSeconds)
        checkInUntil = until
        checkInActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Checking for phone commands")
        onCheckIn?()
        DispatchQueue.main.asyncAfter(deadline: .now() + WakePlan.checkInSeconds + 0.5) { [weak self] in
            MainActor.assumeIsolated { if self?.checkInUntil == until { self?.endCheckIn() } }
        }
    }

    /// Nothing asked for the Mac during the check-in: sleep again (the next wake is asked for on the way down).
    func endCheckIn() {
        checkInUntil = nil
        if let a = checkInActivity { ProcessInfo.processInfo.endActivity(a); checkInActivity = nil }
        guard !holding else { return }   // a phone command or an agent took over; the hold owns sleep now
        if !SleepSwitch.release() { pendingRelease = true }
        // Ask for the next check-in before going down: after a dark wake the will-sleep notification
        // doesn't always arrive, and without this check-ins would stop after the first one.
        scheduleWake()
        if Registry.lidClosed { Shell.pmsetRoot(["sleepnow"]) }
    }

    /// "Wake at 7:00": the next time that clock time comes round, staying awake for `minutes` (nil = off).
    func setWake(at date: Date?, forMinutes minutes: Int? = nil) {
        update { c in
            c.wakeAt = date.map { $0.timeIntervalSince1970 }
            if let m = minutes { c.wakeForMinutes = min(24 * 60, max(5, m)) }
        }
    }

    func setCheckIn(minutes: Int) {
        guard WakePlan.checkInChoices.contains(minutes) else { return }
        update { $0.checkInMinutes = minutes }
    }

    /// Everything the phone panel shows, in one reply. Same shape as the Windows/Linux app.
    func panelJSON() -> [String: Any] {
        let o = lidOutcome
        var d: [String: Any] = [
            "ok": true, "keeps": o.keeps, "holding": holding, "headline": o.headline, "detail": o.detail,
            "lidClosed": lidClosed, "mode": config.mode.rawValue, "preset": config.preset.rawValue, "snoozed": snoozed,
            "holds": holds.map(\.reason),
            "agents": sessions.filter { !$0.kind.isRequest }.map { s in
                var a: [String: Any] = ["id": s.kind.id, "name": s.kind.name, "working": isWorking(s), "keeps": !config.trackOnly.contains(s.kind.id), "instances": s.instances]
                if let st = s.state { a["state"] = st.rawValue }
                if let left = sleepsIn(s) { a["sleepsIn"] = Int((left / 60).rounded(.up)) }
                return a
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
        if let a = powerTestAborted, !powerTestRunning { d["powerTestAborted"] = a }
        d.merge(phoneFigures) { a, _ in a }
        if let u = onUntil { d["alwaysUntil"] = u.formatted(date: .omitted, time: .shortened) }
        d["checkIn"] = config.checkInMinutes
        if AutoApprove.isOn { d["autoApprove"] = true }
        if let w = config.wakeAt { d["wakeAt"] = Date(timeIntervalSince1970: w).formatted(date: .omitted, time: .shortened) }
        d["wakeFor"] = config.wakeForMinutes
        // The phone shows the Mac's Apps tab too: holds it can end, and busy apps with their lid-shut rule.
        d["holdList"] = holds.map { h -> [String: Any] in
            var x: [String: Any] = ["id": h.id, "reason": String(h.reason.prefix(60))]
            if let u = h.until { x["until"] = u.formatted(date: .omitted, time: .shortened) }
            return x
        }
        d["apps"] = userApps.filter { $0.watts >= 0.05 && !isProtected($0) }.prefix(8).compactMap { a -> [String: Any]? in
            guard let bid = a.bundleID else { return nil }
            return ["id": bid, "name": a.name, "w": (a.watts * 10).rounded() / 10, "rule": rule(for: bid).rawValue,
                    "custom": config.appRules[bid] != nil]
        }
        d["sessions"] = stats.sessions.suffix(5).reversed().map { s -> [String: Any] in
            ["when": Date.RelativeFormatStyle(presentation: .named, capitalizationContext: .beginningOfSentence).format(s.date)
                + (s.agent.map { " · \($0)" } ?? ""), "line": SettingsView.sessionLine(s)]
        }
        if !wakeReady { d["wakeNeedsSetup"] = true }
        if let b = battery {
            // The phone's three numbers, as numbers: it formats and animates them itself.
            var n: [String: Any] = ["pct": b.percent, "plugged": !onBattery, "charging": b.charging]
            if let w = systemWatts { n["w"] = (w * 10).rounded() / 10 }
            if let h = closedHours, h > 0 { n["h"] = (h * 12).rounded() / 12 }
            d["numbers"] = n
            if !onBattery { d["battery"] = "\(b.percent)% · plugged in" + (closedHours.map { " (≈\(PanelFormat.hm($0)) on battery, lid closed)" } ?? "") }
            else { d["battery"] = "\(b.percent)%" + (closedHours.map { " · ≈\(PanelFormat.hm($0)) left with the lid closed" } ?? "") }
        }
        return d
    }
}
