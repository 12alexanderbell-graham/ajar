import Foundation

/// "Approve everything": sets Claude Code and Codex to run without asking (their own built-in modes), and puts
/// the person's settings back when it's turned off.
///
/// • Claude Code: `permissions.defaultMode = "bypassPermissions"` and `skipDangerousModePermissionPrompt = true`
///   in ~/.claude/settings.json (the person accepted the same warning in Ajar).
/// • Codex: top-level `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in ~/.codex/config.toml.
///
/// New sessions pick it up; running ones keep the mode they started with. It can only be turned on from Ajar's
/// own window (never from the CLI, MCP, the phone or the settings file), so an agent can't grant itself this.
/// The journal file is the switch: it exists exactly while it's on, and holds what to put back.
enum AutoApprove {
    static var journalURL: URL { StateFiles.dir.appendingPathComponent("auto-approve.json") }
    static var isOn: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    static var claudeURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var codexURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }

    private struct Journal: Codable {
        var claudeMode: String?        // previous permissions.defaultMode (nil = wasn't set)
        var claudeSkip: Bool?          // previous skipDangerousModePermissionPrompt
        var claudeTouched = false
        var codexApproval: String?     // previous top-level lines, verbatim (nil = wasn't there)
        var codexSandbox: String?
        var codexTouched = false
    }

    static let codexApprovalLine = "approval_policy = \"never\""
    static let codexSandboxLine = "sandbox_mode = \"danger-full-access\""

    /// Turns it on. Throws with a plain reason if a file can't be read safely (nothing is changed then).
    static func turnOn() throws {
        guard !isOn else { return }
        var j = Journal()
        // Read both first, so a problem with either changes nothing.
        let claude = try readClaude()
        let codexText = (try? String(contentsOf: codexURL, encoding: .utf8)) ?? ""
        var perms = claude["permissions"] as? [String: Any] ?? [:]
        j.claudeMode = perms["defaultMode"] as? String
        j.claudeSkip = claude["skipDangerousModePermissionPrompt"] as? Bool
        j.codexApproval = topLevelLine(codexText, key: "approval_policy")
        j.codexSandbox = topLevelLine(codexText, key: "sandbox_mode")
        // Journal before touching anything: if Ajar dies halfway, turning it off still puts things back.
        try JSONEncoder().encode(j).write(to: journalURL, options: .atomic)

        var c = claude
        perms["defaultMode"] = "bypassPermissions"
        c["permissions"] = perms
        c["skipDangerousModePermissionPrompt"] = true
        try writeClaude(c)
        j.claudeTouched = true
        try JSONEncoder().encode(j).write(to: journalURL, options: .atomic)
        var t = setTopLevel(codexText, key: "approval_policy", line: codexApprovalLine)
        t = setTopLevel(t, key: "sandbox_mode", line: codexSandboxLine)
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try t.write(to: codexURL, atomically: true, encoding: .utf8)
        j.codexTouched = true
        try JSONEncoder().encode(j).write(to: journalURL, options: .atomic)
    }

    /// Turns it off: puts back what was there, but only where the value is still Ajar's (a value the person has
    /// changed since is left alone).
    static func turnOff() throws {
        guard isOn, let d = try? Data(contentsOf: journalURL), let j = try? JSONDecoder().decode(Journal.self, from: d) else {
            try? FileManager.default.removeItem(at: journalURL)
            return
        }
        if j.claudeTouched, var c = try? readClaude() {
            var perms = c["permissions"] as? [String: Any] ?? [:]
            if perms["defaultMode"] as? String == "bypassPermissions" {
                if let m = j.claudeMode { perms["defaultMode"] = m } else { perms.removeValue(forKey: "defaultMode") }
            }
            if perms.isEmpty { c.removeValue(forKey: "permissions") } else { c["permissions"] = perms }
            if c["skipDangerousModePermissionPrompt"] as? Bool == true {
                if let s = j.claudeSkip { c["skipDangerousModePermissionPrompt"] = s } else { c.removeValue(forKey: "skipDangerousModePermissionPrompt") }
            }
            try writeClaude(c)
        }
        if j.codexTouched, var t = try? String(contentsOf: codexURL, encoding: .utf8) {
            if topLevelLine(t, key: "approval_policy") == codexApprovalLine { t = setTopLevel(t, key: "approval_policy", line: j.codexApproval) }
            if topLevelLine(t, key: "sandbox_mode") == codexSandboxLine { t = setTopLevel(t, key: "sandbox_mode", line: j.codexSandbox) }
            try t.write(to: codexURL, atomically: true, encoding: .utf8)
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    // MARK: Files

    private static func readClaude() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: claudeURL.path) else { return [:] }
        let bad = SetupError(message: "Couldn't read ~/.claude/settings.json (it isn't plain JSON), so nothing was changed.")
        guard let d = try? Data(contentsOf: claudeURL) else { throw bad }
        if String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw bad }
        return obj
    }

    private static func writeClaude(_ obj: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: claudeURL, options: .atomic)
    }

    /// The top-level `key = …` line (before the first [table]), verbatim, or nil.
    static func topLevelLine(_ text: String, key: String) -> String? {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            if isKeyLine(line, key) { return raw }
        }
        return nil
    }

    /// Replaces the top-level `key = …` line with `line` (nil removes it), or adds `line` at the top.
    static func setTopLevel(_ text: String, key: String, line: String?) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            if isKeyLine(t, key) {
                if let line { lines[i] = line } else { lines.remove(at: i) }
                return lines.joined(separator: "\n")
            }
            i += 1
        }
        guard let line else { return text }
        lines.insert(line, at: 0)
        return lines.joined(separator: "\n")
    }

    private static func isKeyLine(_ trimmed: String, _ key: String) -> Bool {
        guard trimmed.hasPrefix(key) else { return false }
        let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }
}
