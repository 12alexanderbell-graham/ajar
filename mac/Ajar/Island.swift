import AppKit
import SwiftUI

/// A Dynamic Island in the MacBook notch. It slides out to announce changes ("Claude Code is working ·
/// stays awake"), and hovering the notch opens quick controls, so the panel is rarely needed.
///
/// Two windows, neither ever resized after creation (resizing a SwiftUI-hosting panel while its content
/// animates made AppKit's constraint pass loop and crash):
///  • the display panel, a fixed expanded-size canvas under the notch that ignores the mouse while collapsed;
///  • a notch-sized invisible hover target that opens it.
@MainActor
final class Island {
    private let engine: Engine
    private let model = IslandModel()
    private var display: NSPanel?
    private var hoverTarget: NSPanel?
    private var collapseWork: DispatchWorkItem?
    private var overNotch = false

    static let expandedSize = CGSize(width: 400, height: 132)

    init(engine: Engine) {
        self.engine = engine
        model.onHover = { [weak self] inside in self?.pointerInPanel(inside) }
        model.setMode = { [weak self] m in
            guard let self else { return }
            if m == .on { self.engine.stayAwake(for: nil) } else { self.engine.mode = m }
            self.model.title = self.engine.statusLine
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        build()
    }

    var enabled = true {
        didSet {
            if enabled { display?.orderFrontRegardless(); if model.hasNotch { hoverTarget?.orderFrontRegardless() } }
            else { display?.orderOut(nil); hoverTarget?.orderOut(nil) }
        }
    }

    // MARK: Geometry

    private var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    /// The notch's rectangle in screen coordinates (or a stand-in under the menu bar on Macs without one).
    private var notchRect: NSRect {
        guard let s = screen else { return .zero }
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let h = s.safeAreaInsets.top
            return NSRect(x: f.minX + l.width, y: f.maxY - h, width: f.width - l.width - r.width, height: h)
        }
        let h = NSStatusBar.system.thickness
        return NSRect(x: f.midX - 90, y: f.maxY - h, width: 180, height: h)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        return p
    }

    private func build() {
        let d = Self.makePanel()
        let host = NSHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        d.contentView = host
        d.ignoresMouseEvents = true
        display = d

        let h = Self.makePanel()
        h.level = .statusBar + 2
        let tracker = HoverView()
        tracker.onChange = { [weak self] inside in self?.pointerOverNotch(inside) }
        h.contentView = tracker
        hoverTarget = h

        model.hasNotch = (screen?.safeAreaInsets.top ?? 0) > 0
        place()
        d.orderFrontRegardless()
        if model.hasNotch { h.orderFrontRegardless() }
    }

    private func place() {
        // Displays change (clamshell with a monitor, unplugging it): only draw over a real notch.
        model.hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        if !model.hasNotch { hoverTarget?.orderOut(nil) } else if enabled { hoverTarget?.orderFrontRegardless() }
        let n = notchRect
        model.notchSize = n.size
        let s = Self.expandedSize
        display?.setFrame(NSRect(x: n.midX - s.width / 2, y: n.maxY - s.height, width: s.width, height: s.height), display: true)
        hoverTarget?.setFrame(n, display: true)
        hoverTarget?.contentView?.frame = NSRect(origin: .zero, size: n.size)
    }

    // MARK: Behaviour

    func show(title: String, subtitle: String, glyph: Bool, for seconds: Double = 3.6) {
        guard enabled else { return }
        model.title = title
        model.subtitle = subtitle
        model.glow = glyph
        model.showControls = false
        open()
        scheduleCollapse(after: seconds)
    }

    private func pointerOverNotch(_ inside: Bool) {
        overNotch = inside
        guard enabled else { return }
        if inside {
            collapseWork?.cancel()
            model.title = engine.statusLine
            model.subtitle = engine.lidClosed ? "Lid closed" : batteryHint
            model.glow = engine.holding
            model.showControls = true
            open()
        } else {
            scheduleCollapse(after: 0.6)
        }
    }

    private func pointerInPanel(_ inside: Bool) {
        if inside { collapseWork?.cancel() } else if !overNotch { scheduleCollapse(after: 0.5) }
    }

    private var batteryHint: String {
        if let b = engine.battery { return b.onAC ? "On power" : "\(b.percent)% battery" }
        return ""
    }

    private func open() {
        model.mode = engine.mode
        display?.ignoresMouseEvents = false
        withAnimation(.spring(duration: 0.45, bounce: 0.28)) { model.open = true }
    }

    private func scheduleCollapse(after s: Double) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func collapse() {
        guard !model.pointerInside, !overNotch else { return }
        withAnimation(.spring(duration: 0.38, bounce: 0.1)) { model.open = false }
        display?.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.model.open else { return }
            self.model.showControls = false
        }
    }
}

/// Invisible notch-sized view that reports the pointer entering and leaving.
final class HoverView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

@MainActor
@Observable
final class IslandModel {
    var open = false
    var title = ""
    var subtitle = ""
    var glow = false
    var showControls = false
    var mode: Mode = .auto
    var hasNotch = true
    var notchSize = CGSize(width: 200, height: 32)
    var pointerInside = false
    var onHover: (Bool) -> Void = { _ in }
    var setMode: (Mode) -> Void = { _ in }
}

/// Always laid out in the same fixed canvas; only the black shape inside it grows and shrinks.
struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let n = model.notchSize
        let full = Island.expandedSize
        let width = model.open ? full.width : n.width
        let height = model.open ? (model.showControls ? full.height : full.height - 44) : n.height
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: model.open ? 26 : 10, topRadius: model.open ? 10 : 6)
                    .fill(Color.black)
                if model.open {
                    content
                        .padding(.top, n.height + 2)
                        .padding(.horizontal, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .contentShape(Rectangle())
            .onHover { inside in model.pointerInside = inside; model.onHover(inside) }
            .opacity(model.hasNotch || model.open ? 1 : 0)
        }
        .frame(width: full.width, height: full.height, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                AjarMark(glow: model.glow)
                    .frame(width: 30, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if model.showControls {
                HStack(spacing: 8) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Button { model.setMode(m); model.mode = m } label: {
                            Text(m.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background {
                                    if model.mode == m { Capsule().fill(Brand.gradient) } else { Capsule().fill(Color.white.opacity(0.14)) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

/// Square top (flush with the screen edge, with small outward flares like the real notch) and rounded bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

#Preview("Island") {
    let m = IslandModel()
    m.open = true; m.showControls = true
    m.title = "Claude Code is working"; m.subtitle = "Keeps working with the lid closed"; m.glow = true
    m.notchSize = CGSize(width: 190, height: 32)
    return IslandView(model: m).background(Color.gray.opacity(0.3))
}
