import AppIntents

/// The running engine, for Shortcuts actions (they run inside the app's process).
@MainActor
enum AjarShared {
    static weak var engine: Engine?
    static var remote: RemoteControl?
    static weak var ui: StatusController?
}

/// Shortcuts, Spotlight and Siri: "Keep Mac awake for 2 hours", "Let Mac sleep", "Ajar status".
struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription("Keeps the Mac awake for a while, even with the lid closed.")

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 1440))
    var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Keep Mac awake for \(\.$minutes) minutes") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let e = AjarShared.engine else { return .result(dialog: "Open Ajar first.") }
        guard e.setupReady else { return .result(dialog: "Ajar needs its one-time setup first. Open Ajar from the menu bar.") }
        e.addHold(reason: "Shortcut", minutes: Double(minutes), pid: nil)
        return .result(dialog: "Staying awake for \(Engine.formatMinutes(Double(minutes))), lid open or closed.")
    }
}

nonisolated struct LetSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Let Mac Sleep"
    static let description = IntentDescription("Ends every keep-awake timer and lets the Mac sleep now; agents can't keep it awake until the lid opens again.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let e = AjarShared.engine else { return .result(dialog: "Ajar isn't running.") }
        e.sleepNow()
        return .result(dialog: "Done. It sleeps now, and agents can't keep it awake until you open the lid again.")
    }
}

nonisolated struct StatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Ajar Status"
    static let description = IntentDescription("Says whether the Mac will stay awake with the lid closed, and how long the battery lasts.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let e = AjarShared.engine else { return .result(value: "Ajar isn't running.", dialog: "Ajar isn't running.") }
        var s = e.statusLine
        if let h = e.closedHours, let b = e.battery { s += ". Battery \(b.percent)%, about \(PanelFormat.hm(h)) with the lid closed." }
        return .result(value: s, dialog: "\(s)")
    }
}

nonisolated struct AjarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: KeepAwakeIntent(), phrases: ["Keep my Mac awake with \(.applicationName)"],
                    shortTitle: "Keep Awake", systemImageName: "laptopcomputer")
        AppShortcut(intent: LetSleepIntent(), phrases: ["Let my Mac sleep with \(.applicationName)"],
                    shortTitle: "Let Sleep", systemImageName: "moon")
        AppShortcut(intent: StatusIntent(), phrases: ["\(.applicationName) status"],
                    shortTitle: "Status", systemImageName: "battery.75percent")
    }
}
