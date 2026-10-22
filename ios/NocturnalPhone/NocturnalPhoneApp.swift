import SwiftUI

@main
struct NocturnalPhoneApp: App {
    @State private var computer = Computer()

    var body: some Scene {
        WindowGroup {
            Group {
                if computer.isPaired { HomeView() } else { PairView() }
            }
            .environment(computer)
            .animation(.smooth, value: computer.isPaired)
        }
    }
}
