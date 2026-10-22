import SwiftUI

/// How long the computer stays awake, as one row of stops from asleep to always awake.
enum Stop: Int, CaseIterable, Identifiable {
    case off, busy, h1, h2, h4, h8, always
    var id: Int { rawValue }

    /// Minutes for the timed stops.
    var minutes: Int? {
        switch self {
        case .h1: 60
        case .h2: 120
        case .h4: 240
        case .h8: 480
        default: nil
        }
    }

    var word: String {
        switch self {
        case .off: "Off"
        case .busy: "When busy"
        case .h1: "For 1 hour"
        case .h2: "For 2 hours"
        case .h4: "For 4 hours"
        case .h8: "For 8 hours"
        case .always: "Always"
        }
    }

    /// The colour of the band under this stop: night at Off, the app's greens towards Always.
    var color: Color {
        switch self {
        case .off: Theme.nightGlow
        case .busy: Color(red: 0.13, green: 0.42, blue: 0.47)
        case .h1: Color(red: 0.10, green: 0.46, blue: 0.33)
        case .h2: Color(red: 0.11, green: 0.54, blue: 0.36)
        case .h4: Color(red: 0.14, green: 0.62, blue: 0.42)
        case .h8: Color(red: 0.18, green: 0.72, blue: 0.50)
        case .always: Theme.mint
        }
    }

    static func nearest(minutes: Double) -> Stop {
        let timed: [Stop] = [.h1, .h2, .h4, .h8]
        return timed.min { abs(log(Double($0.minutes!)) - log(minutes)) < abs(log(Double($1.minutes!)) - log(minutes)) }!
    }
}

/// The keep-awake band: one capsule that is a strip of its stops' colours, with a clear Liquid Glass lens on the
/// chosen one. Drag the lens (it lifts and ticks at every stop) or tap a stop. The choice is sent when the finger
/// lifts; the words above the band say what the lens is on.
struct KeepAwakeBand: View {
    let stop: Stop
    /// The stop under the finger while dragging (nil when not touching), for the words above the band.
    @Binding var hovering: Stop?
    let choose: (Stop) -> Void

    @State private var fingerX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let slot = w / CGFloat(Stop.allCases.count)
            let restX = center(of: stop, slot)
            let x = fingerX.map { min(max($0, slot / 2), w - slot / 2) } ?? restX
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(stops: Stop.allCases.map { .init(color: $0.color, location: (CGFloat($0.rawValue) + 0.5) / CGFloat(Stop.allCases.count)) },
                                         startPoint: .leading, endPoint: .trailing))
                HStack(spacing: 0) {
                    ForEach(Stop.allCases) { s in
                        mark(s)
                            .frame(width: slot, height: Theme.band)
                    }
                }
                Circle()
                    .fill(.clear)
                    .frame(width: Theme.band, height: Theme.band)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .scaleEffect(fingerX == nil ? 1 : 1.18)
                    .offset(x: x - Theme.band / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(.capsule)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if fingerX == nil {
                            withAnimation(Theme.quick) { fingerX = g.location.x }
                        } else {
                            fingerX = g.location.x
                        }
                        let s = nearest(g.location.x, slot)
                        if hovering != s { hovering = s }
                    }
                    .onEnded { g in
                        let s = nearest(g.location.x, slot)
                        withAnimation(Theme.chrome) {
                            fingerX = nil
                            hovering = nil
                        }
                        if s != stop { choose(s) }
                    }
            )
            .animation(Theme.chrome, value: stop)
        }
        .frame(height: Theme.band)
        .sensoryFeedback(.selection, trigger: hovering) { _, new in new != nil }
        .accessibilityElement()
        .accessibilityLabel("Keep awake")
        .accessibilityValue(stop.word)
        .accessibilityIdentifier("band")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if let s = Stop(rawValue: stop.rawValue + 1) { choose(s) }
            case .decrement: if let s = Stop(rawValue: stop.rawValue - 1) { choose(s) }
            @unknown default: break
            }
        }
    }

    private func center(of s: Stop, _ slot: CGFloat) -> CGFloat { slot * (CGFloat(s.rawValue) + 0.5) }

    private func nearest(_ x: CGFloat, _ slot: CGFloat) -> Stop {
        Stop(rawValue: min(Stop.allCases.count - 1, max(0, Int(x / max(slot, 1))))) ?? .busy
    }

    /// Each stop's mark: a symbol at the ends, the hours as numbers in between.
    @ViewBuilder private func mark(_ s: Stop) -> some View {
        switch s {
        case .off: Image(systemName: "moon.fill").font(.system(size: 15, weight: .semibold))
        case .busy: Image(systemName: "sparkle").font(.system(size: 15, weight: .bold))
        case .always: Image(systemName: "infinity").font(.system(size: 15, weight: .bold))
        default: Text("\(s.minutes! / 60)").font(.system(.headline, design: .rounded))
        }
    }
}

#Preview {
    @Previewable @State var stop = Stop.busy
    @Previewable @State var hovering: Stop?
    VStack {
        Text((hovering ?? stop).word).foregroundStyle(.white)
        KeepAwakeBand(stop: stop, hovering: $hovering) { stop = $0 }
    }
    .padding()
    .foregroundStyle(.white)
    .background(Ground(awake: 1))
}
