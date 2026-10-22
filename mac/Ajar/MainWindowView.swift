import SwiftUI

/// The regular window. First run: three short steps (allow it, pick when it stays awake, optional extras).
/// After that, the same screen as the menu bar panel. Always exactly 460 × 720 so its size never depends on
/// live-updating content.
struct MainWindowView: View {
    @Bindable var engine: Engine
    var actions: PanelActions
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var step = 2

    var body: some View {
        Group {
            if !engine.setupReady {
                Welcome(engine: engine)
            } else if !onboardingDone {
                if step == 2 { ChooseMode(engine: engine) { step = 3 } }
                else { Extras { onboardingDone = true } }
            } else if UIState.shared.windowSettings {
                SettingsPage(engine: engine, back: { UIState.shared.windowSettings = false }, quit: actions.quit)
                    .padding(.top, 20)
            } else {
                ScrollView {
                    PanelView(engine: engine, actions: actions)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: 460, height: 720)
        .background(.regularMaterial)
    }
}

/// Step dots and a title, shared by the three first-run screens.
private struct StepHeader: View {
    let step: Int
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { i in
                    Capsule().fill(i == step ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .padding(.bottom, 10)
            Text(title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
    }
}

private struct Welcome: View {
    let engine: Engine
    @State private var working = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                .padding(.top, 36)
            StepHeader(step: 1, title: "Close the lid. Your work keeps going.",
                       subtitle: "Nocturnal keeps your Mac awake with the lid shut while your AI agents work.")
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "laptopcomputer", color: Brand.mid, title: "Shut it and walk away",
                        text: "Your agent keeps going in your bag.")
                Feature(symbol: "leaf.fill", color: .teal, title: "Uses a fraction of the battery",
                        text: "18 W down to 3 W on our test Mac.")
                Feature(symbol: "moon.zzz.fill", color: .indigo, title: "Sleeps when the work is done",
                        text: "Or when the battery runs low.")
            }
            .padding(.horizontal, 40)
            .padding(.top, 4)
            Spacer(minLength: 4)
            VStack(spacing: 8) {
                if let err = engine.setupError { Text(err).font(.system(size: 12)).foregroundStyle(.red) }
                Button {
                    working = true
                    DispatchQueue.main.async { engine.runSetup(); working = false }
                } label: {
                    Text(working ? "Setting Up…" : "Continue").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(working)
                Text("macOS will ask for your password once.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
    }
}

/// Step 2: the one choice that matters.
private struct ChooseMode: View {
    @Bindable var engine: Engine
    var next: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(step: 2, title: "When should it stay awake?", subtitle: "You can change it later.")
                .padding(.top, 56)
            VStack(spacing: 10) {
                option(.auto, title: "When Busy", badge: "Recommended",
                       text: "While an agent is working. Sleeps after it stops.")
                option(.on, title: "Always", badge: nil,
                       text: "Until you turn it off.")
            }
            .padding(.horizontal, 36)
            Spacer()
            Button { next() } label: { Text("Continue").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                .padding(.horizontal, 40).padding(.bottom, 30)
        }
        .onAppear { if engine.mode == .off { engine.mode = .auto } }
    }

    private func option(_ m: Mode, title: String, badge: String?, text: String) -> some View {
        let selected = engine.mode == m
        return Button {
            if m == .on { engine.stayAwake(for: nil) } else { engine.mode = m }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if let badge {
                            Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Step 3: things that help but aren't needed.
private struct Extras: View {
    var done: () -> Void
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                StepHeader(step: 3, title: "Optional extras", subtitle: "Optional. Also in Settings.")
                    .padding(.top, 40)
                ConnectCard()
                    .padding(.horizontal, 28)
                phoneCard
                    .padding(.horizontal, 28)
                VStack(spacing: 6) {
                    Button { done() } label: { Text("Done").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                    Text("Start an agent and close the lid.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40).padding(.bottom, 30).padding(.top, 6)
            }
        }
        .scrollIndicators(.never)
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check on it from your phone").font(.system(size: 14, weight: .semibold))
            Text("See if it's still working from anywhere.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let remote = NocturnalShared.remote {
                if showPairing && remote.enabled {
                    PairingView(settings: remote.settings) { showPairing = false }.frame(maxWidth: .infinity)
                } else {
                    Button { remote.enable(); showPairing = true } label: { Text(remote.enabled ? "Show QR Code" : "Set Up Phone").frame(maxWidth: .infinity) }
                        .controlSize(.large)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Shown once after setup: connect the agents found on this Mac, and the prompt that has one set Nocturnal up.
private struct ConnectCard: View {
    @State private var note: String?
    /// (installed, connected) for Claude Code, Codex, the Claude app; read off the main thread.
    @State private var state = [(false, false), (false, false), (false, false)]
    @State private var working = false

    private func reload() {
        Task {
            state = await Task.detached {
                [(AIConnect.claudeCodeInstalled, AIConnect.claudeCodeConnected), (AIConnect.codexInstalled, AIConnect.codexConnected),
                 (AIConnect.claudeAppInstalled, AIConnect.claudeAppConnected)]
            }.value
        }
    }

    var body: some View {
        let server = AIConnect.serverCommand
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your AI").font(.system(size: 14, weight: .semibold))
            Text("Lets Claude or Codex keep the Mac awake.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Claude Code", state[0]) { AIConnect.connectClaudeCode(server: server) }
            row("Codex", state[1]) { AIConnect.connectCodex(server: server) }
            row("Claude app", state[2]) { AIConnect.connectClaudeApp(server: server) }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AIConnect.setupPrompt, forType: .string)
                note = "Prompt copied. Paste it into Claude or Codex."
            } label: { Text("Copy Setup Prompt").frame(maxWidth: .infinity) }
            .controlSize(.large)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .onAppear(perform: reload)
    }

    @ViewBuilder private func row(_ name: String, _ s: (Bool, Bool), _ action: @escaping @Sendable () -> String) -> some View {
        HStack {
            Text(name).font(.system(size: 13))
            if !s.0 { Text("not found").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Spacer()
            if s.1 { Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary) }
            else {
                Button("Connect") {
                    working = true; note = "Connecting \(name)…"
                    Task { note = await Task.detached { action() }.value; working = false; reload() }
                }
                .controlSize(.small).disabled(working)
            }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Step 2") {
    ChooseMode(engine: .preview()) {}.frame(width: 460, height: 720).background(.regularMaterial)
}

#Preview("Step 3") {
    Extras {}.frame(width: 460, height: 720).background(.regularMaterial)
}

#Preview("Step 1") {
    Welcome(engine: .preview()).frame(width: 460, height: 720).background(.regularMaterial)
}
