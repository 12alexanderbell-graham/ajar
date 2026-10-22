import SwiftUI

/// The whole screen is the computer's state: night while it sleeps, deep green with a mint glow while it keeps
/// working. `awake` runs from 0 (night) to 1 (green) and animates, so a change washes across the screen instead of
/// cutting. The glow drifts too slowly to notice unless you look for it (and not at all with Reduce Motion).
struct Ground: View, Animatable {
    var awake: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: Double {
        get { awake }
        set { awake = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let drift = Float(sin(t / 9) * 0.05)
            let lift = Float(cos(t / 13) * 0.04)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + drift, 0.42 + lift], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: colors,
                smoothsColors: true,
                colorSpace: .perceptual
            )
        }
        .overlay(Grain().blendMode(.overlay))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var colors: [Color] {
        let night = [Theme.nightLift, Theme.night, Theme.nightGlow,
                     Theme.night, Theme.nightLift, Theme.night,
                     Theme.night, Theme.night, Theme.nightLift]
        let green = [Theme.green, Theme.deep, Theme.mint,
                     Theme.deep, Theme.green, Theme.green,
                     Theme.deep, Theme.deep, Theme.green]
        return zip(night, green).map { $0.mix(with: $1, by: awake, in: .perceptual) }
    }
}

/// A fine, fixed grain so the gradient reads as a surface, not a screen fill.
private struct Grain: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(seed: 7)
            let count = Int(size.width * size.height / 90)
            for _ in 0..<count {
                let x = Double(rng.next() % 10_000) / 10_000 * size.width
                let y = Double(rng.next() % 10_000) / 10_000 * size.height
                let light = rng.next() % 2 == 0
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color(light ? .white.opacity(0.10) : .black.opacity(0.12)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#Preview {
    Ground(awake: 1)
}
