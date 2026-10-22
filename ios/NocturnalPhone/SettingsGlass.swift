import SwiftUI

/// Where the settings sheet is: `t` 0 = closed (it is the gear's own glass circle), 1 = half the screen, 2 = full
/// (up to just under the head, so the head never moves). `drag` is the finger's pull on top of that.
struct SheetState: Equatable {
    var t: Double = 0
    var drag: CGFloat = 0
    /// Extra quarter turns for the gear, so it rolls on every open and close.
    var turns: Double = 0
    var contentShown = false

    var isOpen: Bool { t > 0.5 }
    /// 0 closed … 1 open, for what steps out of the sheet's way.
    var progress: Double { min(1, t) }

    mutating func toggle() {
        if isOpen { close() } else { open() }
    }

    mutating func open() {
        contentShown = true
        withAnimation(Theme.grow) { t = 1; drag = 0; turns += 1 }
    }

    mutating func close() {
        withAnimation(Theme.grow) { t = 0; drag = 0; turns += 1 }
    }
}

/// The settings sheet. Closed, it is the glass circle behind the gear. Open, that same glass grows down into a sheet
/// 8 pt in from the screen's edges with a 54 pt corner (the screen's 62 minus 8), and the settings inside grow with
/// it. Pull it up for the whole screen, pull it down or tap outside to pour it back into the gear. No grabber, no
/// title, no dimming behind it.
struct SettingsGlass: View {
    @Binding var state: SheetState
    /// The screen and the gear, measured in window coordinates, so the sheet starts exactly on the gear's glass and
    /// stops 8 pt from the screen's real edges whatever the views around it do.
    let screen: CGSize
    let gear: CGRect

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            layers(origin: origin)
                .opacity(gear == .zero ? 0 : 1)   // nothing to draw until the gear has been measured (first frame only)
        }
    }

    private func layers(origin: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            if state.isOpen {
                // Tapping outside the sheet closes it.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { state.close() }
                    .accessibilityHidden(true)
            }
            // Always drawn: closed, it is a circle exactly on the gear's glass and merges with it.
            SheetBody(t: state.t, drag: state.drag, screen: screen, gear: gear, origin: origin, contentShown: state.contentShown,
                      onDrag: { state.drag = $0 },
                      onRelease: release,
                      onCollapse: { withAnimation(Theme.grow) { state.t = 1; state.drag = 0 } })
        }
        .onChange(of: state.t) { _, t in
            if t == 0 {
                // Content leaves once the glass has poured back into the gear.
                Task { try? await Task.sleep(for: .seconds(0.5)); if state.t == 0 { state.contentShown = false } }
            }
        }
        .sensoryFeedback(.selection, trigger: state.t) { old, new in old != new && [0, 1, 2].contains(new) }
    }

    private func release(_ translation: CGFloat, _ predicted: CGFloat) {
        let projected = translation + (predicted - translation) * 0.5
        withAnimation(Theme.grow) {
            if state.t >= 1.5 {
                state.t = projected > 320 ? 0 : projected > 70 ? 1 : 2
                if state.t == 0 { state.turns += 1 }
            } else {
                state.t = projected < -70 ? 2 : projected > 70 ? 0 : 1
                if state.t == 0 { state.turns += 1 }
            }
            state.drag = 0
        }
    }
}

/// Draws the glass for any `t`, so every frame of the grow is one consistent shape (frame, corner and the content's
/// scale all come from the same value).
private struct SheetBody: View, Animatable {
    var t: Double
    var drag: CGFloat
    let screen: CGSize
    let gear: CGRect
    let origin: CGPoint
    let contentShown: Bool
    let onDrag: (CGFloat) -> Void
    let onRelease: (CGFloat, CGFloat) -> Void
    let onCollapse: () -> Void

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(t, drag) }
        set { t = newValue.first; drag = newValue.second }
    }

    // All three in this view's own coordinates (window coordinates minus where this view starts).
    private var gearRect: CGRect {
        gear.offsetBy(dx: -origin.x, dy: -origin.y)
    }
    private var halfRect: CGRect {
        let h = screen.height * 0.5
        return CGRect(x: Theme.sheetInset, y: screen.height - Theme.sheetInset - h, width: screen.width - Theme.sheetInset * 2, height: h)
            .offsetBy(dx: -origin.x, dy: -origin.y)
    }
    private var fullRect: CGRect {
        let top = gear.maxY + 10
        return CGRect(x: Theme.sheetInset, y: top, width: screen.width - Theme.sheetInset * 2, height: screen.height - Theme.sheetInset - top)
            .offsetBy(dx: -origin.x, dy: -origin.y)
    }

    private var rect: CGRect {
        var r: CGRect
        if t <= 1 {
            r = lerp(gearRect, halfRect, CGFloat(max(0, t)))
        } else {
            r = lerp(halfRect, fullRect, CGFloat(min(1, t - 1)))
        }
        // The finger's pull moves the top edge; past the full height it gives less and less.
        var top = r.minY + drag
        if drag < 0, t >= 0.9, top < fullRect.minY {
            let over = fullRect.minY - top
            top = fullRect.minY - (1 - 1 / (over * 0.55 / 120 + 1)) * 120
        }
        r = CGRect(x: r.minX, y: top, width: r.width, height: max(Theme.head, r.maxY - top))
        return r
    }

    private var corner: CGFloat {
        let r = rect
        return t < 1 ? min(r.width, r.height) / 2 * CGFloat(1 - max(0, t)) + Theme.sheetCorner * CGFloat(max(0, t)) : Theme.sheetCorner
    }

    var body: some View {
        let r = rect
        let shape = RoundedRectangle(cornerRadius: min(corner, min(r.width, r.height) / 2), style: .continuous)
        let scale = max(0.05, r.width / halfRect.width)
        ZStack(alignment: .topLeading) {
            if contentShown {
                ScrollView {
                    SettingsContent()
                        .frame(width: halfRect.width)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(t < 1.5)
                // A soft edge where the content passes under the sheet's top and bottom, so nothing is cut off.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { g in g.contentOffset.y + g.contentInsets.top } action: { _, y in
                    if y < -80, t >= 1.5 { onCollapse() }
                }
                .frame(width: halfRect.width, height: max(1, r.height / scale))
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: r.width, height: r.height, alignment: .topLeading)
                .accessibilityElement(children: t >= 1 ? .contain : .ignore)
            }
            if t >= 1.5 {
                // At full height the content scrolls; this strip along the top still pulls the sheet down.
                Color.clear
                    .frame(width: r.width, height: 26)
                    .contentShape(.rect)
                    .gesture(pull)
            }
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .gesture(pull, isEnabled: t >= 0.9 && t < 1.5)
        .glassEffect(.clear, in: shape)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(t > 0.5)
        .accessibilityHidden(t < 0.5)
    }

    private var pull: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { g in onDrag(g.translation.height) }
            .onEnded { g in onRelease(g.translation.height, g.predictedEndTranslation.height) }
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ f: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f,
               width: a.width + (b.width - a.width) * f, height: a.height + (b.height - a.height) * f)
    }
}
