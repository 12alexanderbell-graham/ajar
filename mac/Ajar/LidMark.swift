import AppKit
import SwiftUI

enum Theme {
    static let paper = Color(red: 0.984, green: 0.976, blue: 0.961)       // warm off-white
    static let card = Color.white
    static let ink = Color(red: 0.11, green: 0.106, blue: 0.098)
    static let muted = Color(red: 0.47, green: 0.45, blue: 0.42)
    static let faint = Color(red: 0.11, green: 0.106, blue: 0.098).opacity(0.07)
    static let hairline = Color(red: 0.11, green: 0.106, blue: 0.098).opacity(0.09)
    static let glow = Color(red: 0.95, green: 0.63, blue: 0.20)            // the light through the gap
    static let glowSoft = Color(red: 0.99, green: 0.93, blue: 0.82)
    static let warn = Color(red: 0.80, green: 0.33, blue: 0.20)
}

/// The mark: a laptop seen side-on, lid open a crack, light spilling out of the gap.
/// `open` is 0…1 (closed…ajar); `light` fades the wedge in.
struct LidMark: View {
    var open: Double
    var light: Double
    var lineWidth: CGFloat = 2.2
    var color: Color = Theme.ink

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let hinge = CGPoint(x: w * 0.16, y: h * 0.70)
            let baseEnd = CGPoint(x: w * 0.86, y: h * 0.70)
            let length = w * 0.70
            let angle = (4 + open * 26) * .pi / 180
            let tip = CGPoint(x: hinge.x + cos(angle) * length, y: hinge.y - sin(angle) * length)

            if light > 0 {
                var wedge = Path()
                wedge.move(to: hinge)
                wedge.addLine(to: tip)
                wedge.addLine(to: baseEnd)
                wedge.closeSubpath()
                ctx.fill(wedge, with: .linearGradient(
                    Gradient(colors: [Theme.glow.opacity(0.95 * light), Theme.glow.opacity(0.25 * light)]),
                    startPoint: hinge, endPoint: CGPoint(x: baseEnd.x, y: tip.y)))
            }
            var lid = Path(); lid.move(to: hinge); lid.addLine(to: tip)
            var base = Path(); base.move(to: hinge); base.addLine(to: baseEnd)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter)
            ctx.stroke(base, with: .color(color), style: style)
            ctx.stroke(lid, with: .color(color), style: style)
        }
    }
}

/// Menu bar glyphs, drawn as template images so they follow the menu bar's colour.
enum MenuGlyph {
    enum State { case off, watching, holding }

    /// The app icon's mark at menu bar size: a thin solid bar (the laptop) and a translucent fan (the lid's swing).
    /// Off: the bar alone, dimmed. Watching: a faint fan. Holding the Mac awake: a stronger fan.
    /// `lidAngle` (live lid icon): the fan opens and closes with the real lid, 0–120° mapped to 0–35° so the
    /// icon keeps the same footprint at any angle.
    static func image(_ state: State, lidAngle: Double? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 12)
        let img = NSImage(size: size, flipped: false) { _ in
            let left: CGFloat = 1.5, length: CGFloat = 15, barH: CGFloat = 1.6, bottom: CGFloat = 1.5
            let hinge = NSPoint(x: left, y: bottom + barH)
            let deg: CGFloat = if let a = lidAngle { CGFloat(min(120, max(0, a)) / 120) * 35 } else { state == .off ? 0 : 35 }

            if deg > 1 {
                let fan = NSBezierPath()
                fan.move(to: hinge)
                fan.appendArc(withCenter: hinge, radius: length, startAngle: deg, endAngle: 0, clockwise: true)
                fan.close()
                NSColor.black.withAlphaComponent(state == .holding ? 0.5 : 0.28).setFill()
                fan.fill()
            }
            NSColor.black.withAlphaComponent(state == .off ? 0.55 : 1).setFill()
            NSRect(x: left, y: bottom, width: length, height: barH).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

#Preview("Mark") {
    HStack(spacing: 24) {
        LidMark(open: 0, light: 0).frame(width: 80, height: 60)
        LidMark(open: 0.8, light: 0).frame(width: 80, height: 60)
        LidMark(open: 1, light: 1).frame(width: 80, height: 60)
        Image(nsImage: MenuGlyph.image(.off))
        Image(nsImage: MenuGlyph.image(.watching))
        Image(nsImage: MenuGlyph.image(.holding))
    }
    .padding(30)
    .background(Theme.paper)
}
