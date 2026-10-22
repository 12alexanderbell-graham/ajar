import Foundation

/// A pretend computer for the demo: answers commands the way Nocturnal does, without any network. Lets App Review
/// (and anyone without Nocturnal yet) see every screen.
@MainActor
final class DemoComputer {
    private var panel: Panel = {
        var p = Panel()
        p.host = "Demo MacBook Pro"
        p.keeps = true
        p.holding = true
        p.mode = "auto"
        p.detail = "Claude Code is working"
        p.checkIn = 15
        p.numbers = .init(pct: 82, w: 3.1, h: 19.25)
        p.agents = [.init(id: "claude-code", name: "Claude Code", working: true, instances: 2, state: "working"),
                    .init(id: "codex", name: "Codex", state: "idle")]
        p.watch = [.init(id: "xcode", name: "Xcode", on: false), .init(id: "ffmpeg", name: "ffmpeg", on: true)]
        return p
    }()

    private var settings: [String: Any] = [
        "screen_off": false, "lock_on_close": false, "low_power": true, "pause_simulators": true, "battery_floor": 10,
        "heat_guard": true, "sleep_when_done": true, "quiet_minutes": 5, "notify_done": true,
    ]
    private static let kinds: [String: String] = ["battery_floor": "int", "quiet_minutes": "int"]

    func handle(_ cmd: String, _ args: [String: Any]) -> Relay.Reply {
        switch cmd {
        case "mode":
            let m = args["mode"] as? String ?? "auto"
            panel.mode = m == "always" ? "on" : m
            panel.alwaysUntil = (args["until_hour"] as? Int).map { "\($0):00" }
            updateOutcome()
        case "preset":
            panel.preset = ["max_battery": "longest", "full_speed": "speed"][args["preset"] as? String ?? ""] ?? "balanced"
        case "track":
            if let i = panel.agents.firstIndex(where: { $0.id == args["agent"] as? String }) { panel.agents[i].keeps = args["keeps"] as? Bool ?? true }
        case "watch":
            if let i = panel.watch.firstIndex(where: { $0.id == args["app"] as? String }) { panel.watch[i].on = !(args["remove"] as? Bool ?? false) }
        case "sleep_now":
            panel.mode = panel.mode == "on" ? "auto" : panel.mode
            panel.holding = false
            updateOutcome()
        case "wake":
            panel.holding = true
            updateOutcome()
        case "set":
            guard let key = args["key"] as? String, settings[key] != nil else { return .init(ok: false, error: "Unknown setting") }
            if key == "battery_floor", let n = args["value"] as? Int, n < (settings[key] as? Int ?? 0) {
                return .init(ok: false, error: "The battery limit can only be lowered on the computer")
            }
            settings[key] = (args["value"] as? String).map { $0 == "on" } ?? args["value"]
        case "schema":
            let list = settings.keys.sorted().compactMap { k -> Setting? in
                Setting(["key": k, "type": Self.kinds[k] ?? "bool", "value": settings[k] as Any])
            }
            return .init(ok: true, settings: list)
        default: break
        }
        return .init(ok: true, panel: panel)
    }

    private func updateOutcome() {
        let working = panel.mode == "on" || (panel.mode == "auto" && panel.holding)
        panel.keeps = working
        panel.agents = panel.agents.map { var a = $0; a.state = working && a.id == "claude-code" ? "working" : "idle"; a.working = a.state == "working"; return a }
        panel.detail = working ? "Claude Code is working" : panel.mode == "off" ? "Nocturnal is off" : "No agent is working right now"
    }
}
