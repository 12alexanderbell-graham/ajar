import AppKit
import SwiftUI

/// Settings as a page inside Ajar's panel or window: a back arrow, then the settings list.
struct SettingsPage: View {
    @Bindable var engine: Engine
    var back: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) {
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
                Button("Quit Ajar", action: quit).buttonStyle(.plain).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
            SettingsView(engine: engine)
        }
    }
}

/// Every setting, grouped like System Settings. Shown inside `SettingsPage`.
struct SettingsView: View {
    @Bindable var engine: Engine
    @State private var login = false
    @State private var cliInstalled = Setup.cliInstalled
    @State private var note: String?
    @State private var lockGrace: Int?
    @State private var topic = ""
    @State private var refresh = false
    /// Off: only the settings most people need. On: everything.
    @AppStorage("settingsAdvanced") private var advanced = false

    private func saveTopic() {
        let t = topic.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || Notifier.validTopic(t) { engine.update { $0.ntfyTopic = t }; topic = t }
        else { note = "Topic names can only use letters, numbers, - and _." }
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Menu bar shows", selection: $engine.menuBarText) {
                    ForEach(MenuBarText.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if advanced {
                    Picker("Appearance", selection: Binding(get: { engine.config.appearance }, set: { v in engine.update { $0.appearance = v } })) {
                        ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Notch island (pops out of the notch, hover for controls)", isOn: Binding(get: { engine.config.notchIsland }, set: { v in engine.update { $0.notchIsland = v } }))
                    Toggle("Show in Dock", isOn: Binding(get: { engine.config.showInDock }, set: { v in engine.update { $0.showInDock = v } }))
                    Toggle("⌃⌥⌘A switches Off / When Busy / Always", isOn: Binding(get: { engine.config.hotkey }, set: { v in engine.update { $0.hotkey = v } }))
                }
                Toggle("Open at login", isOn: Binding(get: { login }, set: { engine.launchAtLogin = $0; login = engine.launchAtLogin }))
            }

            if advanced {
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone alerts")
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
                }
            } header: {
                Text("When Work Stops")
            } footer: {
                Text("Sent when a busy agent has been quiet for 2 minutes. It says \"went idle\": Ajar can't tell finished from stuck. For phone alerts, install the free ntfy app and subscribe to the same topic; keep the random name, anyone who knows it can read it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            }

            if Registry.hasLid { Section {
                Picker("Screen", selection: Binding(get: { engine.config.lockOnClose ? 2 : (engine.config.screenOffNoLock ? 1 : 0) },
                                                    set: { v in engine.update { $0.lockOnClose = v == 2; $0.screenOffNoLock = v == 1 } })) {
                    Text("Dark, no lock").tag(0)
                    // Experimental and refused or locked by macOS on some Macs, so only offered in advanced settings.
                    if advanced || engine.config.screenOffNoLock {
                        Text("Off, no lock (experimental)" + Self.effect(engine.powerEffects["screen_off"])).tag(1)
                    }
                    Text("Off, locks" + Self.effect(engine.powerEffects["screen"])).tag(2)
                }
                if engine.config.screenOffNoLock, lockGrace == 0 {
                    Text("Your Mac asks for the password as soon as its display turns off (System Settings › Lock Screen), so this will most likely lock it. Ajar then goes back to Dark by itself.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if engine.config.lockOnClose {
                    LabeledContent("Your Mac locks") {
                        Text(LockSetting.describe(lockGrace)).foregroundStyle(.secondary)
                    }
                }
                if advanced {
                    Toggle("Menu bar icon follows the real lid angle", isOn: Binding(get: { engine.config.liveLidIcon }, set: { v in engine.update { $0.liveLidIcon = v } }))
                }
            } header: {
                Text("When the Lid Closes")
            } footer: {
                Text(advanced
                     ? "Dark: the screen stays on at zero brightness, so there's no password when you open the lid. Off, no lock: switches the display off without sleeping it, which saves a little more; if macOS refuses or locks the Mac anyway (some Macs do), Ajar goes back to Dark by itself. Off, locks: the most saving, but you type your password when you open the lid. Apps keep running either way."
                     : "Dark: the screen stays on at zero brightness, so there's no password when you open the lid. Off, locks: saves more, but you type your password when you open the lid. Apps keep running either way.")
                    .font(.caption).foregroundStyle(.secondary)
            } }

            PhoneControlSection(engine: engine)

            Section("When to Sleep") {
                Toggle("Sleep when the work is done", isOn: $engine.sleepWhenDone)
                if engine.sleepWhenDone {
                    Picker("After nothing happens for", selection: $engine.quietMinutes) {
                        ForEach(Array(Set([1, 2, 5, 10, 20, 30, 60, engine.quietMinutes])).sorted(), id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
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
                    Text("Ajar will keep going until the battery is empty, and the Mac switches off abruptly at 0%.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Only stay awake when plugged in", isOn: $engine.onlyOnPower)
                Toggle("Heat guard", isOn: $engine.heatGuard)
                Text("Pauses everything it can when the Mac gets hot with the lid shut, and sleeps if it stays hot for 5 minutes or gets critical.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Other apps", selection: $engine.preset) {
                    ForEach(Preset.allCases) { Text($0.label).tag($0) }
                }
                Text(engine.preset.detail).font(.caption).foregroundStyle(.secondary)
                if advanced {
                Toggle(isOn: Binding(get: { engine.config.pauseSimulators }, set: { v in engine.update { $0.pauseSimulators = v } })) {
                    Text("Pause simulators and Xcode previews") + Text(Self.effect(engine.powerEffects["simulators"])).foregroundColor(.secondary)
                }
                if engine.config.pauseSimulators {
                    Toggle("Shut them down instead (frees everything; they don't reopen)", isOn: Binding(get: { engine.config.shutDownSimulators }, set: { v in engine.update { $0.shutDownSimulators = v } }))
                        .font(.callout)
                }
                Toggle(isOn: Binding(get: { engine.config.pauseBackgroundAudio }, set: { v in engine.update { $0.pauseBackgroundAudio = v } })) {
                    Text("Pause background apps holding the speakers") + Text(Self.effect(engine.powerEffects["audio"])).foregroundColor(.secondary)
                }
                Toggle(isOn: $engine.lowPowerWhileClosed) {
                    Text("Turn on Low Power Mode") + Text(Self.effect(engine.powerEffects["low_power"])).foregroundColor(.secondary)
                }
                LabeledContent("Using now") {
                    Text(engine.systemWatts.map { String(format: "%.1f W", $0) + (PowerSensor.isMeasured ? ", measured" : "") } ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if let o = engine.openDraw, let c = engine.closedDraw {
                    LabeledContent("Lid open → closed") {
                        Text(String(format: "%.1f W → %.1f W", o, c)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                }
            } header: {
                Text("While the Lid Is Closed")
            } footer: {
                Text("Music, calls and anything your agents use keep running. Everything comes back when you open the lid. To see what each saving is worth on this Mac, shut the lid and tap Measure on the phone page (or run ajar power test).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if advanced {
            Section("Keep Awake For") {
                Toggle("Claude app (Cowork, computer use)", isOn: $engine.countClaudeApp)
                Toggle("Apps that ask macOS to stay awake (downloads, exports, builds)", isOn: $engine.countRequests)
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
                        Text(a.executables.joined(separator: ", ")).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { engine.update { $0.customAgents.removeAll { $0 == a } } }
                    }
                }
                Menu("Add App…") {
                    ForEach(engine.addableApps.prefix(25)) { app in Button(app.name) { engine.addWatched(app) } }
                }
            }

            if !engine.appRules.isEmpty {
                Section("App Rules") {
                    ForEach(engine.appRules.keys.sorted(), id: \.self) { id in
                        Picker(Self.appName(id), selection: Binding(get: { engine.appRules[id] ?? .leave }, set: { engine.setRule($0, for: id) })) {
                            ForEach(AppRule.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                        }
                    }
                    Button("Reset All Rules") { engine.appRules = [:] }
                }
            }

            }

            Section {
                connectRow("Claude Code", AIConnect.claudeCodeConnected) { AIConnect.connectClaudeCode() }
                connectRow("Codex", AIConnect.codexConnected) { AIConnect.connectCodex() }
                connectRow("Claude app", AIConnect.claudeAppConnected) { AIConnect.connectClaudeApp() }
                LabeledContent("Setup prompt") {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AIConnect.setupPrompt, forType: .string)
                        note = "Copied. Paste it into Claude or Codex and it will set Ajar up with you."
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
            } header: {
                Text("Connect Your AI")
            } footer: {
                Text("Connected agents can keep the Mac awake while they work and change any setting. Only you, here, can loosen the safety settings (heat guard, battery limit).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if advanced && !engine.stats.sessions.isEmpty {
                Section("Recent Lid-Closed Sessions") {
                    ForEach(Array(engine.stats.sessions.suffix(8).reversed().enumerated()), id: \.offset) { _, s in
                        LabeledContent {
                            Text(Self.sessionLine(s)).monospacedDigit().foregroundStyle(.secondary)
                        } label: {
                            Text(s.date.formatted(.relative(presentation: .named)).capitalized + (s.agent.map { " · \($0)" } ?? ""))
                                .lineLimit(1)
                        }
                    }
                    LabeledContent("All time, estimated") {
                        Text(String(format: "≈%.1f Wh", engine.stats.allTimeWhSaved + engine.stats.allTimeWhAvoided)).monospacedDigit()
                    }
                }
            }

            Section {
                Toggle("Show advanced settings", isOn: $advanced)
                LabeledContent("Setup") {
                    if engine.setupReady { Text("Done").foregroundStyle(.secondary) } else { Button("Set Up…") { engine.runSetup() } }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcuts")
                    Text("In the Shortcuts app: Keep Mac Awake, Let Mac Sleep, Get Ajar Status.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Remove Ajar") {
                    Button("Remove Helper…") {
                        do { try engine.uninstallHelper(); note = "Removed. Quit Ajar and move it to the Trash to finish." }
                        catch { note = error.localizedDescription }
                    }
                }
            } footer: {
                Text("Puts back everything Ajar changed first, then removes its sleep permission, watchdog and the ajar command.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        note = "Copied. Paste it into Terminal."
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
    UserDefaults.standard.set(false, forKey: "settingsAdvanced")
    return SettingsPage(engine: .preview(), back: {}, quit: {}).frame(width: 320, height: 1500).background(.regularMaterial)
}

#Preview("Settings, advanced") {
    UserDefaults.standard.set(true, forKey: "settingsAdvanced")
    return SettingsPage(engine: .preview(), back: {}, quit: {}).frame(width: 320, height: 2600).background(.regularMaterial)
}
