import Foundation
import Observation
import UIKit

/// The paired computer as the app sees it: its last status, how fresh that is, and how the last tap is going.
/// Every reply carries the full status, so a tap refreshes the screen too.
@MainActor @Observable
final class Computer {
    enum Ack: Equatable {
        case sending, sent, done, refused, noAnswer, wakeQueued
        case failed(String)
    }

    private(set) var pairing: Pairing?
    private(set) var isDemo = false
    private(set) var panel: Panel?
    private(set) var panelAt: Date?
    private(set) var noAnswer = false
    private(set) var ack: Ack?
    private(set) var settings: [Setting]?
    private(set) var message: String?
    private(set) var wakeSentAt: Date?
    private(set) var pending = 0

    private var relay: Relay?
    private var demo: DemoComputer?
    private var ackClear: Task<Void, Never>?
    private var messageClear: Task<Void, Never>?
    private var lastSent = Date.distantPast
    /// Commands go out one at a time, in the order they were tapped: the computer runs them in arrival order, so
    /// two quick taps (Always, then Off) must not overtake each other on the way.
    private var queue: Task<Void, Never>?

    static let liveFor: TimeInterval = 150
    static let refreshEvery: TimeInterval = 120
    private static let savedPanel = "lastPanel"

    var isPaired: Bool { pairing != nil || isDemo }

    init() {
        if CommandLine.arguments.contains("-demo") { startDemo(); return }   // UI tests and screenshots
        if CommandLine.arguments.contains("-unpaired") { return }
        if let p = PairingStore.load() { use(p) }
    }

    // MARK: Pairing

    func pair(_ p: Pairing) {
        if p != PairingStore.load() { UserDefaults.standard.removeObject(forKey: Self.savedPanel) }   // another computer
        PairingStore.save(p)
        use(p)
        Task { await refresh() }
    }

    /// For App Review and anyone curious: a pretend computer inside the app, nothing sent anywhere.
    func startDemo() {
        isDemo = true
        let d = DemoComputer()
        demo = d
        panel = d.handle("panel", [:]).panel
        panelAt = Date()
    }

    static var preview: Computer {
        let c = Computer()
        c.startDemo()
        return c
    }

    func forget() {
        relay?.stopListening()
        relay = nil
        demo = nil
        isDemo = false
        pairing = nil
        panel = nil
        panelAt = nil
        settings = nil
        noAnswer = false
        ack = nil
        message = nil
        wakeSentAt = nil
        undoHeld()
        lastTimed = nil
        PairingStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.savedPanel)
    }

    private func use(_ p: Pairing) {
        pairing = p
        relay = Relay(pairing: p)
        if let data = UserDefaults.standard.data(forKey: Self.savedPanel),
           let saved = try? JSONDecoder().decode(SavedPanel.self, from: data) {
            panel = saved.panel
            panelAt = saved.at
        }
    }

    // MARK: On screen

    private(set) var listening = false

    func appeared() {
        relay?.listen()
        listening = true
        Task { await refresh() }
    }

    func disappeared() {
        if held != nil { Task { await releaseHeld() } }
        relay?.stopListening()
        listening = false
    }

    /// Asks by itself only after two quiet minutes: every tap's answer already brings the status.
    func tick(_ now: Date) {
        if pending == 0, now.timeIntervalSince(lastSent) > Self.refreshEvery { Task { await refresh() } }
    }

    func refresh() async {
        guard pending == 0 else { return }
        await send("panel", background: true)
    }

    // MARK: Commands

    /// Sends one command. A tap (not `background`) shows Sending…, Sent, then Done; the reply's status is drawn.
    @discardableResult
    func send(_ cmd: String, _ args: [String: Any] = [:], background: Bool = false) async -> Relay.Reply? {
        if !background { show(.sending) }
        pending += 1
        let previous = queue
        let job = Task { () -> Relay.Reply? in
            await previous?.value
            return await perform(cmd, args, background: background)
        }
        queue = Task { _ = await job.value }
        let reply = await job.value
        pending -= 1
        lastSent = Date()
        return reply
    }

    private func perform(_ cmd: String, _ args: [String: Any], background: Bool) async -> Relay.Reply? {
        do {
            let reply: Relay.Reply
            if let demo {
                try? await Task.sleep(for: .milliseconds(250))
                if !background { show(.sent) }
                try? await Task.sleep(for: .milliseconds(250))
                reply = demo.handle(cmd, args)
            } else if let relay {
                reply = try await relay.send(cmd, args, device: UIDevice.current.name) { if !background { show(.sent) } }
            } else {
                return nil
            }
            noAnswer = false
            if let p = reply.panel { draw(p) }
            if let s = reply.settings { settings = s }
            if !reply.ok, let e = reply.error {
                say(e)
                if !background { show(.refused, for: 3) }
            } else if !background {
                show(.done, for: 2)
            }
            return reply
        } catch Relay.Failure.noAnswer {
            noAnswer = true
            if !background { show(cmd == "wake" && (panel?.checkIn ?? 0) > 0 ? .wakeQueued : .noAnswer, for: 6) }
            return nil
        } catch {
            let why = if case Relay.Failure.relay(let w) = error { w } else { "Can't reach the relay" }
            if !background || panelAt == nil { show(.failed(why), for: background ? nil : 6) }
            return nil
        }
    }

    /// A tap shows at once (`edit` applies it to the status on screen); if the computer doesn't take it, the
    /// status goes back to what it last said.
    func change(_ cmd: String, _ args: [String: Any], _ edit: (inout Panel) -> Void) async {
        guard var p = panel else { await send(cmd, args); return }
        let before = p
        edit(&p)
        panel = p
        let reply = await send(cmd, args)
        if reply == nil || reply?.ok == false, panel == p { panel = before }
    }

    /// Same for a setting: shown at once, then read back from the computer (which also shows rows that depend on it).
    func changeSetting(_ key: String, _ value: Setting.Value) async {
        let i = settings?.firstIndex(where: { $0.key == key })
        let before = i.flatMap { settings?[$0].value }
        if let i { settings?[i].value = value }
        let wire: Any = switch value { case .bool(let b): b ? "on" : "off"; case .int(let n): n; case .text(let s): s }
        let reply = await send("set", ["key": key, "value": wire])
        if reply == nil || reply?.ok == false, let i, let before, settings?[i].value == value { settings?[i].value = before }
        await send("schema", background: true)
    }

    func wake() async {
        wakeSentAt = Date()
        await send("wake", ["minutes": 60])
    }

    // MARK: Keep awake

    /// The timed stop the phone last chose, and the "until" time the computer answered with, so the lens stays on
    /// the stop that was picked (the computer only reports the end time).
    private var lastTimed: (stop: Stop, until: String?)?

    /// Where the band's lens sits, read from the status.
    var stop: Stop {
        guard let p = panel else { return .busy }
        switch p.mode {
        case "off": return .off
        case "on":
            guard let until = p.alwaysUntil else { return .always }
            if let t = lastTimed, t.until == nil || t.until == until { return t.stop }
            if let mins = Self.minutesUntil(until) { return Stop.nearest(minutes: max(1, mins)) }
            return .h1
        default: return .busy
        }
    }

    /// Words for the band at rest: what it does now, with the end time for a timed stop.
    var stopWords: String {
        if stop.minutes != nil, let until = panel?.alwaysUntil { return "Until \(until)" }
        return stop.word
    }

    func choose(_ s: Stop) async {
        var args: [String: Any]
        switch s {
        case .off: args = ["mode": "off"]
        case .busy: args = ["mode": "auto"]
        case .always: args = ["mode": "always"]
        default: args = ["mode": "always", "minutes": s.minutes!]
        }
        let until = s.minutes.map { Date().addingTimeInterval(Double($0) * 60).formatted(date: .omitted, time: .shortened) }
        lastTimed = s.minutes != nil ? (s, nil) : nil
        await change("mode", args) { p in
            p.mode = s == .off ? "off" : s == .busy ? "auto" : "on"
            p.alwaysUntil = until
            if s != .busy { p.keeps = s != .off }
        }
        if s.minutes != nil, lastTimed?.stop == s { lastTimed = (s, panel?.alwaysUntil) }
    }

    /// "14:30" or "2:30 PM" from the computer's clock, as minutes from now (the next time the clock shows it).
    static func minutesUntil(_ text: String, now: Date = Date()) -> Double? {
        guard let m = text.firstMatch(of: /(\d{1,2})[:.](\d{2})\s*([AaPp])?/), var h = Int(m.1), let min = Int(m.2) else { return nil }
        if let ap = m.3?.lowercased() { h = h % 12 + (ap == "p" ? 12 : 0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = h; c.minute = min
        guard var d = Calendar.current.date(from: c) else { return nil }
        if d < now { d = d.addingTimeInterval(24 * 3600) }
        return d.timeIntervalSince(now) / 60
    }

    // MARK: Undo instead of "are you sure"

    /// Sleeping the computer (or turning Nocturnal off while the lid is shut, which sleeps it) can't be taken back from
    /// the phone once it happens: a sleeping computer can't hear it. So it waits a few seconds with an Undo.
    enum Held: Equatable { case sleep, off }
    private(set) var held: Held?
    private(set) var heldUntil: Date?
    private var heldTask: Task<Void, Never>?
    static let holdFor: TimeInterval = 4

    func hold(_ h: Held) {
        heldTask?.cancel()
        held = h
        heldUntil = Date().addingTimeInterval(Self.holdFor)
        heldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdFor))
            guard !Task.isCancelled else { return }
            await self?.releaseHeld()
        }
    }

    func undoHeld() {
        heldTask?.cancel()
        heldTask = nil
        held = nil
        heldUntil = nil
    }

    /// Sends the held action now (also when the app goes to the background before the Undo runs out).
    func releaseHeld() async {
        guard let h = held else { return }
        heldTask?.cancel()
        heldTask = nil
        held = nil
        heldUntil = nil
        switch h {
        case .sleep: await send("sleep_now")
        case .off: await choose(.off)
        }
    }

    // MARK: Wakes

    /// The daily wake: "07:00" (24-hour, the computer's clock) or nil to turn it off.
    func setWakeAt(_ time: String?) async {
        await change("wake_at", ["time": time ?? "off"]) { $0.wakeAt = time }
    }

    private func draw(_ p: Panel) {
        panel = p
        panelAt = Date()
        wakeSentAt = nil
        if !isDemo, let data = try? JSONEncoder().encode(SavedPanel(panel: p, at: Date())) {
            UserDefaults.standard.set(data, forKey: Self.savedPanel)
        }
    }

    private func show(_ a: Ack, for seconds: Double? = nil) {
        ack = a
        ackClear?.cancel()
        guard let seconds else { return }
        ackClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.ack = nil }
        }
    }

    private func say(_ text: String) {
        message = text
        messageClear?.cancel()
        messageClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.message = nil }
        }
    }

    // MARK: Words for the screen

    func freshness(at now: Date) -> (text: String, kind: Freshness) {
        if isDemo, ack == nil { return ("Demo", .live) }
        switch ack {
        case .sending: return ("Sending…", .busy)
        case .sent: return ("Sent", .busy)
        case .done: return ("Done", .done)
        case .refused: return ("Not done", .bad)
        case .noAnswer: return ("No answer", .bad)
        case .wakeQueued: return ("Sent. It wakes at its next check-in", .bad)
        case .failed(let why): return (why, .bad)
        case nil: break
        }
        guard let at = panelAt else { return ("Connecting…", .busy) }
        let age = now.timeIntervalSince(at)
        if age < Self.liveFor && !noAnswer { return ("Live", .live) }
        let minutes = Int((age / 60).rounded())
        if minutes < 60 { return ("Last seen \(max(1, minutes)) min ago", .stale) }
        if minutes < 24 * 60 { return ("Last seen \(Int((Double(minutes) / 60).rounded())) h ago", .stale) }
        return ("Last seen " + at.formatted(date: .abbreviated, time: .shortened), .stale)
    }

    enum Freshness { case live, busy, done, bad, stale }

    var headline: String {
        if noAnswer { return panel.map { $0.keeps && !$0.lidClosed } == true ? "Not answering" : "Asleep" }
        guard let p = panel else { return "…" }
        return p.keeps ? "Keeps working" : p.lidClosed ? "Going to sleep" : "Sleeps normally"
    }

    var line: String {
        if noAnswer {
            let every = panel?.checkIn ?? 0
            if wakeSentAt != nil, every > 0 { return "Wake sent. It wakes at its next check-in, within \(every) min." }
            return every > 0 ? "It checks for a wake every \(every) min." : "To wake it from here, turn on check-ins in Nocturnal's settings."
        }
        return panel?.agentLine ?? ""
    }

    var keepsWorking: Bool { (panel?.keeps ?? false) && !noAnswer }

    private struct SavedPanel: Codable {
        var panel: Panel
        var at: Date
    }
}
