import Foundation

/// Talks to the computer through the relay. Commands are posted to the command topic; replies arrive on one
/// streaming connection to the reply topic (opened while the app is on screen), matched to their request by its id.
/// ntfy.sh allows a burst of about 60 requests per address, refilled one every 5 s, so the app never polls.
@MainActor
final class Relay {
    struct Reply {
        var ok: Bool
        var error: String?
        var panel: Panel?
        var settings: [Setting]?
    }

    enum Failure: Error {
        case relay(String)      // the relay refused or couldn't be reached: says why
        case noAnswer           // the relay took it; the computer didn't answer in time (asleep or offline)
    }

    let pairing: Pairing
    private let session: URLSession
    private var waiters: [String: CheckedContinuation<Reply?, Never>] = [:]
    /// Answers that arrived before their request started waiting (kept briefly, a few at most).
    private var early: [String: Reply] = [:]
    private var listener: Task<Void, Never>?
    private var lastID: String?

    static let replyWait: Duration = .seconds(20)

    init(pairing: Pairing) {
        self.pairing = pairing
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90   // the stream sends a keepalive every 45 s
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: Listening

    /// Opens the reply stream (if it isn't open) and keeps it open, reconnecting after errors. Reopening asks for
    /// everything since the last message seen, so answers that came in meanwhile still reach a waiting request.
    /// Waits longer after each failed attempt (5 s up to 2 min), like the computer, so a bad network can't use up
    /// the relay's allowance.
    func listen() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            var wait = 5.0
            while !Task.isCancelled {
                guard let relay = self else { return }
                let lasted = await relay.readStream()
                if lasted { wait = 5 }
                try? await Task.sleep(for: .seconds(lasted ? 1 : wait))
                if !lasted { wait = min(wait * 2, 120) }
            }
        }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
    }

    /// True if the stream proved itself (a keepalive or a message came through) before it ended.
    private func readStream() async -> Bool {
        let since = lastID ?? "2m"
        guard let url = URL(string: "\(pairing.server)/\(pairing.replyTopic)/json?since=\(since)") else { return false }
        var lasted = false
        do {
            let (bytes, response) = try await session.bytes(from: url)
            // A captive portal or proxy answers 200 with a web page: that's not the relay.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else { return false }
            for try await line in bytes.lines {
                if await handle(line: line) { lasted = true }
            }
        } catch {}
        return lasted
    }

    /// Returns true for a keepalive or a message: signs the stream really works.
    @discardableResult
    private func handle(line: String) async -> Bool {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if ev["event"] as? String == "keepalive" { return true }
        guard ev["event"] as? String == "message" else { return false }
        if let id = ev["id"] as? String { lastID = id }
        guard let text = await messageText(ev),
              let plain = pairing.open(text, topic: pairing.replyTopic),
              let reply = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let re = reply["re"] as? String else { return true }
        if let waiter = waiters.removeValue(forKey: re) {
            waiter.resume(returning: Self.decode(reply))
        } else {
            if early.count > 8 { early.removeAll() }
            early[re] = Self.decode(reply)
        }
        return true
    }

    /// ntfy turns messages over 4 KB into attachments; those are fetched (still sealed) from the same relay only.
    private func messageText(_ ev: [String: Any]) async -> String? {
        if let a = ev["attachment"] as? [String: Any], let s = a["url"] as? String, let url = URL(string: s),
           (a["size"] as? Int ?? .max) < 65536, url.host == URL(string: pairing.server)?.host, url.scheme == "https" {
            return (try? await session.data(from: url)).flatMap { String(data: $0.0, encoding: .utf8) }
        }
        return ev["message"] as? String
    }

    static func decode(_ r: [String: Any]) -> Reply {
        var reply = Reply(ok: r["ok"] as? Bool ?? true, error: r["error"] as? String)
        if let p = r["panel"], let data = try? JSONSerialization.data(withJSONObject: p) {
            reply.panel = try? JSONDecoder().decode(Panel.self, from: data)
        }
        if let s = r["settings"] as? [[String: Any]] { reply.settings = s.compactMap(Setting.init) }
        return reply
    }

    // MARK: Sending

    /// Posts one command and waits up to 20 s for its answer. `onSent` runs once the relay has it.
    func send(_ cmd: String, _ args: [String: Any], device: String, onSent: () -> Void) async throws(Failure) -> Reply {
        listen()
        let id = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let message: [String: Any] = ["t": Int(Date().timeIntervalSince1970), "n": id, "cmd": cmd, "args": args, "dev": device]
        guard let plain = try? JSONSerialization.data(withJSONObject: message),
              let body = pairing.seal(plain, topic: pairing.commandTopic),
              let url = URL(string: "\(pairing.server)/\(pairing.commandTopic)") else { throw .relay("Couldn't seal the message") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("yes", forHTTPHeaderField: "Cache")   // kept at the relay, so a sleeping computer gets it at its next check-in

        let answer = Task { () -> Reply? in
            if let r = early.removeValue(forKey: id) { return r }
            if Task.isCancelled { return nil }   // the request already ended; nothing will answer this
            return await withCheckedContinuation { c in waiters[id] = c }
        }
        defer {
            answer.cancel()
            waiters.removeValue(forKey: id)?.resume(returning: nil)
        }
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure.relay(status == 429 ? "Too many requests. Try again in a minute." : "The relay said \(status)") }
        } catch let f as Failure {
            throw f
        } catch {
            throw .relay("Can't reach the relay")
        }
        onSent()
        let timeout = Task { try? await Task.sleep(for: Self.replyWait); waiters.removeValue(forKey: id)?.resume(returning: nil) }
        defer { timeout.cancel() }
        guard let reply = await answer.value ?? early.removeValue(forKey: id) else { throw .noAnswer }
        return reply
    }
}
