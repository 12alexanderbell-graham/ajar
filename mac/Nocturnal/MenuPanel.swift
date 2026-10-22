import AppKit
import SwiftUI

/// The menu bar panel, two tabs:
///  • Now: what the Mac is doing and what it saves (battery, watts, hours), the mode, and tiles for Approve
///    everything, the phone and the lid-shut preset.
///  • Apps: what keeps the Mac awake, what closing the lid slows or pauses, per-app rules.
/// Everything else is in Settings. Before setup is done it shows the first-run steps instead.
struct PanelView: View {
    enum Tab: String { case now, apps }

    @Bindable var engine: Engine
    var actions = PanelActions(openSettings: {}, quit: { NSApp.terminate(nil) })
    /// Opens on this tab (previews and screenshots); otherwise the last one used.
    var showTab: Tab? = nil
    @AppStorage("panelTab") private var tab: Tab = .now
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if engine.setupReady && (onboardingDone || showTab != nil) {
                header
                switch showTab ?? tab {
                case .now: NowTab(engine: engine, openPhone: { UIState.shared.settingsTab = .phone; actions.openSettings() })
                case .apps: AppsView(engine: engine, openAgentSettings: { UIState.shared.settingsTab = .ai; actions.openSettings() })
                }
            } else {
                FirstRunView(engine: engine,
                             openPhoneSettings: { UIState.shared.settingsTab = .phone; actions.openSettings() },
                             done: { onboardingDone = true })
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

/// What the Mac is doing and what it saves, the mode, and the three features people look for. Same shape as the
/// phone: a card (green while it keeps working) with three numbers, the slider, then tiles.
private struct NowTab: View {
    @Bindable var engine: Engine
    var openPhone: () -> Void
    @State private var confirmingApprove = false
    @State private var approveNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card
            EqualSegments(items: Mode.allCases.map { ($0, $0.label) },
                          selection: Binding(get: { engine.mode }, set: { m in
                              if m == .on { engine.stayAwake(for: nil) } else { engine.mode = m }
                          }))
                .help(engine.modeLine)
            if confirmingApprove {
                ApproveConfirm(engine: engine) { message in
                    approveNote = message
                    confirmingApprove = false
                }
                .padding(12)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
            } else {
                tiles
            }
            if let n = approveNote {
                Text(n).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .task(id: n) { try? await Task.sleep(for: .seconds(6)); approveNote = nil }
            }
            if let n = topNotice { NoticeRow(notice: n) }
            actions
        }
    }

    // MARK: Card

    private var card: some View {
        let o = engine.lidOutcome
        let keeps = o.keeps
        return VStack(alignment: .leading, spacing: 4) {
            Text(o.headline).font(.title2.weight(.bold))
            Text(o.detail).font(.body).foregroundStyle(keeps ? Color.white.opacity(0.85) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if Registry.hasLid, let b = engine.battery {
                HStack(alignment: .top, spacing: 6) {
                    Number(value: Double(b.percent), digits: 0, unit: "%", caption: b.charging ? "charging" : engine.onBattery ? "battery" : "plugged in", keeps: keeps)
                    if let w = engine.systemWatts {
                        Number(value: w, digits: w < 10 ? 1 : 0, unit: "W", caption: "using now", keeps: keeps)
                    }
                    if let h = engine.closedHours {
                        Number(value: h, digits: h < 10 ? 1 : 0, unit: "h", caption: engine.onBattery ? "left, lid shut" : "if unplugged", keeps: keeps)
                    }
                }
                .padding(.top, 12)
                if let line = savingsLine {
                    Text(line).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(keeps ? Color.white : Color.accentColor)
                        .padding(.top, 4)
                        .help("What this Mac draws with the lid shut (Nocturnal's rules on) against with it open, measured on this Mac.")
                }
            }
        }
        .foregroundStyle(keeps ? Color.white : Color.primary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if keeps { KeepsBackground() } else { Color.primary.opacity(0.05) } }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.3), value: keeps)
    }

    /// What closing the lid is worth on this Mac: lid shut vs open (measured or learned), else this week's total.
    private var savingsLine: String? {
        let closed = engine.closedEstimate
        if let open = engine.openWatts, open > closed + 0.5 {
            return "Lid shut: ≈\(PanelFormat.w(closed)) instead of \(PanelFormat.w(open))"
        }
        if let w = engine.weekSummary, w.whSaved >= 10 {
            return "This week: \(PanelFormat.hm(w.closedHours)) lid shut, ≈\(String(format: "%.0f", w.whSaved)) Wh saved"
        }
        return nil
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 8) {
            let a = engine.approve
            Tile(symbol: a.on ? "checkmark.shield.fill" : "checkmark.shield", title: "Approve all",
                 state: a.on ? (a.problem != nil ? "Needs you" : "On") : "Off", tint: a.on ? .orange : nil) {
                if a.on || a.problem != nil { approveNote = ApproveConfirm.turnOff(engine) } else { confirmingApprove = true }
            }
            .help(a.on ? (a.endsLine ?? "Claude Code and Codex run without asking. Click to turn off.")
                       : "Let Claude Code and Codex run without asking, until the work finishes")
            let remote = NocturnalShared.remote
            let phones = remote?.settings.phones.count ?? 0
            let phoneState = phones == 0 ? "Pair" : remote?.enabled != true ? "Off" : phones == 1 ? "Paired" : "\(phones) paired"
            Tile(symbol: "iphone", title: "Phone", state: phoneState, tint: nil, action: openPhone)
                .help("Check on it, wake it or let it sleep from your phone")
            if Registry.hasLid { presetTile }
        }
    }

    /// Desktop Macs have no lid, so the lid-shut rules (and this tile) never apply there.
    private var presetTile: some View {
        Menu {
            ForEach(Preset.allCases, id: \.self) { p in
                Button { engine.preset = p } label: {
                    if engine.preset == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                }
            }
        } label: {
            TileFace(symbol: "laptopcomputer", title: "Lid shut", state: engine.preset.label, tint: nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .help(engine.preset.detail)
    }

    // MARK: Notices: one at a time, most important first

    private var topNotice: Notice? {
        if !engine.wakeReady {
            return notice("Needs your password once more to finish updating.", "Set Up") { UIState.shared.whilePinned { engine.runSetup() } }
        }
        if engine.sleepOffOutside {
            return notice("Sleep was switched off outside Nocturnal, so this Mac won't sleep with the lid shut.", "Turn On") { engine.switchSleepBackOn() }
        }
        if !engine.unrestored.isEmpty {
            return notice("Couldn't put back \(engine.unrestored.joined(separator: ", ")) yet.", "Try Again") { engine.retryRestore() }
        }
        if engine.blockedByFloor {
            return notice("At your \(engine.batteryFloor)% battery limit, so it sleeps with the lid shut.", "Keep Going") { engine.overrideFloor() }
        }
        if engine.floorOverride {
            return notice("Going below \(engine.batteryFloor)% until you plug in.", "Undo") { engine.overrideFloor(false) }
        }
        if let w = engine.warning { return Notice(text: w, button: "OK", warning: true) { engine.warning = nil } }
        // The hotspot tip only after it actually cost something: the last lid-shut session lost the internet.
        if engine.onHotspot, !engine.config.hotspotAutomatic, let r = engine.recentReceipt, r.offlineSeconds > 60 {
            return notice("Lost the internet with the lid shut: set Wi‑Fi › Ask to join hotspots to Automatic.", "Open") {
                NSWorkspace.shared.open(NetWatch.wifiSettingsURL)
                engine.update { $0.hotspotAutomatic = true }
            }
        }
        if let r = engine.recentReceipt, abs(dismissedReceiptAt - r.closedAt.timeIntervalSince1970) > 1 {
            return notice("While the lid was shut: " + ([r.agentName].compactMap { $0 } + [Engine.receiptLine(r)]).joined(separator: " · "), "OK") {
                dismissedReceiptAt = r.closedAt.timeIntervalSince1970
            }
        }
        return nil
    }

    /// Which receipt was dismissed, by its session's start (compared to the second: a Double round trip isn't exact).
    @AppStorage("dismissedReceipt") private var dismissedReceiptAt: Double = 0

    private func notice(_ text: String, _ button: String, action: @escaping () -> Void) -> Notice {
        Notice(text: text, button: button, action: action)
    }

    // MARK: Sleep Now and the timer

    @ViewBuilder private var actions: some View {
        if engine.mode == .on || engine.holding {
            HStack(spacing: 10) {
                Button { engine.sleepNow() } label: { Label("Sleep Now", systemImage: "moon.fill") }
                    .help("Let it sleep now. Agents can't keep it awake again until you open the lid.")
                if engine.mode == .on { durationMenu }
                Spacer()
            }
            .controlSize(.regular)
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
            Text(engine.alwaysLeft == nil ? "Set a Timer" : "Change Timer")
        }
        .fixedSize()
        .help("How long to stay awake")
    }
}

/// The card's green: deep green opening to a mint glow, the same as the icon, the phone and the website.
private struct KeepsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.20, blue: 0.10), Color(red: 0.08, green: 0.42, blue: 0.25)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            RadialGradient(colors: [Color(red: 0.25, green: 0.84, blue: 0.61).opacity(0.85), .clear],
                           center: UnitPoint(x: 0.95, y: 0), startRadius: 0, endRadius: 220)
        }
    }
}

/// One line the panel needs to say, at most one at a time.
private struct Notice {
    var text: String
    var button: String? = nil
    var warning = false
    var action: () -> Void = {}
}

private struct NoticeRow: View {
    let notice: Notice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(notice.text).font(.callout).foregroundStyle(notice.warning ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let b = notice.button { Button(b, action: notice.action).controlSize(.small) }
        }
    }
}

/// One of the card's numbers: tabular digits that roll to the new value, the unit, a word under it.
private struct Number: View {
    let value: Double
    let digits: Int
    let unit: String
    let caption: String
    let keeps: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value, format: .number.precision(.fractionLength(digits)))
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: value)).animation(.snappy(duration: 0.6), value: value)
                Text(unit).font(.system(size: 15, weight: .medium))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.callout).foregroundStyle(keeps ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A feature tile: icon, name, state. Always visible, so nothing important hides in Settings.
private struct Tile: View {
    let symbol: String
    let title: String
    let state: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) { TileFace(symbol: symbol, title: title, state: state, tint: tint) }
            .buttonStyle(.plain)
    }
}

private struct TileFace: View {
    let symbol: String
    let title: String
    let state: String
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint ?? Color.accentColor)
                .frame(height: 18)
            Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(state).font(.callout).foregroundStyle(tint ?? .secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.05 : 0.14), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12))
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
            // Only while it's on (or couldn't be put back): a warning, not one more routine setting.
            if let open = openAgentSettings, engine.approve.on {
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
            settingRow("Sleep after idle") { quietMenu }
                .padding(.top, 4)
        }
    }

    /// Approve everything while it's on: agents don't ask, and when it ends. Read from its journal file, so it's
    /// always the real state; the switch is in Settings › Agents.
    private func approveRow(_ open: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents don't ask before acting").font(.subheadline.weight(.semibold))
                Text(engine.approve.endsLine ?? "Approve everything is on")
                    .font(.caption).foregroundStyle(engine.approve.problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Button { open() } label: { Text("Change…") }
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
            Button { engine.sleepWhenDone = false } label: { check(!engine.sleepWhenDone, "Off (awake while the agent is open)") }
        } label: {
            Text(engine.sleepWhenDone ? "\(engine.quietMinutes) min" : "Off")
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
                .help(planNames)
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

    /// Exactly which apps closing the lid would slow or pause right now.
    private var planNames: String {
        let p = engine.closedPlan
        var parts: [String] = []
        if !p.pausedNames.isEmpty { parts.append("Pauses: " + p.pausedNames.joined(separator: ", ")) }
        if !p.slowedNames.isEmpty { parts.append("Slows: " + p.slowedNames.joined(separator: ", ")) }
        return parts.isEmpty ? "Nothing would be slowed or paused right now" : parts.joined(separator: "\n") + "\nAgents, what they use, music and calls are never touched."
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
