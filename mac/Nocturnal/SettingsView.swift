import AppKit
import SwiftUI

/// Settings inside Nocturnal's panel or window: five tabs across the top, each a short page. Phone comes first, so
/// pairing a phone is one click from the panel (its phone button opens this tab).
struct SettingsPage: View {
    @Bindable var engine: Engine
    var back: () -> Void
    var quit: () -> Void
    @Bindable private var ui = UIState.shared

    init(engine: Engine, back: @escaping () -> Void, quit: @escaping () -> Void) {
        self.engine = engine; self.back = back; self.quit = quit
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { back() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Settings").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back (Esc)")
                Spacer()
                Button { quit() } label: { Text("Quit Nocturnal").font(.subheadline).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            SettingsTabs(selection: $ui.settingsTab)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            Divider().padding(.top, 8)
            SettingsView(engine: engine, page: ui.settingsTab)
        }
    }
}

enum SettingsTopic: String, CaseIterable, Identifiable {
    case phone, lid, sleep, ai, general
    var id: String { rawValue }
    var title: String {
        switch self { case .phone: "Phone"; case .lid: "Lid"; case .sleep: "Sleep"; case .ai: "Agents"; case .general: "General" }
    }
    var symbol: String {
        switch self { case .phone: "iphone"; case .lid: "laptopcomputer"; case .sleep: "moon.zzz"; case .ai: "terminal"; case .general: "gearshape" }
    }
}

/// The tab row: plain symbols with a label underneath, like a Mac app's Settings toolbar.
struct SettingsTabs: View {
    @Binding var selection: SettingsTopic
    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTopic.allCases) { t in
                let on = selection == t
                Button { selection = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 15, weight: on ? .semibold : .regular)).frame(height: 18)
                        Text(t.title).font(.system(size: 10.5, weight: on ? .semibold : .regular)).lineLimit(1)
                    }
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor.opacity(0.12) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var engine: Engine
    var page: SettingsTopic
    @State private var login = false
    @State private var cliInstalled = Setup.cliInstalled
    @State private var note: String?
    @State private var approveConfirm = false
    @State private var approveEnds: AutoApprove.Ends = .work
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
        let hooks = ClaudeHooks.currentCommand
        Task {
            let r = await Task.detached { [AIConnect.claudeCodeFullyConnected(hookCommand: hooks), AIConnect.codexConnected, AIConnect.claudeAppConnected] }.value
            connected = r
        }
    }

    var body: some View { form }

    private var form: some View {
        Form {
            switch page {
            case .phone: PhoneControlSection(engine: engine); alertsPage
            case .lid: lidPage
            case .sleep: sleepPage
            case .ai: aiPage
            case .general: generalPage; aboutPage
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
            if old == .phone { saveTopic() }
            if !topicDirty { topic = engine.config.ntfyTopic }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lockGrace = LockSetting.gracePeriod()
            reloadConnected()
        }
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
        }
        Section {
            Toggle("Remind me on an iPhone hotspot", isOn: Binding(get: { !engine.config.hotspotAutomatic }, set: { v in engine.update { $0.hotspotAutomatic = !v } }))
            Button("Open Wi-Fi Settings") { NSWorkspace.shared.open(NetWatch.wifiSettingsURL) }
        } header: {
            Text("Internet")
        } footer: {
            Text("On an iPhone hotspot, set Wi‑Fi › Ask to join hotspots to Automatic.")
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
        }
        Section {
            LabeledContent(PowerSensor.isMeasured ? "Using now, measured" : "Using now, estimated") {
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
            Toggle("Claude app keeps it awake", isOn: $engine.countClaudeApp)
            Toggle("Downloads and exports keep it awake", isOn: $engine.countRequests)
                .help("Any app that asks macOS to stay awake")
        } header: {
            Text("Also keeps it awake")
        }
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
                    // Only the clock time is picked: use its next occurrence, whatever day the old value was on.
                    let hm = Calendar.current.dateComponents([.hour, .minute], from: d)
                    engine.setWake(at: Calendar.current.nextDate(after: Date(), matching: hm, matchingPolicy: .nextTime))
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
            Text("Wakes briefly at each check to pick up a wake from your phone.")
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
                    Button("Suggest") { topic = "nocturnal-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(); topicDirty = true; saveTopic() }
                } else {
                    Button("Send Test") {
                        saveTopic()
                        Notifier.push(topic: topic, title: "Nocturnal test", body: "Phone alerts work. You'll get one when an agent goes idle.") { ok in
                            note = ok ? "Sent. Check the ntfy app on your phone." : "Couldn't reach ntfy.sh. Check the topic and your connection."
                        }
                    }
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("On Your Phone")
        } footer: {
            Text("Get the free ntfy app and subscribe to this topic. Alerts go through ntfy.sh as plain text, not encrypted like phone control.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: AI Agents

    @ViewBuilder private var aiPage: some View {
        let on = engine.approve.on
        Section {
            if approveConfirm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Approve everything?").font(.headline)
                    Text("Claude Code and Codex will run any command, edit or delete any file, and use the network without asking you first, in every project. If an agent misunderstands a task, nothing stops it, and with the lid closed you won't see it happen. macOS's own permission prompts still appear.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Turns off", selection: $approveEnds) {
                        Text("When the work finishes").tag(AutoApprove.Ends.work)
                        Text("In 8 hours").tag(AutoApprove.Ends.time)
                        Text("When I turn it off").tag(AutoApprove.Ends.manual)
                    }
                    HStack {
                        Button("Cancel") { approveConfirm = false }
                        Spacer()
                        Button("Turn On") {
                            do {
                                try AutoApprove.turnOn(ends: approveEnds, hours: approveEnds == .time ? 8 : nil)
                                note = "On. New Claude Code and Codex sessions won't ask; running ones keep their mode."
                            } catch { note = error.localizedDescription }
                            engine.approveChanged()
                            approveConfirm = false
                        }
                        .tint(.red).buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Toggle(isOn: Binding(get: { on }, set: { want in
                    if want { approveEnds = .work; approveConfirm = true; return }
                    do { try AutoApprove.turnOff(); note = "Off. Your previous Claude Code and Codex settings are back." }
                    catch { note = error.localizedDescription }
                    engine.approveChanged()
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Approve everything automatically")
                        Text(on ? (engine.approve.endsLine ?? "On") : "Risky: agents never ask before acting")
                            .font(.caption).foregroundStyle(on ? Color.red : Color.secondary)
                    }
                }
                if let p = engine.approve.problem {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") {
                            do { try AutoApprove.turnOff(); note = "Off. Your previous Claude Code and Codex settings are back." }
                            catch { note = error.localizedDescription }
                            engine.approveChanged()
                        }
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
            Text("Covers Claude Code and Codex in every project. macOS permission prompts can't be clicked for you; Full Disk Access stops most of them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            let server = AIConnect.serverCommand
            let hooks = ClaudeHooks.currentCommand
            connectRow("Claude Code", connected[0]) { AIConnect.connectClaudeCode(server: server, hookCommand: hooks) }
            connectRow("Codex", connected[1]) { AIConnect.connectCodex(server: server) }
            connectRow("Claude app", connected[2]) { AIConnect.connectClaudeApp(server: server) }
        } footer: {
            Text("Lets your agent keep the Mac awake and change settings. Claude Code also tells Nocturnal when it's working, waiting for you, or done.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Setup prompt") {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AIConnect.setupPrompt, forType: .string)
                    note = "Copied. Paste it into Claude or Codex and it sets Nocturnal up with you."
                }
            }
            LabeledContent("nocturnal command") {
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
                if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Connected") }
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
            .help("Setup adds a rule that lets programs running as you switch sleep, Low Power Mode and Time Machine without a password, and nothing else. It stops accidental changes, not a malicious program on your account.")
            LabeledContent("Shortcuts") { Text("3 actions").foregroundStyle(.secondary) }
                .help("Keep Mac Awake, Let Mac Sleep, Get Nocturnal Status")
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
            Button("Remove Nocturnal…", role: .destructive) {
                UIState.shared.whilePinned {
                    do { try engine.uninstallHelper(); note = "Removed. Quit Nocturnal and move it to the Trash to finish." }
                    catch { note = error.localizedDescription }
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } footer: {
            Text("Puts everything back and removes Nocturnal's helper.")
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
                SettingsView(engine: e, page: t).frame(width: 320, height: 760).background(.regularMaterial)
            }
        }
    }
    .frame(width: 5 * 332, height: 760)
}
