import AppKit
import Foundation

/// What an agent itself says it's doing, from its own lifecycle hooks (Claude Code's `UserPromptSubmit`, `Stop`,
/// `Notification` and session events). Far more reliable than guessing from power use: a quiet two-hour build is
/// still "working", a question waiting for an answer is "waiting", and a finished turn is "finished" even while an
/// MCP server keeps ticking. Guessing from power stays as the fallback for agents without hooks.
///
/// Each hook runs `nocturnal event claude-code`, which writes one small file per session into `agent-events/`
/// and returns at once. Nocturnal reads them on its next sample; a session whose process has gone is dropped.
enum AgentState: String, Codable {
    case idle        // open, nothing asked yet
    case working     // a prompt was sent and the turn hasn't ended
    case waiting     // asking the person: a permission prompt or a question
    case finished    // the turn ended
}

struct AgentEvent: Codable, Equatable {
    var agent: String
    var session: String
    var state: AgentState
    var at: Double
    var pid: Int32?
    var pidStart: UInt64?
    var detail: String?
}

enum AgentEvents {
    static var dir: URL { StateFiles.dir.appendingPathComponent("agent-events") }
    static let changed = Notification.Name("com.alexander.Nocturnal.agentEvent")
    /// "Working" with no sign of life at all (no CPU, no transcript, no command running) for this long is treated as
    /// unknown: a turn the person interrupted ends without a Stop event.
    static let stuckAfter: TimeInterval = 30 * 60
    /// How long a question waiting for an answer keeps the Mac awake.
    static let waitLimit: TimeInterval = 30 * 60

    // MARK: Writing (the hook side; runs as `nocturnal event <agent>`, must be quick and never fail loudly)

    static func record(agent: String, input: Data, now: Date = Date()) {
        guard agent.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), agent.count <= 32,
              let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }
        let session = String((obj["session_id"] as? String ?? "unknown")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(64))
        guard !session.isEmpty else { return }
        let url = dir.appendingPathComponent("\(agent)-\(session).json")
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AgentEvent.self, from: $0) }
        let event = obj["hook_event_name"] as? String ?? ""
        let t = now.timeIntervalSince1970
        var state: AgentState
        var at = t
        var detail: String?
        switch event {
        case "UserPromptSubmit": state = .working
        case "Stop": state = .finished
        case "SessionStart":
            // An automatic compaction restarts the session in the middle of a turn: not a change of state.
            if (obj["source"] as? String) == "compact" { return }
            state = .idle
        case "SessionEnd":
            try? FileManager.default.removeItem(at: url)
            post()
            return
        case "Notification":
            let type = (obj["notification_type"] as? String) ?? (obj["matcher"] as? String) ?? ""
            let message = ((obj["message"] as? String) ?? "").lowercased()
            if type == "permission_prompt" || type == "elicitation_dialog" || type == "agent_needs_input"
                || (type.isEmpty && (message.contains("permission") || message.contains("approve"))) {
                state = .waiting
                detail = type.isEmpty ? "permission_prompt" : type
            } else if type == "idle_prompt" || (type.isEmpty && message.contains("waiting for your input")) {
                // Sent about a minute after the turn ended. Keep the real end time if we have it.
                state = .finished
                if previous?.state == .finished, let p = previous?.at { at = p } else { at = t - 60 }
            } else {
                return
            }
        default:
            return
        }
        let (pid, start) = agentProcess(kind: agent)
        let e = AgentEvent(agent: agent, session: session, state: state, at: at,
                           pid: pid ?? previous?.pid, pidStart: pid != nil ? start : previous?.pidStart, detail: detail)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: url, options: .atomic) }
        post()
    }

    private static func post() {
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// The agent process above this hook (hook → maybe a shell → the agent), so a session that dies without a
    /// SessionEnd (killed, crashed, terminal closed) is noticed.
    private static func agentProcess(kind: String) -> (pid_t?, UInt64?) {
        var p = getppid()
        for _ in 0..<6 {
            guard p > 1, let path = Procs.path(p) else { break }
            if AgentWatcher.match(pid: p, path: path)?.id == kind { return (p, Procs.startTime(p)) }
            guard let up = Procs.parent(p) else { break }
            p = up
        }
        return (nil, nil)
    }

    // MARK: Reading (the app side)

    /// Current sessions. Drops (and deletes) ones whose agent process has gone, or that are more than two days old.
    static func load(now: Date = Date()) -> [AgentEvent] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [AgentEvent] = []
        for n in names where n.hasSuffix(".json") {
            let url = dir.appendingPathComponent(n)
            guard let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode(AgentEvent.self, from: d) else {
                try? FileManager.default.removeItem(at: url); continue
            }
            let gone = e.pid.map { Procs.startTime($0) == nil || (e.pidStart != nil && Procs.startTime($0) != e.pidStart) } ?? false
            if gone || now.timeIntervalSince1970 - e.at > 2 * 86_400 { try? FileManager.default.removeItem(at: url); continue }
            out.append(e)
        }
        return out
    }

    /// What the agent of this kind is doing, combining its sessions: working beats waiting beats finished. `lastActive`
    /// is the power-based guess, used to spot a stuck "working" and a question that has since been answered.
    static func state(of kind: String, in events: [AgentEvent], lastActive: Date, now: Date = Date()) -> (AgentState, Date)? {
        let mine = events.filter { $0.agent == kind }
        guard !mine.isEmpty else { return nil }
        var best: (AgentState, Date)?
        func rank(_ s: AgentState) -> Int { switch s { case .working: 3; case .waiting: 2; case .finished: 1; case .idle: 0 } }
        for e in mine {
            let at = Date(timeIntervalSince1970: e.at)
            var s = e.state
            if s == .working, now.timeIntervalSince(max(at, lastActive)) > stuckAfter { continue }   // unknown
            // Busy again after the question: it was answered (Claude Code sends no event for that).
            if s == .waiting, lastActive.timeIntervalSince(at) > 5 { s = .working }
            if best == nil || rank(s) > rank(best!.0) || (rank(s) == rank(best!.0) && at > best!.1) { best = (s, at) }
        }
        return best
    }
}

/// Puts Nocturnal's hooks into Claude Code's user settings (~/.claude/settings.json), next to anything else there,
/// and takes them out again. Each one is a guarded shell command that does nothing if Nocturnal is gone. Off the
/// main thread (Settings runs it detached), so the command is worked out on the main thread and passed in.
nonisolated enum ClaudeHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
    static let marker = "event claude-code"

    /// The command each hook runs: `nocturnal event claude-code`, skipped quietly if the program isn't there.
    static func command(executable exe: String, viaApp: Bool) -> String {
        let q = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(q) ] && \(q)\(viaApp ? " cli" : "") \(marker); exit 0"
    }

    static func isOurs(_ handler: Any) -> Bool {
        guard let h = handler as? [String: Any], let c = h["command"] as? String else { return false }
        return c.contains(marker) && c.lowercased().contains("nocturnal")
    }

    /// All five hooks are in place with this command.
    static func installed(command cmd: String) -> Bool {
        guard let (c, _) = try? AutoApprove.readClaude(), let hooks = c["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            ((hooks[ev] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [Any]) ?? []).contains { ($0 as? [String: Any])?["command"] as? String == cmd }
            }
        }
    }

    /// The settings with Nocturnal's hooks removed (everything else kept), and whether anything changed.
    static func without(_ settings: [String: Any]) -> ([String: Any], Bool) {
        var c = settings
        guard var hooks = c["hooks"] as? [String: Any] else { return (c, false) }
        var changed = false
        for (ev, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                let handlers = (g["hooks"] as? [Any]) ?? []
                let rest = handlers.filter { !isOurs($0) }
                if rest.count != handlers.count { changed = true }
                if rest.isEmpty && !handlers.isEmpty { continue }   // the group only held Nocturnal's hook
                g["hooks"] = rest
                kept.append(g)
            }
            if kept.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = kept }
        }
        if hooks.isEmpty { c.removeValue(forKey: "hooks") } else { c["hooks"] = hooks }
        return (c, changed)
    }

    /// The settings with Nocturnal's hooks added (any older copy replaced).
    static func with(_ settings: [String: Any], command cmd: String) -> [String: Any] {
        var (c, _) = without(settings)
        var hooks = c["hooks"] as? [String: Any] ?? [:]
        let handler: [String: Any] = ["type": "command", "command": cmd, "timeout": 10]
        for ev in events {
            var groups = hooks[ev] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            hooks[ev] = groups
        }
        c["hooks"] = hooks
        return c
    }

    /// Adds the hooks. A copy of the settings file is kept next to it first.
    static func install(command cmd: String) -> String? {
        do {
            let (c, raw) = try AutoApprove.readClaude()
            if let raw { try raw.write(to: AutoApprove.claudeURL.appendingPathExtension("nocturnal-backup")) }
            try AutoApprove.writeClaude(with(c, command: cmd), expecting: raw)
            return nil
        } catch { return error.localizedDescription }
    }

    static func remove() {
        guard let (c, raw) = try? AutoApprove.readClaude() else { return }
        let (out, changed) = without(c)
        if changed { try? AutoApprove.writeClaude(out, expecting: raw) }
    }
}

extension ClaudeHooks {
    /// The hook command for this install: the `nocturnal` command if it's set up, otherwise the app itself.
    @MainActor static var currentCommand: String {
        Setup.cliInstalled ? command(executable: Setup.cliPath, viaApp: false)
            : command(executable: Bundle.main.executablePath ?? "/Applications/Nocturnal.app/Contents/MacOS/Nocturnal", viaApp: true)
    }
}
