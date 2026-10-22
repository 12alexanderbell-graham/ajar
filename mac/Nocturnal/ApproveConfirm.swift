import SwiftUI

/// The one place Approve everything is switched on: says plainly what it means, asks when it should end, and only
/// then writes the agents' settings. Used in the menu bar panel and in Settings › Agents. A phone, an agent or the
/// settings file can never reach this.
struct ApproveConfirm: View {
    @Bindable var engine: Engine
    /// Called when it's done or cancelled, with what to tell the person (nil on cancel).
    var finished: (String?) -> Void
    @State private var ends: AutoApprove.Ends = .work

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approve everything?").font(.headline)
            Text("Claude Code and Codex will run commands, edit files and use the network without asking you, in every project. macOS's own permission prompts still appear.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Turns off", selection: $ends) {
                Text("When the work finishes").tag(AutoApprove.Ends.work)
                Text("In 8 hours").tag(AutoApprove.Ends.time)
                Text("When I turn it off").tag(AutoApprove.Ends.manual)
            }
            HStack {
                Button("Cancel") { finished(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Turn On") {
                    let message: String
                    do {
                        try AutoApprove.turnOn(ends: ends, hours: ends == .time ? 8 : nil)
                        message = "On. New Claude Code and Codex sessions won't ask."
                    } catch {
                        message = error.localizedDescription
                    }
                    engine.approveChanged()
                    finished(message)
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Turning it off needs no confirmation: everyone's previous settings come back.
    static func turnOff(_ engine: Engine) -> String {
        defer { engine.approveChanged() }
        do {
            try AutoApprove.turnOff()
            return "Off. Your previous Claude Code and Codex settings are back."
        } catch {
            return error.localizedDescription
        }
    }
}
