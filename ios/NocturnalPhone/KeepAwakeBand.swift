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

    static func nearest(minutes: Double) -> Stop {
        let timed: [Stop] = [.h1, .h2, .h4, .h8]
        return timed.min { abs(log(Double($0.minutes!)) - log(minutes)) < abs(log(Double($1.minutes!)) - log(minutes)) }!
    }
}

/// The keep-awake control: Apple's own stepped slider, so the thumb is the system's Liquid Glass (it turns to glass
/// while it's held and settles back when let go), with a tick and a short mark at every stop. The choice is sent
/// when the finger lifts; while dragging, the words above say where it would land.
struct KeepAwakeBand: View {
    let stop: Stop
    /// The stop under the thumb while dragging (nil when not touching), for the words above.
    @Binding var hovering: Stop?
    let choose: (Stop) -> Void

    @State private var value: Double = 1
    @State private var dragging = false

    var body: some View {
        Slider(value: $value, in: 0...Double(Stop.allCases.count - 1), step: 1) {
            Text("Keep awake")
        } minimumValueLabel: {
            Image(systemName: "moon.fill").font(.system(size: 15, weight: .semibold)).accessibilityLabel("Off")
        } maximumValueLabel: {
            Image(systemName: "infinity").font(.system(size: 15, weight: .bold)).accessibilityLabel("Always")
        } tick: { v in
            SliderTick(v)
        } onEditingChanged: { editing in
            dragging = editing
            if editing {
                hovering = Stop(rawValue: Int(value.rounded()))
            } else {
                let s = Stop(rawValue: Int(value.rounded())) ?? .busy
                hovering = nil
                if s != stop { choose(s) }
            }
        }
        .tint(Theme.mint)
        .onChange(of: value) { _, v in if dragging { hovering = Stop(rawValue: Int(v.rounded())) } }
        .onChange(of: stop, initial: true) { _, s in
            // The computer's answer (or an Undo) moves the thumb, but never while a finger is on it.
            if !dragging { withAnimation(Theme.chrome) { value = Double(s.rawValue) } }
        }
        .sensoryFeedback(.selection, trigger: Int(value.rounded()))
        .accessibilityValue(stop.word)
        .accessibilityIdentifier("band")
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
    .background(Ground(awake: 1))
}
