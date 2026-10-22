import AppKit
import SwiftUI

@main
struct NocturnalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // `nocturnal …` on the command line and `nocturnal mcp` run here and exit before any UI exists.
        if CLI.shouldRun() { exit(CLI.main()) }
    }

    var body: some Scene {
        // Everything visible is AppKit-managed in StatusController; SwiftUI needs at least one scene.
        Settings { EmptyView() }
            .commands {
                // ⌘, opens Nocturnal's Settings page, not the empty window SwiftUI would show.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { NocturnalShared.ui?.showSettings() }.keyboardShortcut(",")
                }
            }
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
    /// Held for the life of the process: one active Nocturnal per user, decided atomically by the OS.
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy (Xcode snippet runs, a double launch) stays passive so two copies never fight over power settings.
        // The installed copy always wins over development builds.
        let env = ProcessInfo.processInfo.environment
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
            .filter { installed ? $0.bundleURL?.path.hasPrefix("/Applications/") == true : true }
        // Previews never run the installed copy; an installed copy opened from a shell that Xcode started can inherit
        // Xcode's preview variables, and must still start normally.
        let isPreview = !installed && (env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" || env["DYLD_INSERT_LIBRARIES"]?.contains("__preview") == true)
        // A build that isn't the installed app (Xcode snippets, previews, a dev run) never takes control while Nocturnal is
        // installed, even if the installed app is quitting or restarting right then. NOCTURNAL_ACTIVE=1 overrides it.
        let devDefers = !installed && FileManager.default.fileExists(atPath: "/Applications/Nocturnal.app") && env["NOCTURNAL_ACTIVE"] != "1"
        // Atomic single-instance lock, so two copies launched at once can't both take control of power settings.
        lockFD = isPreview || devDefers ? -1 : open(StateFiles.dir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
        let gotLock = lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
        guard others.isEmpty, !isPreview, !devDefers, gotLock else {
            // A passive copy must not keep the lock, or the real app launched later would turn passive too.
            if lockFD >= 0 { close(lockFD); lockFD = -1 }   // closing drops the flock
            engine = Engine(passive: true)
            if !isPreview, others.first?.bundleURL?.path.hasPrefix("/Applications") == true, CommandLine.arguments.count <= 1 {
                // Opened again by hand: drop the running copy's panel down and leave.
                DistributedNotificationCenter.default().postNotificationName(Wire.requestName, object: nil,
                    userInfo: ["json": Wire.json(["id": UUID().uuidString, "cmd": "open", "args": ["where": "panel"]])], deliverImmediately: true)
                NSApp.terminate(nil)
            } else if installed, !isPreview {
                // The installed app lost the lock, or saw a copy that was still quitting (a restart, an update, a
                // short-lived dev copy). Take over as soon as the lock is free instead of staying idle for good.
                waitForLock()
            }
            return
        }
        startActive()
    }

    private var lockRetry: Timer?

    private func waitForLock() {
        lockRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fd = open(StateFiles.dir.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR, 0o600)
                guard fd >= 0 else { return }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return }
                self.lockRetry?.invalidate(); self.lockRetry = nil
                self.lockFD = fd
                self.startActive()
            }
        }
    }

    /// Everything the one active copy runs: the engine, the menu bar item, commands, notifications, phone control.
    private func startActive() {
        engine = Engine()
        let ui = StatusController(engine: engine)
        self.ui = ui
        NocturnalShared.ui = ui
        commands = CommandCenter(engine: engine, ui: ui)
        notifier = Notifier(engine: engine)
        NocturnalShared.engine = engine
        let commands = self.commands
        remote = RemoteControl(engine: engine) { cmd, args, reply in commands?.handle(cmd, args, reply: reply) }
        NocturnalShared.remote = remote
        Hotkey.action = { [weak self] in self?.cycleMode() }
        applyAppearanceSettings()
        observeSettings()

        // First run, or setup not finished: drop the panel down from the menu bar, so the first thing anyone sees
        // is where Nocturnal lives. (A moment later, once the menu bar has placed the icon.)
        if !engine.setupReady || !UserDefaults.standard.bool(forKey: "onboardingDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ui.showPopover() }
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

    /// The four settings this applies, as last applied: `config` changes on every mode or slider change, and only
    /// a real change to one of these should touch the Dock icon, hotkey, island or appearance.
    private var applied: (dock: Bool, hotkey: Bool, island: Bool, look: AppearanceChoice)?

    private func observeSettings() {
        withObservationTracking {
            _ = engine.config
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.applyAppearanceSettings(); self?.observeSettings() }
        }
    }

    private func applyAppearanceSettings() {
        let c = engine.config
        let now = (dock: c.showInDock, hotkey: c.hotkey, island: c.notchIsland, look: c.appearance)
        if let a = applied, a == now { return }
        if applied?.dock != now.dock {
            if c.showInDock { NSApp.setActivationPolicy(.regular) }
            else if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel || $0.level != .normal }) { NSApp.setActivationPolicy(.accessory) }
        }
        if applied?.hotkey != now.hotkey { if c.hotkey { hotkey.register() } else { hotkey.unregister() } }
        if applied?.island != now.island { ui?.island.enabled = c.notchIsland }
        if applied?.look != now.look {
            let a: NSAppearance? = switch c.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
            NSApp.appearance = a
            ui?.applyAppearance(a)
        }
        applied = now
    }

    /// Opened again (Dock icon, Finder, Spotlight): show the panel under the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ui?.showPopover()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let ui else { return nil }
        return QuickMenu.build(engine: engine, openPanel: { ui.showPopover() }, openSettings: { ui.showSettings() })
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }
}
