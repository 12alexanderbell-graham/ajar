import SwiftUI

/// Nocturnal's look, shared by every screen. Rules: nothing fades, numbers count up, no small grey text,
/// few icons, 44 pt targets, and corner radii that nest (an inner radius is the outer one minus the gap).
enum Theme {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 28
    static let control: CGFloat = 56            // slider and capsule height
    static let inset: CGFloat = 4               // slider thumb inset: thumb radius = 28 − 4

    /// The status card while it keeps the computer working: deep green with a mint glow, as on the Mac and the icon.
    static let keepsGradient = ZStack {
        LinearGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.10), Color(red: 0.08, green: 0.42, blue: 0.25)],
                       startPoint: .bottomLeading, endPoint: .topTrailing)
        RadialGradient(colors: [Color(red: 0.25, green: 0.84, blue: 0.61).opacity(0.9), .clear],
                       center: UnitPoint(x: 0.92, y: 0), startRadius: 0, endRadius: 320)
        RadialGradient(colors: [Color(red: 0.13, green: 0.72, blue: 0.40).opacity(0.45), .clear],
                       center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: 240)
    }

    static func freshnessColor(_ k: Computer.Freshness) -> Color {
        switch k {
        case .live: .green
        case .done, .busy: .accentColor
        case .bad: .orange
        case .stale: .secondary
        }
    }
}
