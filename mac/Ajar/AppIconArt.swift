import AppKit

/// The app icon, drawn in code so every size comes from one definition.
///
/// Two shapes on an amber tile: one thin solid bar (the laptop, shut) and a translucent fan above it (the arc the
/// lid swept through as it closed). Flat: no lighting, shadows or 3D, which macOS adds itself.
///
/// Geometry: the bar is 1/14 of the mark's width; the fan is a 35° sector with the bar's length as its radius,
/// pivoting on the bar's left end (the hinge). The mark spans 56% of the tile and its bounding box is centred,
/// lifted 2% because the solid bar sits at the bottom and carries most of the weight.
enum AppIconArt {
    static let tileTop = NSColor(srgbRed: 0.976, green: 0.659, blue: 0.239, alpha: 1)     // #F9A83D
    static let tileBottom = NSColor(srgbRed: 0.937, green: 0.502, blue: 0.137, alpha: 1)  // #EF8023
    static let mark = NSColor(srgbRed: 1, green: 0.992, blue: 0.976, alpha: 1)            // warm white
    static let fanAlpha: CGFloat = 0.36
    static let fanDegrees: CGFloat = 35

    static func draw(_ ctx: CGContext) {
        // Apple's macOS grid: an 824 pt tile on a 1024 canvas.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [tileTop.cgColor, tileBottom.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

        let L = 824 * 0.56
        let barH = L / 14
        let a = fanDegrees * .pi / 180
        let height = barH + L * sin(a)
        let left = 512 - L / 2
        let bottom = 512 - height / 2 + 824 * 0.02
        let hinge = CGPoint(x: left, y: bottom + barH)

        let fan = CGMutablePath()
        fan.move(to: hinge)
        fan.addArc(center: hinge, radius: L, startAngle: a, endAngle: 0, clockwise: true)
        fan.closeSubpath()
        ctx.setFillColor(mark.withAlphaComponent(fanAlpha).cgColor)
        ctx.addPath(fan); ctx.fillPath()

        ctx.setFillColor(mark.cgColor)
        ctx.fill(CGRect(x: left, y: bottom, width: L, height: barH))
        ctx.restoreGState()
    }

    static func image(pixels: Int) -> NSImage {
        let s = CGFloat(pixels)
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: s / 1024, y: s / 1024)
            draw(ctx)
            return true
        }
    }

    static func pngData(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            draw(ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
