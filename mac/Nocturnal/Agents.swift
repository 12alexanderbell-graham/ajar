import AppKit
import Darwin
import IOKit.pwr_mgt

struct AgentKind: Hashable {
    let id: String
    let name: String
    /// Executable names that are this agent outright.
    let executables: Set<String>
    /// Substrings in argv that identify it when it runs under node, bun or python.
    let scriptHints: [String]
    /// Folders the agent writes its transcript to. A fresh write means it's working.
    let transcriptDirs: [String]
    /// Below this many watts for the whole process tree, the agent counts as idle.
    let idleWatts: Double

    static let all: [AgentKind] = [
        AgentKind(id: "claude-code", name: "Claude Code", executables: ["claude"],
                  scriptHints: ["@anthropic-ai/claude-code", "/claude-code/", "/bin/claude"],
                  transcriptDirs: [".claude/projects"], idleWatts: 0.02),
        AgentKind(id: "codex", name: "Codex", executables: ["codex"],
                  scriptHints: ["@openai/codex", "/bin/codex"], transcriptDirs: [".codex/sessions"], idleWatts: 0.02),
        AgentKind(id: "gemini", name: "Gemini CLI", executables: ["gemini"],
                  scriptHints: ["@google/gemini-cli", "/bin/gemini"], transcriptDirs: [".gemini/tmp"], idleWatts: 0.02),
        AgentKind(id: "cursor-agent", name: "Cursor Agent", executables: ["cursor-agent"], scriptHints: ["cursor-agent"], transcriptDirs: [], idleWatts: 0.02),
        AgentKind(id: "opencode", name: "OpenCode", executables: ["opencode"], scriptHints: ["opencode-ai"], transcriptDirs: [], idleWatts: 0.02),
        AgentKind(id: "aider", name: "Aider", executables: ["aider"], scriptHints: ["/bin/aider", "aider-chat"], transcriptDirs: [], idleWatts: 0.02),
        AgentKind(id: "copilot", name: "Copilot CLI", executables: [], scriptHints: ["@github/copilot"], transcriptDirs: [], idleWatts: 0.02),
                AgentKind(id: "amp", name: "Amp", executables: [], scriptHints: ["@sourcegraph/amp"], transcriptDirs: [], idleWatts: 0.02),
        AgentKind(id: "ollama", name: "Ollama", executables: ["ollama"], scriptHints: [], transcriptDirs: [], idleWatts: 0.5),
    ]

    /// The Claude desktop app. Electron idles noisily, so it needs a much higher bar to count as working.
    static let claudeApp = AgentKind(id: "claude-app", name: "Claude app", executables: [], scriptHints: [],
                                     transcriptDirs: [], idleWatts: 0.12)   // measured ~0.3 W for the whole tree mid-session
    static let claudeAppBundleID = "com.anthropic.claudefordesktop"

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]

    /// An app the person added themselves: a game server, a render, a download client, anything.
    static func custom(_ app: WatchedApp) -> AgentKind {
        AgentKind(id: "app:" + app.id, name: app.name, executables: [], scriptHints: [], transcriptDirs: [], idleWatts: 0.15)
    }

    /// Something that asked macOS not to sleep (a download, an export, a build).
    static func sleepRequest(_ name: String) -> AgentKind {
        AgentKind(id: "request:" + name, name: name, executables: [], scriptHints: [], transcriptDirs: [], idleWatts: .infinity)
    }

    var isAI: Bool { !id.hasPrefix("app:") && !id.hasPrefix("request:") }
    var isRequest: Bool { id.hasPrefix("request:") }
}

/// An app picked from "Add app…". `id` is the bundle path, or the executable name for command-line tools.
struct WatchedApp: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct AgentSession: Identifiable, Equatable {
    var id: String { kind.id + "#\(pid)" }
    let pid: pid_t
    let kind: AgentKind
    var project: String?
    var lastActive: Date
    var watts: Double
    var detail: String?
    /// A command the agent started (a build, tests, a download) is still running, even at no power right now.
    var toolRunning = false
    /// Separate copies of this agent that are running (shown as "×2").
    var instances = 1
    /// What the agent itself reported through its hooks (nil when it has none): working, waiting for the person,
    /// finished. Set by the engine; overrides the power-based guess.
    var state: AgentState?
}

/// A sleep blocker someone else is holding, for the "also keeping your Mac awake" list.
struct SleepBlocker: Identifiable, Equatable {
    var id: String { "\(pid)-\(name)" }
    let pid: pid_t
    let process: String
    let name: String
    let since: Date
    /// macOS didn't report when the request started.
    var sinceUnknown = false
}

/// Finds running agents and decides whether each one is actually doing something.
final class AgentWatcher {
    private(set) var sessions: [AgentSession] = []
    /// Agent processes, their children, and everything above them (terminal, editor). Never throttled or frozen.
    private(set) var protectedPids: Set<pid_t> = []
    private(set) var protectedBundles: Set<String> = []

    private var lastTreeEnergy: [pid_t: UInt64] = [:]
    private var lastSample: Date?
    private var transcriptMTime: [String: Date] = [:]
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private(set) var blockers: [SleepBlocker] = []

    /// First time each sleep request was seen, for requests that don't say when they started.
    private var requestFirstSeen: [String: Date] = [:]

    /// A command started by an agent counts as work for two hours whatever it's doing, and after that only while it
    /// uses the CPU (a dev server left idle in the background mustn't keep the Mac awake forever, but a long build
    /// still does). Children started within 30 s of the agent are usually its own helpers (MCP servers, a shell):
    /// they count only while busy, so a command started in the first seconds isn't missed either.
    static let toolMaxAge: TimeInterval = 2 * 3600
    static let helperWindow: TimeInterval = 30
    /// A child process using more than this counts as busy.
    static let busyChildWatts = 0.05

    func sample(custom: [WatchedApp] = [], requests: Bool = true, extraKinds: [AgentKind] = []) {
        let now = Date()
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        let previousSampleUs = lastSample.map { UInt64($0.timeIntervalSince1970 * 1_000_000) }
        lastSample = now

        let pids = Procs.allPids()
        var parent: [pid_t: pid_t] = [:]
        var children: [pid_t: [pid_t]] = [:]
        var paths: [pid_t: String] = [:]
        for pid in pids {
            guard let pp = Procs.parent(pid) else { continue }
            parent[pid] = pp
            children[pp, default: []].append(pid)
        }

        // Find agent roots: the topmost process of each kind, so a CLI and its own helpers count once.
        var found: [(pid_t, AgentKind)] = []
        for pid in pids {
            guard let path = Procs.path(pid) else { continue }
            paths[pid] = path
            let exe = (path as NSString).lastPathComponent
            if let kind = extraKinds.first(where: { $0.executables.contains(exe) }) ?? Self.match(pid: pid, path: path) {
                found.append((pid, kind))
            }
        }
        let foundSet = Dictionary(found.map { ($0.0, $0.1.id) }, uniquingKeysWith: { a, _ in a })
        let roots = found.filter { pid, kind in
            var p = parent[pid]
            while let cur = p, cur > 1 { if foundSet[cur] == kind.id { return false }; p = parent[cur] }
            return true
        }

        // Claude desktop: one session for the whole app, rooted at its main process.
        var allRoots = roots
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == AgentKind.claudeAppBundleID }) {
            allRoots.append((app.processIdentifier, AgentKind.claudeApp))
        }

        // Apps the person added: the topmost process whose bundle (or executable name) matches.
        for app in custom {
            let members = pids.filter { pid in
                guard let path = paths[pid] else { return false }
                return Procs.bundlePath(of: path) == app.id || (path as NSString).lastPathComponent == app.id
            }
            let memberSet = Set(members)
            for pid in members where !(parent[pid].map(memberSet.contains) ?? false) {
                allRoots.append((pid, AgentKind.custom(app)))
            }
        }

        func tree(_ root: pid_t) -> [pid_t] {
            var out: [pid_t] = [], stack = [root]
            while let p = stack.popLast() { out.append(p); stack.append(contentsOf: children[p] ?? []) }
            return out
        }

        let freshTranscripts = Set(AgentKind.all.filter { !$0.transcriptDirs.isEmpty && transcriptsChanged($0) }.map(\.id))
        var newEnergy: [pid_t: UInt64] = [:]
        var next: [AgentSession] = []
        var protect = Set<pid_t>()

        for (root, kind) in allRoots {
            let members = tree(root)
            protect.formUnion(members)
            var p = parent[root]
            while let cur = p, cur > 1 { protect.insert(cur); p = parent[cur] }

            // Per process, so a child that exits doesn't make the whole tree read 0 W: each process counts what it
            // used since the last sample, and one that started since then counts everything it used.
            var used: UInt64 = 0
            var usedBy: [pid_t: UInt64] = [:]
            for pid in members {
                guard let e = Procs.usage(pid)?.ri_energy_nj else { continue }
                newEnergy[pid] = e
                var d: UInt64 = 0
                if let prev = lastTreeEnergy[pid] { if e >= prev { d = e - prev } }
                else if let since = previousSampleUs, let start = Procs.startTime(pid), start >= since { d = e }
                usedBy[pid] = d
                used &+= d
            }
            let watts = dt > 0 && previousSampleUs != nil ? Double(used) / 1e9 / dt : 0

            let previous = sessions.first { $0.pid == root && $0.kind == kind }
            var tool = false
            if kind.isAI, let rootStart = Procs.startTime(root) {
                let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)
                tool = members.dropFirst().contains { p in
                    guard foundSet[p] != kind.id, let s = Procs.startTime(p), s > rootStart, nowUs > s else { return false }
                    let busy = dt > 0 && Double(usedBy[p] ?? 0) / 1e9 / dt > Self.busyChildWatts
                    let early = Double(s - rootStart) / 1e6 <= Self.helperWindow
                    let old = Double(nowUs - s) / 1e6 >= Self.toolMaxAge
                    return early || old ? busy : true
                }
            }
            let busy = watts > kind.idleWatts || freshTranscripts.contains(kind.id) || tool
            let active = busy ? now : (previous?.lastActive ?? .distantPast)
            next.append(AgentSession(pid: root, kind: kind, project: previous?.project ?? Self.workingDirectoryName(root),
                                     lastActive: active, watts: watts, toolRunning: tool))
        }

        // Anything else that asked macOS to stay awake. Fresh requests (a download, an export, a build) count as
        // work; ones held for hours are almost always forgotten, so they're only listed, never obeyed.
        var stale: [SleepBlocker] = []
        var seenKeys = Set<String>()
        for var r in Self.sleepRequests() where r.pid != getpid() && !protect.contains(r.pid) {
            // A request with no start time is aged from when Nocturnal first saw it, not treated as new forever.
            let key = "\(r.pid)|\(r.name)"
            seenKeys.insert(key)
            if r.sinceUnknown {
                let first = requestFirstSeen[key] ?? now
                requestFirstSeen[key] = first
                r = SleepBlocker(pid: r.pid, process: r.process, name: r.name, since: first)
            }
            if now.timeIntervalSince(r.since) < 6 * 3600 {
                guard requests else { continue }
                let kind = AgentKind.sleepRequest(r.process)
                next.append(AgentSession(pid: r.pid, kind: kind, project: nil, lastActive: now, watts: 0, detail: r.name))
                var p: pid_t? = r.pid
                while let cur = p, cur > 1 { protect.insert(cur); p = parent[cur] }
            } else {
                stale.append(r)
            }
        }
        blockers = stale.sorted { $0.since < $1.since }
        requestFirstSeen = requestFirstSeen.filter { seenKeys.contains($0.key) }

        lastTreeEnergy = newEnergy
        // One row per agent kind: a desktop app and its bundled CLI, or two terminals running Claude Code,
        // are the same thing to the person reading the list.
        var merged: [String: AgentSession] = [:]
        var order: [String] = []
        for s in next {
            if var m = merged[s.kind.id] {
                m.watts += s.watts
                m.toolRunning = m.toolRunning || s.toolRunning
                m.instances += 1
                if s.lastActive > m.lastActive { m.lastActive = s.lastActive }
                if m.project == nil { m.project = s.project }
                if m.detail == nil { m.detail = s.detail }
                merged[s.kind.id] = m
            } else {
                merged[s.kind.id] = s
                order.append(s.kind.id)
            }
        }
        sessions = order.compactMap { merged[$0] }.sorted { $0.lastActive > $1.lastActive }
        protectedPids = protect
        protectedBundles = Set(protect.compactMap { paths[$0].flatMap(Procs.bundlePath(of:)) })
    }

    private static let ignoredRequesters: Set<String> = ["powerd", "WindowServer", "coreaudiod", "mds_stores", "mds", "loginwindow", "sharingd", "bluetoothd"]
    private static let blockingTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    private static let mediaHints = ["audio", "video", "media", "playback", "playing", "webrtc", "call", "wake lock", "music", "now playing"]

    /// Who is currently asking macOS not to sleep, from the power manager's own list.
    static func sleepRequests() -> [SleepBlocker] {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let byPid = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [SleepBlocker] = []
        for (pidNum, list) in byPid {
            for a in list {
                let type = (a["AssertionTrueType"] as? String) ?? (a["AssertType"] as? String) ?? ""
                guard blockingTypes.contains(type) else { continue }
                // Music, video and calls keep an open Mac awake for the person watching; with the lid shut
                // nobody is, and macOS itself would sleep, so they never count as work.
                let assertName = ((a["AssertName"] as? String) ?? "").lowercased()
                if mediaHints.contains(where: assertName.contains) { continue }
                let pid = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? pidNum.int32Value
                let proc = (a["Process Name"] as? String) ?? ""
                guard !ignoredRequesters.contains(proc), isUserFacing(pid: pid, name: proc) else { continue }
                let app = NSRunningApplication(processIdentifier: pid)
                let display = app?.localizedName ?? (Procs.path(pid).map { ($0 as NSString).lastPathComponent } ?? proc)
                let start = a["AssertStartWhen"] as? Date
                out.append(SleepBlocker(pid: pid, process: display, name: (a["AssertName"] as? String) ?? type,
                                        since: start ?? Date(), sinceUnknown: start == nil))
            }
        }
        return out
    }

    /// Only requests from apps the person runs count. macOS daemons (nsurlsessiond, backupd, softwareupdated)
    /// ask to stay awake all the time for their own housekeeping and must never keep a closed laptop running.
    /// `caffeinate` is the exception: someone typed it on purpose.
    private static func isUserFacing(pid: pid_t, name: String) -> Bool {
        if name == "caffeinate" { return true }
        guard let path = Procs.path(pid), let bundle = Procs.bundlePath(of: path) else { return false }
        let lower = (bundle as NSString).lastPathComponent.lowercased()
        if lower.contains("update") || lower.contains("helper") || lower.contains("agent.app") { return false }
        return !bundle.hasPrefix("/System/Library/") && !bundle.hasPrefix("/Library/Apple/") && !bundle.hasPrefix("/usr/")
    }

    static func match(pid: pid_t, path: String) -> AgentKind? {
        let exe = (path as NSString).lastPathComponent
        if let k = AgentKind.all.first(where: { $0.executables.contains(exe) }) { return k }
        guard AgentKind.interpreters.contains(exe) || exe.hasPrefix("python") else { return nil }
        let args = Procs.arguments(pid).prefix(3).joined(separator: " ")
        return AgentKind.all.first { k in k.scriptHints.contains { args.contains($0) } }
    }

    private func transcriptsChanged(_ kind: AgentKind) -> Bool {
        var changed = false
        for dir in kind.transcriptDirs {
            let newest = Self.newestModification(in: home + "/" + dir, depth: 5)
            if let n = newest, let old = transcriptMTime[dir], n > old { changed = true }
            if let n = newest { transcriptMTime[dir] = n }
        }
        return changed
    }

    /// Newest mtime among folders and files a few levels down. Every folder is opened: appending to a
    /// transcript doesn't change its folder's time, so skipping "old" folders would miss a long session in an
    /// old project folder. Capped at 20 000 entries (a few milliseconds).
    static func newestModification(in path: String, depth: Int) -> Date? {
        var budget = 20_000
        return newest(in: path, depth: depth, budget: &budget)
    }

    private static func newest(in path: String, depth: Int, budget: inout Int) -> Date? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        var newest: Date?
        for item in items where !item.hasPrefix(".") {
            guard budget > 0 else { break }
            budget -= 1
            let full = path + "/" + item
            guard let attrs = try? fm.attributesOfItem(atPath: full), let m = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || m > newest! { newest = m }
            // attributesOfItem doesn't follow symlinks, so a link back up the tree can't loop.
            if depth > 1, attrs[.type] as? FileAttributeType == .typeDirectory,
               let inner = Self.newest(in: full, depth: depth - 1, budget: &budget), inner > (newest ?? .distantPast) {
                newest = inner
            }
        }
        return newest
    }

    static func workingDirectoryName(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !path.isEmpty, path != "/", !path.contains(".app/") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : (path as NSString).lastPathComponent
    }
}
