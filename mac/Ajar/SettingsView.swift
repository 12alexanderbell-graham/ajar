import AppKit
import SwiftUI

/// Standard macOS Settings window.
struct SettingsView: View {
    @Bindable var engine: Engine
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
            Section("General") {
                Picker("Menu bar shows", selection: $engine.menuBarText) {
                    ForEach(MenuBarText.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Appearance", selection: Binding(get: { engine.config.appearance }, set: { v in engine.update { $0.appearance = v } })) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Notch island (pops out of the notch, hover for controls)", isOn: Binding(get: { engine.config.notchIsland }, set: { v in engine.update { $0.notchIsland = v } }))
                Toggle("Show in Dock", isOn: Binding(get: { engine.config.showInDock }, set: { v in engine.update { $0.showInDock = v } }))
                Toggle("⌃⌥⌘A switches Off / When Busy / Always", isOn: Binding(get: { engine.config.hotkey }, set: { v in engine.update { $0.hotkey = v } }))
                Toggle("Open at login", isOn: Binding(get: { login }, set: { engine.launchAtLogin = $0; login = engine.launchAtLogin }))
            }

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
                LabeledContent("Phone alerts") {
                    HStack {
                        TextField("ntfy topic", text: $topic, prompt: Text("ntfy topic (off)"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(width: 170)
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
                Text("Fires once an agent that was busy for at least a minute has been quiet for 2 minutes. It says \"went idle\", not \"finished\": Ajar can't tell a finished task from a crash or a question waiting for you. The chime plays even with the lid closed. For phone alerts, install the free ntfy app and subscribe to the same topic name; anyone who knows the name can read it, so keep the random one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if Registry.hasLid { Section {
                Picker("Screen", selection: Binding(get: { engine.config.lockOnClose ? 2 : (engine.config.screenOffNoLock ? 1 : 0) },
                                                    set: { v in engine.update { $0.lockOnClose = v == 2; $0.screenOffNoLock = v == 1 } })) {
                    Text("Dark, no lock screen").tag(0)
                    Text("Fully off, no lock screen (experimental)" + Self.effect(engine.powerEffects["screen_off"])).tag(1)
                    Text("Fully off, locks like normal" + Self.effect(engine.powerEffects["screen"])).tag(2)
                }
                if engine.config.lockOnClose {
                    LabeledContent("Your Mac locks") {
                        Text(LockSetting.describe(lockGrace)).foregroundStyle(.secondary)
                    }
                }
                Toggle("Menu bar icon follows the real lid angle", isOn: Binding(get: { engine.config.liveLidIcon }, set: { v in engine.update { $0.liveLidIcon = v } }))
            } header: {
                Text("When the Lid Closes")
            } footer: {
                Text("\"Dark\" keeps the screen on at zero brightness. \"Fully off, no lock screen\" switches the built-in display off without sleeping it, which saves more; if macOS won't, it stays dark. The screen comes back the moment you open the lid. Apps keep running either way.")
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
                LabeledContent("Sleep at battery level") {
                    HStack {
                        Slider(value: Binding(get: { Double(engine.batteryFloor) }, set: { engine.batteryFloor = Int($0) }), in: 0...50, step: 5)
                            .frame(width: 160)
                        Text(engine.batteryFloor == 0 ? "Never" : "\(engine.batteryFloor)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if engine.batteryFloor == 0 {
                    Text("Ajar will keep going until the battery is empty, and the Mac switches off abruptly at 0%.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Only stay awake when plugged in", isOn: $engine.onlyOnPower)
                Toggle("Heat guard", isOn: $engine.heatGuard)
                Text("Slows things down when the Mac gets hot, and sleeps if it gets critical.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Other apps", selection: $engine.preset) {
                    ForEach(Preset.allCases) { Text($0.label).tag($0) }
                }
                Text(engine.preset.detail).font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: Binding(get: { engine.config.pauseSimulators }, set: { v in engine.update { $0.pauseSimulators = v } })) {
                    Text("Pause simulators and Xcode previews") + Text(Self.effect(engine.powerEffects["simulators"])).foregroundColor(.secondary)
                }
                if engine.config.pauseSimulators {
                    Toggle("Shut simulators down instead (frees everything, doesn't reopen them)", isOn: Binding(get: { engine.config.shutDownSimulators }, set: { v in engine.update { $0.shutDownSimulators = v } }))
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
            } header: {
                Text("While the Lid Is Closed")
            } footer: {
                Text("Music, calls, and services agents use (Docker, local models, browsers) keep running; agents and everything they started are never touched. Everything comes back the moment you open the lid. To measure what each saving is worth on this Mac, close the lid and run ajar power test from your phone or AI.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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

            Section {
                LabeledContent("Claude Code") {
                    connectButton(AIConnect.claudeCodeConnected) { AIConnect.connectClaudeCode() }
                }
                LabeledContent("Codex") {
                    connectButton(AIConnect.codexConnected) { AIConnect.connectCodex() }
                }
                LabeledContent("Claude app") {
                    connectButton(AIConnect.claudeAppConnected) { AIConnect.connectClaudeApp() }
                }
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
                Text("Connected agents can keep the Mac awake while they work, read what's using power, and change any setting (ajar settings lists them all). Paste the setup prompt and your agent tunes Ajar with you. Only you, here, can loosen the safety settings: turn off the heat guard, lower the battery limit, or allow going below it. Edits to the settings file that try to are undone.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    LabeledContent("All time, estimated") {
                        Text(String(format: "≈%.1f Wh", engine.stats.allTimeWhSaved + engine.stats.allTimeWhAvoided)).monospacedDigit()
                    }
                }
            }

            Section {
                LabeledContent("Setup") {
                    if engine.setupReady { Text("Done").foregroundStyle(.secondary) } else { Button("Set Up…") { engine.runSetup() } }
                }
                LabeledContent("Shortcuts") {
                    Text("Keep Mac Awake, Let Mac Sleep, Get Ajar Status").foregroundStyle(.secondary)
                }
                LabeledContent("Remove Ajar") {
                    Button("Remove Helper…") {
                        do { try engine.uninstallHelper(); note = "Removed. Quit Ajar and move it to the Trash to finish." }
                        catch { note = error.localizedDescription }
                    }
                }
            } footer: {
                Text("Removing puts every setting Ajar changed back first, and only then takes out the sleep permission, the watchdog and the ajar command. If something can't be put back yet, it stops and keeps them so it can keep trying.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 700)
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

    @ViewBuilder private func connectButton(_ connected: Bool, _ action: @escaping () -> String) -> some View {
        let _ = refresh   // re-read the connected state after a connect
        Button(connected ? "Connected ✓ Reconnect" : "Connect") { note = action(); refresh.toggle() }
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
