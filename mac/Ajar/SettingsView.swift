import AppKit
import SwiftUI

/// Settings as pages inside Ajar's panel or window, organised like iOS Settings: a short list of topics,
/// each opening its own page. Short pages fit the narrow panel without a wall of options.
struct SettingsPage: View {
    @Bindable var engine: Engine
    var back: () -> Void
    var quit: () -> Void
    @State private var page: SettingsTopic?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { if page != nil { page = nil } else { back() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text(page?.title ?? "Settings").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back (Esc)")
                Spacer()
                if page == nil {
                    Button("Quit Ajar", action: quit).buttonStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
            SettingsView(engine: engine, page: $page)
                .id(page)   // each page starts scrolled to the top
        }
        .animation(.snappy(duration: 0.2), value: page)
    }
}

enum SettingsTopic: String, CaseIterable, Identifiable {
    case lid, sleep, awake, alerts, phone, ai, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lid: "Lid Closed"; case .sleep: "Sleep & Safety"; case .awake: "Keep Awake For"; case .alerts: "Notifications"
        case .phone: "Phone"; case .ai: "AI Agents"; case .general: "General"; case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .lid: "laptopcomputer"; case .sleep: "moon.zzz.fill"; case .awake: "sparkles"; case .alerts: "bell.badge.fill"
        case .phone: "iphone"; case .ai: "terminal.fill"; case .general: "gearshape.fill"; case .about: "info"
        }
    }
    var color: Color {
        switch self {
        case .lid: .blue; case .sleep: .indigo; case .awake: .orange; case .alerts: .red
        case .phone: .green; case .ai: .teal; case .general: .gray; case .about: .gray
        }
    }
}

struct SettingsView: View {
    @Bindable var engine: Engine
    @Binding var page: SettingsTopic?
    @State private var login = false
    @State private var cliInstalled = Setup.cliInstalled
    @State private var note: String?
    @State private var lockGrace: Int?
    @State private var topic = ""
    @State private var refresh = false

    private func saveTopic() {
        let t = topic.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || Notifier.validTopic(t) { engine.update { $0.ntfyTopic = t }; topic = t }
        else { note = "Topic names can only use letters, numbers, - and _." }
    }

    var body: some View {
        Form {
            switch page {
            case nil: home
            case .lid: lidPage
            case .sleep: sleepPage
            case .awake: awakePage
            case .alerts: alertsPage
            case .phone: PhoneControlSection(engine: engine)
            case .ai: aiPage
            case .general: generalPage
            case .about: aboutPage
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { login = engine.launchAtLogin; cliInstalled = Setup.cliInstalled; lockGrace = LockSetting.gracePeriod(); topic = engine.config.ntfyTopic }
        .onDisappear { saveTopic() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lockGrace = LockSetting.gracePeriod()
        }
    }

    // MARK: Home

    @ViewBuilder private var home: some View {
        Section {
            if Registry.hasLid { topicRow(.lid, screenName + " · " + engine.preset.label) }
            topicRow(.sleep, sleepSummary)
            topicRow(.awake, engine.countClaudeApp ? "Agents, Claude app, downloads" : "Agents, downloads")
        }
        Section {
            topicRow(.alerts, engine.config.notifyDone ? (engine.config.ntfyTopic.isEmpty ? "On" : "On, and on your phone") : "Off")
            topicRow(.phone, AjarShared.remote?.enabled == true ? "Paired" : "Off")
            topicRow(.ai, aiSummary)
        }
        Section {
            topicRow(.general, "Menu bar, login, look")
            topicRow(.about, "Setup, shortcuts, history, remove")
        }
    }

    private func topicRow(_ t: SettingsTopic, _ summary: String) -> some View {
        Button { page = t } label: {
            HStack(spacing: 10) {
                IconTile(symbol: t.symbol, color: t.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).foregroundStyle(.primary)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var screenName: String {
        engine.config.lockOnClose ? "Screen off, locks" : (engine.config.screenOffNoLock ? "Screen off" : "Screen dark")
    }
    private var sleepSummary: String {
        var p = [engine.sleepWhenDone ? "After \(engine.quietMinutes) min idle" : "Not when idle"]
        p.append(engine.batteryFloor == 0 ? "no battery limit" : "at \(engine.batteryFloor)%")
        return p.joined(separator: ", ")
    }
    private var aiSummary: String {
        let _ = refresh
        let n = [AIConnect.claudeCodeConnected, AIConnect.codexConnected, AIConnect.claudeAppConnected].filter { $0 }.count
        return n == 0 ? "Not connected" : "\(n) connected"
    }

    // MARK: Lid Closed

    @ViewBuilder private var lidPage: some View {
        Section {
            Picker("Screen", selection: Binding(get: { engine.config.lockOnClose ? 2 : (engine.config.screenOffNoLock ? 1 : 0) },
                                                set: { v in engine.update { $0.lockOnClose = v == 2; $0.screenOffNoLock = v == 1 } })) {
                Text("Dark, no lock").tag(0)
                Text("Off, no lock (experimental)" + Self.effect(engine.powerEffects["screen_off"])).tag(1)
                Text("Off, locks" + Self.effect(engine.powerEffects["screen"])).tag(2)
            }
            if engine.config.screenOffNoLock, lockGrace == 0 {
                Text("Your Mac asks for the password as soon as its display turns off (System Settings › Lock Screen), so this will most likely lock it. Ajar then goes back to Dark by itself.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if engine.config.lockOnClose {
                LabeledContent("Your Mac locks") { Text(LockSetting.describe(lockGrace)).foregroundStyle(.secondary) }
            }
        } footer: {
            Text("Dark: no password when you open the lid. Off, locks: saves more, but you type your password. Off, no lock: in between; on some Macs macOS locks anyway.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Other apps", selection: $engine.preset) {
                ForEach(Preset.allCases) { Text($0.label).tag($0) }
            }
            Text(engine.preset.detail).font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: $engine.lowPowerWhileClosed) {
                Text("Low Power Mode") + Text(Self.effect(engine.powerEffects["low_power"])).foregroundColor(.secondary)
            }
            Toggle(isOn: Binding(get: { engine.config.pauseSimulators }, set: { v in engine.update { $0.pauseSimulators = v } })) {
                Text("Pause simulators and previews") + Text(Self.effect(engine.powerEffects["simulators"])).foregroundColor(.secondary)
            }
            if engine.config.pauseSimulators {
                Toggle("Shut them down instead", isOn: Binding(get: { engine.config.shutDownSimulators }, set: { v in engine.update { $0.shutDownSimulators = v } }))
                    .help("Frees everything; they don't reopen by themselves")
            }
            Toggle(isOn: Binding(get: { engine.config.pauseBackgroundAudio }, set: { v in engine.update { $0.pauseBackgroundAudio = v } })) {
                Text("Pause apps holding the speakers") + Text(Self.effect(engine.powerEffects["audio"])).foregroundColor(.secondary)
            }
        } header: {
            Text("Saving Power")
        } footer: {
            Text("Music, calls and anything your agents use keep running, and everything comes back when you open the lid. To see what each saving is worth on this Mac, shut the lid and tap Measure on the phone page.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Using now") {
                Text(engine.systemWatts.map { String(format: "%.1f W", $0) } ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            if let o = engine.openDraw, let c = engine.closedDraw {
                LabeledContent("Lid open → closed") {
                    Text(String(format: "%.1f W → %.1f W", o, c)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Sleep & Safety

    @ViewBuilder private var sleepPage: some View {
        Section {
            Toggle("Sleep when the work is done", isOn: $engine.sleepWhenDone)
            if engine.sleepWhenDone {
                Picker("After nothing happens for", selection: $engine.quietMinutes) {
                    ForEach(Array(Set([1, 2, 5, 10, 20, 30, 60, engine.quietMinutes])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                }
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sleep at battery level")
                    Spacer()
                    Text(engine.batteryFloor == 0 ? "Never" : "\(engine.batteryFloor)%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(engine.batteryFloor) }, set: { engine.batteryFloor = Int($0) }), in: 0...50, step: 5)
                    .labelsHidden()
            }
            if engine.batteryFloor == 0 {
                Text("Ajar keeps going until the battery is empty, and the Mac switches off abruptly at 0%.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Only stay awake when plugged in", isOn: $engine.onlyOnPower)
            Toggle("Heat guard", isOn: $engine.heatGuard)
        } header: {
            Text("Safety")
        } footer: {
            Text("Heat guard pauses everything it can when the Mac gets hot with the lid shut, and sleeps it if it stays hot for 5 minutes or gets critical. Only you can loosen these; AI agents and the phone can't.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Keep Awake For

    @ViewBuilder private var awakePage: some View {
        Section {
            Toggle("Claude app (Cowork, computer use)", isOn: $engine.countClaudeApp)
            Toggle("Downloads, exports and builds", isOn: $engine.countRequests)
                .help("Any app that asks macOS to stay awake")
        } footer: {
            Text("Claude Code, Codex, Gemini, Cursor and other agents are picked up on their own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Also While These Run") {
            ForEach(engine.watchedApps) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.id)).resizable().frame(width: 16, height: 16)
                    Text(app.name)
                    Spacer()
                    Button("Remove") { engine.removeWatched(app) }
                }
            }
            ForEach(engine.config.customAgents, id: \.self) { a in
                HStack {
                    Image(systemName: "terminal")
                    Text(a.name)
                    Spacer()
                    Button("Remove") { engine.update { $0.customAgents.removeAll { $0 == a } } }
                }
            }
            Menu("Add App…") {
                ForEach(engine.addableApps.prefix(25)) { app in Button(app.name) { engine.addWatched(app) } }
            }
        }
        if !engine.appRules.isEmpty {
            Section {
                ForEach(engine.appRules.keys.sorted(), id: \.self) { id in
                    Picker(Self.appName(id), selection: Binding(get: { engine.appRules[id] ?? .leave }, set: { engine.setRule($0, for: id) })) {
                        ForEach(AppRule.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                    }
                }
                Button("Reset All Rules") { engine.appRules = [:] }
            } header: {
                Text("App Rules While Closed")
            }
        }
    }

    // MARK: Notifications

    @ViewBuilder private var alertsPage: some View {
        Section {
            Toggle("Notify me when an agent goes idle", isOn: Binding(get: { engine.config.notifyDone }, set: { v in engine.update { $0.notifyDone = v } }))
            Toggle("Play a chime too", isOn: Binding(get: { engine.config.doneChime }, set: { v in
                engine.update { $0.doneChime = v }
                if v { Notifier.play(engine.config.chimeSound) }
            }))
            if engine.config.doneChime {
                Picker("Chime", selection: Binding(get: { engine.config.chimeSound }, set: { v in
                    engine.update { $0.chimeSound = v }
                    Notifier.play(v)
                })) {
                    ForEach(Notifier.sounds, id: \.self) { Text($0).tag($0) }
                }
            }
        } footer: {
            Text("Sent when a busy agent has been quiet for 2 minutes. It says \"went idle\": Ajar can't tell finished from stuck. The chime plays even with the lid shut.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                TextField("ntfy topic", text: $topic, prompt: Text("ntfy topic (off)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveTopic() }
                if topic.isEmpty {
                    Button("Suggest") { topic = "ajar-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(); saveTopic() }
                } else {
                    Button("Send Test") {
                        saveTopic()
                        Notifier.push(topic: topic, title: "Ajar test", body: "Phone alerts work. You'll get one when an agent goes idle.") { ok in
                            note = ok ? "Sent. Check the ntfy app on your phone." : "Couldn't reach ntfy.sh. Check the topic and your connection."
                        }
                    }
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("On Your Phone")
        } footer: {
            Text("Install the free ntfy app and subscribe to the same topic. Keep the random name: anyone who knows it can read the alerts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: AI Agents

    @ViewBuilder private var aiPage: some View {
        Section {
            connectRow("Claude Code", AIConnect.claudeCodeConnected) { AIConnect.connectClaudeCode() }
            connectRow("Codex", AIConnect.codexConnected) { AIConnect.connectCodex() }
            connectRow("Claude app", AIConnect.claudeAppConnected) { AIConnect.connectClaudeApp() }
        } footer: {
            Text("Connected agents can keep the Mac awake while they work, see what's using power and change settings. They can't loosen the safety settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Setup prompt") {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AIConnect.setupPrompt, forType: .string)
                    note = "Copied. Paste it into Claude or Codex and it sets Ajar up with you."
                }
            }
            LabeledContent("ajar command") {
                if cliInstalled { Text("Installed").foregroundStyle(.secondary) }
                else { Button("Install…") { do { try Setup.installCLI() } catch { note = error.localizedDescription }; cliInstalled = Setup.cliInstalled } }
            }
            LabeledContent("Settings file") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Config.url]) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func connectRow(_ name: String, _ connected: Bool, _ action: @escaping () -> String) -> some View {
        let _ = refresh   // re-read the connected state after a connect
        LabeledContent {
            Button(connected ? "Reconnect" : "Connect") { note = action(); refresh.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Connected") }
            }
        }
    }

    // MARK: General

    @ViewBuilder private var generalPage: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { login }, set: { engine.launchAtLogin = $0; login = engine.launchAtLogin }))
            Picker("Menu bar shows", selection: $engine.menuBarText) {
                ForEach(MenuBarText.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if Registry.hasLid {
                Toggle("Icon follows the real lid angle", isOn: Binding(get: { engine.config.liveLidIcon }, set: { v in engine.update { $0.liveLidIcon = v } }))
            }
            Toggle("Show in Dock", isOn: Binding(get: { engine.config.showInDock }, set: { v in engine.update { $0.showInDock = v } }))
        }
        Section {
            Picker("Appearance", selection: Binding(get: { engine.config.appearance }, set: { v in engine.update { $0.appearance = v } })) {
                ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("Notch island", isOn: Binding(get: { engine.config.notchIsland }, set: { v in engine.update { $0.notchIsland = v } }))
                .help("Short announcements pop out of the notch; hover for controls")
            Toggle("⌃⌥⌘A switches mode", isOn: Binding(get: { engine.config.hotkey }, set: { v in engine.update { $0.hotkey = v } }))
                .help("Off → When Busy → Always")
        }
    }

    // MARK: About

    @ViewBuilder private var aboutPage: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—").foregroundStyle(.secondary)
            }
            LabeledContent("Setup") {
                if engine.setupReady { Text("Done").foregroundStyle(.secondary) } else { Button("Set Up…") { engine.runSetup() } }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Shortcuts")
                Text("In the Shortcuts app: Keep Mac Awake, Let Mac Sleep, Get Ajar Status.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if !engine.stats.sessions.isEmpty {
            Section("Recent Lid-Closed Sessions") {
                ForEach(Array(engine.stats.sessions.suffix(8).reversed().enumerated()), id: \.offset) { _, s in
                    LabeledContent {
                        Text(Self.sessionLine(s)).monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(s.date.formatted(.relative(presentation: .named)).capitalized + (s.agent.map { " · \($0)" } ?? ""))
                            .lineLimit(1)
                    }
                }
            }
        }
        Section {
            Button("Remove Ajar…", role: .destructive) {
                do { try engine.uninstallHelper(); note = "Removed. Quit Ajar and move it to the Trash to finish." }
                catch { note = error.localizedDescription }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } footer: {
            Text("Puts back everything Ajar changed first, then removes its sleep permission, watchdog and the ajar command.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// " · saves 1.2 W" once measured on this Mac.
    static func effect(_ w: Double?) -> String {
        guard let w else { return "" }
        return w >= 0.05 ? String(format: "  ·  saves %.1f W", w) : "  ·  ≈0 W here"
    }

    static func sessionLine(_ s: SavingsStats.Session) -> String {
        var parts = [PanelFormat.hm(s.closedMinutes / 60) + " closed"]
        if let a = s.startPercent, let b = s.endPercent, a >= b { parts.append("used \(a - b)%") }
        if s.sleptMinutes > 0.5 { parts.append("then slept") }
        return parts.joined(separator: " · ")
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Reads (never changes) macOS's "Require password after screen saver begins or display is turned off" delay.
enum LockSetting {
    private typealias GetGrace = @convention(c) (CFDictionary?) -> Unmanaged<CFDictionary>?
    private static let getGrace: GetGrace? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_NOW),
              let f = dlsym(h, "MKBDeviceGetGracePeriod") else { return nil }
        return unsafeBitCast(f, to: GetGrace.self)
    }()

    /// Seconds between the display turning off and the lock; 0 = immediately; nil if macOS won't say.
    static func gracePeriod() -> Int? {
        // Ownership of the returned dictionary isn't documented; not releasing it costs a few bytes, over-releasing would crash.
        guard let d = getGrace?(nil)?.takeUnretainedValue() as? [String: Any] else { return nil }
        return (d["GracePeriod"] as? NSNumber)?.intValue
    }

    static func describe(_ s: Int?) -> String {
        guard let s else { return "Unknown" }
        if s == 0 { return "Immediately" }
        if s < 0 || s >= 86_400 { return "Never" }
        if s < 60 { return "After \(s) seconds" }
        if s < 3600 { return "After \(s / 60) minutes" }
        return "After \(s / 3600) hours"
    }
}

#Preview("Settings") {
    SettingsPage(engine: .preview(), back: {}, quit: {}).frame(width: 320, height: 620).background(.regularMaterial)
}

#Preview("Settings pages") {
    let e = Engine.preview()
    return ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
            ForEach(SettingsTopic.allCases) { t in
                SettingsView(engine: e, page: .constant(t)).frame(width: 320, height: 760).background(.regularMaterial)
            }
        }
    }
    .frame(width: 8 * 332, height: 760)
}
