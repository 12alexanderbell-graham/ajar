import AppKit
import SwiftUI

@main
struct AjarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // `ajar …` on the command line and `ajar mcp` run here and exit before any UI exists.
        if CLI.shouldRun() { exit(CLI.main()) }
    }

    var body: some Scene {
        // Everything visible is AppKit-managed in StatusController; SwiftUI needs at least one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var engine: Engine!
    private var ui: StatusController?
    private var commands: CommandCenter?
    private var notifier: Notifier?
    private var remote: RemoteControl?
    private let hotkey = Hotkey()
    /// Held for the life of the process: one active Ajar per user, decided atomically by the OS.
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy (Xcode snippet runs, a double launch) stays passive so two copies never fight over power settings.
        // The installed copy always wins over development builds.
        let env = ProcessInfo.processInfo.environment
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
            .filter { installed ? $0.bundleURL?.path.hasPrefix("/Applications/") == true : true }
        let isPreview = env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["DYLD_INSERT_LIBRARIES"]?.contains("__preview") == true
        // Atomic single-instance lock, so two copies launched at once can't both take control of power settings.
        lockFD = isPreview ? -1 : open(StateFiles.dir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        let gotLock = lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
        guard others.isEmpty, !isPreview, gotLock else {
            // A passive copy must not keep the lock, or the real app launched later would turn passive too.
            if lockFD >= 0 { close(lockFD); lockFD = -1 }   // closing drops the flock
            engine = Engine(passive: true)
            if !isPreview, others.first?.bundleURL?.path.hasPrefix("/Applications") == true, CommandLine.arguments.count <= 1 {
                // Opened again by hand: bring up the running copy's window and leave.
                DistributedNotificationCenter.default().postNotificationName(Wire.requestName, object: nil,
                    userInfo: ["json": Wire.json(["id": UUID().uuidString, "cmd": "open", "args": ["where": "window"]])], deliverImmediately: true)
                NSApp.terminate(nil)
            }
            return
        }

        engine = Engine()
        let ui = StatusController(engine: engine)
        self.ui = ui
        commands = CommandCenter(engine: engine, ui: ui)
        notifier = Notifier(engine: engine)
        AjarShared.engine = engine
        let commands = self.commands
        remote = RemoteControl(engine: engine) { cmd, args, reply in commands?.handle(cmd, args, reply: reply) }
        AjarShared.remote = remote
        Hotkey.action = { [weak self] in self?.cycleMode() }
        applyAppearanceSettings()
        observeSettings()

        if !engine.setupReady || !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            ui.showMainWindow()
        }
    }

    private func cycleMode() {
        let next: Mode = switch engine.mode { case .off: .auto; case .auto: .on; case .on: .off }
        if next == .on { engine.stayAwake(for: nil) } else { engine.mode = next }
        if engine.config.notchIsland {
            ui?.island.show(title: "\(next.label): \(engine.statusLine)",
                            subtitle: "⌃⌥⌘A to change", glyph: engine.holding, for: 2)
        }
        NSSound(named: "Tink")?.play()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = engine.config.showInDock
            _ = engine.config.hotkey
            _ = engine.config.notchIsland
            _ = engine.config.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.applyAppearanceSettings(); self?.observeSettings() }
        }
    }

    private func applyAppearanceSettings() {
        let c = engine.config
        if c.showInDock { NSApp.setActivationPolicy(.regular) }
        else if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel || $0.level != .normal }) { NSApp.setActivationPolicy(.accessory) }
        if c.hotkey { hotkey.register() } else { hotkey.unregister() }
        ui?.island.enabled = c.notchIsland
        NSApp.appearance = switch c.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ui?.showMainWindow()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let ui else { return nil }
        return QuickMenu.build(engine: engine, openPanel: { ui.showMainWindow() }, openSettings: { ui.showSettings() })
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }
}
