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

    static var claudeCodeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.claude/local/claude", "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claudeCodeConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    static var claudeCodeConnected: Bool {
        guard let d = try? Data(contentsOf: claudeCodeConfig), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["mcpServers"] as? [String: Any])?["ajar"] != nil
    }

    static var claudeCodeInstalled: Bool { claudeCodeBinary != nil || FileManager.default.fileExists(atPath: claudeCodeConfig.path) }

    /// Adds Ajar as a user-scope MCP server for Claude Code (every project). Uses `claude mcp add` when the
    /// command is installed; otherwise writes the same entry into ~/.claude.json (backup kept next to it).
    static func connectClaudeCode() -> String {
        let (cmd, args) = serverCommand
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

    static var codexConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml") }
    static var codexInstalled: Bool { FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) }
    static var codexConnected: Bool { ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").contains("[mcp_servers.ajar]") }

    /// Appends an `[mcp_servers.ajar]` table to ~/.codex/config.toml (backup kept). Leaves an existing entry alone.
    static func connectCodex() -> String {
        let (cmd, args) = serverCommand
        let existing = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if existing.contains("[mcp_servers.ajar]") { return "Codex already has Ajar." }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let block = "\n[mcp_servers.ajar]\ncommand = \(q(cmd))\nargs = [\(args.map(q).joined(separator: ", "))]\n"
        do {
            try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !existing.isEmpty { try existing.write(to: codexConfig.appendingPathExtension("ajar-backup"), atomically: true, encoding: .utf8) }
            try (existing + block).write(to: codexConfig, atomically: true, encoding: .utf8)
            return "Added to Codex (~/.codex/config.toml). New sessions can use Ajar."
        } catch {
            return "Couldn't write Codex's config: \(error.localizedDescription)"
        }
    }

    // MARK: Claude app

    static var claudeAppConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    static var claudeAppInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Claude.app") }
    static var claudeAppConnected: Bool {
        guard let d = try? Data(contentsOf: claudeAppConfig), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["mcpServers"] as? [String: Any])?["ajar"] != nil
    }

    static func connectClaudeApp() -> String {
        let (cmd, args) = serverCommand
        return editJSON(claudeAppConfig, done: "Added to the Claude app. Restart it to pick Ajar up.") { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["ajar"] = ["command": cmd, "args": args]
            root["mcpServers"] = servers
        }
    }

    /// Reads a JSON config, changes it, writes it back atomically with a backup of the original. Refuses to touch
    /// a file it can't parse.
    private static func editJSON(_ url: URL, done: String, _ change: (inout [String: Any]) -> Void) -> String {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "\(url.lastPathComponent) isn't valid JSON, so I left it alone."
            }
            root = obj
            try? data.write(to: url.appendingPathExtension("ajar-backup"))
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

    /// Which agents are on this Mac and whether each already has Ajar.
    static func status() -> [[String: Any]] {
        [["agent": "claude_code", "installed": claudeCodeInstalled, "connected": claudeCodeConnected],
         ["agent": "codex", "installed": codexInstalled, "connected": codexConnected],
         ["agent": "claude_app", "installed": claudeAppInstalled, "connected": claudeAppConnected]]
    }
}
