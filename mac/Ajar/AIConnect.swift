import Foundation

/// Hooks Ajar up to the AI agents people use, and the one prompt that has an agent set Ajar up for them.
/// Each connect step keeps everything else in the other app's config and saves a backup first.
enum AIConnect {
    /// What the MCP server is started with.
    static var serverCommand: (command: String, args: [String]) {
        Setup.cliInstalled ? (Setup.cliPath, ["mcp"]) : (Bundle.main.executablePath ?? "/Applications/Ajar.app/Contents/MacOS/Ajar", ["cli", "mcp"])
    }

    static let setupPrompt = """
    Ajar is installed on this Mac. It keeps the Mac awake with the lid closed while you (and other agents) work, \
    and cuts power use while the lid is shut. You can control all of it through the `ajar` MCP tools (or the \
    `ajar` command). Set it up for me:

    1. Call ajar_settings and ajar_power to see every setting and what is using power right now.
    2. Ask me, in one short message: which apps must keep running at full speed with the lid shut (music, calls, \
    a local model, Docker...), whether my Mac should stay awake only while agents work or always, and whether I'm \
    OK with a lock screen when I open the lid in exchange for the screen turning fully off (the biggest saving).
    3. Apply the strongest savings that don't touch what I named: preset max_battery, pause_simulators, \
    pause_background_audio, low_power, per-app rules with ajar_set_app_rule, and lock_on_close only if I said yes.
    4. If my lid is closed, run ajar_power_test and tell me what each saving is worth in watts.
    5. From now on, call ajar_keep_awake before long work and ajar_release when it's done.

    Never turn off the heat guard or lower the battery limit; Ajar won't let you, and that's on purpose.
    """

    // MARK: Claude Code
    // The checks and connects below read and write other apps' files and run their CLIs, so they're nonisolated:
    // Settings runs them off the main thread. The no-argument connect functions are for the main thread.

    nonisolated static var claudeCodeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var claudeCodeConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    nonisolated static var claudeCodeConnected: Bool {
        guard let d = try? Data(contentsOf: claudeCodeConfig), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["mcpServers"] as? [String: Any])?["ajar"] != nil
    }

    nonisolated static var claudeCodeInstalled: Bool { claudeCodeBinary != nil || FileManager.default.fileExists(atPath: claudeCodeConfig.path) }

    static func connectClaudeCode() -> String { connectClaudeCode(server: serverCommand) }

    /// Adds Ajar as a user-scope MCP server for Claude Code (every project). Uses `claude mcp add` when the
    /// command is installed; otherwise writes the same entry into ~/.claude.json (backup kept next to it).
    nonisolated static func connectClaudeCode(server: (command: String, args: [String])) -> String {
        let (cmd, args) = server
        if let bin = claudeCodeBinary {
            _ = Shell.run(bin, ["mcp", "remove", "--scope", "user", "ajar"])   // re-adding updates a stale path
            let r = Shell.run(bin, ["mcp", "add", "--scope", "user", "ajar", "--", cmd] + args)
            if r.code == 0 { return "Added to Claude Code for all projects. New sessions can use Ajar." }
        }
        return editJSON(claudeCodeConfig, done: "Added to Claude Code (~/.claude.json). New sessions can use Ajar.") { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["ajar"] = ["type": "stdio", "command": cmd, "args": args, "env": [String: String]()]
            root["mcpServers"] = servers
        }
    }

    // MARK: Codex

    nonisolated static var codexConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml") }
    nonisolated static var codexInstalled: Bool { FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) }
    nonisolated static var codexConnected: Bool {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        return codexAjarRange(text.components(separatedBy: "\n")) != nil || codexInlineAjar(text)
    }

    /// A table header line's name (`[mcp_servers.ajar]`, `[ mcp_servers . "ajar" ]` → `mcp_servers.ajar`), or nil.
    nonisolated static func codexHeader(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else { return nil }
        return String(t[t.index(after: t.startIndex)..<close]).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
    }

    /// The lines of a real `[mcp_servers.ajar]` table: header up to the next table.
    nonisolated static func codexAjarRange(_ lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { codexHeader($0) == "mcp_servers.ajar" }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: { codexHeader($0) != nil }) ?? lines.count
        return start..<end
    }

    /// An ajar entry written another way: `mcp_servers.ajar = {…}` or `mcp_servers.ajar.command = …` at the top,
    /// or `ajar = {…}` / `ajar.command = …` inside `[mcp_servers]`. Left alone (adding a table would duplicate it).
    nonisolated static func codexInlineAjar(_ text: String) -> Bool {
        var table = ""
        for l in text.components(separatedBy: "\n") {
            if let h = codexHeader(l) { table = h; continue }
            let t = l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
            if t.hasPrefix("#") || !t.contains("=") { continue }
            if table.isEmpty && (t.hasPrefix("mcp_servers.ajar=") || t.hasPrefix("mcp_servers.ajar.")) { return true }
            if table == "mcp_servers" && (t.hasPrefix("ajar=") || t.hasPrefix("ajar.")) { return true }
        }
        return false
    }

    /// The config text with Ajar's table added or its command and args updated (pure, so it can be checked).
    nonisolated static func codexUpdated(_ existing: String, command cmd: String, args: [String]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let commandLine = "command = \(q(cmd))", argsLine = "args = [\(args.map(q).joined(separator: ", "))]"
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if let r = codexAjarRange(lines) {
            // Update just the command and args lines; any other keys, comments and spacing stay as they are.
            func key(_ l: String) -> String { l.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
            var sawCommand = false, sawArgs = false
            for i in r where i > r.lowerBound {
                let k = key(lines[i])
                if k == "command" { lines[i] = commandLine; sawCommand = true }
                else if k == "args" { lines[i] = argsLine; sawArgs = true }
            }
            var insert: [String] = []
            if !sawCommand { insert.append(commandLine) }
            if !sawArgs { insert.append(argsLine) }
            lines.insert(contentsOf: insert, at: r.lowerBound + 1)
        } else {
            if lines.last == "" { lines.removeLast() }   // the file's final newline
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["[mcp_servers.ajar]", commandLine, argsLine, ""]
        }
        return lines.joined(separator: "\n")
    }

    static func connectCodex() -> String { connectCodex(server: serverCommand) }

    /// Adds (or updates, so a moved app is picked up) the `[mcp_servers.ajar]` table in ~/.codex/config.toml.
    /// Everything else in the file is kept, and the original is saved next to it first.
    nonisolated static func connectCodex(server: (command: String, args: [String])) -> String {
        let (cmd, args) = server
        let fm = FileManager.default
        var existing = ""
        if fm.fileExists(atPath: codexConfig.path) {
            guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else {
                return "Couldn't read ~/.codex/config.toml, so I left it alone."
            }
            existing = text
        }
        if codexInlineAjar(existing) { return "Codex already has an ajar entry written by hand; left it as it is." }
        let updated = codexUpdated(existing, command: cmd, args: args)
        do {
            try fm.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !existing.isEmpty { try existing.write(to: codexConfig.appendingPathExtension("ajar-backup"), atomically: true, encoding: .utf8) }
            try updated.write(to: codexConfig, atomically: true, encoding: .utf8)
            return "Added to Codex (~/.codex/config.toml). New sessions can use Ajar."
        } catch {
            return "Couldn't write Codex's config: \(error.localizedDescription)"
        }
    }

    // MARK: Claude app

    nonisolated static var claudeAppConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    nonisolated static var claudeAppInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Claude.app") }
    nonisolated static var claudeAppConnected: Bool {
        guard let d = try? Data(contentsOf: claudeAppConfig), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["mcpServers"] as? [String: Any])?["ajar"] != nil
    }

    static func connectClaudeApp() -> String { connectClaudeApp(server: serverCommand) }

    nonisolated static func connectClaudeApp(server: (command: String, args: [String])) -> String {
        let (cmd, args) = server
        return editJSON(claudeAppConfig, done: "Added to the Claude app. Restart it to pick Ajar up.") { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["ajar"] = ["command": cmd, "args": args]
            root["mcpServers"] = servers
        }
    }

    /// Reads a JSON config, changes it, writes it back atomically with a backup of the original. Refuses to touch
    /// a file it can't read or parse (starting from empty would wipe the other app's settings).
    nonisolated private static func editJSON(_ url: URL, done: String, _ change: (inout [String: Any]) -> Void) -> String {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return "Couldn't read \(url.lastPathComponent), so I left it alone." }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "\(url.lastPathComponent) isn't valid JSON, so I left it alone."
            }
            root = obj
            do { try data.write(to: url.appendingPathExtension("ajar-backup")) }
            catch { return "Couldn't save a backup of \(url.lastPathComponent), so I left it alone." }
        }
        change(&root)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            return done
        } catch {
            return "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Removes Ajar's MCP entry from every agent it was added to (Remove Ajar), so they don't keep starting a
    /// program that's about to be deleted. Everything else in their configs stays.
    nonisolated static func disconnectAll() {
        let dropAjar: (inout [String: Any]) -> Void = { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: "ajar")
            root["mcpServers"] = servers
        }
        if claudeCodeConnected {
            if let bin = claudeCodeBinary { _ = Shell.run(bin, ["mcp", "remove", "--scope", "user", "ajar"]) }
            if claudeCodeConnected { _ = editJSON(claudeCodeConfig, done: "", dropAjar) }
        }
        if claudeAppConnected { _ = editJSON(claudeAppConfig, done: "", dropAjar) }
        if let text = try? String(contentsOf: codexConfig, encoding: .utf8) {
            var lines = text.components(separatedBy: "\n")
            if let r = codexAjarRange(lines) {
                try? text.write(to: codexConfig.appendingPathExtension("ajar-backup"), atomically: true, encoding: .utf8)
                lines.removeSubrange(r)
                try? lines.joined(separator: "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
            }
        }
    }
}
