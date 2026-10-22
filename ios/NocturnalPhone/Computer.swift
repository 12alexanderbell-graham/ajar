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
    /// The demo dressed for screenshots (website, App Store): no Exit Demo, and it reads "Live".
    private(set) var isMarketing = false
    private(set) var panel: Panel?
    private(set) var panelAt: Date?
    private(set) var noAnswer = false
    private(set) var ack: Ack?
    private(set) var settings: [Setting]?
    private(set) var message: String?
    private(set) var wakeSentAt: Date?
    /// When the computer was last seen going to sleep: it agreed to Sleep, or reported the lid shut with nothing
    /// keeping it awake. A sleeping computer can't answer, so the app says so at once instead of waiting for a
    /// request to time out.
    private(set) var asleepSince: Date?
    private(set) var pending = 0
    /// The stop under the finger while the band is dragged; the ground follows it.
    var hovering: Stop?

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
        if CommandLine.arguments.contains("-marketing") { isMarketing = true; startDemo(); return }
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
        asleepSince = nil
        hovering = nil
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
            if cmd == "sleep_now", reply.ok { asleepSince = Date() }
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
            if !background { show(.noAnswer, for: 6) }
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

    /// A sleeping computer picks the wake up at its next check-in, so this says "sent" straight away rather than
    /// waiting for an answer that can't come yet.
    func wake() async {
        wakeSentAt = Date()
        show(.wakeQueued, for: 6)
        await send("wake", ["minutes": panel?.wakeFor ?? 60], background: true)
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

    /// The stop the band shows. While Sleep counts down it already shows where the computer will be afterwards:
    /// sleeping ends Always and timers (back to When busy), and Off is Off.
    var shownStop: Stop {
        switch held {
        case .off: .off
        case .sleep: stop.minutes != nil || stop == .always ? .busy : stop
        case nil: stop
        }
    }

    /// Words for the band at rest: what it does now, with the end time for a timed stop.
    var stopWords: String {
        if asleep { return "Asleep" }
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
    func setWakeAt(_ time: String?, minutes: Int? = nil) async {
        var args: [String: Any] = ["time": time ?? "off"]
        if let minutes { args["minutes"] = minutes }
        await change("wake_at", args) { p in
            p.wakeAt = time
            if let minutes { p.wakeFor = minutes }
        }
    }

    private func draw(_ p: Panel) {
        let wasSleeping = panel.map { $0.lidClosed && !$0.keeps } ?? false
        if p.keeps || (!p.lidClosed && asleepSince.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            asleepSince = nil
        } else if p.lidClosed && !p.keeps && !wasSleeping {
            asleepSince = Date()
        }
        if p.keeps { wakeSentAt = nil }
        panel = p
        panelAt = Date()
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
        switch ack {
        case .sending: return ("Sending…", .busy)
        case .sent: return ("Sent", .busy)
        case .done: return ("Done", .done)
        case .refused: return ("Not done", .bad)
        case .noAnswer: return ("No answer", .bad)
        case .wakeQueued: return ("Wake sent", .done)
        case .failed(let why): return (why, .bad)
        case nil: break
        }
        if let since = asleepSince ?? (asleep ? panelAt : nil) {
            return ("Asleep since " + since.formatted(date: .omitted, time: .shortened), .stale)
        }
        if isDemo { return (isMarketing ? "Live" : "Demo", .live) }
        guard let at = panelAt else { return ("Connecting…", .busy) }
        let age = now.timeIntervalSince(at)
        if age < Self.liveFor && !noAnswer { return ("Live", .live) }
        let minutes = Int((age / 60).rounded())
        if minutes < 60 { return ("Last seen \(max(1, minutes)) min ago", .stale) }
        if minutes < 24 * 60 { return ("Last seen \(Int((Double(minutes) / 60).rounded())) h ago", .stale) }
        return ("Last seen " + at.formatted(date: .abbreviated, time: .shortened), .stale)
    }

    enum Freshness { case live, busy, done, bad, stale }

    /// Asleep, as far as the phone can tell: it went to sleep, or it stopped answering with nothing keeping it awake.
    var asleep: Bool { asleepSince != nil || (noAnswer && !notAnswering) }

    /// Kept awake with the lid open, yet silent: offline, not asleep.
    private var notAnswering: Bool { noAnswer && panel.map { $0.keeps && !$0.lidClosed } == true }

    /// It can take a command now. Asleep or silent, nothing but a wake would land.
    var reachable: Bool { !asleep && !notAnswering }

    /// Minutes between its check-ins while asleep (0: it can't be woken from here).
    var checkIn: Int { panel?.checkIn ?? 0 }

    var headline: String {
        if notAnswering { return "Not answering" }
        if asleep { return "Asleep" }
        if held != nil { return "Going to sleep" }
        guard let p = panel else { return "…" }
        return p.keeps ? "Keeps working" : p.lidClosed ? "Going to sleep" : "Sleeps normally"
    }

    var line: String {
        guard asleep || notAnswering else { return panel?.agentLine ?? "" }
        if checkIn == 0 { return "To wake it from here, turn on check-ins on the computer." }
        if let sent = wakeSentAt {
            let by = sent.addingTimeInterval(Double(checkIn) * 60).formatted(date: .omitted, time: .shortened)
            return "Wake sent. It wakes at its next check-in, by \(by)."
        }
        return "It checks for a wake every \(checkIn) min."
    }

    var keepsWorking: Bool { (panel?.keeps ?? false) && reachable }

    /// How awake the ground looks, from night (0) to green (1): it follows the band under the finger, goes towards
    /// night while a sleep counts down, is night while asleep, and otherwise matches the band.
    var groundLevel: Double {
        guard isPaired else { return 1 }
        if let h = hovering { return h.level(working: true) }
        if held != nil || asleep { return 0 }
        if notAnswering { return 0.3 }
        return shownStop.level(working: keepsWorking)
    }

    private struct SavedPanel: Codable {
        var panel: Panel
        var at: Date
    }
}
