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
        }
    }
}

enum SettingsTopic: String, CaseIterable, Identifiable {
    case lid, sleep, awake, alerts, phone, ai, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lid: "Lid Closed"; case .sleep: "Sleep & Safety"; case .awake: "Apps"; case .alerts: "Notifications"
        case .phone: "Phone"; case .ai: "AI Agents"; case .general: "General"; case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .lid: "laptopcomputer"; case .sleep: "moon.zzz.fill"; case .awake: "square.grid.2x2.fill"; case .alerts: "bell.badge.fill"
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
    @State private var approveOn = AutoApprove.isOn
    @State private var approveConfirm = false
    @State private var lockGrace: Int?
    @State private var topic = ""
    /// The topic field was edited here: only then is it saved (never overwrite a change made by the phone or an agent).
    @State private var topicDirty = false
    @State private var connected = [false, false, false]   // Claude Code, Codex, Claude app
    @State private var working = false

    private func saveTopic() {
        guard topicDirty else { return }
        let t = topic.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || Notifier.validTopic(t) { engine.update { $0.ntfyTopic = t }; topic = t; topicDirty = false }
        else { note = "Topic names can only use letters, numbers, - and _." }
    }

    /// Reading ~/.claude.json can take a moment for heavy Claude Code users, so it's done off the main thread.
    private func reloadConnected() {
        Task {
            let r = await Task.detached { [AIConnect.claudeCodeConnected, AIConnect.codexConnected, AIConnect.claudeAppConnected] }.value
            connected = r
        }
    }

    var body: some View {
        if page == .awake {
            // What keeps the Mac awake and what happens to each app: lists with live numbers, not a form.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Claude app (Cowork, computer use) keeps it awake", isOn: $engine.countClaudeApp)
                    Toggle("Downloads, exports and builds keep it awake", isOn: $engine.countRequests)
                        .help("Any app that asks macOS to stay awake")
                    Divider()
                    AppsView(engine: engine)
                }
                .font(.subheadline)
                .padding(16)
            }
            .scrollIndicators(.never)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            switch page {
            case nil: home
            case .lid: lidPage
            case .sleep: sleepPage
            case .awake: EmptyView()   // shown as a list above, not in the form
            case .alerts: alertsPage
            case .phone: PhoneControlSection(engine: engine)
            case .ai: aiPage
            case .general: generalPage
            case .about: aboutPage
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .id(page)   // a fresh list per page, so each opens at the top (this view's state stays)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { login = engine.launchAtLogin; cliInstalled = Setup.cliInstalled; lockGrace = LockSetting.gracePeriod(); topic = engine.config.ntfyTopic; reloadConnected() }
        .onDisappear { saveTopic() }
        .onChange(of: page) { old, _ in
            note = nil
            if old == .alerts { saveTopic() }
            if !topicDirty { topic = engine.config.ntfyTopic }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lockGrace = LockSetting.gracePeriod()
            reloadConnected()
        }
    }

    // MARK: Home

    @ViewBuilder private var home: some View {
        Section {
            if Registry.hasLid { topicRow(.lid, screenName + " · " + engine.preset.label) }
            topicRow(.sleep, sleepSummary)
            topicRow(.awake, "What keeps it awake, what pauses")
        }
        Section {
            topicRow(.alerts, alertsSummary)
            topicRow(.phone, AjarShared.remote?.enabled == true ? "On" : "Off")
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
        let n = connected.filter { $0 }.count
        return n == 0 ? "Not connected" : "\(n) connected"
    }
    private var alertsSummary: String {
        let parts = (engine.config.notifyDone ? ["On this Mac"] : []) + (engine.config.ntfyTopic.isEmpty ? [] : ["on your phone"])
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }

    // MARK: Lid Closed

    @ViewBuilder private var lidPage: some View {
        Section {
            Picker("Screen", selection: Binding(get: { engine.config.lockOnClose ? 2 : (engine.config.screenOffNoLock ? 1 : 0) },
                                                set: { v in engine.update { $0.lockOnClose = v == 2; $0.screenOffNoLock = v == 1 } })) {
                Text("Dark, no lock").tag(0)
                Text("Off, no lock (experimental)").tag(1)
                Text("Off, locks").tag(2)
            }
            if engine.config.screenOffNoLock, lockGrace == 0 {
                Text("Your Mac locks as soon as its screen turns off, so this will probably lock it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if engine.config.lockOnClose {
                LabeledContent("Your Mac locks") { Text(LockSetting.describe(lockGrace)).foregroundStyle(.secondary) }
            }
        } footer: {
            Text("Dark means no password when you open the lid.")
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
            Toggle("Pause Time Machine backups", isOn: Binding(get: { engine.config.pauseTimeMachine }, set: { v in engine.update { $0.pauseTimeMachine = v } }))
                .help("Backups switch back on when the lid opens")
            Toggle("Run builds on efficiency cores", isOn: Binding(get: { engine.config.slowBuildsWhileClosed }, set: { v in engine.update { $0.slowBuildsWhileClosed = v } }))
                .help("Experimental: the agent's compilers and build tools use less power but take several times longer")
        } header: {
            Text("Saving Power")
        } footer: {
            Text("Music, calls and your agents keep running.")
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
            if let t = engine.powerEffects["total"] {
                LabeledContent("Savings, measured") {
                    Text(String(format: "%.1f W", t)).monospacedDigit().foregroundStyle(.secondary)
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
        wakeSection
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
                Text("It keeps going until the battery runs out.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Only stay awake when plugged in", isOn: $engine.onlyOnPower)
            Toggle("Heat guard", isOn: $engine.heatGuard)
        } header: {
            Text("Safety")
        } footer: {
            Text("Heat guard puts the Mac to sleep if it gets too hot with the lid shut.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Waking up

    @ViewBuilder private var wakeSection: some View {
        Section {
            Toggle("Wake at a set time", isOn: Binding(get: { engine.config.wakeAt != nil }, set: { on in
                engine.setWake(at: on ? PanelFormatTime.next(hour: 7) : nil)
            }))
            .disabled(!engine.wakeReady)
            if let at = engine.config.wakeAt {
                DatePicker("Wake at", selection: Binding(get: { Date(timeIntervalSince1970: at) }, set: { d in
                    engine.setWake(at: d > Date() ? d : Calendar.current.date(byAdding: .day, value: 1, to: d))
                }), displayedComponents: [.hourAndMinute])
                Picker("Then stay awake for", selection: Binding(get: { engine.config.wakeForMinutes }, set: { m in engine.update { $0.wakeForMinutes = m } })) {
                    ForEach(Array(Set([15, 30, 60, 120, engine.config.wakeForMinutes])).sorted(), id: \.self) { Text(Engine.formatMinutes(Double($0))).tag($0) }
                }
            }
            Picker("Check for a wake from your phone", selection: Binding(get: { engine.config.checkInMinutes }, set: { engine.setCheckIn(minutes: $0) })) {
                Text("Never").tag(0)
                Text("Every 15 min").tag(15)
                Text("Every 30 min").tag(30)
                Text("Every hour").tag(60)
            }
            .disabled(!engine.wakeReady)
            if !engine.wakeReady {
                HStack {
                    Text("Needs Set Up to run once more after this update.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up") { engine.runSetup() }
                }
            }
        } header: {
            Text("Waking Up")
        } footer: {
            Text("While it's asleep with the lid shut, it wakes for about 25 seconds at each check, picks up a wake you sent from the phone, and sleeps again. Each check uses a little battery. A Mac that's shut down can't be woken.")
                .font(.caption).foregroundStyle(.secondary)
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
            Text("When an agent has been quiet for 2 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                TextField("ntfy topic", text: Binding(get: { topic }, set: { topic = $0; topicDirty = true }), prompt: Text("ntfy topic (off)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveTopic() }
                if topic.isEmpty {
                    Button("Suggest") { topic = "ajar-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(); topicDirty = true; saveTopic() }
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
            Text("Get the free ntfy app and subscribe to this topic.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: AI Agents

    @ViewBuilder private var aiPage: some View {
        Section {
            if approveConfirm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Approve everything?").font(.headline)
                    Text("Claude Code and Codex will run any command, edit or delete any file, and use the network without asking you first. If an agent misunderstands a task, nothing stops it, and with the lid closed you won't see it happen. Turn it off here at any time; your old settings come back.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { approveConfirm = false }
                        Spacer()
                        Button("Turn On") {
                            do { try AutoApprove.turnOn(); note = "On. New Claude Code and Codex sessions won't ask; running ones keep their mode." }
                            catch { note = error.localizedDescription }
                            approveOn = AutoApprove.isOn
                            approveConfirm = false
                        }
                        .tint(.red).buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Toggle(isOn: Binding(get: { approveOn }, set: { on in
                    if on { approveConfirm = true; return }
                    do { try AutoApprove.turnOff(); note = "Off. Your previous Claude Code and Codex settings are back." }
                    catch { note = error.localizedDescription }
                    approveOn = AutoApprove.isOn
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Approve everything automatically")
                        Text("Risky: agents never ask before acting").font(.caption).foregroundStyle(approveOn ? Color.red : Color.secondary)
                    }
                }
            }
            LabeledContent("macOS permission prompts") {
                Button("Grant Full Disk Access…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        } header: {
            Text("Approvals")
        } footer: {
            Text("macOS's own permission dialogs can't be clicked for you. Give Terminal (and Claude, Codex or your editor) Full Disk Access once, and they stop appearing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            let server = AIConnect.serverCommand
            connectRow("Claude Code", connected[0]) { AIConnect.connectClaudeCode(server: server) }
            connectRow("Codex", connected[1]) { AIConnect.connectCodex(server: server) }
            connectRow("Claude app", connected[2]) { AIConnect.connectClaudeApp(server: server) }
        } footer: {
            Text("Lets your agent keep the Mac awake and change settings.")
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
                else {
                    Button("Install…") {
                        UIState.shared.whilePinned { do { try Setup.installCLI() } catch { note = error.localizedDescription } }
                        cliInstalled = Setup.cliInstalled
                    }
                }
            }
            LabeledContent("Settings file") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Config.url]) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func connectRow(_ name: String, _ connected: Bool, _ action: @escaping @Sendable () -> String) -> some View {
        LabeledContent {
            Button(connected ? "Reconnect" : "Connect") {
                // Runs the agent's own CLI (a second or two): off the main thread so the panel doesn't freeze.
                working = true
                note = "Connecting \(name)…"
                Task {
                    note = await Task.detached { action() }.value
                    working = false
                    reloadConnected()
                }
            }
            .disabled(working)
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
                Text("Keep Mac Awake, Let Mac Sleep, Get Ajar Status").font(.caption).foregroundStyle(.secondary)
            }
        }
        if !engine.stats.sessions.isEmpty {
            Section("Recent Lid-Closed Sessions") {
                ForEach(Array(engine.stats.sessions.suffix(8).reversed().enumerated()), id: \.offset) { _, s in
                    LabeledContent {
                        Text(Self.sessionLine(s)).monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        Text(Date.RelativeFormatStyle(presentation: .named, capitalizationContext: .beginningOfSentence).format(s.date) + (s.agent.map { " · \($0)" } ?? ""))
                            .lineLimit(1)
                    }
                }
            }
        }
        Section {
            Button("Remove Ajar…", role: .destructive) {
                UIState.shared.whilePinned {
                    do { try engine.uninstallHelper(); note = "Removed. Quit Ajar and move it to the Trash to finish." }
                    catch { note = error.localizedDescription }
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } footer: {
            Text("Puts everything back and removes Ajar's helper.")
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
