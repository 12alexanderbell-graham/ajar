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
/// then washing to night if the computer sleeps.
private struct Root: View {
    @Environment(Computer.self) private var computer

    var body: some View {
        ZStack {
            Ground(awake: computer.isPaired ? (computer.keepsWorking ? 1 : 0) : 1)
                .animation(.smooth(duration: 1.1), value: computer.isPaired ? computer.keepsWorking : true)
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
