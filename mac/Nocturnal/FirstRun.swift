import AppKit
import SwiftUI

/// First run, inside the menu bar panel itself (so the first thing anyone sees is where Nocturnal lives):
///  1. what it does, and the one password prompt it needs;
///  2. connecting the agents found on this Mac, and the phone. Both optional, both also in Settings.
struct FirstRunView: View {
    @Bindable var engine: Engine
    var openPhoneSettings: () -> Void
    var done: () -> Void

    var body: some View {
        if engine.setupReady { ConnectStep(openPhoneSettings: openPhoneSettings, done: done) }
        else { WelcomeStep(engine: engine) }
    }
}

private struct WelcomeStep: View {
    let engine: Engine
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Close the lid.").font(.headline)
                    Text("Your work keeps going.").font(.headline).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Feature(symbol: "laptopcomputer", text: "Stays awake with the lid shut while your agents work")
                Feature(symbol: "moon.zzz.fill", text: "Sleeps when the work is done or the battery runs low")
                Feature(symbol: "iphone", text: "Check on it from your phone")
            }
            if let err = engine.setupError { Text(err).font(.caption).foregroundStyle(.red) }
            Button {
                working = true
                // The password prompt counts as a click outside the panel; keep it open meanwhile.
                UIState.shared.whilePinned { engine.runSetup() }
                working = false
            } label: { Text(working ? "Setting Up…" : "Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working)
            Text("macOS asks for your password once.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

private struct ConnectStep: View {
    var openPhoneSettings: () -> Void
    var done: () -> Void
    @State private var note: String?
    /// (installed, connected) for Claude Code, Codex and the Claude app; read off the main thread.
    @State private var state = [(false, false), (false, false), (false, false)]
    @State private var working = false

    var body: some View {
        let server = AIConnect.serverCommand
        let hooks = ClaudeHooks.currentCommand
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your agents").font(.headline)
            Text("So Nocturnal knows when they're working, waiting for you, or done.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                row("Claude Code", state[0]) { AIConnect.connectClaudeCode(server: server, hookCommand: hooks) }
                row("Codex", state[1]) { AIConnect.connectCodex(server: server) }
                row("Claude app", state[2]) { AIConnect.connectClaudeApp(server: server) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Button { done(); openPhoneSettings() } label: {
                Label("Pair your phone", systemImage: "iphone").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            Button { done() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let hooks = ClaudeHooks.currentCommand
        Task {
            state = await Task.detached {
                [(AIConnect.claudeCodeInstalled, AIConnect.claudeCodeFullyConnected(hookCommand: hooks)),
                 (AIConnect.codexInstalled, AIConnect.codexConnected),
                 (AIConnect.claudeAppInstalled, AIConnect.claudeAppConnected)]
            }.value
        }
    }

    @ViewBuilder private func row(_ name: String, _ s: (installed: Bool, connected: Bool), _ action: @escaping @Sendable () -> String) -> some View {
        HStack {
            Text(name)
            if !s.installed { Text("not found").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            if s.connected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Connected")
            } else {
                Button("Connect") {
                    working = true
                    note = "Connecting \(name)…"
                    Task { note = await Task.detached { action() }.value; working = false; reload() }
                }
                .controlSize(.small).disabled(working)
            }
        }
        .font(.subheadline)
    }
}

private struct Feature: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("First run") {
    FirstRunView(engine: .preview(setupReady: false), openPhoneSettings: {}, done: {})
        .padding(16).frame(width: 320).background(.regularMaterial)
}

#Preview("Connect") {
    FirstRunView(engine: .preview(), openPhoneSettings: {}, done: {})
        .padding(16).frame(width: 320).background(.regularMaterial)
}
