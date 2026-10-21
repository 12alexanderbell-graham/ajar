import AppKit
import SwiftUI

/// The menu bar panel, flat like the system Battery and Wi-Fi menus.
/// Geometry: one 16 pt leading edge, 8 pt rhythm (8 inside a group, 16 between groups),
/// system text styles only, dividers instead of cards. Every number carries its unit and what it's compared to.
///  • Now: mode, what's happening, battery numbers, this week.
///  • Rules: what keeps the Mac awake, what closing the lid does, per-app rules.
struct PanelView: View {
    enum Tab: String { case now, rules }

    @Bindable var engine: Engine
    var actions = PanelActions(openSettings: {}, quit: { NSApp.terminate(nil) })
    @AppStorage("panelTab") private var tab: Tab = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.setupReady {
                header
                switch tab {
                case .now: NowTab(engine: engine, openRules: { tab = .rules })
                case .rules: RulesTab(engine: engine)
                }
            } else {
                SetupView(engine: engine)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .onAppear { engine.panelOpen = true }
        .onDisappear { engine.panelOpen = false }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ForEach([Tab.now, Tab.rules], id: \.self) { t in
                Button { tab = t } label: {
                    Text(t == .now ? "Now" : "Rules")
                        .font(.headline)
                        .foregroundStyle(tab == t ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Menu {
                Button("Settings…") { actions.openSettings() }
                Divider()
                Button("Quit Ajar") { actions.quit() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }
}

// MARK: - Now

private struct NowTab: View {
    @Bindable var engine: Engine
    var openRules: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                EqualSegments(items: Mode.allCases.map { ($0, $0.label) },
                              selection: Binding(get: { engine.mode }, set: { m in
                                  if m == .on { engine.stayAwake(for: nil) } else { engine.mode = m }
                              }))
                outcome
            }

            if let w = engine.warning {
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !engine.unrestored.isEmpty {
                notice("Couldn't put back \(engine.unrestored.joined(separator: ", ")) yet. Ajar keeps trying.", button: "Try Again") { engine.retryRestore() }
            }

            if let r = engine.recentReceipt, dismissedReceipt != r.closedAt { receipt(r) }

            Divider()
            battery

            if let w = engine.weekSummary {
                Divider()
                week(w)
            }
        }
    }

    /// Which receipt was dismissed (by its session), so the next session's receipt still shows.
    @State private var dismissedReceipt: Date?

    /// "Close the lid: keeps working" with the reason and what it'll cost, so nobody has to work it out.
    private var outcome: some View {
        let o = engine.lidOutcome
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: o.keeps ? "laptopcomputer" : "moon.zzz")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(o.keeps ? Color.green : Color.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.headline).font(.subheadline.weight(.semibold))
                Text(o.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if engine.mode == .on { durationMenu }
            else if engine.holding {
                Button("Sleep Now") { engine.sleepNow() }
                    .buttonStyle(.link).font(.subheadline)
                    .help("Let it sleep now. Agents can't keep it awake again until you open the lid.")
            }
        }
    }

    private func receipt(_ r: Receipt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("While the lid was closed").font(.subheadline.weight(.semibold))
                Text(([r.agentName].compactMap { $0 } + [Engine.receiptLine(r)]).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Button { dismissedReceipt = r.closedAt } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
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
                let d = Self.next(hour: h)
                Button("Until \(d.formatted(date: .omitted, time: .shortened))") { engine.stayAwake(until: d) }
            }
            Divider()
            Button("Until I Turn It Off") { engine.stayAwake(for: nil) }
        } label: {
            Text(engine.alwaysLeft == nil ? "Set Timer" : "Change")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How long to stay awake")
    }

    /// The next time the clock shows `hour`:00 (tomorrow if that's already passed today).
    static func next(hour: Int) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return today > Date() ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    @ViewBuilder private var battery: some View {
        if engine.blockedByFloor {
            notice("Battery at \(engine.battery?.percent ?? 0)%, below your \(engine.batteryFloor)% limit. Sleeps when closed.",
                   button: "Keep Going") { engine.overrideFloor() }
        } else if engine.floorOverride {
            notice("Going below \(engine.batteryFloor)% until you plug in.", button: "Undo") { engine.overrideFloor(false) }
        }

        if let b = engine.battery {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(batteryState(b)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                if !engine.onBattery {
                    // On a charger that keeps up, it runs forever; the battery figure is what you'd get unplugged.
                    Figure(value: engine.closedHours.map { PanelFormat.hm($0) } ?? "No limit",
                           caption: engine.closedHours == nil ? "on the charger" : "on battery with the lid closed (charger in now)")
                        .help("Running on the charger, so there's no limit now. The figure is how long the battery would last with the lid closed if you unplugged.")
                    Text(drawLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                } else if let closed = engine.closedHours {
                    let open = engine.openHours
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Figure(value: PanelFormat.hm(closed), caption: "left with lid closed")
                        if let open, closed > open {
                            Figure(value: "+" + PanelFormat.hm(closed - open),
                                   caption: "vs. \(PanelFormat.hm(open)) lid open", tint: .green)
                        }
                    }
                    .help("Down to \(engine.batteryFloor == 0 ? "0%" : "your \(engine.batteryFloor)% limit"), from \(b.percent)%. Closed is estimated from what's running now and measured while the lid is shut.")
                    Text(drawLine).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
    }

    private func batteryState(_ b: BatteryReading) -> String {
        if b.charging { return "\(b.percent)% · charging" }
        if engine.onBattery, let d = engine.drawNow { return "\(b.percent)% · \(PanelFormat.pct(engine.percentPerHour(d))) an hour now" }
        return b.onAC ? "\(b.percent)% · plugged in" : "\(b.percent)%"
    }

    private var drawLine: String {
        var s = "Uses ≈\(PanelFormat.w(engine.closedEstimate)) closed"
        if let o = engine.openWatts { s += " · \(PanelFormat.w(o)) open" }
        return s
    }

    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { action() } label: { Text(button) }.controlSize(.small)
        }
    }

    private func week(_ w: Engine.WeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(PanelFormat.hm(w.closedHours)) working, lid closed")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text("\(w.sessions) session\(w.sessions == 1 ? "" : "s")" + (w.whSaved >= 1 ? " · ≈\(String(format: "%.0f", w.whSaved)) Wh saved" : "") + (w.percentSaved >= 5 ? " · ≈\(String(format: "%.1f", w.percentSaved / 100)) full charges" : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .help("Estimated, not metered: power macOS attributes to apps before and while Ajar slowed them (net, including any that used more), plus confirmed sleeps after the work stopped, valued at the power drawn just before.")
    }
}

/// A big number with a plain-language caption underneath.
private struct Figure: View {
    let value: String
    let caption: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText()).animation(.snappy, value: value)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Rules

private struct RulesTab: View {
    @Bindable var engine: Engine
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            keepAwake
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
                Text("Claude, Codex, Gemini, Cursor and other agents are picked up on their own. Add any app with +.")
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
        .help("How long an agent can sit idle before Ajar lets the Mac sleep")
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
        .help("Below this, Ajar lets the Mac sleep when the lid is closed. With Never it keeps going to empty, and the Mac switches off at 0%.")
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
                    .buttonStyle(.link).font(.subheadline)
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
        .buttonStyle(.link).font(.subheadline)
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
            Text("Set Up Ajar").font(.headline)
            Text("Ajar needs your password once to control sleep.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let err = engine.setupError { Text(err).font(.subheadline).foregroundStyle(.red) }
            Button { engine.runSetup() } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 8)
        }
    }
}

#Preview("Now") {
    UserDefaults.standard.set("now", forKey: "panelTab")
    return PanelView(engine: .preview()).background(.regularMaterial)
}

#Preview("Rules") {
    UserDefaults.standard.set("rules", forKey: "panelTab")
    return PanelView(engine: .preview()).background(.regularMaterial)
}
