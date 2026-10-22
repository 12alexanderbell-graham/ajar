import SwiftUI

@main
struct NocturnalPhoneApp: App {
    @State private var computer = Computer()

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(computer)
                .preferredColorScheme(.dark)   // the ground is always deep green or night; the ink is white
        }
    }
}

/// One ground under everything, so moving from pairing to the computer (or the demo) is the same green carrying on,
/// then following the band and washing to night when the computer sleeps.
private struct Root: View {
    @Environment(Computer.self) private var computer

    var body: some View {
        ZStack {
            // Slow when the computer changes state, quick while a finger drags the band.
            Ground(awake: computer.groundLevel)
                .animation(.smooth(duration: computer.hovering == nil ? 1.1 : 0.35), value: computer.groundLevel)
            if computer.isPaired {
                HomeView()
                    .transition(.move(edge: .bottom))
            } else {
                PairView()
                    .transition(.move(edge: .top))
            }
        }
        .animation(Theme.grow, value: computer.isPaired)
    }
}
