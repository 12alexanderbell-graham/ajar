import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI

/// Phone control from anywhere, with ntfy.sh as a relay that can't read anything. Same protocol as the
/// Windows/Linux app and the phone page:
///  • a random 256-bit key, shown as a QR code (a link with the key after `#`, never sent to any server)
///  • two unguessable topic names derived from the key: commands and replies
///  • every message AES-256-GCM encrypted with the topic name as associated data (nonce ‖ ciphertext ‖ tag,
///    base64url), carrying a timestamp and a random id: stale, future-dated and repeated commands are dropped
/// Nocturnal only publishes when the phone asks, so normal use is a handful of messages a day. The phone can't
/// loosen the battery limit or the heat guard (the same rules as agents and the settings file).
struct RemoteSettings: Codable, Equatable {
    var enabled = false
    var key = ""
    var server = "https://ntfy.sh"
    var panelUrl = ""

    /// Where the phone page lives once the Nocturnal site is online. Empty until then: pairing shows the code to
    /// paste into the page instead.
    static let defaultPanelURL = "https://nocturnal.tools/remote/"

    static var url: URL { StateFiles.dir.appendingPathComponent("remote.json") }
    static func load() -> RemoteSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(RemoteSettings.self, from: d) else { return RemoteSettings() }
        return s
    }
    /// Owner-only: whoever has the key can control this Mac.
    @discardableResult
    func save() -> Bool {
        guard let d = try? JSONEncoder().encode(self), StateFiles.writeDurably(d, to: Self.url, mode: 0o600) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        return true
    }

    var keyData: Data? { RemoteCrypto.b64decode(key).flatMap { $0.count == 32 ? $0 : nil } }

    var pairingLink: String? {
        let base = panelUrl.isEmpty ? Self.defaultPanelURL : panelUrl
        guard !base.isEmpty, keyData != nil else { return nil }
        let s = server == "https://ntfy.sh" ? "" : "&s=" + (server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return "\(base)#k=\(key)\(s)"
    }
}

enum RemoteCrypto {
    static let allowed: Set<String> = ["panel", "mode", "preset", "watch", "track", "sleep_now", "set", "power", "power_test", "schema", "wake", "wake_at"]
    /// Commands still worth running when they arrive late: a "wake" sent while the Mac slept waits at the relay
    /// until the next check-in. Everything else is dropped after 5 minutes (the phone stopped waiting).
    static func maxAge(_ cmd: String) -> TimeInterval { cmd == "wake" ? WakePlan.wakeMaxAge : 300 }

    /// ntfy.sh turns messages over 4096 bytes into file attachments, which the phone page can't read as a reply.
    /// A sealed message is about 4/3 of the plaintext plus 38 bytes, so replies stay under this many bytes.
    static let maxReply = 2800

    /// The command's outcome (not its full result: for `panel` that's the panel itself, which doubled the size)
    /// plus the panel, trimmed to fit one ntfy message. Same rules as the Windows/Linux app.
    static func phoneReply(_ result: [String: Any], panel: [String: Any], cmd: String = "") -> [String: Any] {
        var r: [String: Any] = [:]
        for k in ["ok", "error", "next"] { if let v = result[k] { r[k] = v } }
        if cmd == "schema" {
            // The phone's Settings page: values and choices only (its labels live in the page), no panel.
            r["settings"] = (result["settings"] as? [[String: Any]] ?? []).map { s in s.filter { ["key", "type", "allowed", "value"].contains($0.key) } }
            return r
        }
        var p = panel
        func size() -> Int { r["panel"] = p; return Wire.compact(r).utf8.count }
        if size() > maxReply, let w = p["watch"] as? [[String: Any]] {
            p["watch"] = w.filter { $0["on"] as? Bool == true }   // offered apps go first; the ones kept awake stay
        }
        if size() > maxReply {
            if let a = p["agents"] as? [[String: Any]] { p["agents"] = Array(a.prefix(4)) }
            p["holds"] = nil
        }
        // Still too big (many watched apps, long warnings): cut until it fits, least important first.
        for cut in ["savings", "savingsUnclear", "weekLine", "drawLine", "figureCaption"] where size() > maxReply { p[cut] = nil }
        while size() > maxReply, var w = p["watch"] as? [[String: Any]], !w.isEmpty { w.removeLast(); p["watch"] = w }
        if size() > maxReply, let w = p["warnings"] as? [String] { p["warnings"] = w.map { String($0.prefix(120)) } }
        r["panel"] = p
        return r
    }

    static func newKey() -> String {
        b64encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    static func b64encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func b64decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// (commands, replies)
    static func topics(_ key: Data) -> (String, String) {
        func t(_ label: String) -> String {
            let h = SHA256.hash(data: Data(label.utf8) + key)
            return "nocturnal-" + h.map { String(format: "%02x", $0) }.joined().prefix(24)
        }
        return (t("nocturnal/cmd/v1"), t("nocturnal/reply/v1"))
    }

    static func seal(_ key: Data, topic: String, _ text: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: SymmetricKey(data: key), authenticating: Data(topic.utf8)),
              let combined = box.combined else { return nil }
        return b64encode(combined)
    }

    static func open(_ key: Data, topic: String, _ message: String) -> String? {
        guard let raw = b64decode(message), raw.count >= 28, raw.count <= 65536,
              let box = try? AES.GCM.SealedBox(combined: raw),
              let pt = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(topic.utf8)) else { return nil }
        return String(data: pt, encoding: .utf8)
    }
}

/// Rejects stale, future-dated, repeated and too-frequent commands. The ids seen are saved, so a command copied
/// off the relay can't be replayed after Nocturnal restarts either.
struct RemoteGuard {
    private(set) var seen: [String: Date] = [:]
    private var recent: [Date] = []

    init(seen: [String: Date] = [:]) { self.seen = seen }

    mutating func check(t: Double, id: String, maxAge: TimeInterval = 300, now: Date = Date()) -> String? {
        guard !id.isEmpty, id.count <= 64 else { return "bad id" }
        let n = now.timeIntervalSince1970
        guard t + maxAge >= n, t <= n + 60 else { return "too old or from the future (check the phone's clock)" }
        // Ids are remembered as long as any command can still be accepted, so none runs twice.
        seen = seen.filter { now.timeIntervalSince($0.value) <= WakePlan.wakeMaxAge + 60 }
        guard seen[id] == nil else { return "already handled" }
        recent.removeAll { now.timeIntervalSince($0) > 60 }
        guard recent.count < 30 else { return "too many commands, wait a minute" }
        seen[id] = now
        recent.append(now)
        return nil
    }
}

@MainActor
@Observable
final class RemoteControl {
    private(set) var settings = RemoteSettings.load()
    private(set) var status: String?
    private var task: Task<Void, Never>?
    /// Replay protection, kept across reconnects (a wake restarts the listener).
    private var guardian = RemoteGuard(seen: RemoteControl.loadSeen())
    private static var seenURL: URL { StateFiles.dir.appendingPathComponent("remote-seen.json") }
    private static func loadSeen() -> [String: Date] {
        (try? Data(contentsOf: seenURL)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }
    private let engine: Engine
    private let run: (String, [String: Any], @escaping ([String: Any]) -> Void) -> Void

    init(engine: Engine, run: @escaping (String, [String: Any], @escaping ([String: Any]) -> Void) -> Void) {
        self.engine = engine
        self.run = run
        if settings.enabled { start() }
        // A check-in wake (lid shut, screen off): reconnect at once to read what the phone sent while asleep.
        engine.onCheckIn = { [weak self] in if self?.enabled == true { self?.start() } }
        // After sleep or a network change the open connection is usually dead but only noticed after the idle
        // timeout; reconnect at once instead.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.enabled == true { self?.start() } }
        }
    }

    var enabled: Bool { settings.enabled && settings.keyData != nil }

    /// Turns phone control on (making a key the first time) and returns the settings to show for pairing.
    func enable(newKey: Bool = false) {
        var s = settings
        if s.key.isEmpty || s.keyData == nil || newKey { s.key = RemoteCrypto.newKey() }
        s.enabled = true
        guard s.save() else { status = "Couldn't save the pairing key"; return }
        settings = s
        if newKey { StateFiles.remove(cursorURL) }
        start()
    }

    func disable() {
        settings.enabled = false
        settings.save()
        task?.cancel()
        task = nil
        status = nil
        engine.remoteStatus = nil
    }

    private var cursorURL: URL { StateFiles.dir.appendingPathComponent("remote-cursor") }

    private func setStatus(_ s: String?) {
        status = s
        engine.remoteStatus = s
    }

    private func start() {
        task?.cancel()
        guard let key = settings.keyData else { return }
        let (cmdTopic, replyTopic) = RemoteCrypto.topics(key)
        let server = settings.server.hasSuffix("/") ? String(settings.server.dropLast()) : settings.server
        let cursorURL = self.cursorURL
        task = Task { [weak self] in
            var since = StateFiles.read(cursorURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var backoff: UInt64 = 5
            while !Task.isCancelled {
                var gotMessage = false
                // With no cursor yet, only new messages are read; after that, exactly from the last one handled,
                // so a restart never runs the same command twice.
                let valid = since.map { !$0.isEmpty && $0.count <= 32 && $0.allSatisfy { $0.isLetter || $0.isNumber } } ?? false
                guard let url = URL(string: "\(server)/\(cmdTopic)/json" + (valid ? "?since=\(since!)" : "")) else { return }
                var req = URLRequest(url: url)
                req.timeoutInterval = 120   // ntfy sends a keepalive every ~45 s; silence beyond this means a dead link
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    // A captive portal or proxy answers 200 with a web page: that's not the relay.
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else { throw URLError(.badServerResponse) }
                    await MainActor.run { self?.setStatus("Connected") }
                    for try await line in bytes.lines {
                        guard let ev = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        // "open" comes first on every stream, so only a keepalive or a message proves the link lasts.
                        if ev["event"] as? String == "keepalive" { gotMessage = true; backoff = 5 }
                        guard ev["event"] as? String == "message" else { continue }
                        gotMessage = true; backoff = 5
                        if let id = ev["id"] as? String, id.count <= 32, id.allSatisfy({ $0.isLetter || $0.isNumber }) {
                            since = id
                            StateFiles.write(id, to: cursorURL)
                        }
                        guard let text = RemoteCrypto.open(key, topic: cmdTopic, ev["message"] as? String ?? ""),
                              let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }   // not from the phone: no reply
                        let n = msg["n"] as? String ?? ""
                        let cmd = msg["cmd"] as? String ?? ""
                        var args = msg["args"] as? [String: Any] ?? [:]
                        let sent = (msg["t"] as? NSNumber)?.doubleValue ?? 0
                        // How long a wake waited at the relay: an old one is only for a Mac that's still shut.
                        if cmd == "wake" { args["_age"] = max(0, Date().timeIntervalSince1970 - sent) }
                        // Reached the relay more than 5 minutes ago (by the relay's clock, not the phone's): the
                        // phone stopped waiting long ago. No reply: after a long sleep there can be a backlog of
                        // these, and every reply counts against the relay's limits.
                        let maxAge = RemoteCrypto.maxAge(cmd)
                        if let at = (ev["time"] as? NSNumber)?.doubleValue, at + maxAge < Date().timeIntervalSince1970 { continue }
                        guard let me = self else { return }
                        let problem = me.guardian.check(t: sent, id: n, maxAge: maxAge)
                            ?? (RemoteCrypto.allowed.contains(cmd) ? nil : "\(cmd) isn't allowed from the phone")
                        if !n.isEmpty, me.guardian.seen[n] != nil {
                            _ = StateFiles.writeDurably((try? JSONEncoder().encode(me.guardian.seen)) ?? Data(), to: RemoteControl.seenURL)
                        }
                        var reply: [String: Any] = problem.map { ["ok": false, "error": $0] } ?? [:]
                        if problem == nil, let me = self {
                            reply = await me.execute(cmd, args)
                        }
                        reply["re"] = n
                        reply["t"] = Int(Date().timeIntervalSince1970)
                        if let sealed = RemoteCrypto.seal(key, topic: replyTopic, Wire.compact(reply)), let purl = URL(string: "\(server)/\(replyTopic)") {
                            var p = URLRequest(url: purl)
                            p.httpMethod = "POST"
                            p.httpBody = Data(sealed.utf8)
                            p.setValue("yes", forHTTPHeaderField: "Cache")
                            p.timeoutInterval = 15
                            _ = try? await URLSession.shared.data(for: p)
                        }
                    }
                    // The stream ended without an error. If nothing real came through, don't reconnect in a tight loop.
                    if !gotMessage {
                        try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                        backoff = min(backoff * 2, 120)
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run { self?.setStatus("Can't reach \(server.replacingOccurrences(of: "https://", with: "")), retrying") }
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 120)
                }
            }
        }
    }

    private func execute(_ cmd: String, _ args: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { cont in
            var done = false
            run(cmd, args) { [weak self] result in
                guard !done else { return }
                done = true
                cont.resume(returning: RemoteCrypto.phoneReply(result, panel: cmd == "schema" ? [:] : self?.engine.panelJSON() ?? [:], cmd: cmd))
            }
        }
    }
}

// MARK: - UI

/// Settings › Phone Control.
struct PhoneControlSection: View {
    @Bindable var engine: Engine
    @State private var showPairing = false

    var body: some View {
        let remote = NocturnalShared.remote
        if let remote, remote.enabled {
            Section {
                LabeledContent("Status") { Text(remote.status ?? "Starting…").foregroundStyle(.secondary) }
                if showPairing {
                    // Inline rather than a sheet: Settings live in the menu bar panel, which can't host sheets.
                    PairingView(settings: remote.settings) { showPairing = false }
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Show QR Code") { showPairing = true }
                }
                Toggle("Phone control", isOn: Binding(get: { remote.enabled }, set: { on in
                    if on { remote.enable() } else { remote.disable(); showPairing = false }
                }))
                Button("Revoke All Phones", role: .destructive) { remote.enable(newKey: true); showPairing = true }
                    .help("Makes a new key: every phone paired before (and any copy of its link or QR code) stops working")
            } header: {
                Text("Your Phone")
            } footer: {
                Text("Commands are end-to-end encrypted. The phone can't loosen the battery limit or the heat guard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            // Not paired yet: the first thing on the Phone tab, one button.
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("Use Nocturnal from your phone").font(.headline)
                    Text("See it working, wake it or let it sleep, from anywhere.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    // A fresh key every time: phones paired before phone control was switched off don't come back.
                    Button { remote?.enable(newKey: true); showPairing = true } label: { Text("Pair a Phone").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(remote == nil)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
    }
}

struct PairingView: View {
    let settings: RemoteSettings
    var done: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Pair Your Phone").font(.headline)
            if let link = settings.pairingLink, let qr = Self.qr(link) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text("Scan with your phone's camera, then Share › Add to Home Screen.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("The phone page isn't online yet. When it is, paste this pairing code into it:")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Text(settings.key).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.pairingLink ?? settings.key, forType: .string)
                }
            }
            Text("Anyone with this code can control this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Done", action: done).keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 8)
    }

    static func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: img)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return ns
    }
}
