import SwiftUI

/// Sleep, Wake and Settings: three liquid glass circles that blend into one capsule. Sleep takes a second tap and
/// grows into "Tap to sleep" while it waits for it.
struct CapsuleBar: View {
    let sleep: () -> Void
    let wake: () -> Void
    let settings: () -> Void

    @State private var armed = false
    @State private var disarm: Task<Void, Never>?
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 10) {
                Button {
                    disarm?.cancel()
                    if armed { armed = false; sleep(); return }
                    armed = true
                    disarm = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { armed = false } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.fill")
                        if armed { Text("Tap to sleep").font(.headline).fixedSize() }
                    }
                    .frame(minWidth: Theme.control, minHeight: Theme.control)
                    .padding(.horizontal, armed ? 18 : 0)
                    .contentShape(.capsule)
                }
                .foregroundStyle(armed ? .white : .primary)
                .glassEffect(armed ? .regular.tint(.red).interactive() : .regular.interactive(), in: .capsule)
                .glassEffectID("sleep", in: glass)
                .accessibilityLabel(armed ? "Tap again to sleep" : "Sleep now")

                circle("sun.max.fill", "Wake it for an hour", id: "wake", action: wake)
                circle("slider.horizontal.3", "Settings", id: "settings", action: settings)
            }
            .font(.system(size: 20, weight: .semibold))
            .buttonStyle(.plain)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: armed)
        .sensoryFeedback(.warning, trigger: armed) { _, now in now }
    }

    private func circle(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Theme.control, height: Theme.control)
                .contentShape(.circle)
        }
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(id, in: glass)
        .accessibilityLabel(label)
    }
}

#Preview {
    CapsuleBar(sleep: {}, wake: {}, settings: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}
