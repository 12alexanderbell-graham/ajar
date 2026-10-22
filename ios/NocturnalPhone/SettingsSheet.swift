import SwiftUI

/// Everything that isn't on the main screen, inside the glass sheet: what keeps the computer awake, what happens with
/// the lid shut, when it sleeps, waking it from here, what each saving is worth, and this phone. Values and choices
/// come from the computer (the same table its agents use); only the words live here.
struct SettingsContent: View {
    @Environment(Computer.self) private var computer
    @State private var confirmForget = false

    private static let presets = [("max_battery", "longest", "Max Battery"), ("balanced", "balanced", "Balanced"), ("full_speed", "speed", "Full Speed")]
    private static let presetDetail = ["longest": "Pauses other apps until the lid opens. Music, calls and what agents use keep going.",
                                       "balanced": "Slows other apps down.", "speed": "Leaves apps alone. Rules for single apps still apply."]
    private static let statusWords = ["waiting": "Waiting for you", "working": "Working", "finished": "Finished", "idle": "Idle"]
    private static let ruleWords = ["leave": "Leave", "slow": "Slow", "pause": "Pause"]
    /// The words for every setting the computer has. A setting the computer adds later still shows (under More),
    /// named from its key, so the phone never falls behind.
    static let labels = [
        "low_power": "Low Power Mode", "pause_simulators": "Pause simulators and previews",
        "shut_down_simulators": "Shut them down instead", "pause_background_audio": "Pause apps holding the speakers",
        "pause_time_machine": "Pause Time Machine backups", "slow_builds": "Run builds on efficiency cores",
        "sleep_when_done": "Sleep when the work is done", "quiet_minutes": "After nothing happens for",
        "battery_floor": "Sleep at battery level", "only_on_power": "Only when plugged in", "heat_guard": "Heat guard",
        "claude_app": "Claude app (Cowork, computer use)", "downloads": "Downloads, exports and builds",
        "notify_done": "Notify when an agent finishes", "done_chime": "Play a chime too",
        "menubar": "Menu bar shows", "appearance": "Appearance", "live_lid_icon": "Icon follows the real lid",
        "notch_island": "Notch island", "show_in_dock": "Show in Dock", "hotkey": "⌃⌥⌘A switches mode",
    ]
    private static let enumWords = [
        "menubar": ["none": "Icon Only", "battery": "Battery %", "watts": "Watts", "timeLeft": "Time Left", "timer": "Timer"],
        "appearance": ["system": "System", "light": "Light", "dark": "Dark"],
    ]
    /// Shown elsewhere, or set from its own control.
    private static let handled: Set<String> = Set(labels.keys).union(["mode", "preset", "screen_off", "lock_on_close", "check_in_minutes", "ntfy_topic"])

    var body: some View {
        let p = computer.panel ?? Panel()
        let by = Dictionary((computer.settings ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 34) {
            if !computer.reachable {
                note(computer.asleep ? "It's asleep. Settings change once it wakes." : "It isn't answering. Settings change once it's back.",
                     color: Theme.amber)
            }
            Group { sections(p, by) }
                .disabled(!computer.reachable)

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

    // MARK: Sections

    @ViewBuilder private func sections(_ p: Panel, _ by: [String: Setting]) -> some View {
        keepsAwake(p, by)

        group("With the lid shut") {
            Segments(options: Self.presets.map { ($0.1, $0.2) }, selection: p.preset) { wire in
                let arg = Self.presets.first { $0.1 == wire }!.0
                Task { await computer.change("preset", ["preset": arg]) { $0.preset = wire } }
            }
            note(Self.presetDetail[p.preset] ?? "")
            screenRow(by)
            settingRows(["low_power", "pause_simulators"], by)
            if by["pause_simulators"]?.bool == true { settingRows(["shut_down_simulators"], by) }
            settingRows(["pause_background_audio", "pause_time_machine", "slow_builds"], by)
        }

        busyApps(p)

        group("When it sleeps") {
            settingRows(["sleep_when_done"], by)
            if by["sleep_when_done"]?.bool != false { settingRows(["quiet_minutes"], by) }
            settingRows(["battery_floor", "only_on_power", "heat_guard"], by)
            note("The battery limit, heat guard and plugged-in rule only loosen on the computer.")
        }

        group("Waking it from here") {
            checkIn(by)
            WakeAtRow(current: p.wakeAt, minutes: p.wakeFor ?? 60) { time, minutes in
                Task { await computer.setWakeAt(time, minutes: minutes) }
            }
            if p.wakeNeedsSetup { note("Wakes need a one-time setup on the computer: Settings › General › Set Up.", color: Theme.amber) }
        }

        savings(p)

        if !p.sessions.isEmpty {
            group("Recent lid-shut sessions") {
                ForEach(p.sessions) { s in
                    Row {
                        Text(s.when).font(.body).lineLimit(1)
                        Spacer()
                        Text(s.line).font(.subheadline.weight(.medium)).monospacedDigit().lineLimit(1)
                    }
                }
            }
        }

        group("Notifications") { settingRows(["notify_done", "done_chime"], by) }

        group("On the computer") {
            ForEach(["menubar", "appearance"].compactMap { by[$0] }) { s in enumRow(s) }
            settingRows(["live_lid_icon", "notch_island", "show_in_dock", "hotkey"], by)
        }

        let extra = (computer.settings ?? []).filter { !Self.handled.contains($0.key) && ($0.type == "bool" || $0.type == "int" || $0.type == "enum") }
        if !extra.isEmpty {
            group("More") { ForEach(extra) { s in s.type == "enum" ? AnyView(enumRow(s)) : AnyView(row(s)) } }
        }

        group("Approve everything") {
            Row {
                Text("Claude Code and Codex").font(.body)
                Spacer()
                Text(p.autoApprove ? "On" : "Off").font(.headline).foregroundStyle(p.autoApprove ? Theme.amber : .white)
            }
            note("Only the computer can switch it on.")
        }
    }

    /// The Mac's Apps tab: what holds it awake right now (each can be ended), the agents, and the apps that keep it
    /// awake while busy.
    private func keepsAwake(_ p: Panel, _ by: [String: Setting]) -> some View {
        group("Keeps it awake") {
            if p.agents.isEmpty && p.watch.isEmpty && p.holdList.isEmpty {
                note("Agents and busy apps show up here while they run.")
            }
            ForEach(p.holdList) { h in
                Row {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.reason).font(.body).lineLimit(2)
                        Text(h.until.map { "Until \($0)" } ?? "Until it's ended").font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    Button("End") {
                        Task { await computer.change("release", ["id": h.id]) { $0.holdList.removeAll { $0.id == h.id } } }
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .glassEffect(.clear.interactive(), in: .capsule)
                    .buttonStyle(Press())
                }
            }
            ForEach(p.agents) { a in
                ToggleRow(title: a.name + (a.instances > 1 ? " ×\(a.instances)" : ""),
                          detail: agentDetail(a),
                          detailColor: a.status == "waiting" ? Theme.amber : a.status == "working" ? Theme.mint : .white,
                          isOn: Binding(get: { a.keeps }, set: { on in
                              Task { await computer.change("track", ["agent": a.id, "keeps": on]) { $0.agents[id: a.id]?.keeps = on } }
                          }))
            }
            ForEach(p.watch) { app in
                ToggleRow(title: app.name, detail: "Keeps it awake while busy", isOn: Binding(get: { app.on }, set: { on in
                    Task { await computer.change("watch", ["app": app.id, "remove": !on]) { $0.watch[id: app.id]?.on = on } }
                }))
            }
            settingRows(["claude_app", "downloads"], by)
        }
    }

    private func agentDetail(_ a: Panel.Agent) -> String {
        let word = Self.statusWords[a.status] ?? ""
        if let m = a.sleepsIn { return word + " · lets it sleep in \(m) min" }
        return word
    }

    /// The Mac's busy apps, each with what happens to it while the lid is shut, and a way to make it keep the
    /// computer awake while it's busy.
    @ViewBuilder private func busyApps(_ p: Panel) -> some View {
        if !p.apps.isEmpty {
            group("Busy apps") {
                ForEach(p.apps) { app in
                    Row {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.body).lineLimit(1)
                            Text(String(format: "%.1f W now", app.w)).font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                        Spacer()
                        Menu {
                            Picker("With the lid shut", selection: Binding(get: { app.custom ? app.rule : "default" }, set: { r in
                                Task {
                                    await computer.change("rule", ["app": app.id, "rule": r]) { p in
                                        if let i = p.apps.firstIndex(where: { $0.id == app.id }) {
                                            p.apps[i].custom = r != "default"
                                            if r != "default" { p.apps[i].rule = r }
                                        }
                                    }
                                }
                            })) {
                                Text("Leave Running").tag("leave")
                                Text("Slow Down").tag("slow")
                                Text("Pause Until Opened").tag("pause")
                                Text("Use the Preset").tag("default")
                            }
                            Button("Keep Awake While Busy", systemImage: "plus") {
                                Task { await computer.send("watch", ["app": app.id]) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(Self.ruleWords[app.rule] ?? app.rule).font(.headline)
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
                note("What each app does while the lid is shut. Busy apps can also keep it awake.")
            }
        }
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

    private static func label(_ key: String) -> String {
        labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @ViewBuilder private func row(_ s: Setting) -> some View {
        let label = Self.label(s.key)
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
            let steps = Array(Set((isFloor ? [0, 5, 10, 15, 20, 25, 30, 40, 50] : [1, 2, 5, 10, 20, 30, 60, 120]) + [s.int])).sorted()
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

    /// A choice from a short list: equal segments for three or fewer, a menu for more.
    @ViewBuilder private func enumRow(_ s: Setting) -> some View {
        let words = Self.enumWords[s.key] ?? [:]
        let options: [(id: String, title: String)] = s.allowed.map { ($0, words[$0] ?? $0.capitalized) }
        if options.count <= 3 {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.label(s.key)).font(.body)
                Segments(options: options, selection: s.text) { v in Task { await computer.changeSetting(s.key, .text(v)) } }
            }
            .padding(.vertical, 6)
        } else {
            MenuRow(title: Self.label(s.key), value: words[s.text] ?? s.text) {
                ForEach(options, id: \.id) { o in
                    Button(o.title) { Task { await computer.changeSetting(s.key, .text(o.id)) } }
                }
            }
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

    @ViewBuilder private func checkIn(_ by: [String: Setting]) -> some View {
        if let s = by["check_in_minutes"] {
            let choices = s.allowed.isEmpty ? ["0", "15", "30", "60"] : s.allowed
            Segments(options: choices.map { ($0, $0 == "0" ? "Never" : "\($0) min") }, selection: s.text) { v in
                Task { await computer.changeSetting("check_in_minutes", .text(v)) }
            }
            note(s.text == "0" ? "While it sleeps it doesn't check for a wake, so it can't be woken from here."
                 : "While it sleeps it checks for a wake every \(s.text) minutes. Each check costs a little battery.")
        }
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
                    } else if p.savings.isEmpty {
                        note("Measuring needs the lid shut while Nocturnal keeps it awake.")
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

/// The daily wake: a switch and, while it's on, the time and how long it stays awake.
struct WakeAtRow: View {
    let current: String?
    let minutes: Int
    let set: (String?, Int?) -> Void
    @State private var time = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? .now

    var body: some View {
        VStack(spacing: 0) {
            ToggleRow(title: "Wake every day", detail: current.map { "At \($0)" },
                      isOn: Binding(get: { current != nil }, set: { on in set(on ? Self.wire(time) : nil, nil) }))
            if current != nil {
                Row {
                    Text("At").font(.body)
                    Spacer()
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .onChange(of: time) { _, t in set(Self.wire(t), nil) }
                }
                MenuRow(title: "Then stays awake for", value: minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h") {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { m in
                        Button(m < 60 ? "\(m) min" : "\(m / 60) h") { set(Self.wire(time), m) }
                    }
                }
            }
        }
        .onAppear {
            guard let c = current, let m = c.firstMatch(of: /(\d{1,2})[:.](\d{2})\s*([AaPp])?/), var h = Int(m.1), let mi = Int(m.2) else { return }
            if let ap = m.3?.lowercased() { h = h % 12 + (ap == "p" ? 12 : 0) }
            time = Calendar.current.date(from: DateComponents(hour: h, minute: mi)) ?? time
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
