import AppKit
import Observation
import SwiftUI

/// Owns the menu bar icon and its popover, the only window Nocturnal has. Plain AppKit so it can be opened from
/// code (first launch, the `nocturnal open` command, the Dock, a second launch) and checked by snapshot.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    let engine: Engine
    let island: Island
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    /// Fit the popover to what it shows, capped to the menu bar's screen. The main page reports its own height
    /// (measured on the live view, so dismissed rows and "Show More" count); Settings scroll inside a fixed page.
    /// Applied on the next run loop turn, outside any layout pass: letting SwiftUI drive the popover's size
    /// directly made AppKit's constraint pass loop and crash.
    private func fitPopover() {
        let screen = item.button?.window?.screen ?? NSScreen.main
        let maxH = (screen?.visibleFrame.height ?? 900) - 40
        let ui = UIState.shared
        let h = ui.panelSettings ? UIState.settingsHeight : ceil(ui.panelHeight)
        let size = NSSize(width: 320, height: min(max(h, 120), maxH))
        if abs(popover.contentSize.height - size.height) > 1 || popover.contentSize.width != size.width {
            popover.contentSize = size
        }
    }

    /// Refits when the page or its height changes, and keeps the popover open while a password prompt is up.
    private func observeUI() {
        withObservationTracking {
            let ui = UIState.shared
            _ = ui.panelHeight; _ = ui.panelSettings; _ = ui.pinned
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fitPopover()
                self.popover.behavior = UIState.shared.pinned ? .applicationDefined : .transient
                self.observeUI()
            }
        }
    }

    /// The panel counts as open while the popover is on screen (faster refresh then).
    private func updatePanelOpen() {
        engine.panelOpen = popover.isShown
    }

    /// Nocturnal's own Light/Dark choice also for the popover, which otherwise follows the menu bar.
    func applyAppearance(_ a: NSAppearance?) {
        popover.appearance = a
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
        let host = NSHostingController(rootView: PopoverRoot(engine: engine, actions: actions, back: { UIState.shared.panelSettings = false }))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        item.autosaveName = "NocturnalStatusItem"
        refreshIcon()
        observeUI()
        UIState.shared.pinHook = { [weak self] on in self?.popover.behavior = on ? .applicationDefined : .transient }
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
        button.toolTip = "Nocturnal · " + engine.statusLine
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
        fitPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate()
        updatePanelOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        UIState.shared.panelSettings = false   // opens on the main page next time, like system menus
        UIState.shared.pinned = false
        updatePanelOpen()
    }

    // MARK: Settings

    /// Settings slide in inside the panel, never in a separate window.
    func showSettings() {
        UIState.shared.panelSettings = true
        if popover.isShown { fitPopover() } else { showPopover() }
    }

    // MARK: Verification

    /// Renders what the popover shows into a PNG, so a build can be checked without screen access.
    func snapshot(to url: URL, settings: Bool = false) -> Bool {
        if settings { showSettings() } else if !popover.isShown { showPopover() }
        let view = popover.contentViewController?.view
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

/// Which page Nocturnal's panel shows. Not saved: it opens on the main page.
@Observable @MainActor
final class UIState {
    static let shared = UIState()
    var panelSettings = false
    /// Which Settings tab is showing. Phone first; the panel's phone button opens it directly.
    var settingsTab: SettingsTopic = .phone
    /// Height the main page needs, reported by the live view.
    var panelHeight: CGFloat = 420
    /// Keep the popover open (a password prompt is up for something started from it).
    var pinned = false

    /// Runs work that shows a macOS password prompt without the popover closing under it (clicking the prompt
    /// counts as clicking outside a transient popover).
    func whilePinned<T>(_ work: () -> T) -> T {
        // Set at once: work() blocks the main thread while the prompt is up, so a queued change would land too late.
        pinned = true
        pinHook?(true)
        let result = work()
        // Let the clicks and focus changes from the dismissed prompt arrive first, then go back to normal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pinned = false; self.pinHook?(false) }
        return result
    }
    /// Set by StatusController: changes the popover's behaviour immediately.
    var pinHook: ((Bool) -> Void)?
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
                ScrollView {
                    PanelView(engine: engine, actions: actions)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ui.panelHeight = $0 }
                }
                .scrollIndicators(.never)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: ui.panelSettings)
        .clipped()
    }
}
