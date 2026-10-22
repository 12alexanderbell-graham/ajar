import Foundation

/// What Nocturnal has actually saved, kept in stats.json next to the config.
///
/// Two kinds of saving, counted separately and never mixed with guesses:
///  • measured: what Nocturnal's savings were worth while the lid was closed, integrated over time: the power
///    test's whole-Mac figure when there is one, otherwise each slowed or paused app's power from macOS's energy
///    counters, before (running normally) and while slowed.
///  • slept: after the work finished Nocturnal put the Mac to sleep instead of letting it idle with the lid
///    shut. Valued at the power the Mac was drawing just before it slept.
struct SavingsStats: Codable, Equatable {
    struct Session: Codable, Equatable {
        var date: Date
        var closedMinutes: Double
        var whSaved: Double
        var sleptMinutes: Double
        var whAvoided: Double
        var startPercent: Int?
        var endPercent: Int?
        var agent: String?
    }

    var sessions: [Session] = []

    static var url: URL { StateFiles.dir.appendingPathComponent("stats.json") }

    static func load() -> SavingsStats {
        guard let d = try? Data(contentsOf: url) else { return SavingsStats() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(SavingsStats.self, from: d)) ?? SavingsStats()
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }

    mutating func add(_ s: Session) {
        sessions.append(s)
        if sessions.count > 400 { sessions.removeFirst(sessions.count - 400) }
        save()
    }

    func week() -> (wh: Double, whAvoided: Double, sleptMinutes: Double, closedMinutes: Double, count: Int) {
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let w = sessions.filter { $0.date > cutoff }
        return (w.reduce(0) { $0 + $1.whSaved }, w.reduce(0) { $0 + $1.whAvoided },
                w.reduce(0) { $0 + $1.sleptMinutes }, w.reduce(0) { $0 + $1.closedMinutes }, w.count)
    }
}

/// Result of "Measure": the same rules applied for a few seconds with the lid open.
struct SavingsTest: Equatable {
    var before: Double
    var after: Double
    var apps: [(name: String, before: Double, after: Double)]
    var date = Date()

    static func == (a: SavingsTest, b: SavingsTest) -> Bool { a.date == b.date }
}
