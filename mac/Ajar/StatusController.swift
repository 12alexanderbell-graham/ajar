import AppKit
import Observation
import SwiftUI

/// Owns the menu bar icon, its popover, and Ajar's windows. Plain AppKit so every piece can be opened
/// from code (the `ajar open` command, the Dock, a second launch) and checked by snapshot.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    let engine: Engine
    let island: Island
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var measurer: NSHostingController<PanelView>!
    private var fitTimer: Timer?

    /// Fit the popover to its content, outside any layout pass, capped to the screen.
    private func fitPopover() {
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        // Settings scroll inside a fixed page; the main page is as tall as its content.
        let h = UIState.shared.panelSettings ? UIState.settingsHeight : ceil(measurer.sizeThatFits(in: CGSize(width: 320, height: 4000)).height)
        let size = NSSize(width: 320, height: min(h, maxH))
        if abs(popover.contentSize.height - size.height) > 1 || popover.contentSize.width != size.width {
            popover.contentSize = size
        }
    }

    init(engine: Engine) {
        self.engine = engine
        self.island = Island(engine: engine)
        super.init()
        engine.onAnnounce = { [weak self] title, subtitle in
            guard let self, self.engine.config.notchIsland else { return }
            self.island.show(title: title, subtitle: subtitle, glyph: self.engine.holding)
        }

        let actions = PanelActions(openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) })
        // Sized by hand from a separate measuring copy. Letting SwiftUI drive the popover's size from live content
        // made AppKit's constraint pass loop and crash ("more Update Constraints passes than views").
        let host = NSHostingController(rootView: PopoverRoot(engine: engine, actions: actions,
                                                             back: { [weak self] in UIState.shared.panelSettings = false; self?.fitPopover() }))
        host.sizingOptions = []
        popover.contentViewController = host
        measurer = NSHostingController(rootView: PanelView(engine: engine, actions: actions))
        measurer.sizingOptions = []
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        item.autosaveName = "AjarStatusItem"
        refreshIcon()
    }

    // MARK: Icon

    /// Re-renders the icon whenever anything it reads changes.
    private func refreshIcon() {
        withObservationTracking {
            applyIcon()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refreshIcon() }
        }
    }

    // Live lid icon: the drawn lid follows the real one.
    private let lidSensor = LidSensor()
    private var lidTimer: Timer?
    private var shownAngle: Double?

    private var lidFastUntil = Date.distantPast

    /// Reads the sensor once a second while the lid sits still, and ~7× a second for 2 s after it moves,
    /// so the icon animates smoothly without waking the CPU constantly.
    private func updateLidTimer() {
        let want = engine.config.liveLidIcon && lidSensor.available
        if want && lidTimer == nil {
            scheduleLidRead(after: 0.1)
        } else if !want, let t = lidTimer {
            t.invalidate(); lidTimer = nil; shownAngle = nil
        }
    }

    private func scheduleLidRead(after delay: TimeInterval) {
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lidTimer != nil, self.engine.config.liveLidIcon else { self?.lidTimer = nil; return }
                if let a = self.lidSensor.angle(), abs(a - (self.shownAngle ?? -100)) >= 2 {
                    self.shownAngle = a
                    self.lidFastUntil = Date().addingTimeInterval(2)
                    self.applyIcon()
                }
                self.scheduleLidRead(after: Date() < self.lidFastUntil ? 0.15 : 1.0)
            }
        }
        t.tolerance = delay * 0.3
        RunLoop.main.add(t, forMode: .common)
        lidTimer = t
    }

    private func applyIcon() {
        guard let button = item.button else { return }
        updateLidTimer()
        let state: MenuGlyph.State = engine.holding ? .holding : (engine.mode == .off ? .off : .watching)
        button.image = MenuGlyph.image(state, lidAngle: engine.config.liveLidIcon ? shownAngle : nil)
        button.toolTip = "Ajar · " + engine.statusLine
        let text = engine.menuBarTitle
        button.title = text.isEmpty ? "" : " " + text
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
    }

    // MARK: Popover

    @objc func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            let menu = QuickMenu.build(engine: engine, openPanel: { [weak self] in self?.showPopover() },
                                       openSettings: { [weak self] in self?.showSettings() })
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button else { return }
        engine.panelOpen = true
        fitPopover()
        fitTimer?.invalidate()
        fitTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitPopover() }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) {
        fitTimer?.invalidate()
        UIState.shared.panelSettings = false   // opens on the main page next time, like system menus
        engine.panelOpen = false
    }

    // MARK: Windows

    /// Settings live inside Ajar's own panel (or its window when that's open), never in a separate window.
    func showSettings() {
        if let w = mainWindow, w.isVisible {
            UIState.shared.windowSettings = true
            present(w)
            return
        }
        UIState.shared.panelSettings = true
        if popover.isShown { fitPopover() } else { showPopover() }
    }

    /// A normal window with the same controls, for when the menu bar is crowded or on first launch.
    func showMainWindow() {
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainWindowView(engine: engine, actions: .init(
                openSettings: { UIState.shared.windowSettings = true },
                quit: { NSApp.terminate(nil) })))
            // Fixed size: letting SwiftUI resize the window from live-updating content caused an AppKit layout-loop crash.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 460, height: 720))
            w.title = "Ajar"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            mainWindow = w
        }
        engine.panelOpen = true
        present(mainWindow!)
    }

    private var observedWindows = Set<ObjectIdentifier>()

    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // One close observer per window, not one per time it's shown.
        if observedWindows.insert(ObjectIdentifier(w)).inserted {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
    }

    private func windowClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.mainWindow?.isVisible != true {
                UIState.shared.windowSettings = false
                if !self.engine.config.showInDock { NSApp.setActivationPolicy(.accessory) }
                if !self.popover.isShown { self.engine.panelOpen = false }
            }
        }
    }

    // MARK: Verification

    /// Renders what the popover shows into a PNG, so a build can be checked without screen access.
    func snapshot(to url: URL, window: Bool = false, settings: Bool = false) -> Bool {
        let view: NSView?
        if settings {
            showSettings()
            view = popover.contentViewController?.view
        } else if window {
            showMainWindow()
            view = mainWindow?.contentView
        } else {
            if !popover.isShown { showPopover() }
            view = popover.contentViewController?.view
        }
        guard let v = view else { return false }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

struct PanelActions {
    var openSettings: () -> Void
    var quit: () -> Void
}

/// Which page Ajar's panel and window show. Not saved: both open on the main page.
@Observable @MainActor
final class UIState {
    static let shared = UIState()
    var panelSettings = false
    var windowSettings = false
    /// Height of the settings page in the menu bar panel (it scrolls inside).
    static let settingsHeight: CGFloat = 620
}

/// The menu bar panel's content: the main page, or Settings sliding in over it.
struct PopoverRoot: View {
    @Bindable var engine: Engine
    var actions: PanelActions
    var back: () -> Void
    private var ui = UIState.shared

    init(engine: Engine, actions: PanelActions, back: @escaping () -> Void) {
        self.engine = engine; self.actions = actions; self.back = back
    }

    var body: some View {
        ZStack(alignment: .top) {
            if ui.panelSettings {
                SettingsPage(engine: engine, back: back, quit: actions.quit)
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
            } else {
                ScrollView { PanelView(engine: engine, actions: actions) }
                    .scrollIndicators(.never)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: ui.panelSettings)
        .clipped()
    }
}
