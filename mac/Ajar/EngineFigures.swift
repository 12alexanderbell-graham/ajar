import Foundation

/// The concrete numbers the panel shows. Everything here is derived from live readings; nothing is stored.
extension Engine {
    /// Battery is actually draining (on battery, or on a charger too weak to keep up).
    var onBattery: Bool { battery.map { $0.discharging || !$0.onAC } ?? false }

    /// What the Mac draws with the lid open: live while open on battery, otherwise the last learned value.
    var openWatts: Double? { lidClosed ? openDraw : (drawNow ?? openDraw) }

    /// Hours of battery left, down to the battery limit.
    var closedHours: Double? { hoursLeft(at: closedEstimate) }
    var openHours: Double? { openWatts.flatMap { hoursLeft(at: $0) } }

    /// Battery percent used per hour at a given draw.
    func percentPerHour(_ watts: Double) -> Double { watts / max(fullWh, 1) * 100 }

    /// What closing the lid does under the current rules.
    struct ClosedPlan {
        var slowed = 0
        var paused = 0
        var lowPower: Bool
        var watts: Double
    }

    var closedPlan: ClosedPlan {
        var p = ClosedPlan(lowPower: config.lowPowerWhileClosed && config.preset != .speed, watts: closedEstimate)
        for a in userApps where !isProtected(a) {
            switch rule(for: a.bundleID) {
            case .slow: p.slowed += 1
            case .pause: p.paused += 1
            case .leave: break
            }
        }
        return p
    }

    /// An app's expected draw with the lid closed under its rule (slowed ≈ ¼, measured; paused = 0).
    func closedWatts(for a: AppUsage) -> Double {
        if isProtected(a) { return a.watts }
        switch rule(for: a.bundleID) { case .leave: return a.watts; case .slow: return a.watts * 0.25; case .pause: return 0 }
    }

    /// Seconds until Ajar lets the Mac sleep if this agent stays idle, or nil when that doesn't apply.
    func sleepsIn(_ s: AgentSession) -> TimeInterval? {
        guard config.mode == .auto, config.sleepWhenDone, !isWorking(s), s.lastActive != .distantPast,
              !config.trackOnly.contains(s.kind.id) else { return nil }
        let left = TimeInterval(config.quietMinutes * 60) - Date().timeIntervalSince(s.lastActive)
        return left > 0 ? left : nil
    }

    /// "Always" with a timer: time remaining.
    var alwaysLeft: TimeInterval? {
        guard config.mode == .on, let u = onUntil else { return nil }
        return max(0, u.timeIntervalSinceNow)
    }

    /// The question people actually have: what happens if I close the lid right now?
    var lidOutcome: (keeps: Bool, headline: String, detail: String) {
        // Desktop Macs (mini, Studio, iMac, Pro) have no lid: same logic, worded for idle sleep instead.
        let keeps = Registry.hasLid ? "Close the lid: keeps working" : "Stays awake"
        let sleeps = Registry.hasLid ? "Close the lid: it sleeps" : "Sleeps normally"
        guard setupReady else { return (false, sleeps, "Ajar needs its one-time setup") }
        if let b = blockedReason { return (false, sleeps, b) }
        if holding {
            var parts: [String] = [holdReason ?? "Staying awake"]
            if onBattery, let h = closedHours { parts.append("≈\(PanelFormat.hm(h)) on battery") }
            if Registry.hasLid { parts.append(config.lockOnClose ? "locks" : "no lock screen") }
            return (true, keeps, parts.joined(separator: " · "))
        }
        switch config.mode {
        case .off: return (false, sleeps, "Ajar is off")
        case .auto: return (false, sleeps, "Nothing is working right now. Starts on its own when an agent does")
        case .on: return (false, sleeps, "Starting…")
        }
    }

    /// The last lid-closed session, for half an hour after the lid opened.
    var recentReceipt: Receipt? {
        guard let r = receipt, let opened = r.openedAt, Date().timeIntervalSince(opened) < 1800 else { return nil }
        return r
    }

    /// Last 7 days, for the panel.
    struct WeekSummary {
        var sessions: Int
        var closedHours: Double
        var whSaved: Double
        var percentSaved: Double
    }

    var weekSummary: WeekSummary? {
        let w = stats.week()
        guard w.count > 0 else { return nil }
        let wh = w.wh + w.whAvoided
        return WeekSummary(sessions: w.count, closedHours: w.closedMinutes / 60, whSaved: wh, percentSaved: percent(ofWh: wh))
    }
}
