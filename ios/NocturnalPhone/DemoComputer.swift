import Foundation

/// A pretend computer for the demo: answers commands the way Nocturnal does, without any network. Lets App Review
/// (and anyone without Nocturnal yet) see every screen. It plays a MacBook working with its lid shut.
@MainActor
final class DemoComputer {
    private var panel: Panel = {
        var p = Panel()
        p.host = CommandLine.arguments.contains("-marketing") ? "MacBook Pro" : "Demo MacBook Pro"
        p.keeps = true
        p.holding = true
        p.lidClosed = true
        p.mode = "auto"
        p.detail = "Claude Code is working"
        p.checkIn = 15
        p.numbers = .init(pct: 82, w: 3.1, h: 19.25)
        p.agents = [.init(id: "claude-code", name: "Claude Code", working: true, instances: 2, state: "working"),
                    .init(id: "codex", name: "Codex", state: "waiting")]
        p.watch = [.init(id: "xcode", name: "Xcode", on: false), .init(id: "ffmpeg", name: "ffmpeg", on: true)]
        p.drawLine = "Uses ≈3.1 W shut · 11 W open"
        p.weekTitle = "6 h 20 min working, lid shut"
        p.weekLine = "4 sessions · ≈38 Wh saved"
        p.savings = ["total": 7.9, "low_power": 1.2, "apps": 2.4, "simulators": 3.6, "audio": 0.7]
        p.canMeasure = true
        p.wakeFor = 60
        p.holdList = [.init(id: "h1", reason: "Exporting a video (Final Cut Pro)", until: nil)]
        p.apps = [.init(id: "com.google.Chrome", name: "Google Chrome", w: 2.4, rule: "slow"),
                  .init(id: "com.tinyspeck.slackmacgap", name: "Slack", w: 0.9, rule: "pause", custom: true),
                  .init(id: "com.spotify.client", name: "Spotify", w: 0.6, rule: "leave")]
        p.sessions = [.init(when: "Last night · Claude Code", line: "6 h 10 min closed · used 21%"),
                      .init(when: "Yesterday · Codex", line: "1 h 5 min closed · used 6% · then slept"),
                      .init(when: "Monday · Claude Code", line: "3 h closed · used 11%")]
        return p
    }()

    /// Claude Code is busy; Sleep makes agents wait until the lid opens (as on the Mac).
    private var agentWorking = true
    private var snoozed = false

    private var settings: [String: Any] = [
        "low_power": true, "pause_simulators": true, "shut_down_simulators": false, "pause_background_audio": true,
        "screen_off": false, "lock_on_close": false,
        "sleep_when_done": true, "quiet_minutes": 5, "battery_floor": 10, "only_on_power": false, "heat_guard": true,
        "claude_app": true, "downloads": true, "notify_done": true, "done_chime": false,
        "check_in_minutes": "15", "pause_time_machine": true, "slow_builds": false,
        "menubar": "battery", "appearance": "system", "live_lid_icon": true, "notch_island": true, "show_in_dock": false, "hotkey": true,
    ]
    private static let kinds: [String: String] = ["battery_floor": "int", "quiet_minutes": "int", "check_in_minutes": "enum",
                                                  "menubar": "enum", "appearance": "enum"]
    private static let allowed: [String: [String]] = ["check_in_minutes": ["0", "15", "30", "60"],
                                                      "menubar": ["none", "battery", "watts", "timeLeft", "timer"],
                                                      "appearance": ["system", "light", "dark"]]

    func handle(_ cmd: String, _ args: [String: Any]) -> Relay.Reply {
        switch cmd {
        case "mode":
            let m = args["mode"] as? String ?? "auto"
            panel.mode = m == "always" ? "on" : m
            snoozed = false
            panel.alwaysUntil = (args["minutes"] as? Int).map { Date().addingTimeInterval(Double($0) * 60).formatted(date: .omitted, time: .shortened) }
            updateOutcome()
        case "preset":
            panel.preset = ["max_battery": "longest", "full_speed": "speed"][args["preset"] as? String ?? ""] ?? "balanced"
        case "track":
            if let i = panel.agents.firstIndex(where: { $0.id == args["agent"] as? String }) { panel.agents[i].keeps = args["keeps"] as? Bool ?? true }
        case "watch":
            let id = args["app"] as? String
            if let i = panel.watch.firstIndex(where: { $0.id == id }) {
                panel.watch[i].on = !(args["remove"] as? Bool ?? false)
            } else if let id, let app = panel.apps.first(where: { $0.id == id }) {
                panel.watch.append(.init(id: id, name: app.name, on: true))
            }
        case "sleep_now":
            panel.mode = panel.mode == "on" ? "auto" : panel.mode
            panel.alwaysUntil = nil
            panel.holdList.removeAll()
            snoozed = true
            updateOutcome()
        case "wake":
            let minutes = args["minutes"] as? Int ?? 60
            let until = Date().addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)
            panel.holdList.append(.init(id: "wake", reason: "Woken from your phone", until: until))
            snoozed = false
            updateOutcome()
        case "wake_at":
            let t = args["time"] as? String ?? "off"
            panel.wakeAt = t == "off" ? nil : t
            if let m = args["minutes"] as? Int { panel.wakeFor = m }
        case "release":
            panel.holdList.removeAll { $0.id == args["id"] as? String }
            updateOutcome()
        case "rule":
            if let i = panel.apps.firstIndex(where: { $0.id == args["app"] as? String }) {
                let r = args["rule"] as? String ?? "default"
                panel.apps[i].custom = r != "default"
                panel.apps[i].rule = r == "default" ? (panel.preset == "longest" ? "pause" : panel.preset == "speed" ? "leave" : "slow") : r
            }
        case "power_test":
            panel.canMeasure = false
            panel.powerTest = "Measuring: step 1 of 4"
        case "set":
            guard let key = args["key"] as? String, settings[key] != nil else { return .init(ok: false, error: "Unknown setting") }
            if key == "battery_floor", let n = args["value"] as? Int, n < (settings[key] as? Int ?? 0) {
                return .init(ok: false, error: "The battery limit can only be lowered on the computer")
            }
            if Self.kinds[key] == "enum" { settings[key] = "\(args["value"] ?? "")" }
            else { settings[key] = (args["value"] as? String).map { $0 == "on" } ?? args["value"] }
            if key == "check_in_minutes" { panel.checkIn = Int(settings[key] as? String ?? "0") }
        case "schema":
            let list = settings.keys.sorted().compactMap { k -> Setting? in
                Setting(["key": k, "type": Self.kinds[k] ?? "bool", "value": settings[k] as Any, "allowed": Self.allowed[k] as Any])
            }
            return .init(ok: true, settings: list)
        default: break
        }
        return .init(ok: true, panel: panel)
    }

    /// The Mac's rule: Always keeps it awake, holds keep it awake in any mode, and When busy follows the agents
    /// unless Sleep told them to wait for the lid.
    private func updateOutcome() {
        let agents = panel.mode == "auto" && !snoozed && agentWorking
        let working = panel.mode == "on" || !panel.holdList.isEmpty || agents
        panel.keeps = working
        panel.holding = working
        panel.agents = panel.agents.map { a in
            var a = a
            if a.id == "claude-code" { a.state = agents ? "working" : "idle" }
            a.working = a.state == "working"
            return a
        }
        panel.numbers?.w = working ? 3.1 : 0.4
        panel.detail = panel.mode == "on" ? "Kept awake by you"
            : agents ? "Claude Code is working"
            : panel.holdList.last?.reason
            ?? (panel.mode == "off" ? "Nocturnal is off" : snoozed ? "Sleeping until you open the lid" : "No agent is working right now")
    }
}
