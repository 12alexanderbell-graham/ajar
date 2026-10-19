import SwiftUI

/// The regular window: a welcome + setup flow the first time, then the same controls as the menu bar panel.
/// Always exactly 460 × 720 so its size never depends on live-updating content.
struct MainWindowView: View {
    @Bindable var engine: Engine
    var actions: PanelActions
    @State private var showConnect = !UserDefaults.standard.bool(forKey: "aiCardDismissed")

    var body: some View {
        Group {
            if engine.setupReady {
                ScrollView {
                    if showConnect {
                        ConnectCard { showConnect = false; UserDefaults.standard.set(true, forKey: "aiCardDismissed") }
                            .padding(.horizontal, 20).padding(.top, 20)
                    }
                    PanelView(engine: engine, actions: actions)
                        .frame(maxWidth: .infinity)
                        .padding(.top, showConnect ? 8 : 28)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            } else {
                Welcome(engine: engine)
            }
        }
        .frame(width: 460, height: 720)
        .background(.regularMaterial)
    }
}

private struct Welcome: View {
    let engine: Engine
    @State private var working = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .padding(.top, 44)
            VStack(spacing: 6) {
                Text("Welcome to Ajar").font(.system(size: 26, weight: .bold))
                Text("Close the lid. Your work keeps going.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "sparkles", color: .blue, title: "Stays awake only when it matters",
                        text: "When Claude Code, Codex, a download or an app you pick is working. Otherwise your Mac sleeps like normal.")
                Feature(symbol: "leaf.fill", color: .green, title: "Saves battery while it's closed",
                        text: "Turns on Low Power Mode and slows or pauses the apps you're not using, then puts everything back.")
                Feature(symbol: "moon.zzz.fill", color: .indigo, title: "Sleeps when the work is done",
                        text: "No more hot, dead laptop in your bag. Battery and heat limits always win.")
                Feature(symbol: "terminal.fill", color: .gray, title: "Your AI can drive it",
                        text: "Connect Claude Code, Codex or the Claude app in one click, then paste the setup prompt: your agent tunes Ajar with you.")
            }
            .padding(.horizontal, 36)
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
                Text("macOS asks for your password once. Ajar gets permission to change only sleep and Low Power Mode, adds a small watchdog that undoes everything if Ajar quits unexpectedly, and installs the ajar command for Claude. Settings → Remove Helper takes it all out.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 30)
        }
    }
}

/// Shown once after setup: connect the agents found on this Mac, and the prompt that has one set Ajar up.
private struct ConnectCard: View {
    var dismiss: () -> Void
    @State private var note: String?
    @State private var tick = false

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connect your AI").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done", action: dismiss).buttonStyle(.borderless).font(.system(size: 12))
            }
            Text("So Claude or Codex can keep the Mac awake while they work and tune Ajar's savings with you.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Claude Code", AIConnect.claudeCodeInstalled, AIConnect.claudeCodeConnected) { AIConnect.connectClaudeCode() }
            row("Codex", AIConnect.codexInstalled, AIConnect.codexConnected) { AIConnect.connectCodex() }
            row("Claude app", AIConnect.claudeAppInstalled, AIConnect.claudeAppConnected) { AIConnect.connectClaudeApp() }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AIConnect.setupPrompt, forType: .string)
                note = "Prompt copied. Paste it into Claude or Codex."
            } label: { Text("Copy Setup Prompt").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private func row(_ name: String, _ installed: Bool, _ connected: Bool, _ action: @escaping () -> String) -> some View {
        HStack {
            Text(name).font(.system(size: 13))
            if !installed { Text("not found").font(.system(size: 11)).foregroundStyle(.tertiary) }
            Spacer()
            if connected { Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary) }
            else { Button("Connect") { note = action(); tick.toggle() }.controlSize(.small) }
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
