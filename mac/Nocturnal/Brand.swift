import AppKit
import SwiftUI

/// Nocturnal's colours: the green of the app icon and the website.
enum Brand {
    static let mid = Color(red: 0.078, green: 0.424, blue: 0.251)     // #146C40
    static let mint = Color(red: 0.247, green: 0.839, blue: 0.612)    // #3FD69C
    /// The tile gradient, for filled controls on dark backgrounds (the notch island).
    static let gradient = LinearGradient(colors: [mid, Color(red: 0.12, green: 0.6, blue: 0.38)], startPoint: .bottomLeading, endPoint: .topTrailing)
}

/// The app icon's mark: one thin bar (the laptop, shut) and a translucent fan, a 35° sector pivoting on the bar's
/// left end (the lid's swing). `open` is 0…1 (closed…35°); `glow` tints the fan mint.
struct NocturnalMark: View {
    var open: Double = 1
    var glow: Bool = false

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let barH = max(1.5, w / 14)
            let hinge = CGPoint(x: 0, y: size.height - barH)
            let deg = 35 * min(1, max(0, open))
            if deg > 0.5 {
                var fan = Path()
                fan.move(to: hinge)
                fan.addArc(center: hinge, radius: w, startAngle: .degrees(-deg), endAngle: .zero, clockwise: false)
                fan.closeSubpath()
                ctx.fill(fan, with: .color(glow ? Brand.mint.opacity(0.85) : Color.white.opacity(0.38)))
            }
            ctx.fill(Path(CGRect(x: 0, y: size.height - barH, width: w, height: barH)), with: .color(.white))
        }
        .aspectRatio(1 / (1 / 14 + sin(35 * .pi / 180)), contentMode: .fit)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: glow)
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
        NocturnalMark(open: 0.2).frame(width: 60)
        NocturnalMark().frame(width: 60)
        NocturnalMark(glow: true).frame(width: 60)
        Image(nsImage: MenuGlyph.image(.off))
        Image(nsImage: MenuGlyph.image(.watching))
        Image(nsImage: MenuGlyph.image(.holding))
    }
    .padding(30)
    .background(Color.gray)
}
