import SwiftUI

/// Off / When Busy / Always. A liquid glass thumb that follows the finger, stretches while it moves and settles
/// with a small overshoot. Off with the lid shut takes a second tap: a sleeping computer can't hear the phone.
struct ModeSlider: View {
    static let modes = ["off", "auto", "on"]
    static let labels = ["off": "Off", "auto": "When Busy", "on": "Always"]

    let mode: String
    let needsConfirmForOff: Bool
    let choose: (String) -> Void

    @State private var dragX: CGFloat?
    @State private var armedOff = false
    @State private var disarm: Task<Void, Never>?

    private var index: Int { armedOff ? 0 : Self.modes.firstIndex(of: mode) ?? 1 }

    var body: some View {
        GeometryReader { geo in
            let segment = (geo.size.width - Theme.inset * 2) / 3
            let restX = CGFloat(index) * segment
            let x = dragX ?? restX
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Color.clear
                    .frame(width: segment, height: Theme.control - Theme.inset * 2)
                    .glassEffect(.regular.tint(armedOff ? .red : .accentColor).interactive(), in: .capsule)
                    .scaleEffect(x: dragX == nil ? 1 : 1.08, y: dragX == nil ? 1 : 0.92)
                    .offset(x: Theme.inset + x)
                HStack(spacing: 0) {
                    ForEach(Array(Self.modes.enumerated()), id: \.element) { i, m in
                        Button { tap(m) } label: {
                            Text(i == 0 && armedOff ? "Tap again" : Self.labels[m]!)
                                .font(.headline)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == nearest(x, segment) ? .white : .primary)
                        .accessibilityAddTraits(i == index ? .isSelected : [])
                    }
                }
                .padding(Theme.inset)
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { g in dragX = min(max(0, restX + g.translation.width), segment * 2) }
                    .onEnded { g in
                        let end = min(max(0, restX + g.predictedEndTranslation.width * 0.4 + g.translation.width * 0.6), segment * 2)
                        let m = Self.modes[nearest(end, segment)]
                        dragX = nil
                        if m != mode { tap(m) }
                    }
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.66), value: index)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragX == nil)
        }
        .frame(height: Theme.control)
        .sensoryFeedback(.selection, trigger: index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep awake")
    }

    private func nearest(_ x: CGFloat, _ segment: CGFloat) -> Int {
        min(2, max(0, Int((x / max(segment, 1)).rounded())))
    }

    private func tap(_ m: String) {
        disarm?.cancel()
        if m == "off", needsConfirmForOff, !armedOff, mode != "off" {
            armedOff = true
            disarm = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { armedOff = false } }
            return
        }
        armedOff = false
        if m != mode { choose(m) }
    }
}

#Preview {
    @Previewable @State var mode = "auto"
    ModeSlider(mode: mode, needsConfirmForOff: true) { mode = $0 }
        .padding()
}
