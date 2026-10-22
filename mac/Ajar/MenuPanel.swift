import AppKit
import SwiftUI

/// The menu bar panel, two tabs:
///  • Now: the mode (Off / When Busy / Always) with one sentence, what closing the lid does right now, the battery.
///  • Apps: what keeps the Mac awake, what closing the lid slows or pauses, the battery limit, per-app rules.
/// Everything else is in Settings.
struct PanelView: View {
    enum Tab: String { case now, apps }

    @Bindable var engine: Engine
    var actions = PanelActions(openSettings: {}, quit: { NSApp.terminate(nil) })
    /// Opens on this tab (previews and screenshots); otherwise the last one used.
    var showTab: Tab? = nil
    @AppStorage("panelTab") private var tab: Tab = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.setupReady {
                header
                switch showTab ?? tab {
                case .now: NowTab(engine: engine)
                case .apps: AppsView(engine: engine, openAgentSettings: { UIState.shared.settingsTab = .ai; actions.openSettings() })
                }
            } else {
                SetupView(engine: engine)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ForEach([Tab.now, Tab.apps], id: \.self) { t in
                Button { tab = t } label: {
                    Text(t == .now ? "Now" : "Apps")
                        .font(.headline)
                        .foregroundStyle((showTab ?? tab) == t ? .primary : .tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { UIState.shared.settingsTab = .phone; actions.openSettings() } label: {
                Image(systemName: "iphone").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Phone: pair your phone, see it here")
            Button { actions.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
        }
    }
}

// MARK: - Now

private struct NowTab: View {
    @Bindable var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EqualSegments(items: Mode.allCases.map { ($0, $0.label) },
                          selection: Binding(get: { engine.mode }, set: { m in
                              if m == .on { engine.stayAwake(for: nil) } else { engine.mode = m }
                          }))
                .help(engine.modeLine)

            Divider()
            outcome

            if let w = engine.warning {
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !engine.unrestored.isEmpty {
                notice("Couldn't put back \(engine.unrestored.joined(separator: ", ")) yet. Nocturnal keeps trying.", button: "Try Again") { engine.retryRestore() }
            }
            if engine.blockedByFloor {
                notice("Battery is at \(engine.battery?.percent ?? engine.batteryFloor)%, at your \(engine.batteryFloor)% limit, so it sleeps with the lid closed.", button: "Keep Awake Anyway") { engine.overrideFloor() }
            } else if engine.floorOverride {
                notice("Going below \(engine.batteryFloor)% until you plug in.", button: "Undo") { engine.overrideFloor(false) }
            }
            if engine.onHotspot && !engine.config.hotspotAutomatic && Registry.hasLid { hotspotNotice }
            if let r = engine.recentReceipt, dismissedReceipt != r.closedAt { receipt(r) }

            if Registry.hasLid, let b = engine.battery {
                Divider()
                battery(b)
            }
        }
    }

    /// One figure: how long it lasts with the lid closed, and what that gains over leaving it open.
    private func battery(_ b: BatteryReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let closed = engine.closedHours {
                Figure(value: PanelFormat.hm(closed), caption: "\(b.percent)% · " + (engine.onBattery ? "lid closed" : "unplugged, lid closed"))
                if engine.onBattery, let open = engine.openHours, closed > open {
                    Figure(value: "+" + PanelFormat.hm(closed - open), caption: "vs. lid open", tint: .accentColor)
                }
            } else {
                Label(b.charging ? "\(b.percent)% · charging" : "\(b.percent)%", systemImage: batteryIcon)
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help("Down to \(engine.batteryFloor == 0 ? "0%" : "your \(engine.batteryFloor)% limit"), estimated from what's running now and measured while the lid is shut. Uses ≈\(PanelFormat.w(engine.closedEstimate)) closed\(engine.openWatts.map { ", \(PanelFormat.w($0)) open" } ?? "").")
    }

    private var batteryIcon: String {
        guard let b = engine.battery else { return "battery.100" }
        if b.charging { return "battery.100.bolt" }
        switch b.percent { case ..<13: return "battery.0"; case ..<38: return "battery.25"; case ..<63: return "battery.50"; case ..<88: return "battery.75"; default: return "battery.100" }
    }

    /// Which receipt was dismissed (by its session), so the next session's receipt still shows.
    @AppStorage("dismissedReceipt") private var dismissedReceiptAt: Double = 0
    private var dismissedReceipt: Date? { dismissedReceiptAt > 0 ? Date(timeIntervalSince1970: dismissedReceiptAt) : nil }

    /// "Keeps working" or "Sleeps normally", and why, big enough to be the first thing anyone reads.
    private var outcome: some View {
        let o = engine.lidOutcome
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: o.keeps ? "laptopcomputer" : "moon.zzz.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(o.keeps ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.headline).font(.headline)
                Text(o.detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if engine.mode == .on { durationMenu.padding(.top, 2).padding(.leading, -3) }   // the menu's own inset, so it lines up with the text
                else if engine.holding {
                    Button("Sleep Now") { engine.sleepNow() }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.subheadline).padding(.top, 2)
                        .help("Let it sleep now. Agents can't keep it awake again until you open the lid.")
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// On an iPhone hotspot: macOS only reconnects to it by itself with the lid shut if "Ask to join hotspots" is
    /// on Automatic. Nocturnal can't read or change that setting, so it asks once and remembers the answer.
    private var hotspotNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "personalhotspot").font(.system(size: 13)).foregroundStyle(.orange).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("You're on your iPhone's hotspot").font(.subheadline.weight(.semibold))
                Text("Set Wi‑Fi › Ask to join hotspots to Automatic, or it won't reconnect with the lid shut.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Open Wi-Fi Settings") { NSWorkspace.shared.open(NetWatch.wifiSettingsURL) }
                    Button("It's on Automatic") { engine.update { $0.hotspotAutomatic = true } }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption.weight(.medium))
            }
        }
    }

    private func receipt(_ r: Receipt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("While the lid was closed").font(.subheadline.weight(.semibold))
                Text(([r.agentName].compactMap { $0 } + [Engine.receiptLine(r)]).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Button { dismissedReceiptAt = r.closedAt.timeIntervalSince1970 } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
        }
    }

    private var durationMenu: some View {
        Menu {
            ForEach([30, 60, 120, 240, 480], id: \.self) { m in
                Button("For " + Engine.formatMinutes(Double(m))) { engine.stayAwake(for: m) }
            }
            Divider()
            ForEach([7, 8, 9], id: \.self) { h in
                let d = PanelFormatTime.next(hour: h)
                Button("Until \(d.formatted(date: .omitted, time: .shortened))") { engine.stayAwake(until: d) }
            }
            Divider()
            Button("Until I Turn It Off") { engine.stayAwake(for: nil) }
        } label: {
            Text(engine.alwaysLeft == nil ? "Set a timer" : "Change timer").font(.subheadline).foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How long to stay awake")
    }


    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { action() } label: { Text(button) }.controlSize(.small)
        }
    }

}

/// A big number with a plain caption underneath.
private struct Figure: View {
    let value: String
    let caption: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText()).animation(.snappy, value: value)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

enum PanelFormat {
    static func hm(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        if m < 60 { return "\(max(1, m)) min" }
        return m % 60 == 0 || m >= 600 ? "\(Int((Double(m) / 60).rounded())) h" : "\(m / 60) h \(m % 60) min"
    }
    static func w(_ watts: Double) -> String { String(format: watts < 10 ? "%.1f W" : "%.0f W", watts) }
    static func pct(_ p: Double) -> String { p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p) }
    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        return m < 60 ? "\(max(1, m)) min" : hm(seconds / 3600)
    }
}

// MARK: - Apps (the panel's Apps tab, and Settings › Keep Awake For)

struct AppsView: View {
    @Bindable var engine: Engine
    /// Opens Settings › Agents (nil where Settings are already open).
    var openAgentSettings: (() -> Void)? = nil
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            keepAwake
            if let open = openAgentSettings {
                Divider()
                approveRow(open)
            }
            if Registry.hasLid {   // desktop Macs have no lid and no battery, so these rules never apply
                Divider()
                whileClosed
            }
            let apps = engine.userApps.filter { $0.watts >= 0.05 && !engine.isProtected($0) }
            if !apps.isEmpty {
                Divider()
                otherApps(apps)
            }
        }
    }

    // What keeps the Mac awake

    private var keepAwake: some View {
        group("Keeps the Mac awake", accessory: AnyView(addMenu)) {
            let rows = engine.sessions.filter { s in
                (s.kind != AgentKind.claudeApp || engine.countClaudeApp) && (!s.kind.isRequest || engine.isWorking(s))
            }
            if rows.isEmpty && engine.watchedApps.isEmpty && engine.holds.isEmpty {
                Text("Agents are found on their own. Add any app with +.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(engine.holds) { h in
                ListRow {
                    IconTile(symbol: "terminal.fill", color: .gray)
                } title: { Text(h.reason) } subtitle: {
                    Text(holdLine(h)).monospacedDigit()
                } trailing: {
                    RemoveButton { _ = engine.releaseHold(h.id) }
                }
            }
            ForEach(rows.prefix(5)) { s in
                AgentRow(session: s, working: engine.isWorking(s), engine: engine, sleepsIn: engine.sleepsIn(s))
            }
            ForEach(engine.watchedApps.filter { w in !rows.contains { $0.kind.id == "app:" + w.id } }) { w in
                ListRow {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: w.id)).resizable().frame(width: 22, height: 22)
                } title: { Text(w.name) } subtitle: { Text("Not open") } trailing: {
                    RemoveButton { engine.removeWatched(w) }
                }
            }
            settingRow("Sleep once idle for") { quietMenu }
                .padding(.top, 4)
        }
    }

    /// Approve everything, where agents are: its state, and the way to the switch (Settings › Agents, which
    /// shows the warning first). Read from its journal file, so it's always the real state.
    private func approveRow(_ open: @escaping () -> Void) -> some View {
        let on = AutoApprove.isOn
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Approve everything").font(.subheadline.weight(.semibold))
                Text(on ? "On: Claude Code and Codex don't ask" : "Off: agents ask before acting")
                    .font(.caption).foregroundStyle(on ? Color.orange : Color.secondary)
            }
            Spacer()
            Button { open() } label: { Text(on ? "Change…" : "Turn On…") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.subheadline)
        }
    }

    private func holdLine(_ h: Hold) -> String {
        if let u = h.until {
            return "Until \(u.formatted(date: .omitted, time: .shortened)) · \(PanelFormat.minutes(u.timeIntervalSinceNow)) left"
        }
        return h.pid.map { "While process \($0) runs" } ?? "Until released"
    }

    private var quietMenu: some View {
        Menu {
            ForEach([1, 2, 5, 10, 20, 30, 60], id: \.self) { m in
                Button { engine.update { $0.sleepWhenDone = true; $0.quietMinutes = m } } label: {
                    check(engine.sleepWhenDone && engine.quietMinutes == m, "\(m) min")
                }
            }
            Divider()
            Button { engine.sleepWhenDone = false } label: { check(!engine.sleepWhenDone, "Never (awake as long as the agent app is open)") }
        } label: {
            Text(engine.sleepWhenDone ? "\(engine.quietMinutes) min" : "Never")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("How long an agent can sit idle before Nocturnal lets the Mac sleep")
    }

    private var addMenu: some View {
        Menu {
            let options = engine.addableApps
            if options.isEmpty { Text("No other apps open") }
            ForEach(options.prefix(20)) { app in Button(app.name) { engine.addWatched(app) } }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Keep the Mac awake while an app is busy")
    }

    // What closing the lid does

    private var whileClosed: some View {
        group("When the lid is closed") {
            EqualSegments(items: Preset.allCases.map { ($0, $0.label) }, selection: $engine.preset)
                .frame(maxWidth: .infinity)
                .help(engine.preset.detail)
            Text(planLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            settingRow("Stop at battery") { floorMenu }
                .padding(.top, 4)
        }
    }

    private var planLine: String {
        let p = engine.closedPlan
        var parts: [String] = []
        parts.append(p.lowPower ? "Low Power Mode on" : "Normal power mode")
        if p.slowed > 0 { parts.append("\(p.slowed) app\(p.slowed == 1 ? "" : "s") slowed") }
        if p.paused > 0 { parts.append("\(p.paused) paused") }
        if p.slowed == 0 && p.paused == 0 { parts.append("nothing slowed") }
        parts.append("≈\(PanelFormat.w(p.watts))")
        return parts.joined(separator: " · ")
    }

    private var floorMenu: some View {
        Menu {
            Button { engine.batteryFloor = 0 } label: { check(engine.batteryFloor == 0, "Never (run to 0%)") }
            Divider()
            ForEach([5, 10, 15, 20, 30, 50], id: \.self) { f in
                Button { engine.batteryFloor = f } label: { check(engine.batteryFloor == f, "\(f)%") }
            }
        } label: {
            Text(engine.batteryFloor == 0 ? "Never" : "\(engine.batteryFloor)%")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Below this, Nocturnal lets the Mac sleep when the lid is closed. With Never it keeps going to empty, and the Mac switches off at 0%.")
    }

    // Per-app rules

    private func otherApps(_ apps: [AppUsage]) -> some View {
        let total = apps.reduce(0) { $0 + $1.watts }
        let closed = apps.reduce(0) { $0 + engine.closedWatts(for: $1) }
        let shown = showAll ? apps : Array(apps.prefix(4))
        return group("Other apps · \(PanelFormat.w(total)) → \(PanelFormat.w(closed)) closed", accessory: AnyView(measure)) {
            ForEach(shown) { app in EnergyRow(app: app, engine: engine) }
            if apps.count > 4 {
                Button(showAll ? "Show Fewer" : "Show \(apps.count - 4) More") { showAll.toggle() }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.subheadline)
            }
            if let t = engine.lastTest, Date().timeIntervalSince(t.date) < 3600, t.before > 0 {
                let change = Int(((t.after / t.before - 1) * 100).rounded())
                Text("Measured \(t.date.formatted(date: .omitted, time: .shortened)): \(PanelFormat.w(t.before)) → \(PanelFormat.w(t.after)) (\(change > 0 ? "+" : "")\(change)%)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var measure: some View {
        Button { engine.measureSavings() } label: {
            if engine.measuring { ProgressView().controlSize(.mini) } else { Text("Measure") }
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.subheadline)
        .disabled(engine.measuring || (engine.lidClosed && engine.holding))
        .help("Applies these rules for about 5 seconds and reads each app's real power before and after")
    }

    // Building blocks

    private func group<C: View>(_ title: String, accessory: AnyView? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                accessory
            }
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }

    private func settingRow<C: View>(_ title: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline)
            Spacer()
            control()
        }
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Setup

private struct SetupView: View {
    let engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set Up Nocturnal").font(.headline)
            Text("Nocturnal needs your password once to control sleep.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let err = engine.setupError { Text(err).font(.subheadline).foregroundStyle(.red) }
            Button { UIState.shared.whilePinned { engine.runSetup() } } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 8)
        }
    }
}

#Preview("Now") {
    PanelView(engine: .preview(), showTab: .now).background(.regularMaterial)
}

#Preview("Apps") {
    PanelView(engine: .preview(), showTab: .apps).background(.regularMaterial)
}

#Preview("On a hotspot") {
    let e = Engine.preview()
    e.previewOnHotspot()
    return PanelView(engine: e, showTab: .now).background(.regularMaterial)
}

#Preview("Now, When Busy") {
    let e = Engine.preview()
    e.mode = .auto   // preview engines never save
    return PanelView(engine: e, showTab: .now).background(.regularMaterial)
}
