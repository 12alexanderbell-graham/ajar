import AppKit

/// The app icon, drawn in code so every size comes from one definition.
///
/// The tile is Nocturnal's green: deep forest green in the lower left, opening to a mint glow in the upper right, with a
/// fine film grain (the same look as the brand's banner). The mark is white: one thin bar (the laptop, shut) and a
/// translucent fan above it (the arc the lid swept through as it closed).
///
/// Geometry: the bar is 1/14 of the mark's width; the fan is a 35° sector with the bar's length as its radius,
/// pivoting on the bar's left end (the hinge). The mark spans 56% of the tile and its bounding box is centred,
/// lifted 2% because the solid bar sits at the bottom and carries most of the weight.
enum AppIconArt {
    static let deep = NSColor(srgbRed: 0.031, green: 0.204, blue: 0.102, alpha: 1)   // #08341A
    static let mid = NSColor(srgbRed: 0.078, green: 0.424, blue: 0.251, alpha: 1)    // #146C40
    static let mint = NSColor(srgbRed: 0.247, green: 0.839, blue: 0.612, alpha: 1)   // #3FD69C
    static let mark = NSColor.white
    static let fanAlpha: CGFloat = 0.38
    static let fanDegrees: CGFloat = 35

    /// `square`: the tile fills the whole canvas with square corners (iOS home-screen and web icons, where the
    /// system rounds the corners itself).
    static func draw(_ ctx: CGContext, grain: Bool = true, square: Bool = false) {
        // Apple's macOS grid: an 824 pt tile on a 1024 canvas.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = square ? CGPath(rect: tile, transform: nil) : CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        if square { ctx.scaleBy(x: 1024 / 824, y: 1024 / 824); ctx.translateBy(x: -100, y: -100) }
        ctx.addPath(tilePath); ctx.clip()

        // Base: deep (lower left) to mid (upper right).
        let base = CGGradient(colorsSpace: space, colors: [deep.cgColor, mid.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Mint glow, upper right, with a soft quadratic falloff.
        let stops: [CGFloat] = stride(from: 0, through: 1, by: 0.125).map { $0 }
        let glowColors = stops.map { l in mint.withAlphaComponent(pow(1 - l, 2) * 0.95).cgColor }
        let glow = CGGradient(colorsSpace: space, colors: glowColors as CFArray, locations: stops)!
        let centre = CGPoint(x: 1024 * 0.86, y: 1024 * 0.82)
        ctx.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 1024 * 0.75, options: [])

        if grain, let noise = grainImage { ctx.draw(noise, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }

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

    /// Film grain: each pixel lightened or darkened by a few percent, from a fixed seed so the icon never changes.
    private static let grainImage: CGImage? = {
        let n = 1024
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var s: UInt32 = 0x9E3779B9
        for i in 0..<(n * n) {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            let u = Double(s) / Double(UInt32.max) * 2 - 1        // −1…1
            let v = Double(s % 997) / 996 * 2 - 1
            let g = (u + v) / 2                                   // triangular, centred on 0
            let alpha = UInt8(min(255, abs(g) * 0.11 * 255))
            let c: UInt8 = g >= 0 ? alpha : 0                     // premultiplied white, or black
            px[i * 4] = c; px[i * 4 + 1] = c; px[i * 4 + 2] = c; px[i * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    static func image(pixels: Int) -> NSImage {
        let s = CGFloat(pixels)
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: s / 1024, y: s / 1024)
            draw(ctx, grain: pixels >= 128)
            return true
        }
    }

    static func pngData(pixels: Int, square: Bool = false) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            draw(ctx, grain: pixels >= 128, square: square)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
