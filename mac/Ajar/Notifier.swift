import AppKit
import UserNotifications

/// "Claude Code went idle" alerts: a Mac notification, an optional chime, and an optional phone push through
/// ntfy (free app, no account: the person subscribes to a topic name and Nocturnal posts to it).
/// Asks for notification permission the first time one is due, not at launch.
@MainActor
final class Notifier {
    private let engine: Engine

    /// System sounds people can pick for the chime.
    static let sounds = ["Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Funk", "Bottle", "Tink", "Blow"]

    init(engine: Engine) {
        self.engine = engine
        engine.onFinished = { [weak self] name, minutes, gone, state in self?.finished(name, minutes: minutes, gone: gone, state: state) }
        engine.onNeedsYou = { [weak self] name in self?.needsYou(name) }
        engine.onNote = { [weak self] title, body in self?.note(title, body) }
        for n in engine.pendingNotes { note(n.0, n.1) }
        engine.pendingNotes.removeAll()
    }

    /// A plain notification (settings-file problems and similar).
    func note(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// Activity stopped. With hooks, Claude Code says it finished its turn; without them Nocturnal only sees activity
    /// stop and can't tell a finished task from a crash or a question, so it says "went idle" (or "closed").
    private func finished(_ name: String, minutes: Double, gone: Bool, state: AgentState?) {
        let c = engine.config
        if c.doneChime { Self.play(c.chimeSound) }

        var body = "Busy for \(Engine.formatMinutes(minutes))"
        if engine.lidClosed { body += " with the lid closed" }
        if let b = engine.battery { body += " · battery \(b.percent)%" }
        if c.mode == .auto && c.sleepWhenDone && engine.lidClosed && engine.holds.isEmpty {
            // This alert comes 2 minutes into the quiet time, so that much of it has already passed.
            body += ". Sleeps in \(max(1, c.quietMinutes - 2)) min if nothing else starts."
        }
        let title = gone ? "\(name) closed" : (state == .finished ? "\(name) finished" : (state == .waiting ? "\(name) is waiting for you" : "\(name) went idle"))

        if !c.ntfyTopic.isEmpty { Self.push(topic: c.ntfyTopic, title: title, body: body) }
        guard c.notifyDone else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil   // the chime setting decides about sound
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            // Asking again is free once answered, and picks up permission granted later in System Settings.
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// An agent asked the person something (a permission prompt) while the lid is shut.
    private func needsYou(_ name: String) {
        let c = engine.config
        let title = "\(name) is waiting for you"
        let body = "It asked for your approval. It stays awake for up to \(Int(AgentEvents.waitLimit / 60)) min."
        if !c.ntfyTopic.isEmpty { Self.push(topic: c.ntfyTopic, title: title, body: body) }
        guard c.notifyDone else { return }
        note(title, body)
    }

    static func play(_ name: String) {
        (NSSound(named: NSSound.Name(name)) ?? NSSound(named: "Glass"))?.play()
    }

    /// Topic names are public on ntfy.sh, so Settings suggests a random one. Only letters, digits, - and _.
    static func validTopic(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 64 && t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func push(topic: String, title: String, body: String, completion: ((Bool) -> Void)? = nil) {
        guard validTopic(topic), let url = URL(string: "https://ntfy.sh/" + topic) else { completion?(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("laptop", forHTTPHeaderField: "Tags")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }
}
