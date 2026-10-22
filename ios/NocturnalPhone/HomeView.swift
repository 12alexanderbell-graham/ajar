import SwiftUI

/// The one screen. The ground is the state (green while the computer keeps working, night while it sleeps). Top: the
/// head (Exit Demo on the left in the demo, the gear on the right) and a slot for notices. Middle: which computer,
/// how fresh the news is, what it's doing, its numbers and what the lid-shut time has saved. Bottom: what the band is
/// set to (or the Undo), the keep-awake band, and the main circle (sleep now, or wake it).
/// The settings sheet grows out of the gear and pours back into it.
struct HomeView: View {
    @Environment(Computer.self) private var computer
    @Environment(\.scenePhase) private var phase
    @State private var hovering: Stop?
    @State private var sheet = SheetState()
    @State private var gearFrame = CGRect.zero

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            // Everything below is laid out in whole-screen points, safe areas included, so the sheet, the gear and
            // the head are measured from the same origin.
            let size = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        content(context.date, size: size, safe: safe)
                            .frame(width: size.width, height: size.height)
                        SettingsGlass(state: $sheet,
                                      screen: CGSize(width: size.width, height: geo.frame(in: .global).maxY + safe.bottom),
                                      gear: gearFrame)
                        head
                            .padding(.top, safe.top + 2)
                            .padding(.horizontal, Theme.side)
                            .frame(width: size.width, alignment: .top)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
                .onChange(of: context.date) { _, now in if phase == .active { computer.tick(now) } }
            }
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        // Only a real trip to the background closes the stream: a glance at Notification Center (inactive) doesn't.
        .onChange(of: phase, initial: true) { old, now in
            if now == .active, old != .inactive || !computer.listening { computer.appeared() }
            if now == .background { computer.disappeared() }
        }
    }

    // MARK: Layout

    private func content(_ now: Date, size: CGSize, safe: EdgeInsets) -> some View {
        let open = sheet.progress
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: Theme.head)
                .padding(.top, safe.top + 2)
            NoticeSlot(notice: notice)
                .frame(height: 52)
                .padding(.top, 8)
            Spacer(minLength: 8)
            hero(now)
                // Words never sit under the sheet: they step up and back while it rises.
                .scaleEffect(1 - 0.08 * open, anchor: .top)
                .offset(y: -size.height * 0.16 * open - size.height * 0.6 * max(0, sheet.t - 1))
            Spacer(minLength: 8)
            figures
                .offset(y: size.height * 0.5 * open)
            Spacer(minLength: 8)
            bottom
                .offset(y: size.height * 0.5 * open)
                .padding(.bottom, max(safe.bottom, 8) + Theme.bottom - 14)
        }
        .padding(.horizontal, Theme.side)
    }

    private var head: some View {
        HStack {
            if computer.isDemo {
                Button { withAnimation(Theme.smooth) { computer.forget() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        Text("Exit Demo").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: Theme.head)
                    .contentShape(.capsule)
                }
                .buttonStyle(Press())
                .glassEffect(.clear.interactive(), in: .capsule)
                .accessibilityIdentifier("exitDemo")
            }
            Spacer()
            // The sheet's glass pours out of the gear's glass (both sit in one glass container).
            HeadCircle(symbol: "gearshape.fill", label: sheet.isOpen ? "Close settings" : "Settings", turns: sheet.turns) {
                sheet.toggle()
            }
            .accessibilityIdentifier("settings")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { gearFrame = $0 }
        }
        .frame(height: Theme.head)
    }

    private func hero(_ now: Date) -> some View {
        let fresh = computer.freshness(at: now)
        return VStack(spacing: 0) {
            Text(computer.panel?.host ?? "Your computer")
                .font(.headline)
                .lineLimit(1)
                .rise(0)
            Button { Task { await computer.refresh() } } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(fresh.kind == .busy ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.freshnessColor(fresh.kind)))
                        .strokeBorder(Theme.freshnessColor(fresh.kind), lineWidth: fresh.kind == .busy ? 2 : 0)
                        .frame(width: 8, height: 8)
                    Text(fresh.text)
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.interpolate)
                }
                .foregroundStyle(Theme.freshnessColor(fresh.kind))
                .frame(minHeight: 32)
                .padding(.horizontal, 10)
                .contentShape(.capsule)
            }
            .buttonStyle(Press())
            .animation(Theme.smooth, value: fresh.text)
            .accessibilityHint("Refreshes")
            .rise(1)

            Text(computer.headline)
                .font(.system(.largeTitle, weight: .bold))
                .multilineTextAlignment(.center)
                .contentTransition(.interpolate)
                .animation(Theme.smooth, value: computer.headline)
                .padding(.top, 18)
                .accessibilityIdentifier("headline")
                .rise(2)
            Text(computer.line)
                .font(.body)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .contentTransition(.interpolate)
                .animation(Theme.smooth, value: computer.line)
                .padding(.top, 8)
                .padding(.horizontal, 12)
                .rise(3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Battery, power draw and hours left with the lid shut; then what the lid-shut time is worth.
    private var figures: some View {
        let p = computer.panel
        let n = p?.figures
        return VStack(spacing: 18) {
            HStack(spacing: 0) {
                if let n {
                    Figure(value: Double(n.pct), digits: 0, unit: "%",
                           spoken: n.charging ? "Battery, charging" : n.plugged ? "Battery, plugged in" : "Battery")
                    Figure(value: n.w, digits: (n.w ?? 0) < 10 ? 1 : 0, unit: "W", spoken: "Using now")
                    Figure(value: n.h, digits: (n.h ?? 0) < 10 ? 1 : 0, unit: "h",
                           spoken: n.plugged ? "Hours on battery with the lid shut" : "Hours left with the lid shut")
                }
            }
            .frame(height: 44)
            Text(savingsLine(p))
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .contentTransition(.interpolate)
        }
        .rise(4)
    }

    /// Two lines: the week so far ("6 h 20 min working, lid shut" / "4 sessions · ≈38 Wh saved"), or what being shut
    /// saves right now.
    private func savingsLine(_ p: Panel?) -> String {
        guard let p else { return "" }
        if let t = p.weekTitle { return "This week: " + t + (p.weekLine.map { "\n" + $0 } ?? "") }
        return p.drawLine ?? ""
    }

    private var bottom: some View {
        VStack(spacing: 14) {
            ReadoutSlot(words: (hovering?.word) ?? computer.stopWords)
                .frame(height: 44)
            HStack(spacing: Theme.gap) {
                KeepAwakeBand(stop: computer.held == .off ? .off : computer.stop, hovering: $hovering) { s in
                    if s == .off, computer.panel?.lidClosed == true, computer.panel?.mode != "off" {
                        computer.hold(.off)     // with the lid shut, Off sleeps it: Undo for a few seconds
                    } else {
                        if computer.held == .off { computer.undoHeld() }
                        Task { await computer.choose(s) }
                    }
                }
                mainCircle
            }
        }
        .rise(5)
    }

    /// Sleep now while it's awake (with an Undo), wake it for an hour while it's asleep.
    private var mainCircle: some View {
        let asleep = computer.noAnswer
        return Button {
            if asleep { Task { await computer.wake() } } else { computer.hold(.sleep) }
        } label: {
            Image(systemName: asleep ? "sun.max.fill" : "moon.zzz.fill")
                .font(.system(size: 20, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Theme.band, height: Theme.band)
                .contentShape(.circle)
        }
        .buttonStyle(Press())
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(asleep ? "Wake it for an hour" : "Sleep now")
        .accessibilityIdentifier("main")
    }

    private var notice: Notice? {
        let p = computer.panel
        if let m = computer.message { return Notice(symbol: "exclamationmark.circle.fill", text: m, color: Theme.red) }
        if let w = p?.warnings.first { return Notice(symbol: "exclamationmark.triangle.fill", text: w, color: Theme.amber) }
        if let t = p?.powerTest { return Notice(symbol: "gauge.with.dots.needle.33percent", text: t, color: .white) }
        if p?.autoApprove == true { return Notice(symbol: "checkmark.shield.fill", text: "Approve everything is on", color: Theme.amber) }
        return nil
    }
}

// MARK: Pieces

/// One number with its unit; rolls to new values. The unit says what it is; VoiceOver hears the full words.
private struct Figure: View {
    let value: Double?
    let digits: Int
    let unit: String
    let spoken: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value {
                Text(value, format: .number.precision(.fractionLength(digits)))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(Theme.smooth, value: value)
            } else {
                Text("–").font(.system(.title, design: .rounded, weight: .semibold))
            }
            Text(unit).font(.system(.headline, design: .rounded))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(value.map { "\($0.formatted(.number.precision(.fractionLength(digits)))) \(unit)" } ?? "unknown")
    }
}

struct Notice: Equatable {
    let symbol: String
    let text: String
    let color: Color
}

/// The place under the head where notices appear. It has its own height, so nothing below moves when one comes.
private struct NoticeSlot: View {
    let notice: Notice?

    var body: some View {
        ZStack {
            if let n = notice {
                HStack(spacing: 8) {
                    Image(systemName: n.symbol).foregroundStyle(n.color)
                    Text(n.text).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .glassEffect(.clear, in: .capsule)
                .transition(.offset(y: -30).combined(with: .scale(scale: 0.9, anchor: .top)))
                .id(n.text)
                .accessibilityIdentifier("notice")
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.chrome, value: notice)
    }
}

/// What the band is set to, or the Undo after Sleep or Off. Same place, same height.
private struct ReadoutSlot: View {
    @Environment(Computer.self) private var computer
    let words: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            ZStack {
                if let held = computer.held, let until = computer.heldUntil {
                    let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                    HStack(spacing: 12) {
                        Text(held == .sleep ? "Sleeps in \(left) s" : "Off, it sleeps in \(left) s")
                            .font(.headline)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Theme.quick, value: left)
                        Button("Undo") { withAnimation(Theme.chrome) { computer.undoHeld() } }
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .glassEffect(.clear.interactive(), in: .capsule)
                            .buttonStyle(Press())
                            .accessibilityIdentifier("undo")
                    }
                    .transition(.offset(y: 16).combined(with: .scale(scale: 0.94)))
                } else {
                    Text(words)
                        .font(.headline)
                        .contentTransition(.interpolate)
                        .animation(Theme.quick, value: words)
                        .transition(.offset(y: -16).combined(with: .scale(scale: 0.94)))
                        .accessibilityIdentifier("readout")
                }
            }
            .frame(maxWidth: .infinity)
            .animation(Theme.chrome, value: computer.held)
        }
        .sensoryFeedback(.warning, trigger: computer.held) { _, new in new != nil }
    }
}

#Preview {
    HomeView().environment(Computer.preview).background(Ground(awake: 1))
}
