import SwiftUI

/// What the computer is doing: green while it keeps working, plain while it sleeps, with three numbers that count
/// to their new values.
struct StatusCard: View {
    let headline: String
    let line: String
    let warnings: [String]
    let keeps: Bool
    let numbers: Panel.Numbers?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.7)
                .contentTransition(.interpolate)
            Text(line)
                .font(.body)
                .foregroundStyle(keeps ? Color.white.opacity(0.86) : .secondary)
            ForEach(warnings, id: \.self) { w in
                Text(w).font(.callout.weight(.semibold)).foregroundStyle(keeps ? .white : .orange).padding(.top, 4)
            }
            Spacer(minLength: 26)
            if let n = numbers {
                HStack(alignment: .top, spacing: 8) {
                    Figure(value: Double(n.pct), digits: 0, unit: "%",
                           caption: n.charging ? "charging" : n.plugged ? "plugged in" : "battery", keeps: keeps)
                    if let w = n.w {
                        Figure(value: w, digits: w < 10 ? 1 : 0, unit: "W", caption: "using now", keeps: keeps)
                    }
                    if let h = n.h {
                        Figure(value: h, digits: h < 10 ? 1 : 0, unit: "h", caption: n.plugged ? "if unplugged" : "left, lid shut", keeps: keeps)
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(keeps ? .white : .primary)
        .background {
            if keeps { Theme.keepsGradient } else { Color(.secondarySystemGroupedBackground) }
        }
        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .animation(.smooth(duration: 0.35), value: keeps)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status")
    }
}

/// One number: big tabular digits that roll to the new value, the unit beside it, a word under it.
private struct Figure: View {
    let value: Double
    let digits: Int
    let unit: String
    let caption: String
    let keeps: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value, format: .number.precision(.fractionLength(digits)))
                    .font(.system(size: 38, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(.snappy(duration: 0.7), value: value)
                Text(unit).font(.system(size: 21, weight: .medium))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(keeps ? Color.white.opacity(0.8) : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    VStack(spacing: 16) {
        StatusCard(headline: "Keeps working", line: "Claude Code is working", warnings: [], keeps: true,
                   numbers: .init(pct: 82, w: 3.1, h: 19.2))
        StatusCard(headline: "Sleeps normally", line: "Nocturnal is off", warnings: [], keeps: false,
                   numbers: .init(pct: 100, h: 9.5, plugged: true))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
