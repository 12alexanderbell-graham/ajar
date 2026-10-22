import SwiftUI

/// Nocturnal's look, shared by every screen. The rules it follows (from the design book):
/// - The state is the material: the whole screen is green while the computer keeps working, night while it sleeps.
/// - One ink: white, at full strength. No grey text, no low-opacity controls.
/// - Fixed places: the head at the top, the keep-awake band at the bottom, the main circle bottom right. Nothing that
///   appears ever moves what is already on the screen.
/// - Nothing fades: things rise into place, roll, or grow out of what opened them and go back into it.
/// - Corners nest: a sheet 8 in from the screen's 62 pt corner has a 54 pt corner.
enum Theme {
    static let side: CGFloat = 20               // head and bottom stand on the same two side lines
    static let bottom: CGFloat = 20
    static let head: CGFloat = 44               // head circles
    static let band: CGFloat = 56               // the keep-awake band and the main circle
    static let gap: CGFloat = 8
    static let sheetInset: CGFloat = 8
    static let screenCorner: CGFloat = 62
    static var sheetCorner: CGFloat { screenCorner - sheetInset }

    // The palette: night, the greens of the app icon, white ink, and red only for errors and destructive things.
    static let night = Color(red: 0.035, green: 0.047, blue: 0.098)
    static let nightLift = Color(red: 0.086, green: 0.118, blue: 0.247)
    static let nightGlow = Color(red: 0.231, green: 0.298, blue: 0.604)
    static let deep = Color(red: 0.020, green: 0.157, blue: 0.086)
    static let green = Color(red: 0.063, green: 0.400, blue: 0.231)
    static let mint = Color(red: 0.251, green: 0.839, blue: 0.608)
    static let amber = Color(red: 1.0, green: 0.776, blue: 0.282)
    static let red = Color(red: 1.0, green: 0.42, blue: 0.38)

    // One spring family.
    static let chrome = Animation.spring(response: 0.38, dampingFraction: 0.84)
    static let quick = Animation.spring(response: 0.26, dampingFraction: 1)
    static let smooth = Animation.spring(response: 0.44, dampingFraction: 1)
    static let grow = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let rise = Animation.spring(response: 0.55, dampingFraction: 0.86)

    static func freshnessColor(_ k: Computer.Freshness) -> Color {
        switch k {
        case .live: mint
        case .bad: amber
        case .done, .busy, .stale: .white
        }
    }
}

/// Words and blocks arriving on a screen rise 14 pt into place, one after another.
struct Rise: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: shown || reduceMotion ? 0 : 14)
            .blur(radius: shown || reduceMotion ? 0 : 6)
            .onAppear {
                withAnimation(Theme.rise.delay(Double(order) * 0.05)) { shown = true }
            }
    }
}

extension View {
    func rise(_ order: Int = 0) -> some View { modifier(Rise(order: order)) }
}

/// Press: sinks at once (90 ms), comes back softer (260 ms).
struct Press: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.09) : .easeOut(duration: 0.26), value: configuration.isPressed)
    }
}

/// A 44 pt glass circle with one symbol, for the head.
struct HeadCircle: View {
    let symbol: String
    let label: String
    var turns: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .rotationEffect(.degrees(turns * 120))
                .frame(width: Theme.head, height: Theme.head)
                .contentShape(.circle)
        }
        .buttonStyle(Press())
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .circle)
        .animation(Theme.grow, value: turns)
        .accessibilityLabel(label)
    }
}
