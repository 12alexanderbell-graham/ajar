import AppKit
import Carbon.HIToolbox

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

/// The native right-click menu (menu bar icon and Dock icon): every common action without opening the panel.
@MainActor
enum QuickMenu {
    static func build(engine: Engine, openPanel: @escaping () -> Void, openSettings: @escaping () -> Void) -> NSMenu {
        let m = NSMenu()
        let status = NSMenuItem(title: engine.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        if let b = engine.battery {
            var line = "\(b.percent)%"
            if let h = engine.closedHours {
                line += engine.onBattery ? " · \(PanelFormat.hm(h)) left closed" : " · ∞ plugged in (\(PanelFormat.hm(h)) if unplugged)"
            }
            let i = NSMenuItem(title: line, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
        }
        if engine.blockedByFloor {
            m.addItem(ActionItem("Keep Going Below \(engine.batteryFloor)%") { engine.overrideFloor() })
        } else if engine.floorOverride {
            m.addItem(ActionItem("Stop at \(engine.batteryFloor)% Again") { engine.overrideFloor(false) })
        }
        if !engine.unrestored.isEmpty {
            m.addItem(ActionItem("Couldn't Put Back \(engine.unrestored.joined(separator: ", ")), Try Again") { engine.retryRestore() })
        }
        m.addItem(ActionItem("Let It Sleep Now") { engine.sleepNow() })
        m.addItem(.separator())

        m.addItem(ActionItem("Off", checked: engine.mode == .off) { engine.mode = .off })
        m.addItem(ActionItem("When Busy (agents working)", checked: engine.mode == .auto) { engine.mode = .auto })
        let always = NSMenuItem(title: engine.onUntil.map { "Always, Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Always", action: nil, keyEquivalent: "")
        always.state = engine.mode == .on ? .on : .off
        let sub = NSMenu()
        sub.addItem(ActionItem("For 1 Hour") { engine.stayAwake(for: 60) })
        sub.addItem(ActionItem("For 3 Hours") { engine.stayAwake(for: 180) })
        sub.addItem(ActionItem("For 8 Hours") { engine.stayAwake(for: 480) })
        sub.addItem(.separator())
        sub.addItem(ActionItem("Until Turned Off") { engine.stayAwake(for: nil) })
        always.submenu = sub
        m.addItem(always)

        m.addItem(.separator())
        let closedHeader = NSMenuItem(title: "When the Lid Is Closed", action: nil, keyEquivalent: ""); closedHeader.isEnabled = false
        m.addItem(closedHeader)
        for p in Preset.allCases {
            m.addItem(ActionItem(p.label, checked: engine.preset == p) { engine.preset = p })
        }
        if !engine.holds.isEmpty {
            m.addItem(.separator())
            for h in engine.holds {
                m.addItem(ActionItem("End “\(h.reason)”") { _ = engine.releaseHold(h.id) })
            }
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Open Ajar…", handler: openPanel))
        m.addItem(ActionItem("Settings…", key: ",", handler: openSettings))
        m.addItem(ActionItem("Quit Ajar", key: "q") { NSApp.terminate(nil) })
        return m
    }
}

/// ⌃⌥⌘A cycles Off → Auto → Always from anywhere. Carbon hotkeys need no Accessibility permission.
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    static var action: (() -> Void)?

    func register() {
        guard ref == nil else { return }
        if handler == nil {   // installed once; only the key registration comes and goes
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.action?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x414A4152), id: 1) // 'AJAR'
        if RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &ref) != noErr {
            ref = nil   // another app owns the shortcut; stay unregistered rather than half-registered
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
