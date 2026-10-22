import Foundation

/// What the computer reports: the same status its menu shows. Every field is optional on the wire, so older
/// versions of Nocturnal (which send fewer fields) still decode.
nonisolated struct Panel: Codable, Equatable, Sendable {
    var host = "Your computer"
    var keeps = false
    var holding = false
    var lidClosed = false
    var mode = "auto"
    var preset = "balanced"
    var detail = ""
    var warnings: [String] = []
    var agents: [Agent] = []
    var watch: [WatchedApp] = []
    var numbers: Numbers?
    var batteryLine: String?
    var battery: String?
    var watts: Double?
    var checkIn: Int?
    var alwaysUntil: String?
    var autoApprove = false
    var canMeasure = false
    var powerTest: String?
    var powerTestAborted: String?
    var savings: [String: Double] = [:]
    var savingsUnclear: [String] = []
    /// "Uses ≈2.1 W closed · 9 W open": what the lid-shut savings are worth right now.
    var drawLine: String?
    /// "6 h 20 min working, lid closed" and "4 sessions · ≈38 Wh saved": the week so far.
    var weekTitle: String?
    var weekLine: String?
    /// The daily wake ("7:00"), and whether the computer still needs its one-time setup for wakes.
    var wakeAt: String?
    var wakeNeedsSetup = false
    /// How long a daily wake keeps it awake, in minutes.
    var wakeFor: Int?
    /// The Mac's Apps tab: what holds it awake (each can be ended), busy apps with their lid-shut rule, and the last
    /// few lid-shut sessions.
    var holdList: [HoldItem] = []
    var apps: [AppItem] = []
    var sessions: [SessionItem] = []

    struct HoldItem: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var reason: String
        var until: String?
    }

    struct AppItem: Codable, Equatable, Sendable, Identifiable {
        var id: String          // bundle id
        var name: String
        var w: Double
        var rule: String        // leave, slow, pause (what applies now)
        var custom = false      // set for this app, not the preset's default

        init(id: String, name: String, w: Double, rule: String, custom: Bool = false) {
            (self.id, self.name, self.w, self.rule, self.custom) = (id, name, w, rule, custom)
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0
            rule = try c.decodeIfPresent(String.self, forKey: .rule) ?? "leave"
            custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        }
    }

    struct SessionItem: Codable, Equatable, Sendable, Identifiable {
        var when: String
        var line: String
        var id: String { when + line }
    }

    struct Agent: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var working = false
        var keeps = true
        var instances = 1
        var state: String?
        /// Minutes until it lets the computer sleep, once it has gone quiet.
        var sleepsIn: Int?

        /// "working", "waiting", "finished" or "idle"; older computers only say whether it's working.
        var status: String { state ?? (working ? "working" : "idle") }

        init(id: String, name: String, working: Bool = false, keeps: Bool = true, instances: Int = 1, state: String? = nil) {
            (self.id, self.name, self.working, self.keeps, self.instances, self.state) = (id, name, working, keeps, instances, state)
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? false
            keeps = try c.decodeIfPresent(Bool.self, forKey: .keeps) ?? true
            instances = try c.decodeIfPresent(Int.self, forKey: .instances) ?? 1
            state = try c.decodeIfPresent(String.self, forKey: .state)
            sleepsIn = try c.decodeIfPresent(Int.self, forKey: .sleepsIn)
        }
    }

    struct WatchedApp: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var on: Bool
    }

    /// The status card's three numbers. `w` is missing on the charger on Windows and Linux; `h` when there's no estimate.
    struct Numbers: Codable, Equatable, Sendable {
        var pct: Int
        var w: Double?
        var h: Double?
        var plugged = false
        var charging = false

        init(pct: Int, w: Double? = nil, h: Double? = nil, plugged: Bool = false, charging: Bool = false) {
            (self.pct, self.w, self.h, self.plugged, self.charging) = (pct, w, h, plugged, charging)
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            pct = try c.decode(Int.self, forKey: .pct)
            w = try c.decodeIfPresent(Double.self, forKey: .w)
            h = try c.decodeIfPresent(Double.self, forKey: .h)
            plugged = try c.decodeIfPresent(Bool.self, forKey: .plugged) ?? false
            charging = try c.decodeIfPresent(Bool.self, forKey: .charging) ?? false
        }
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // A field of the wrong type falls back too, so one odd value can't hide the whole status.
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { o(k) ?? fallback }
        func o<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        host = v(.host, "Your computer")
        keeps = v(.keeps, false)
        holding = v(.holding, false)
        lidClosed = v(.lidClosed, false)
        mode = v(.mode, "auto")
        preset = v(.preset, "balanced")
        detail = v(.detail, "")
        warnings = v(.warnings, [])
        agents = v(.agents, [])
        watch = v(.watch, [])
        numbers = o(.numbers)
        batteryLine = o(.batteryLine)
        battery = o(.battery)
        watts = o(.watts)
        checkIn = o(.checkIn)
        alwaysUntil = o(.alwaysUntil)
        autoApprove = v(.autoApprove, false)
        canMeasure = v(.canMeasure, false)
        powerTest = o(.powerTest)
        powerTestAborted = o(.powerTestAborted)
        savings = v(.savings, [:])
        savingsUnclear = v(.savingsUnclear, [])
        drawLine = o(.drawLine)
        weekTitle = o(.weekTitle)
        weekLine = o(.weekLine)
        wakeAt = o(.wakeAt)
        wakeNeedsSetup = v(.wakeNeedsSetup, false)
        wakeFor = o(.wakeFor)
        holdList = v(.holdList, [])
        apps = v(.apps, [])
        sessions = v(.sessions, [])
    }

    /// The numbers: sent as numbers by current versions, read from the sentence older ones sent.
    var figures: Numbers? {
        if let numbers { return numbers }
        let line = batteryLine ?? battery ?? ""
        guard let pct = line.firstMatch(of: /(\d{1,3})\s*%/).flatMap({ Int($0.1) }) else { return nil }
        var hours: Double?
        if let m = line.firstMatch(of: /(\d+)\s*h(?:\s*(\d+)\s*min)?/) {
            hours = Double(m.1)! + (m.2.flatMap { Double($0) } ?? 0) / 60
        } else if let m = line.firstMatch(of: /(\d+)\s*min/) {
            hours = Double(m.1)! / 60
        }
        return Numbers(pct: pct, w: watts, h: hours, plugged: line.contains("plugged") || line.contains("charg"))
    }

    /// One line about the agents, most urgent first; otherwise the computer's own reason.
    var agentLine: String {
        func names(_ list: [Agent]) -> String { list.count == 1 ? list[0].name : "\(list.count) agents" }
        func verb(_ list: [Agent]) -> String { list.count == 1 ? "is" : "are" }
        let waiting = agents.filter { $0.status == "waiting" }
        let working = agents.filter { $0.status == "working" }
        let finished = agents.filter { $0.status == "finished" }
        if !waiting.isEmpty { return "\(names(waiting)) \(verb(waiting)) waiting for you" }
        if !working.isEmpty { return "\(names(working)) \(verb(working)) working" }
        if !finished.isEmpty { return "\(names(finished)) finished" }
        return detail
    }
}

/// One setting as the computer describes it: its key, kind and current value. The words for it live in the app.
nonisolated struct Setting: Equatable, Sendable, Identifiable {
    enum Value: Equatable, Sendable { case bool(Bool), int(Int), text(String) }
    var key: String
    var type: String
    var value: Value
    var allowed: [String]
    var id: String { key }

    init?(_ d: [String: Any]) {
        guard let key = d["key"] as? String, let type = d["type"] as? String else { return nil }
        self.key = key
        self.type = type
        allowed = d["allowed"] as? [String] ?? []
        switch d["value"] {
        case let b as Bool where type == "bool": value = .bool(b)
        case let n as NSNumber where type == "int": value = .int(n.intValue)
        case let s as String: value = .text(s)
        case let n as NSNumber: value = .text(n.stringValue)   // an enum of numbers (check-in minutes) arrives as a number
        default: return nil
        }
    }

    var bool: Bool { if case .bool(let b) = value { b } else { false } }
    var int: Int { if case .int(let n) = value { n } else { 0 } }
    var text: String { if case .text(let s) = value { s } else { "" } }
}
