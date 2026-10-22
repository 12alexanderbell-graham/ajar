import AppKit
import Foundation

/// "Until 7:00": the next time the clock shows that hour (tomorrow if it's already passed today).
enum PanelFormatTime {
    static func next(hour: Int) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: max(0, min(23, hour)), minute: 0, second: 0, of: Date()) ?? Date()
        return today > Date().addingTimeInterval(60) ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }
}

/// The single command surface behind the `nocturnal` CLI, the MCP server and the app's own controls.
/// Requests arrive as distributed notifications; replies are written to a file the caller is waiting on.
enum Wire {
    static let requestName = Notification.Name("com.alexander.Nocturnal.request")
    static var replyDir: URL {
        let u = StateFiles.dir.appendingPathComponent("replies")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// No whitespace: for the phone relay, where every byte counts against ntfy's 4096-byte message limit.
    static func compact(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj), let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

@MainActor
final class CommandCenter {
    let engine: Engine
    let ui: StatusController

    init(engine: Engine, ui: StatusController) {
        self.engine = engine
        self.ui = ui
        DistributedNotificationCenter.default().addObserver(forName: Wire.requestName, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?["json"] as? String else { return }
            MainActor.assumeIsolated { self?.receive(raw) }
        }
    }

    private func receive(_ raw: String) {
        // Any local process can post this notification, so the reply id must be a plain name (no paths).
        guard let req = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let id = req["id"] as? String, let cmd = req["cmd"] as? String,
              !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
        let args = req["args"] as? [String: Any] ?? [:]
        handle(cmd, args) { result in
            let url = Wire.replyDir.appendingPathComponent(id + ".json")
            try? Wire.json(result).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Commands

    func handle(_ cmd: String, _ a: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        func ok(_ extra: [String: Any] = [:]) { var r = extra; r["ok"] = true; r["status"] = engine.statusLine; reply(r) }
        func fail(_ msg: String) { reply(["ok": false, "error": msg]) }
        /// Finite, non-negative numbers only, capped so nothing downstream can overflow (NaN, inf, 1e400, -5).
        func num(_ k: String, max cap: Double = 1_000_000) -> Double? {
            guard let v = (a[k] as? NSNumber)?.doubleValue ?? (a[k] as? String).flatMap(Double.init), v.isFinite, v >= 0 else { return nil }
            return min(v, cap)
        }
        func str(_ k: String) -> String? { a[k] as? String }
        func bool(_ k: String) -> Bool? {
            if let b = a[k] as? Bool { return b }
            if let s = (a[k] as? String)?.lowercased() { return ["on", "true", "yes", "1"].contains(s) ? true : (["off", "false", "no", "0"].contains(s) ? false : nil) }
            return (a[k] as? NSNumber)?.boolValue
        }

        switch cmd {
        case "status":
            engine.refreshFast()
            engine.sampleEnergyNow { [weak self] in guard let self else { return }; reply(self.statusDict()) }

        case "energy":
            engine.sampleEnergyNow { [weak self] in guard let self else { return }; reply(["ok": true, "apps": self.energyList(limit: 15)]) }

        case "mode":
            guard let m = str("mode").flatMap(Self.parseMode) else { return fail("mode must be off, when_busy (auto) or always") }
            if m == .on {
                // "until_hour": the next time this Mac's clock reads that hour (the phone may be elsewhere).
                if let h = num("until_hour", max: 23) { engine.stayAwake(until: PanelFormatTime.next(hour: Int(h))) }
                else { engine.stayAwake(for: num("minutes", max: 7 * 24 * 60).map { max(1, Int($0)) }) }
            } else { engine.mode = m }
            ok()

        case "panel":
            reply(engine.panelJSON())

        case "track":
            guard let id = str("agent"), engine.sessions.contains(where: { $0.kind.id == id }) || engine.config.trackOnly.contains(id) else {
                return fail("no agent \(str("agent") ?? "?") is running")
            }
            // The phone sends the state it wants ("keeps"), so a retried tap can't flip it back; older callers toggle.
            if let keeps = bool("keeps") { engine.setKeepsAwake(id, keeps) } else { engine.toggleTrackOnly(id) }
            ok()

        case "sleep_now":
            engine.sleepNow()
            ok()

        case "release_own":
            // MCP: an agent may only end holds its own session made.
            guard let id = str("id"), let pid = num("pid", max: Double(Int32.max)).map({ Int32($0) }) else { return fail("needs id and pid") }
            let n = engine.releaseHolds(ownedBy: pid, id: id)
            n == 0 ? fail("no hold \(id) made by this session") : ok(["released": n])

        case "release_pid":
            guard let pid = num("pid", max: Double(Int32.max)).map({ Int32($0) }) else { return fail("needs pid") }
            ok(["released": engine.releaseHolds(ownedBy: pid)])

        case "quit":
            reply(["ok": true])
            DispatchQueue.main.async { NSApp.terminate(nil) }

        case "hold":
            guard engine.setupReady else { return fail("Nocturnal needs its one-time setup first. Open Nocturnal from the menu bar and click Continue.") }
            // A hold is an explicit request, so it works in any mode without changing the person's mode.
            let pid = num("pid", max: Double(Int32.max)).map { Int32($0) }.flatMap { p -> Int32? in
                p > 1 && (kill(p, 0) == 0 || errno == EPERM) ? p : nil
            }
            if a["pid"] != nil && pid == nil { return fail("pid must be a running process id") }
            let reason = String((str("reason") ?? "Asked to stay awake").prefix(80))
            let owner = num("owner", max: Double(Int32.max)).map { Int32($0) }
            let h = engine.addHold(reason: reason, minutes: num("minutes", max: 7 * 24 * 60), pid: pid, owner: owner)
            ok(["hold": holdDict(h)])

        case "release":
            // One hold by id, or all of them only when asked in so many words (`nocturnal release` with no id).
            if let id = str("id") { return ok(["released": engine.releaseHold(id)]) }
            guard a["all"] as? Bool == true else { return fail("id: the hold to end (see nocturnal status), or all: true") }
            ok(["released": engine.releaseHold(nil)])

        case "wake":
            // From the phone while the Mac slept (picked up at the next check-in), or any time: stay awake a while.
            guard engine.setupReady else { return fail("Nocturnal needs its one-time setup first. Open Nocturnal from the menu bar and click Continue.") }
            // One that waited at the relay and arrives with the lid open is stale: someone opened the Mac in the
            // meantime, and a surprise hour awake after they close it again would be wrong.
            if !engine.lidClosed, let age = (a["_age"] as? NSNumber)?.doubleValue, age > 300 { return ok(["skipped": "already awake"]) }
            let minutes = num("minutes", max: 24 * 60).map { max(5, $0) } ?? 60
            let h = engine.addHold(reason: String((str("reason") ?? "Woken from your phone").prefix(80)), minutes: minutes, pid: nil)
            ok(["hold": holdDict(h)])

        case "wake_at":
            // "07:00" (the next time the clock shows it), "off", or Unix seconds; optional minutes to stay awake.
            guard let t = str("time") ?? (a["time"] as? NSNumber).map({ $0.stringValue }) else { return fail("time: HH:MM, off, or Unix seconds") }
            if ["off", "none", "cancel"].contains(t.lowercased()) { engine.setWake(at: nil); return ok(["wakeAt": NSNull()]) }
            guard engine.wakeReady else { return fail("Scheduled wakes need Set Up to run again (Settings › General › Set Up), once, after this update.") }
            guard let date = Self.parseWakeTime(t) else { return fail("time: HH:MM (24-hour), off, or Unix seconds") }
            engine.setWake(at: date, forMinutes: num("minutes", max: 24 * 60).map { Int($0) })
            ok(["wakeAt": date.formatted(date: .abbreviated, time: .shortened)])

        case "preset":
            guard let p = str("preset").flatMap(Self.parsePreset) else { return fail("preset must be max_battery, balanced or full_speed") }
            engine.preset = p
            ok()

        case "rule":
            guard let app = str("app"), let found = Self.resolveApp(app) else { return fail("Couldn't find an app called \(str("app") ?? "?")") }
            guard let bid = found.bundleID else { return fail("\(found.name) has no bundle id") }
            let raw = (str("rule") ?? "").lowercased()
            if raw == "default" || raw == "reset" {
                engine.update { $0.appRules.removeValue(forKey: bid) }
                return ok(["app": found.name, "rule": engine.rule(for: bid).rawValue + " (preset default)"])
            }
            guard let r = AppRule(rawValue: raw) else { return fail("rule must be leave, slow, pause or default") }
            engine.setRule(r, for: bid)
            ok(["app": found.name, "rule": r.rawValue])

        case "watch":
            // Add or remove anything that should keep the Mac awake while it's busy: an app by name, bundle id
            // or path ("Google Chrome", "com.google.Chrome") or a command-line tool by executable name ("ffmpeg").
            guard let query = str("app")?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return fail("needs app") }
            let remove = bool("remove") == true
            if remove, let existing = engine.watchedApps.first(where: {
                $0.name.lowercased() == query.lowercased() || $0.id == query || ($0.id as NSString).lastPathComponent.lowercased() == query.lowercased() + ".app"
            }) {
                engine.removeWatched(existing)
                return ok(["removed": existing.name, "watch_list": engine.watchedApps.map(\.name)])
            }
            let w: WatchedApp
            if let found = Self.resolveApp(query) { w = WatchedApp(id: found.path, name: found.name) }
            else if !query.contains("/") && query.count <= 64 { w = WatchedApp(id: query, name: query) }   // executable name
            else { return fail("Couldn't find \(query)") }
            if remove {
                guard engine.watchedApps.contains(w) else { return fail("\(w.name) isn't on the list") }
                engine.removeWatched(w)
            } else { engine.addWatched(w) }
            ok([remove ? "removed" : "added": w.name, "watch_list": engine.watchedApps.map(\.name)])

        case "agent":
            guard let name = str("name"), let exe = str("executable") else { return fail("needs name and executable") }
            engine.update { c in
                c.customAgents.removeAll { $0.name == name }
                if bool("remove") != true { c.customAgents.append(CustomAgent(name: name, executables: [exe], idleWatts: num("idle_watts"))) }
            }
            ok()

        case "set":
            guard let key = str("key") else { return fail("needs key") }
            guard let spec = SettingsSchema.spec(key) else {
                return fail("unknown setting \(key). Keys: \(SettingsSchema.all.map(\.key).joined(separator: ", ")) (nocturnal settings explains each)")
            }
            guard let v = a["value"] else { return fail("\(spec.key) needs a value") }
            var bad: String?
            engine.update { c in bad = spec.set(&c, v) }
            if let bad { return fail("\(spec.key) needs \(bad)") }
            ok(["key": spec.key, "value": spec.get(engine.config)])

        case "power":
            engine.sampleEnergyNow { [weak self] in guard let self else { return }; reply(self.engine.powerReport()) }

        case "power_test":
            let detailed = bool("detailed") ?? false
            if let problem = engine.startPowerTest(includeScreen: bool("screen") ?? false, detailed: detailed) { return fail(problem) }
            ok(["started": true, "about_seconds": detailed ? 720 : 210,
                "next": "Call power again (nocturnal power) for results once power_test shows done."])

        case "schema":
            var d = SettingsSchema.describe(engine.config)
            d["ok"] = true
            reply(d)

        case "config":
            ok(["path": Config.url.path, "config": (try? JSONSerialization.jsonObject(with: engine.config.encoded())) ?? [:]])

        case "open":
            if str("where") == "window" { ui.showMainWindow() } else { ui.showPopover() }
            ok()

        case "settings":
            ui.showSettings()
            ok()

        case "snapshot":
            // Only ever writes a .png inside Nocturnal's own folder: any local process can send this command, so it must
            // never be able to overwrite the person's files. A given path keeps just its file name.
            let name = str("path").map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "snapshot.png"
            guard name.lowercased().hasSuffix(".png"), !name.hasPrefix(".") else { return fail("snapshot name must end in .png") }
            let path = StateFiles.dir.appendingPathComponent(name).path
            let window = str("where") == "window"
            let settings = str("where") == "settings"
            // Give SwiftUI a beat to lay out and load data before capturing.
            if settings { ui.showSettings() } else if window { ui.showMainWindow() } else { ui.showPopover() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                let done = self.ui.snapshot(to: URL(fileURLWithPath: path), window: window, settings: settings)
                done ? ok(["path": path]) : fail("snapshot failed")
            }

        case "override_floor":
            // Running below the person's battery limit is their call, made in Nocturnal's own UI. Commands can only
            // turn the override back off.
            if bool("on") ?? true { return fail("Going below the battery limit can only be allowed in Nocturnal itself") }
            engine.overrideFloor(false)
            ok(["below_floor_allowed": engine.floorOverride])

        case "measure":
            guard !(engine.lidClosed && engine.holding) else { return fail("Open the lid to measure") }
            engine.measureSavings()
            func poll() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if self.engine.measuring { return poll() }
                    guard let t = self.engine.lastTest else { return fail("measurement failed") }
                    ok(["before_watts": (t.before * 100).rounded() / 100, "after_watts": (t.after * 100).rounded() / 100,
                        "apps": t.apps.map { ["name": $0.name, "before_watts": ($0.before * 100).rounded() / 100, "after_watts": ($0.after * 100).rounded() / 100] }])
                }
            }
            poll()

        case "island":
            // Any local program can send this, so keep it to one short line each.
            let line = { (s: String?, n: Int) in s.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(n)) } }
            ui.island.show(title: line(str("title"), 40) ?? "Nocturnal", subtitle: line(str("subtitle"), 80) ?? engine.statusLine, glyph: engine.holding)
            ok()

        default:
            fail("Unknown command \(cmd)")
        }
    }

    // MARK: Payloads

    private func statusDict() -> [String: Any] {
        var d: [String: Any] = [
            "ok": true,
            "status": engine.statusLine,
            "mode": engine.mode.rawValue,
            "keeping_awake": engine.holding,
            "lid_closed": engine.lidClosed,
            "setup_done": engine.setupReady,
            "preset": engine.preset.rawValue,
            "closed_estimate_watts": (engine.closedEstimate * 10).rounded() / 10,
            "system_watts": engine.systemWatts.map { ($0 * 10).rounded() / 10 } as Any? ?? NSNull(),
            "power_measured": PowerSensor.isMeasured,
            "config_path": Config.url.path,
            "holds": engine.holds.map(holdDict),
            "watch_list": engine.watchedApps.map(\.name),
            "app_rules": engine.appRules.mapValues(\.rawValue),
            "watching": engine.sessions.map { s in
                [
                    "running_command": s.toolRunning,
                    "instances": s.instances,
                    "name": s.kind.name,
                    "kind": s.kind.isRequest ? "sleep_request" : (s.kind.isAI ? "agent" : "app"),
                    "working": engine.isWorking(s),
                    "idle_minutes": s.lastActive == .distantPast ? -1 : Int(Date().timeIntervalSince(s.lastActive) / 60),
                    "project": s.project ?? "",
                ] as [String: Any]
            },
            "apps_using_energy": energyList(limit: 8),
            "ignored_sleep_blockers": engine.blockers.map { ["process": $0.process, "since": ISO8601DateFormatter().string(from: $0.since)] },
        ]
        if let b = engine.battery {
            d["battery"] = ["percent": b.percent, "watts": (b.watts * 10).rounded() / 10, "on_power": b.onAC, "charging": b.charging]
        }
        if let h = engine.hoursLeft(at: engine.closedEstimate), engine.battery?.onAC == false { d["hours_left_closed"] = (h * 10).rounded() / 10 }
        let w = engine.stats.week()
        d["estimated_savings_this_week"] = [
            "full_charges_equivalent": (engine.percent(ofWh: w.wh + w.whAvoided) / 100 * 100).rounded() / 100,
            (PowerSensor.isMeasured ? "vs_lid_open_wh" : "by_slowing_apps_wh"): (w.wh * 100).rounded() / 100,
            "by_sleeping_when_done_wh": (w.whAvoided * 100).rounded() / 100,
            "slept_minutes": Int(w.sleptMinutes),
            "sessions": w.count,
        ]
        if engine.lidClosed && engine.holding { d["saving_now_watts"] = (engine.liveSavingW * 100).rounded() / 100 }
        if let r = engine.blockedReason { d["blocked_by"] = r }
        if let w = engine.warning { d["warning"] = w }
        if !engine.unrestored.isEmpty { d["not_put_back_yet"] = engine.unrestored }
        if let r = engine.holdReason, engine.holding { d["reason"] = r }
        return d
    }

    private func energyList(limit: Int) -> [[String: Any]] {
        engine.userApps.prefix(limit).map { a in
            [
                "name": a.name,
                "bundle_id": a.bundleID ?? "",
                "watts": (a.watts * 100).rounded() / 100,
                "while_closed": engine.isProtected(a) ? "kept (Nocturnal is keeping it awake)" : engine.rule(for: a.bundleID).rawValue,
            ]
        }
    }

    private func holdDict(_ h: Hold) -> [String: Any] {
        var d: [String: Any] = ["id": h.id, "reason": h.reason]
        if let u = h.until { d["until"] = ISO8601DateFormatter().string(from: u) }
        if let p = h.pid { d["pid"] = p }
        return d
    }

    // MARK: Parsing

    /// "7:00" / "07:00" / "19:30" → the next time the clock shows it; or Unix seconds within the next week.
    static func parseWakeTime(_ t: String) -> Date? {
        let s = t.trimmingCharacters(in: .whitespaces)
        if let secs = Double(s), secs.isFinite {
            let d = Date(timeIntervalSince1970: secs)
            return d > Date().addingTimeInterval(60) && d < Date().addingTimeInterval(7 * 86400) ? d : nil
        }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else { return nil }
        return today > Date().addingTimeInterval(60) ? today : cal.date(byAdding: .day, value: 1, to: today)
    }

    static func parseMode(_ s: String) -> Mode? {
        switch s.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "off": .off; case "auto", "when_busy", "busy": .auto; case "on", "always", "always_on": .on; default: nil
        }
    }

    static func parsePreset(_ s: String) -> Preset? {
        switch s.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "longest", "battery", "longest_battery", "max_battery", "max": .longest
        case "balanced": .balanced
        case "speed", "full", "full_speed": .speed
        default: nil
        }
    }

    /// Finds an app by bundle id, display name (running or installed) or path.
    static func resolveApp(_ query: String) -> (name: String, bundleID: String?, path: String)? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasSuffix(".app"), FileManager.default.fileExists(atPath: q) {
            return (FileManager.default.displayName(atPath: q).replacingOccurrences(of: ".app", with: ""), Bundle(path: q)?.bundleIdentifier, q)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) {
            return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), q, url.path)
        }
        let lower = q.lowercased()
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.lowercased() == lower }), let url = app.bundleURL {
            return (app.localizedName ?? q, app.bundleIdentifier, url.path)
        }
        for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            let path = "\(dir)/\(q).app"
            if FileManager.default.fileExists(atPath: path) { return (q, Bundle(path: path)?.bundleIdentifier, path) }
        }
        // Partial names only when exactly one running app matches, so "Code" can never hit Xcode by accident.
        let partial = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.localizedName?.lowercased().contains(lower) == true }
        if partial.count == 1, let app = partial.first, let url = app.bundleURL {
            return (app.localizedName ?? q, app.bundleIdentifier, url.path)
        }
        return nil
    }
}
