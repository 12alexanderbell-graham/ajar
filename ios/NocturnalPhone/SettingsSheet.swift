import SwiftUI

/// Everything that isn't on the main screen: agents, apps, the lid-shut preset, the computer's settings, and this
/// phone. Values and choices come from the computer (the same table its agents use); only the words live here.
struct SettingsSheet: View {
    @Environment(Computer.self) private var computer
    @State private var confirmForget = false

    private static let presets = [("max_battery", "longest", "Max Battery"), ("balanced", "balanced", "Balanced"), ("full_speed", "speed", "Full Speed")]
    private static let presetDetail = ["longest": "Pauses chat and background apps. Music and calls keep going.",
                                       "balanced": "Slows background apps.", "speed": "Leaves apps alone."]
    private static let statusWords = ["waiting": "Waiting for you", "working": "Working", "finished": "Finished", "idle": "Idle"]
    private static let groups: [(String, [String], String)] = [
        ("Screen and power", ["low_power", "pause_simulators", "shut_down_simulators", "pause_background_audio"], ""),
        ("Sleep and safety", ["sleep_when_done", "quiet_minutes", "battery_floor", "only_on_power", "heat_guard"],
         "The battery limit and heat guard can only be loosened on the computer."),
        ("Keep awake for", ["claude_app", "downloads"], "Agents are found on their own."),
        ("Notifications", ["notify_done", "done_chime"], ""),
    ]
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
        List {
            Section("Agents") {
                if p.agents.isEmpty { Text("Agents show up here when they run.").foregroundStyle(.secondary) }
                ForEach(p.agents) { a in
                    Toggle(isOn: Binding(get: { a.keeps }, set: { on in
                        Task { await computer.change("track", ["agent": a.id, "keeps": on]) { $0.agents[id: a.id]?.keeps = on } }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name + (a.instances > 1 ? " ×\(a.instances)" : ""))
                            Text(Self.statusWords[a.status] ?? "")
                                .font(.subheadline.weight(a.status == "waiting" ? .semibold : .regular))
                                .foregroundStyle(a.status == "waiting" ? .orange : a.status == "working" ? .green : .secondary)
                        }
                    }
                }
            }
            Section("Also while these run") {
                if p.watch.isEmpty { Text("Busy apps show up here.").foregroundStyle(.secondary) }
                ForEach(p.watch) { app in
                    Toggle(app.name, isOn: Binding(get: { app.on }, set: { on in
                        Task { await computer.change("watch", ["app": app.id, "remove": !on]) { $0.watch[id: app.id]?.on = on } }
                    }))
                }
            }
            Section {
                Picker("With the lid shut", selection: Binding(get: { p.preset }, set: { wire in
                    let (arg, _, _) = Self.presets.first { $0.1 == wire }!
                    Task { await computer.change("preset", ["preset": arg]) { $0.preset = wire } }
                })) {
                    ForEach(Self.presets, id: \.1) { Text($0.2).tag($0.1) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: { Text("With the lid shut") } footer: { Text(Self.presetDetail[p.preset] ?? "").font(.subheadline) }

            settingsSections
            savings(p)

            Section {
                LabeledContent("Claude Code and Codex") {
                    Text(p.autoApprove ? "On" : "Off").foregroundStyle(p.autoApprove ? .orange : .secondary).fontWeight(p.autoApprove ? .semibold : .regular)
                }
            } header: { Text("Approve everything") } footer: { Text("Only your computer can switch it on, in Nocturnal's settings.").font(.subheadline) }

            Section {
                Button("Refresh") { Task { await computer.send("panel") } }
                Button(computer.isDemo ? "Leave the demo" : "Forget \(p.host)", role: .destructive) { confirmForget = true }
            } header: { Text("This phone") } footer: {
                Text((computer.panelAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened)). " } ?? "")
                     + "End-to-end encrypted. To add another phone, pair it on your computer.").font(.subheadline)
            }
        }
        .headerProminence(.increased)
        .confirmationDialog(computer.isDemo ? "Leave the demo?" : "Forget \(p.host)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button(computer.isDemo ? "Leave the demo" : "Forget", role: .destructive) { computer.forget() }
        } message: {
            if !computer.isDemo { Text("This phone stops controlling it. To use it again, pair again on the computer.") }
        }
        .task { await computer.send("schema", background: true) }
    }

    @ViewBuilder private var settingsSections: some View {
        if let list = computer.settings {
            let by = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            screenSection(by)
            ForEach(Self.groups, id: \.0) { title, keys, foot in
                let rows = keys.compactMap { by[$0] }.filter { !($0.key == "quiet_minutes" && by["sleep_when_done"]?.bool == false) }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row($0) }
                    } header: { Text(title) } footer: { if !foot.isEmpty { Text(foot).font(.subheadline) } }
                }
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    /// Two settings behind one menu, as on the computer: dark (no lock), fully off (no lock), or off and locked.
    @ViewBuilder private func screenSection(_ by: [String: Setting]) -> some View {
        if by["screen_off"] != nil || by["lock_on_close"] != nil {
            let current = by["lock_on_close"]?.bool == true ? "locks" : by["screen_off"]?.bool == true ? "off" : "dark"
            Section {
                Picker("Screen", selection: Binding(get: { current }, set: { v in
                    Task {
                        if by["lock_on_close"] != nil { await computer.changeSetting("lock_on_close", .bool(v == "locks")) }
                        if by["screen_off"] != nil { await computer.changeSetting("screen_off", .bool(v == "off")) }
                    }
                })) {
                    Text("Dark, no lock").tag("dark")
                    if by["screen_off"] != nil { Text("Off, no lock").tag("off") }
                    if by["lock_on_close"] != nil { Text("Off, locks").tag("locks") }
                }
            } footer: { Text("Dark means no password when you open the lid.").font(.subheadline) }
        }
    }

    @ViewBuilder private func row(_ s: Setting) -> some View {
        let label = Self.labels[s.key] ?? s.key.replacingOccurrences(of: "_", with: " ")
        switch s.type {
        case "bool":
            Toggle(label, isOn: Binding(get: { s.bool }, set: { v in Task { await computer.changeSetting(s.key, .bool(v)) } }))
                .disabled(s.key == "heat_guard" && s.bool)   // only switched on from here
        case "int":
            let isFloor = s.key == "battery_floor"
            let steps = Array(Set((isFloor ? [0, 5, 10, 15, 20, 25, 30, 40, 50] : [1, 2, 5, 10, 20, 30, 60]) + [s.int])).sorted()
            Picker(label, selection: Binding(get: { s.int }, set: { v in Task { await computer.changeSetting(s.key, .int(v)) } })) {
                ForEach(steps, id: \.self) { n in
                    Text(isFloor ? (n == 0 ? "Never" : "\(n)%") : "\(n) min").tag(n)
                        .selectionDisabled(isFloor && n < s.int)   // the limit is only lowered on the computer
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func savings(_ p: Panel) -> some View {
        if !p.savings.isEmpty || !p.savingsUnclear.isEmpty || p.powerTest != nil || p.canMeasure || p.powerTestAborted != nil {
            Section("What each saving is worth") {
                if let t = p.powerTest {
                    Text(t + ". Keep the lid shut.")
                } else {
                    if let a = p.powerTestAborted { Text("Last time it stopped: " + a) }
                    if let total = p.savings["total"] { LabeledContent("All of Nocturnal's savings", value: watts(total)) }
                    if p.savingsUnclear.contains("total") { LabeledContent("All of Nocturnal's savings", value: "unclear") }
                    ForEach([("low_power", "Low Power Mode"), ("apps", "Slowing other apps"), ("simulators", "Pausing simulators"),
                             ("audio", "Pausing background audio"), ("screen_off", "Screen fully off")], id: \.0) { k, name in
                        if let v = p.savings[k] { LabeledContent(name, value: watts(v)) }
                    }
                    if p.canMeasure {
                        Button(p.savings.isEmpty ? "Measure now (about 4 min)" : "Measure again (about 4 min)") {
                            Task { await computer.send("power_test") }
                        }
                    }
                }
            }
        }
    }

    private func watts(_ v: Double) -> String { v >= 0.05 ? String(format: "saves %.1f W", v) : "≈0 W" }
}

private extension Array where Element: Identifiable {
    subscript(id id: Element.ID) -> Element? {
        get { first { $0.id == id } }
        set { if let i = firstIndex(where: { $0.id == id }), let v = newValue { self[i] = v } }
    }
}
