import SwiftUI

/// The one screen: the computer's name and how fresh the news is, the status card, the keep-awake slider, and the
/// capsule. Settings rise in a sheet that stops at a quarter and half of the screen.
struct HomeView: View {
    @Environment(Computer.self) private var computer
    @Environment(\.scenePhase) private var phase
    @State private var settingsOpen = false
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let p = computer.panel
            VStack(alignment: .leading, spacing: 0) {
                header(context.date)
                if let m = computer.message {
                    Text(m)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
                        .padding(.bottom, 14)
                }
                StatusCard(headline: computer.headline, line: computer.line, warnings: p?.warnings ?? [],
                           keeps: computer.keepsWorking, numbers: p?.figures)
                    .frame(minHeight: 230, maxHeight: 400)
                    .layoutPriority(1)
                Spacer(minLength: 16)
                ModeSlider(mode: p?.mode ?? "auto", needsConfirmForOff: p?.lidClosed ?? false) { m in
                    Task { await computer.change("mode", ["mode": m]) { $0.mode = m } }
                }
                if p?.mode == "on" { timers.padding(.top, 12) }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, Theme.control + 40)
            .onChange(of: context.date) { _, now in if phase == .active { computer.tick(now) } }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            CapsuleBar(
                sleep: { Task { await computer.send("sleep_now") } },
                wake: { Task { await computer.wake() } },
                settings: { detent = .medium; settingsOpen = true }
            )
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $settingsOpen) {
            SettingsSheet()
                .presentationDetents([.fraction(0.25), .medium], selection: $detent)
                .presentationContentInteraction(.scrolls)
        }
        // Only a real trip to the background closes the stream: a glance at Notification Center (inactive) doesn't.
        .onChange(of: phase, initial: true) { old, now in
            if now == .active, old != .inactive || !computer.listening { computer.appeared() }
            if now == .background { computer.disappeared() }
        }
    }

    private func header(_ now: Date) -> some View {
        let fresh = computer.freshness(at: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text(computer.panel?.host ?? "Your computer")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .lineLimit(2)
            HStack(spacing: 8) {
                Circle()
                    .fill(fresh.kind == .busy ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.freshnessColor(fresh.kind)))
                    .strokeBorder(Theme.freshnessColor(fresh.kind), lineWidth: fresh.kind == .busy ? 2 : 0)
                    .frame(width: 9, height: 9)
                Text(fresh.text)
                    .foregroundStyle(Theme.freshnessColor(fresh.kind))
                    .contentTransition(.interpolate)
            }
            .animation(.smooth, value: fresh.text)
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var timers: some View {
        HStack(spacing: 8) {
            Button("1 hour") { Task { await computer.send("mode", ["mode": "always", "minutes": 60]) } }
            Button("4 hours") { Task { await computer.send("mode", ["mode": "always", "minutes": 240]) } }
            Button("Until 7:00") { Task { await computer.send("mode", ["mode": "always", "until_hour": 7]) } }
        }
        .font(.headline)
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

#Preview {
    HomeView().environment(Computer.preview)
}
