import SwiftUI

/// Everything that isn't on the main screen, inside the glass sheet: what keeps the computer awake, what happens with
/// the lid shut, when it sleeps, waking it from here, what each saving is worth, and this phone. Values and choices
/// come from the computer (the same table its agents use); only the words live here.
struct SettingsContent: View {
    @Environment(Computer.self) private var computer
    @State private var confirmForget = false

    private static let presets = [("max_battery", "longest", "Max Battery"), ("balanced", "balanced", "Balanced"), ("full_speed", "speed", "Full Speed")]
    private static let presetDetail = ["longest": "Pauses chat and background apps. Music and calls keep going.",
                                       "balanced": "Slows background apps down.", "speed": "Leaves every app alone."]
    private static let statusWords = ["waiting": "Waiting for you", "working": "Working", "finished": "Finished", "idle": "Idle"]
    private static let labels = [
        "low_power": "Low Power Mode", "pause_simulators": "Pause simulators and previews",
        "shut_down_simulators": "Shut simulators down instead", "pause_background_audio": "Pause apps holding the speakers",
        "sleep_when_done": "Sleep when the work is done", "quiet_minutes": "After nothing happens for",
        "battery_floor": "Sleep at battery level", "only_on_power": "Only when plugged in", "heat_guard": "Heat guard",
        "claude_app": "Claude app (Cowork, computer use)", "downloads": "Downloads, exports and builds",
        "notify_done": "Notify when an agent finishes", "done_chime": "Play a chime too",
    ]

    var body: some View {
        let p = computer.panel ?? Panel()
        let by = Dictionary((computer.settings ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 34) {
            group("Keeps it awake") {
                if p.agents.isEmpty && p.watch.isEmpty { note("Agents and busy apps show up here while they run.") }
                ForEach(p.agents) { a in
                    ToggleRow(title: a.name + (a.instances > 1 ? " ×\(a.instances)" : ""),
                              detail: Self.statusWords[a.status], detailColor: a.status == "waiting" ? Theme.amber : a.status == "working" ? Theme.mint : .white,
                              isOn: Binding(get: { a.keeps }, set: { on in
                                  Task { await computer.change("track", ["agent": a.id, "keeps": on]) { $0.agents[id: a.id]?.keeps = on } }
                              }))
                }
                ForEach(p.watch) { app in
                    ToggleRow(title: app.name, detail: "App", isOn: Binding(get: { app.on }, set: { on in
                        Task { await computer.change("watch", ["app": app.id, "remove": !on]) { $0.watch[id: app.id]?.on = on } }
                    }))
                }
                settingRows(["claude_app", "downloads"], by)
            }

            group("With the lid shut") {
                Segments(options: Self.presets.map { ($0.1, $0.2) }, selection: p.preset) { wire in
                    let arg = Self.presets.first { $0.1 == wire }!.0
                    Task { await computer.change("preset", ["preset": arg]) { $0.preset = wire } }
                }
                note(Self.presetDetail[p.preset] ?? "")
                screenRow(by)
                settingRows(["low_power", "pause_simulators"], by)
                if by["pause_simulators"]?.bool == true { settingRows(["shut_down_simulators"], by) }
                settingRows(["pause_background_audio"], by)
            }

            group("When it sleeps") {
                settingRows(["sleep_when_done"], by)
                if by["sleep_when_done"]?.bool != false { settingRows(["quiet_minutes"], by) }
                settingRows(["battery_floor", "only_on_power", "heat_guard"], by)
                note("The battery limit, heat guard and plugged-in rule only loosen on the computer.")
            }

            group("Waking it from here") {
                checkIn(by, p)
                wakeAt(p)
                if p.wakeNeedsSetup { note("Wakes need a one-time setup on the computer: Settings › General › Set Up.", color: Theme.amber) }
            }

            savings(p)

            group("Notifications") { settingRows(["notify_done", "done_chime"], by) }

            group("Approve everything") {
                Row {
                    Text("Claude Code and Codex").font(.body)
                    Spacer()
                    Text(p.autoApprove ? "On" : "Off").font(.headline).foregroundStyle(p.autoApprove ? Theme.amber : .white)
                }
                note("Only the computer can switch it on.")
            }

            VStack(alignment: .leading, spacing: 10) {
                if let at = computer.panelAt {
                    note("Updated \(at.formatted(date: .omitted, time: .shortened)). End-to-end encrypted. Add or revoke phones on the computer.")
                }
                Button(computer.isDemo ? "Leave the demo" : "Forget \(p.host)", role: .destructive) { confirmForget = true }
                    .font(.headline)
                    .foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .buttonStyle(Press(scale: 0.97))
                    .accessibilityIdentifier("forget")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 34)
        .confirmationDialog(computer.isDemo ? "Leave the demo?" : "Forget \(p.host)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button(computer.isDemo ? "Leave the demo" : "Forget", role: .destructive) { computer.forget() }
        } message: {
            if !computer.isDemo { Text("This phone stops controlling it. To use it again, pair again on the computer.") }
        }
        .task { await computer.send("schema", background: true) }
    }

    // MARK: Pieces

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func note(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    @ViewBuilder private func settingRows(_ keys: [String], _ by: [String: Setting]) -> some View {
        ForEach(keys.compactMap { by[$0] }) { s in row(s) }
    }

    @ViewBuilder private func row(_ s: Setting) -> some View {
        let label = Self.labels[s.key] ?? s.key.replacingOccurrences(of: "_", with: " ")
        switch s.type {
        case "bool":
            // The heat guard and the plugged-in rule only switch on from here; off is the computer's call.
            if (s.key == "heat_guard" || s.key == "only_on_power") && s.bool {
                Row {
                    Text(label).font(.body)
                    Spacer()
                    Text("On").font(.headline)
                }
            } else {
                ToggleRow(title: label, isOn: Binding(get: { s.bool }, set: { v in Task { await computer.changeSetting(s.key, .bool(v)) } }))
            }
        case "int":
            let isFloor = s.key == "battery_floor"
            let steps = Array(Set((isFloor ? [0, 5, 10, 15, 20, 25, 30, 40, 50] : [1, 2, 5, 10, 20, 30, 60]) + [s.int])).sorted()
                .filter { !isFloor || $0 >= s.int }   // the battery limit is only lowered on the computer
            MenuRow(title: label, value: isFloor ? (s.int == 0 ? "Never" : "\(s.int)%") : "\(s.int) min") {
                ForEach(steps, id: \.self) { n in
                    Button(isFloor ? (n == 0 ? "Never" : "\(n)%") : "\(n) min") { Task { await computer.changeSetting(s.key, .int(n)) } }
                }
            }
        default:
            EmptyView()
        }
    }

    /// Two settings behind one menu, as on the computer: dark (no lock), fully off (no lock), or off and locked.
    @ViewBuilder private func screenRow(_ by: [String: Setting]) -> some View {
        if by["screen_off"] != nil || by["lock_on_close"] != nil {
            let current = by["lock_on_close"]?.bool == true ? "Off, locks" : by["screen_off"]?.bool == true ? "Off, no lock" : "Dark, no lock"
            MenuRow(title: "Screen", value: current) {
                Button("Dark, no lock") { setScreen("dark", by) }
                if by["screen_off"] != nil { Button("Off, no lock") { setScreen("off", by) } }
                if by["lock_on_close"] != nil { Button("Off, locks") { setScreen("locks", by) } }
            }
        }
    }

    private func setScreen(_ v: String, _ by: [String: Setting]) {
        Task {
            if by["lock_on_close"] != nil { await computer.changeSetting("lock_on_close", .bool(v == "locks")) }
            if by["screen_off"] != nil { await computer.changeSetting("screen_off", .bool(v == "off")) }
        }
    }

    @ViewBuilder private func checkIn(_ by: [String: Setting], _ p: Panel) -> some View {
        if let s = by["check_in_minutes"] {
            let choices = s.allowed.isEmpty ? ["0", "15", "30", "60"] : s.allowed
            Segments(options: choices.map { ($0, $0 == "0" ? "Never" : "\($0) min") }, selection: s.text) { v in
                Task { await computer.changeSetting("check_in_minutes", .text(v)) }
            }
            note(s.text == "0" ? "While it sleeps it doesn't check for a wake, so it can't be woken from here."
                 : "While it sleeps it checks for a wake every \(s.text) minutes. Each check costs a little battery.")
        }
    }

    private func wakeAt(_ p: Panel) -> some View {
        WakeAtRow(current: p.wakeAt) { time in Task { await computer.setWakeAt(time) } }
    }

    @ViewBuilder private func savings(_ p: Panel) -> some View {
        if !p.savings.isEmpty || !p.savingsUnclear.isEmpty || p.powerTest != nil || p.canMeasure || p.powerTestAborted != nil {
            group("What each saving is worth") {
                if let t = p.powerTest {
                    note(t + ". Keep the lid shut.")
                } else {
                    if let a = p.powerTestAborted { note("Last time it stopped: " + a, color: Theme.amber) }
                    if let total = p.savings["total"] { valueRow("All of Nocturnal's savings", watts(total), bold: true) }
                    if p.savingsUnclear.contains("total") { valueRow("All of Nocturnal's savings", "unclear", bold: true) }
                    ForEach([("low_power", "Low Power Mode"), ("apps", "Slowing other apps"), ("simulators", "Pausing simulators"),
                             ("audio", "Pausing background audio"), ("screen_off", "Screen fully off")], id: \.0) { k, name in
                        if let v = p.savings[k] { valueRow(name, watts(v)) }
                    }
                    if p.canMeasure {
                        Button(p.savings.isEmpty ? "Measure now (about 4 min)" : "Measure again (about 4 min)") {
                            Task { await computer.send("power_test") }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .glassEffect(.clear.interactive(), in: .capsule)
                        .buttonStyle(Press(scale: 0.97))
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func valueRow(_ title: String, _ value: String, bold: Bool = false) -> some View {
        Row {
            Text(title).font(bold ? .headline : .body)
            Spacer()
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func watts(_ v: Double) -> String { v >= 0.05 ? String(format: "%.1f W", v) : "≈0 W" }
}

// MARK: Rows

/// One row: at least 56 tall, words left, control right, no dividers.
struct Row<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        HStack(spacing: 14) { content }
            .frame(minHeight: 56)
            .contentShape(.rect)
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    var detailColor: Color = .white
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(detailColor)
                }
            }
        }
        .tint(Theme.mint)
        .frame(minHeight: 56)
    }
}

struct MenuRow<Items: View>: View {
    let title: String
    let value: String
    @ViewBuilder let items: Items

    var body: some View {
        Row {
            Text(title).font(.body)
            Spacer()
            Menu {
                items
            } label: {
                HStack(spacing: 6) {
                    Text(value).font(.headline).monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .contentShape(.capsule)
            }
            .foregroundStyle(.white)
            .glassEffect(.clear.interactive(), in: .capsule)
        }
    }
}

/// Equal parts in one capsule, with a glass lens on the chosen one that slides between them. Never sized by the words.
struct Segments: View {
    let options: [(id: String, title: String)]
    let selection: String
    let choose: (String) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { o in
                Button { if o.id != selection { choose(o.id) } } label: {
                    Text(o.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if o.id == selection {
                                Capsule().fill(.white.opacity(0.18))
                                    .matchedGeometryEffect(id: "lens", in: ns)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(Press(scale: 0.97))
                .accessibilityAddTraits(o.id == selection ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.08), in: .capsule)
        .animation(Theme.chrome, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The daily wake: a switch and, while it's on, the time.
struct WakeAtRow: View {
    let current: String?
    let set: (String?) -> Void
    @State private var time = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? .now

    var body: some View {
        VStack(spacing: 0) {
            ToggleRow(title: "Wake every day", detail: current.map { "At \($0)" },
                      isOn: Binding(get: { current != nil }, set: { on in set(on ? Self.wire(time) : nil) }))
            if current != nil {
                Row {
                    Text("At").font(.body)
                    Spacer()
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .onChange(of: time) { _, t in set(Self.wire(t)) }
                }
            }
        }
        .onAppear {
            if let c = current, let m = c.firstMatch(of: /(\d{1,2})[:.](\d{2})/), let h = Int(m.1), let mi = Int(m.2) {
                time = Calendar.current.date(from: DateComponents(hour: h, minute: mi)) ?? time
            }
        }
    }

    static func wire(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 0)
    }
}

extension Array where Element: Identifiable {
    subscript(id id: Element.ID) -> Element? {
        get { first { $0.id == id } }
        set { if let i = firstIndex(where: { $0.id == id }), let v = newValue { self[i] = v } }
    }
}
