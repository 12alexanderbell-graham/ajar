import AppKit
import SwiftUI

// Shared building blocks for the panel and Settings (the panel itself is in MenuPanel.swift).

/// A real NSSegmentedControl with equal-width segments that fills the row, so every segmented control
/// in the panel shares the same edges (SwiftUI's segmented Picker sizes to its labels on macOS).
struct EqualSegments<T: Hashable>: NSViewRepresentable {
    let items: [(T, String)]
    @Binding var selection: T

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: items.map(\.1), trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(SegmentTarget.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Never wider than the panel's margins, even when the labels' natural width is a few points more.
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.onChange = pick
        if let i = items.firstIndex(where: { $0.0 == selection }), c.selectedSegment != i { c.selectedSegment = i }
    }

    func makeCoordinator() -> SegmentTarget { SegmentTarget(onChange: pick) }

    private func pick(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = items[index].0
    }
}

/// The segmented control's action target. Not generic (a generic nested coordinator crashed Xcode 26's compiler).
final class SegmentTarget: NSObject {
    var onChange: (Int) -> Void
    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSSegmentedControl) { onChange(sender.selectedSegment) }
}

/// iOS Settings–style coloured rounded-square icon.
struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

struct ListRow<Icon: View, Title: View, Subtitle: View, Trailing: View>: View {
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                title.font(.body).lineLimit(1)
                subtitle.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 32)
    }
}

struct AgentRow: View {
    let session: AgentSession
    let working: Bool
    let engine: Engine
    var sleepsIn: TimeInterval? = nil

    var body: some View {
        ListRow {
            icon
        } title: {
            Text(session.kind.name)
        } subtitle: {
            Text(state).monospacedDigit()
        } trailing: {
            HStack(spacing: 8) {
                if working && !trackOnly { ActivityDot() }
                if session.kind.id.hasPrefix("app:") {
                    let id = String(session.kind.id.dropFirst(4))
                    RemoveButton { engine.watchedApps.removeAll { $0.id == id } }
                } else if !session.kind.isRequest {
                    Menu {
                        Button { engine.toggleTrackOnly(session.kind.id) } label: {
                            if trackOnly { Text("Keep Mac Awake While It Works") } else { Label("Keep Mac Awake While It Works", systemImage: "checkmark") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose whether \(session.kind.name) keeps the Mac awake")
                }
            }
        }
        .opacity(trackOnly ? 0.6 : 1)
    }

    private var trackOnly: Bool { engine.config.trackOnly.contains(session.kind.id) }

    @ViewBuilder private var icon: some View {
        if session.kind.id.hasPrefix("app:") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: String(session.kind.id.dropFirst(4)))).resizable().frame(width: 22, height: 22)
        } else if session.kind == AgentKind.claudeApp,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentKind.claudeAppBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
        } else if session.kind.isRequest {
            IconTile(symbol: "arrow.down.circle.fill", color: .blue)
        } else {
            IconTile(symbol: Self.symbol(for: session.kind.id), color: Self.color(for: session.kind.id))
        }
    }

    static func symbol(for id: String) -> String {
        switch id { case "claude-code": "asterisk"; case "ollama": "cpu"; case "codex": "chevron.left.forwardslash.chevron.right"; default: "terminal.fill" }
    }

    static func color(for id: String) -> Color {
        switch id { case "claude-code": .orange; case "codex": .black; case "gemini": .blue; case "ollama": .gray; default: .indigo }
    }

    private var state: String {
        var parts: [String] = []
        if session.kind.isRequest {
            parts.append(session.detail.map(Self.tidy) ?? "Asked to stay awake")
        } else if session.state == .waiting && working {
            parts.append("Waiting for you")
        } else if working {
            parts.append(session.kind.isAI ? "Working" : "Busy")
            if session.watts >= 0.05 { parts.append(String(format: "%.1f W", session.watts)) }
        } else if session.lastActive == .distantPast {
            parts.append("Idle")
        } else {
            let m = Int(Date().timeIntervalSince(session.lastActive) / 60)
            if session.state == .finished { parts.append(m < 1 ? "Finished just now" : "Finished \(m) min ago") }
            else { parts.append(m < 1 ? "Idle just now" : "Idle \(m) min") }
            if let s = sleepsIn { parts.append("sleep in \(PanelFormat.minutes(s))") }
        }
        if let p = session.project { parts.append(p) }
        if trackOnly { parts.append("doesn't keep awake") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "com.apple.", with: "").replacingOccurrences(of: "_", with: " ")
    }
}

struct ActivityDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

struct RemoveButton: View {
    var action: () -> Void
    var body: some View {
        Button { action() } label: {
            Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

struct EnergyRow: View {
    let app: AppUsage
    let engine: Engine

    var body: some View {
        ListRow {
            Image(nsImage: EnergySampler.icon(for: app)).resizable().frame(width: 22, height: 22)
        } title: {
            Text(app.name)
        } subtitle: {
            let closed = engine.closedWatts(for: app)
            Text(abs(closed - app.watts) < 0.05
                 ? "\(PanelFormat.w(app.watts)) · unchanged closed"
                 : "\(PanelFormat.w(app.watts)) → \(PanelFormat.w(closed)) closed").monospacedDigit()
        } trailing: {
            if engine.isProtected(app) {
                Text("Kept running").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let id = app.bundleID {
                Menu {
                    ForEach(AppRule.allCases, id: \.self) { r in
                        Button { engine.setRule(r, for: id) } label: {
                            if engine.rule(for: id) == r { Label(r.menuTitle, systemImage: "checkmark") } else { Text(r.menuTitle) }
                        }
                    }
                } label: {
                    Text(engine.rule(for: id).label).font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

