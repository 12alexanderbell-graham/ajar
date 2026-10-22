import CryptoKit
import Foundation

/// "Approve everything": sets Claude Code and Codex to run without asking (their own built-in modes), and puts
/// the person's settings back when it's turned off.
///
/// • Claude Code: `permissions.defaultMode = "bypassPermissions"` and `skipDangerousModePermissionPrompt = true`
///   in ~/.claude/settings.json (the person accepted the same warning in Nocturnal).
/// • Codex: top-level `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` in ~/.codex/config.toml.
///
/// These are user-wide defaults: every project, new sessions only (running ones keep the mode they started with).
/// It never answers macOS's own permission prompts. It can only be turned on from Nocturnal's own window (never
/// from the CLI, MCP, the phone or the settings file), so an agent can't grant itself this, and it turns itself off
/// when the work finishes, at a set time, or when the person turns it off.
///
/// The journal file is the switch: it exists exactly while it's on (or while something couldn't be put back yet),
/// and holds what to put back. Each file is marked as touched in the journal, durably, *before* it's written, and
/// the journal is only removed once every touched file has been put back and read again to check. Putting back is
/// safe to repeat: it only changes values that are still Nocturnal's.
enum AutoApprove {
    /// Tests only: a folder standing in for the home folder (and Nocturnal's own folder).
    nonisolated(unsafe) static var testRoot: URL?

    static var journalURL: URL { (testRoot ?? StateFiles.dir).appendingPathComponent("auto-approve.json") }
    static var isOn: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    nonisolated static var claudeURL: URL {
        (testRoot ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(".claude/settings.json")
    }
    static var codexURL: URL {
        if let t = testRoot { return t.appendingPathComponent(".codex/config.toml") }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("config.toml")
    }

    /// When it turns itself off.
    enum Ends: String, Codable, CaseIterable {
        case work, time, manual
    }

    struct Journal: Codable {
        var claudeMode: String?        // previous permissions.defaultMode (nil = wasn't set)
        var claudeSkip: Bool?          // previous skipDangerousModePermissionPrompt
        var claudeTouched = false      // marked before the file is written; cleared once it's put back
        var codexApproval: String?     // previous top-level lines, verbatim (nil = wasn't there)
        var codexSandbox: String?
        var codexTouched = false
        var ends: Ends?                // nil (older journals) = when the person turns it off
        var endsAt: Double?            // Unix seconds: the set time, or the latest it can last while waiting for work
        var sawWork: Bool?             // Nocturnal has kept the Mac awake for work since it was turned on
        var since: Double?
        /// Why the last attempt to put things back failed. While set, it's still (possibly) on.
        var problem: String?
    }

    static let codexApprovalLine = "approval_policy = \"never\""
    static let codexSandboxLine = "sandbox_mode = \"danger-full-access\""
    /// "When the work finishes" still ends after a day, so a session that never starts can't leave it on.
    static let workCap: TimeInterval = 24 * 3600

    static func load() -> Journal? {
        guard let d = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: d)
    }

    @discardableResult
    private static func save(_ j: Journal) -> Bool {
        guard let d = try? JSONEncoder().encode(j) else { return false }
        if testRoot != nil { return (try? d.write(to: journalURL, options: .atomic)) != nil }
        return StateFiles.writeDurably(d, to: journalURL)
    }

    /// The last failure to put things back, if any (Approve everything may still be in force).
    static var problem: String? { isOn ? (load()?.problem ?? (load() == nil ? "Its record is damaged" : nil)) : nil }

    /// Turns it on. Throws with a plain reason if a file can't be read or written safely; then nothing stays changed.
    static func turnOn(ends: Ends = .work, hours: Double? = nil) throws {
        guard !isOn else { return }
        // Read both first, so a problem with either changes nothing.
        let (claude, claudeRaw) = try readClaude()
        let codexText = try readCodex()
        try TOMLTop.check(codexText)
        let perms = claude["permissions"] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        var j = Journal()
        j.claudeMode = perms["defaultMode"] as? String
        j.claudeSkip = claude["skipDangerousModePermissionPrompt"] as? Bool
        j.codexApproval = TOMLTop.line(codexText, key: "approval_policy")
        j.codexSandbox = TOMLTop.line(codexText, key: "sandbox_mode")
        j.ends = ends
        j.since = now
        switch ends {
        case .time: j.endsAt = now + (hours ?? 8) * 3600
        case .work: j.endsAt = now + workCap
        case .manual: j.endsAt = nil
        }
        // Both files are marked as touched before either is written: if Nocturnal dies at any point from here on,
        // turning it off (or the next launch) puts back whatever was written. Nothing written yet means nothing to undo.
        j.claudeTouched = true
        j.codexTouched = true
        guard save(j) else { throw SetupError(message: "Couldn't save Nocturnal's record of your settings, so nothing was changed.") }
        do {
            var c = claude
            var p = perms
            p["defaultMode"] = "bypassPermissions"
            c["permissions"] = p
            c["skipDangerousModePermissionPrompt"] = true
            try writeClaude(c, expecting: claudeRaw)
            var t = try TOMLTop.set(codexText, key: "approval_policy", line: codexApprovalLine)
            t = try TOMLTop.set(t, key: "sandbox_mode", line: codexSandboxLine)
            try writeCodex(t, expecting: codexText)
            // Read both back: it's only "on" once both tools would actually see it.
            let (c2, _) = try readClaude()
            let t2 = try readCodex()
            guard (c2["permissions"] as? [String: Any])?["defaultMode"] as? String == "bypassPermissions",
                  TOMLTop.line(t2, key: "approval_policy") == codexApprovalLine,
                  TOMLTop.line(t2, key: "sandbox_mode") == codexSandboxLine else {
                throw SetupError(message: "The settings didn't stick (another app may have rewritten them), so it was turned off again.")
            }
            saveShellRestore(j, claude: c2, codexText: t2)
        } catch {
            // Put back whatever got changed, so a failure never leaves it half on. If even that fails, the journal
            // stays and the panel says so.
            try? turnOff()
            throw error
        }
    }

    /// Turns it off: puts back what was there, but only where the value is still Nocturnal's (a value the person has
    /// changed since is left alone). Throws, and keeps the journal, if any file couldn't be put back and checked.
    static func turnOff() throws {
        guard isOn else { return }
        // A damaged journal still means "on": undo Nocturnal's own values (they can only be Nocturnal's) without the
        // previous ones, rather than leaving both tools running without asking.
        var j = load() ?? Journal(claudeTouched: true, codexTouched: true)
        var problems: [String] = []
        if j.claudeTouched {
            do { try restoreClaude(j); j.claudeTouched = false } catch { problems.append(error.localizedDescription) }
        }
        if j.codexTouched {
            do { try restoreCodex(j); j.codexTouched = false } catch { problems.append(error.localizedDescription) }
        }
        if problems.isEmpty {
            try? FileManager.default.removeItem(at: restoreDir)
            try? FileManager.default.removeItem(at: journalURL)
            if isOn { throw SetupError(message: "Put your settings back, but couldn't remove Nocturnal's record of them. It will try again.") }
            return
        }
        j.problem = problems.joined(separator: " ")
        save(j)
        throw SetupError(message: j.problem! + " Approve everything may still be on; Nocturnal keeps trying.")
    }

    /// Notes that Nocturnal kept the Mac awake for work since it was turned on ("when the work finishes").
    static func markWork() {
        guard var j = load(), j.ends == .work, j.sawWork != true, j.problem == nil else { return }
        j.sawWork = true
        save(j)
    }

    /// Why it should turn itself off now, if it should. `holdingForWork`: Nocturnal is keeping the Mac awake right now.
    static func expiry(holdingForWork: Bool, now: Date = Date()) -> String? {
        guard let j = load() else { return nil }
        if j.problem != nil { return "retry" }
        if let at = j.endsAt, now.timeIntervalSince1970 >= at { return j.ends == .time ? "Its time was up" : "No work started for a day" }
        if j.ends == .work, j.sawWork == true, !holdingForWork { return "The work finished" }
        return nil
    }

    /// One line for the panel and Settings: how and when it ends.
    static var endsLine: String? {
        guard let j = load() else { return nil }
        if j.problem != nil { return "Couldn't put your settings back yet" }
        switch j.ends {
        case .work: return j.sawWork == true ? "Turns off when the work finishes" : "Turns off when the next work finishes"
        case .time:
            guard let at = j.endsAt else { return nil }
            return "Turns off at " + Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .shortened)
        case .manual, nil: return "Stays on until you turn it off"
        }
    }

    // MARK: Putting back

    /// Claude's settings with Nocturnal's values put back (pure).
    private static func restored(claude c0: [String: Any], _ j: Journal) -> [String: Any] {
        var c = c0
        var perms = c["permissions"] as? [String: Any] ?? [:]
        if perms["defaultMode"] as? String == "bypassPermissions" {
            if let m = j.claudeMode { perms["defaultMode"] = m } else { perms.removeValue(forKey: "defaultMode") }
        }
        if perms.isEmpty { c.removeValue(forKey: "permissions") } else { c["permissions"] = perms }
        if c["skipDangerousModePermissionPrompt"] as? Bool == true {
            if let s = j.claudeSkip { c["skipDangerousModePermissionPrompt"] = s } else { c.removeValue(forKey: "skipDangerousModePermissionPrompt") }
        }
        return c
    }

    /// Codex's config with Nocturnal's lines put back (pure).
    private static func restored(codex t0: String, _ j: Journal) throws -> String {
        var t = t0
        if TOMLTop.line(t, key: "approval_policy") == codexApprovalLine { t = try TOMLTop.set(t, key: "approval_policy", line: j.codexApproval) }
        if TOMLTop.line(t, key: "sandbox_mode") == codexSandboxLine { t = try TOMLTop.set(t, key: "sandbox_mode", line: j.codexSandbox) }
        return t
    }

    /// For the watchdog script, in case the app is deleted while this is on: each file's put-back version and the
    /// fingerprint of the file as Nocturnal left it. The script only copies the put-back version over a file
    /// that still has exactly that fingerprint (anything changed since is left for Nocturnal itself).
    static var restoreDir: URL { (testRoot ?? StateFiles.dir).appendingPathComponent("approve-restore") }

    private static func saveShellRestore(_ j: Journal, claude: [String: Any], codexText: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        func put(_ name: String, target: URL, restoredData: Data?) {
            guard let restoredData, let now = try? Data(contentsOf: target) else { return }
            let sha = SHA256.hash(data: now).map { String(format: "%02x", $0) }.joined()
            try? restoredData.write(to: restoreDir.appendingPathComponent("\(name).restored"), options: .atomic)
            try? Data(sha.utf8).write(to: restoreDir.appendingPathComponent("\(name).sha"), options: .atomic)
            try? Data(target.path.utf8).write(to: restoreDir.appendingPathComponent("\(name).target"), options: .atomic)
        }
        put("claude", target: claudeURL,
            restoredData: try? JSONSerialization.data(withJSONObject: restored(claude: claude, j), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        put("codex", target: codexURL, restoredData: (try? restored(codex: codexText, j)).map { Data($0.utf8) })
    }

    private static func restoreClaude(_ j: Journal) throws {
        guard FileManager.default.fileExists(atPath: claudeURL.path) else { return }   // nothing there, nothing to undo
        let (c0, raw) = try readClaude(forRestore: true)
        let c = restored(claude: c0, j)
        if !NSDictionary(dictionary: c).isEqual(to: c0) { try writeClaude(c, expecting: raw) }
        // Check what's on disk now.
        let (after, _) = try readClaude(forRestore: true)
        let mode = (after["permissions"] as? [String: Any])?["defaultMode"] as? String
        if mode == "bypassPermissions" && j.claudeMode != "bypassPermissions" {
            throw SetupError(message: "~/.claude/settings.json still says bypassPermissions.")
        }
    }

    private static func restoreCodex(_ j: Journal) throws {
        guard FileManager.default.fileExists(atPath: codexURL.path) else { return }
        guard let t0 = try? String(contentsOf: codexURL, encoding: .utf8) else {
            throw SetupError(message: "Couldn't read ~/.codex/config.toml to put it back.")
        }
        let t = try restored(codex: t0, j)
        if t != t0 { try writeCodex(t, expecting: t0) }
        guard let after = try? String(contentsOf: codexURL, encoding: .utf8) else {
            throw SetupError(message: "Couldn't read ~/.codex/config.toml back to check it.")
        }
        if TOMLTop.line(after, key: "approval_policy") == codexApprovalLine && j.codexApproval != codexApprovalLine
            || TOMLTop.line(after, key: "sandbox_mode") == codexSandboxLine && j.codexSandbox != codexSandboxLine {
            throw SetupError(message: "~/.codex/config.toml still says never ask.")
        }
    }

    // MARK: Files

    /// The parsed settings and the exact bytes they came from (for compare-and-swap); empty if there's no file.
    nonisolated static func readClaude(forRestore: Bool = false) throws -> ([String: Any], Data?) {
        guard FileManager.default.fileExists(atPath: claudeURL.path) else { return ([:], nil) }
        let bad = EditError(message: forRestore
            ? "Couldn't read ~/.claude/settings.json to put it back (it isn't plain JSON or can't be opened)."
            : "Couldn't read ~/.claude/settings.json (it isn't plain JSON), so nothing was changed.")
        guard let d = try? Data(contentsOf: claudeURL) else { throw bad }
        if String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ([:], d) }
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw bad }
        return (obj, d)
    }

    /// Codex's config as text; "" if there is none. Throws if it exists but can't be read, so it's never overwritten.
    private static func readCodex() throws -> String {
        guard FileManager.default.fileExists(atPath: codexURL.path) else { return "" }
        guard let t = try? String(contentsOf: codexURL, encoding: .utf8) else {
            throw SetupError(message: "Couldn't read ~/.codex/config.toml, so nothing was changed.")
        }
        return t
    }

    /// Writes only if the file still holds exactly what was read (Claude Code or an editor may be saving it too).
    nonisolated static func writeClaude(_ obj: [String: Any], expecting raw: Data?) throws {
        let now = FileManager.default.fileExists(atPath: claudeURL.path) ? try? Data(contentsOf: claudeURL) : nil
        guard now == raw else { throw EditError(message: "~/.claude/settings.json changed while Nocturnal was editing it; try again.") }
        try FileManager.default.createDirectory(at: claudeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try d.write(to: claudeURL, options: .atomic)
    }

    private static func writeCodex(_ text: String, expecting old: String) throws {
        let now = FileManager.default.fileExists(atPath: codexURL.path) ? (try? String(contentsOf: codexURL, encoding: .utf8)) : ""
        guard now == old else { throw SetupError(message: "~/.codex/config.toml changed while Nocturnal was editing it; try again.") }
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: codexURL, atomically: true, encoding: .utf8)
    }
}

/// A file couldn't be read or written safely (usable off the main thread, unlike SetupError).
nonisolated struct EditError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Top-level `key = value` lines in a TOML file, edited as text so comments and layout stay as they are. Knows
/// enough TOML not to be fooled: table headers end the top level, lines inside multi-line strings and multi-line
/// arrays are never keys, and quoted keys (`"approval_policy" = …`) count. Same rules as the Windows/Linux app.
enum TOMLTop {
    private struct Entry { let index: Int; let key: String }

    /// The top-level key lines, in order, with the index where the top level ends (the first table header).
    private static func scan(_ lines: [String]) -> (entries: [Entry], end: Int) {
        var entries: [Entry] = []
        var multi: String?      // open multi-line string delimiter
        var depth = 0           // open brackets of a multi-line array
        for (i, raw) in lines.enumerated() {
            if let m = multi {
                if occurrences(of: m, in: raw) % 2 == 1 { multi = nil }
                continue
            }
            if depth > 0 { depth = max(0, depth + bracketDelta(stripStrings(raw))); continue }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if t.hasPrefix("[") { return (entries, i) }   // a table header: the top level ends here
            guard let eq = keyEnd(t) else { continue }
            let key = unquote(String(t[..<eq]).trimmingCharacters(in: .whitespaces))
            entries.append(Entry(index: i, key: key))
            let value = String(t[t.index(after: eq)...])
            for d in ["\"\"\"", "'''"] where occurrences(of: d, in: value) % 2 == 1 { multi = d; break }
            if multi == nil { depth = max(0, bracketDelta(stripStrings(value))) }
        }
        return (entries, lines.count)
    }

    /// Where the key part of a `key = value` line ends (the `=` outside quotes), or nil.
    private static func keyEnd(_ t: String) -> String.Index? {
        var quote: Character?
        var i = t.startIndex
        while i < t.endIndex {
            let ch = t[i]
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "=" { return i }
            i = t.index(after: i)
        }
        return nil
    }

    private static func unquote(_ k: String) -> String {
        if k.count >= 2, let f = k.first, f == k.last, f == "\"" || f == "'" { return String(k.dropFirst().dropLast()) }
        return k
    }

    private static func occurrences(of s: String, in t: String) -> Int { t.components(separatedBy: s).count - 1 }

    /// The line with its quoted strings and trailing comment removed (so brackets inside strings don't count).
    static func stripStrings(_ s: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if let q = quote {
                if escaped { escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "#" { break }
            out.append(ch)
        }
        return out
    }

    private static func bracketDelta(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1 == "[" ? 1 : $1 == "]" ? -1 : 0) }
    }

    /// The top-level `key = …` line, verbatim, or nil.
    static func line(_ text: String, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        return scan(lines).entries.first { $0.key == key }.map { lines[$0.index] }
    }

    /// Refuses files whose top level Nocturnal can't edit safely (the same key twice).
    static func check(_ text: String) throws {
        let keys = scan(text.components(separatedBy: "\n")).entries.map(\.key)
        for k in ["approval_policy", "sandbox_mode"] where keys.filter({ $0 == k }).count > 1 {
            throw SetupError(message: "~/.codex/config.toml sets \(k) twice, so Nocturnal left it alone.")
        }
    }

    /// Replaces the top-level `key = …` line with `line` (nil removes it), or adds `line` at the top. Checks the
    /// result has the key exactly once (or not at all when removing), so it can never write a broken file.
    static func set(_ text: String, key: String, line: String?) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let e = scan(lines).entries.first(where: { $0.key == key }) {
            if let line { lines[e.index] = line } else { lines.remove(at: e.index) }
        } else if let line {
            lines.insert(line, at: 0)
        }
        let out = lines.joined(separator: "\n")
        let count = scan(out.components(separatedBy: "\n")).entries.filter { $0.key == key }.count
        guard count == (line == nil ? 0 : 1) else {
            throw SetupError(message: "Couldn't edit \(key) in ~/.codex/config.toml safely, so it was left alone.")
        }
        return out
    }
}
