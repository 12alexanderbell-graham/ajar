import AppKit
import Foundation

/// `ajar` on the command line and `ajar mcp` for Claude. Both are thin clients: they send a request
/// to the running app and print the reply. Runs inside the app binary before any UI starts.
enum CLI {
    static func shouldRun() -> Bool {
        let args = CommandLine.arguments
        if (args.first.map { ($0 as NSString).lastPathComponent } == "ajar") { return true }
        return args.count > 1 && args[1] == "cli"
    }

    static func main() -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.first == "cli" { args.removeFirst() }
        guard let cmd = args.first else { print(usage); return 0 }
        let rest = Array(args.dropFirst())

        switch cmd {
        case "help", "-h", "--help": print(usage); return 0
        case "mcp": return MCPServer.run()
        case "status": return show(send("status", [:]), json: rest.contains("--json"))
        case "energy": return show(send("energy", [:]), json: rest.contains("--json"))
        case "measure": return show(send("measure", [:], timeout: 20), json: true)
        case "anyway":
            guard rest.first == "off" else { print("ajar: going below the battery limit can only be allowed in Ajar itself (it's the person's call)"); return 2 }
            return show(send("override_floor", ["on": false]))
        case "off", "auto": return show(send("mode", ["mode": cmd]))
        case "sleep": return show(send("sleep_now", [:]))
        case "watchdog": print(Watchdog.run(force: false)); return 0
        case "doctor": return doctor()
        case "rescue": return rescue()
        case "on", "always":
            var a: [String: Any] = ["mode": "always"]
            if let f = flag("--for", rest) {
                guard let m = parseDuration(f) else { print("ajar: --for needs a duration like 90m, 2h or 1h30m"); return 2 }
                a["minutes"] = m
            }
            return show(send("mode", a))
        case "hold":
            var a: [String: Any] = ["reason": flag("--reason", rest) ?? "Kept awake from the terminal"]
            if let f = flag("--for", rest) {
                guard let m = parseDuration(f) else { print("ajar: --for needs a duration like 90m, 2h or 1h30m"); return 2 }
                a["minutes"] = m
            }
            if let p = flag("--pid", rest).flatMap(Int.init) { a["pid"] = p }
            return show(send("hold", a))
        case "release": return show(send("release", rest.first.map { ["id": $0] } ?? ["all": true]))
        case "wake-at", "wake_at":
            guard let t = rest.first else { print("ajar wake-at HH:MM [--for 30m] | off"); return 2 }
            var w: [String: Any] = ["time": t]
            if let i = rest.firstIndex(of: "--for"), i + 1 < rest.count, let m = parseDuration(rest[i + 1]) { w["minutes"] = m }
            return show(send("wake_at", w))
        case "check-in", "check_in":
            guard let m = rest.first else { print("ajar check-in 0|15|30|60"); return 2 }
            return show(send("set", ["key": "check_in_minutes", "value": m]))
        case "run": return runWrapped(rest)
        case "preset":
            guard let p = rest.first else { print("ajar preset max_battery|balanced|full_speed"); return 2 }
            return show(send("preset", ["preset": p]))
        case "rule":
            guard rest.count >= 2 else { print("ajar rule <app> leave|slow|pause"); return 2 }
            return show(send("rule", ["app": rest.dropLast().joined(separator: " "), "rule": rest.last!]))
        case "watch", "unwatch":
            guard !rest.isEmpty else { print("ajar \(cmd) <app>"); return 2 }
            return show(send("watch", ["app": rest.joined(separator: " "), "remove": cmd == "unwatch"]))
        case "set":
            guard rest.count == 2 else { print("ajar set <key> <value>"); return 2 }
            return show(send("set", ["key": rest[0], "value": rest[1]]))
        case "config": return show(send("config", [:]), json: true)
        case "settings", "schema":
            let r = send("schema", [:])
            if rest.contains("--json") || (r["ok"] as? Bool) == false { return show(r, json: true) }
            for s in (r["settings"] as? [[String: Any]]) ?? [] {
                let value: Any = (s["type"] as? String == "bool") ? ((s["value"] as? Bool) == true ? "on" : "off") : (s["value"] ?? "")
                print("\(s["key"] ?? "") = \(value)   [\(((s["allowed"] as? [String]) ?? []).joined(separator: "|"))]")
                print("    \(s["description"] ?? "")\((s["note"] as? String).map { " (\($0))" } ?? "")")
            }
            print("\nChange with: ajar set <key> <value>. Per-app rules: ajar rule <app> leave|slow|pause. File: \(r["config_file"] ?? "")")
            return 0
        case "power":
            if rest.first == "test" {
                let start = send("power_test", ["screen": rest.contains("--screen"), "detailed": rest.contains("--detailed")])
                guard (start["ok"] as? Bool) != false else { return show(start) }
                print("Measuring for about \(((start["about_seconds"] as? Int) ?? 210) / 60 + 1) min, keep the lid shut (agents keep running)…")
                let deadline = Date().addingTimeInterval(rest.contains("--detailed") ? 1500 : 420)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 5)
                    let r = send("power", [:])
                    let status = r["power_test"] as? String ?? ""
                    if status == "done" { return showPower(r, json: rest.contains("--json")) }
                    if status.hasPrefix("aborted") || status == "not run yet" { print("ajar: power test \(status)"); return 1 }
                }
                print("ajar: the test didn't finish in time; run ajar power later for results"); return 1
            }
            return showPower(send("power", [:]), json: rest.contains("--json"))
        case "connect":
            let which = rest.first ?? "all"
            var did = false
            if which == "claude" || which == "claude-code" || (which == "all" && AIConnect.claudeCodeInstalled) { print("Claude Code: " + AIConnect.connectClaudeCode()); did = true }
            if which == "codex" || (which == "all" && AIConnect.codexInstalled) { print("Codex: " + AIConnect.connectCodex()); did = true }
            if which == "claude-app" || (which == "all" && AIConnect.claudeAppInstalled) { print("Claude app: " + AIConnect.connectClaudeApp()); did = true }
            if !did { print("No agent found. Use: ajar connect claude | codex | claude-app"); return 2 }
            return 0
        case "prompt": print(AIConnect.setupPrompt); return 0
        case "open": return show(send("open", ["where": rest.first ?? "panel"]))
        case "snapshot": return show(send("snapshot", ["path": rest.first ?? "", "where": rest.dropFirst().first ?? "panel"].filter { !($0.value).isEmpty }, timeout: 15))
        case "island": return show(send("island", ["title": rest.first ?? "Ajar", "subtitle": rest.dropFirst().joined(separator: " ")]))
        default:
            print("Unknown command '\(cmd)'.\n"); print(usage); return 2
        }
    }

    // MARK: Transport

    static func send(_ cmd: String, _ args: [String: Any], timeout: TimeInterval = 8) -> [String: Any] {
        if let r = attempt(cmd, args, timeout: timeout) { return r }
        // Not running: start it in the background and try once more.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.alexander.Ajar").isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-b", "com.alexander.Ajar"]
            try? p.run(); p.waitUntilExit()
            Thread.sleep(forTimeInterval: 2.5)
            if let r = attempt(cmd, args, timeout: timeout) { return r }
        }
        return ["ok": false, "error": "Ajar didn't answer. Is it running? Open /Applications/Ajar.app"]
    }

    private static func attempt(_ cmd: String, _ args: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let id = UUID().uuidString
        let req: [String: Any] = ["id": id, "cmd": cmd, "args": args]
        let reply = Wire.replyDir.appendingPathComponent(id + ".json")
        DistributedNotificationCenter.default().postNotificationName(Wire.requestName, object: nil,
                                                                      userInfo: ["json": Wire.json(req)], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: reply), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try? FileManager.default.removeItem(at: reply)
                return obj
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    // MARK: Output

    @discardableResult
    static func show(_ r: [String: Any], json: Bool = false) -> Int32 {
        if json { print(Wire.json(r)); return (r["ok"] as? Bool) == false ? 1 : 0 }
        if (r["ok"] as? Bool) == false { FileHandle.standardError.write(Data(("ajar: " + (r["error"] as? String ?? "failed") + "\n").utf8)); return 1 }
        if let status = r["status"] as? String { print(status) }
        if let h = r["hold"] as? [String: Any], let id = h["id"] { print("hold \(id)\(h["until"].map { " until \($0)" } ?? "")") }
        if let b = r["battery"] as? [String: Any] {
            print("battery \(b["percent"] ?? "?")%, \(b["on_power"] as? Bool == true ? "on power" : "\(b["watts"] ?? "?") W")")
        }
        if let h = r["hours_left_closed"] { print("lid closed: ≈\(h) h left (≈\(r["closed_estimate_watts"] ?? "?") W, estimated)") }
        if let w = r["warning"] as? String { print("note: \(w)") }
        if let n = r["not_put_back_yet"] as? [String], !n.isEmpty { print("not put back yet: \(n.joined(separator: ", "))") }
        if let w = r["watching"] as? [[String: Any]], !w.isEmpty {
            for s in w { print("  \(s["working"] as? Bool == true ? "●" : "○") \(s["name"] ?? "")\((s["project"] as? String).map { $0.isEmpty ? "" : " · \($0)" } ?? "")") }
        }
        if let apps = (r["apps"] ?? r["apps_using_energy"]) as? [[String: Any]], !apps.isEmpty {
            for a in apps { print(String(format: "  %6.2f W  %@  (%@)", (a["watts"] as? Double) ?? 0, a["name"] as? String ?? "", a["while_closed"] as? String ?? "")) }
        }
        if let n = r["released"] { print("released \(n)") }
        if let p = r["path"] as? String, r["config"] == nil { print(p) }
        return 0
    }

    // MARK: ajar run -- <command>

    /// Holds first (tied to this wrapper, so nothing runs unprotected), starts the command, re-ties the hold to
    /// the command, and releases it the moment the command ends. If this wrapper is killed, its hold ends with it.
    private static func runWrapped(_ rest: [String]) -> Int32 {
        var parts = rest
        var reason: String?
        // Only Ajar's own flags, before "--": the command's arguments (even its own --reason) are passed through.
        let end = parts.firstIndex(of: "--") ?? parts.count
        if let i = parts[..<end].firstIndex(of: "--reason"), i + 1 < end { reason = parts[i + 1]; parts.removeSubrange(i...(i + 1)) }
        if parts.first == "--" { parts.removeFirst() }
        guard !parts.isEmpty else { print("ajar run [--reason text] -- <command> [args…]"); return 2 }
        let why = reason ?? "Running \(parts[0])"
        let bridge = send("hold", ["reason": why, "pid": Int(getpid())])
        if (bridge["ok"] as? Bool) == false { FileHandle.standardError.write(Data("ajar: \(bridge["error"] ?? "") (running anyway)\n".utf8)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = parts
        do { try p.run() } catch {
            release(bridge)
            FileHandle.standardError.write(Data("ajar: couldn't start \(parts[0])\n".utf8)); return 127
        }
        let hold = (bridge["ok"] as? Bool) == true ? send("hold", ["reason": why, "pid": Int(p.processIdentifier)]) : [:]
        release(bridge)
        p.waitUntilExit()
        release(hold)
        // Like a shell: a command killed by a signal exits with 128 + the signal number.
        return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    }

    private static func release(_ r: [String: Any]) {
        if let id = (r["hold"] as? [String: Any])?["id"] as? String { _ = send("release", ["id": id], timeout: 4) }
    }

    // MARK: doctor / rescue

    private static func doctor() -> Int32 {
        print("Ajar folder: \(StateFiles.dir.path)")
        print(Heartbeat.appIsAlive() ? "App: running" : "App: not running")
        print("Watchdog: " + (Setup.watchdogLoaded ? "running" : (Setup.watchdogReady ? "installed but not loaded (open Ajar › Settings › General › Set Up)" : "not installed")))
        print("Sleep permission: " + (Setup.sudoReady ? "set up" : "missing (open Ajar to set it up)"))
        print("Sleep switched off right now: " + (Registry.sleepDisabled ? "yes" : "no"))
        let left = Watchdog.outstanding()
        print(left.isEmpty ? "Changes Ajar has made right now: none" : "Changes Ajar has made right now:\n  " + left.joined(separator: "\n  "))
        if Heartbeat.appIsAlive(), let s = attempt("status", [:], timeout: 5) {
            if let st = s["status"] as? String { print("Status: \(st)") }
            for k in ["warning", "blocked_by"] { if let w = s[k] as? String { print("Note: \(w)") } }
        }
        return 0
    }

    /// Stops the app (it puts things back as it quits), then undoes anything still recorded, directly. Works
    /// when the app is stuck or gone.
    private static func rescue() -> Int32 {
        if Heartbeat.appIsAlive() {
            _ = attempt("quit", [:], timeout: 5)
            for _ in 0..<50 where Heartbeat.appIsAlive() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        _ = Watchdog.run(force: true)
        let left = Watchdog.outstanding()
        if left.isEmpty { print("Everything Ajar changed is back to how it was. Ajar is stopped; open it again when you want it."); return 0 }
        print("Couldn't undo:\n  " + left.joined(separator: "\n  "))
        print("By hand: sudo pmset -a disablesleep 0 switches sleep back on; quit and reopen any app listed above.")
        return 1
    }

    // MARK: Helpers

    static func flag(_ name: String, _ args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// "90", "90m", "2h", "1h30m" → minutes.
    static func parseDuration(_ s: String) -> Double? {
        if let n = Double(s) { return n.isFinite && n > 0 ? min(n, 7 * 24 * 60) : nil }
        guard s.allSatisfy({ $0.isNumber || $0 == "." || "hms".contains($0.lowercased()) }) else { return nil }
        var total = 0.0, num = ""
        for ch in s.lowercased() {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            switch ch { case "h": total += n * 60; case "m": total += n; case "s": total += n / 60; default: return nil }
            num = ""
        }
        if let n = Double(num) { total += n }
        return total > 0 && total.isFinite ? min(total, 7 * 24 * 60) : nil
    }

    static let usage = """
    ajar: keep your Mac awake with the lid closed, without wasting battery.

      ajar status [--json]              what it's doing and why
      ajar auto | off                   switch mode
      ajar on|always [--for 2h]         keep awake no matter what
      ajar sleep                        let it sleep now (agents wait until the lid opens again)
      ajar hold [--for 90m] [--reason "training"] [--pid N]
                                        keep awake until time runs out, the process exits, or release
      ajar release [id]                 end one hold, or all of them
      ajar wake-at 07:00 [--for 30m]    wake from sleep at that time and stay awake a while (off cancels)
      ajar check-in 0|15|30|60          while asleep with the lid shut, wake this often to pick up a wake from the phone
      ajar run [--reason text] -- cmd   keep awake exactly as long as cmd runs
      ajar preset max_battery|balanced|full_speed
      ajar rule <app> leave|slow|pause  what an app does while the lid is closed
      ajar watch|unwatch <app>          keep awake while an app is busy
      ajar set <key> <value>            change any setting (ajar settings lists them all, with what each does)
      ajar settings [--json]            every setting, its value, allowed values and what it does
      ajar power [--json]               whole-Mac watts and what to switch off to save more
      ajar power test [--detailed]      lid closed: measure what Ajar saves on this Mac (~4 min; --detailed ~12 min)
      ajar connect [claude|codex|claude-app]   add Ajar's MCP server to your agents
      ajar prompt                       the prompt that has your agent set Ajar up with you
      ajar anyway off                   stop going below the battery limit (allowing it is done in Ajar)
      ajar measure                      estimate what slowing apps saves, in ~7 s
      ajar doctor                       health check: watchdog, permission, what Ajar has changed right now
      ajar rescue                       put back everything Ajar changed, even if the app is stuck
      ajar energy                       apps using the most power right now
      ajar config                       settings (also editable at the printed path)
      ajar open [window]                show the panel or the window
      ajar mcp                          run as an MCP server for Claude

    Connect your agents: ajar connect     Then paste: ajar prompt
    """

    static func showPower(_ r: [String: Any], json: Bool) -> Int32 {
        if json || (r["ok"] as? Bool) == false { return show(r, json: true) }
        print("Using \((r["system_watts"] as? Double).map { String(format: "%.1f", $0) } ?? "?") W now (\(r["source"] as? String ?? "")). Lid \(r["lid_closed"] as? Bool == true ? "closed" : "open").")
        if let o = r["learned_open_watts"] as? Double, let c = r["learned_closed_watts"] as? Double { print("Learned: \(o) W open, \(c) W closed.") }
        for s in (r["suspects"] as? [[String: Any]]) ?? [] {
            let active = s["active"] as? Bool == true
            let saved = (s["measured_saving_watts"] as? Double).map { String(format: "  (measured: saves %.1f W)", $0) } ?? ""
            print("\(active ? "•" : "✓") \(s["title"] ?? "")\(saved)")
            if active, let k = s["setting"], let v = s["suggested_value"] { print("    fix: ajar set \(k) \(v)\((s["tradeoff"] as? String).map { "  — \($0)" } ?? "")") }
        }
        if let t = r["measured_total_saving_watts"] as? Double, let m = r["measured_closed_watts"] as? [String: Any] {
            print(String(format: "Measured: Ajar's savings are worth %.1f W with the lid shut", t) + ((m["without_savings"] as? Double).flatMap { w in (m["with_savings"] as? Double).map { String(format: " (%.1f W → %.1f W)", w, $0) } } ?? ""))
        } else if let t = r["measured_total_saving_watts"] as? String { print("Measured: " + t) }
        print("Power test: \(r["power_test"] ?? "")")
        return 0
    }
}

/// Minimal MCP server over stdio (JSON-RPC 2.0, one message per line).
enum MCPServer {
    struct Tool {
        let name: String
        let description: String
        let schema: [String: Any]
        let call: ([String: Any]) -> [String: Any]
    }

    static func prop(_ type: String, _ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["type": type, "description": description]
        extra.forEach { p[$0.key] = $0.value }
        return p
    }

    static func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    static let tools: [Tool] = [
        Tool(name: "ajar_status",
             description: "Get Ajar's state: whether the Mac is being kept awake and why, lid open/closed, battery, estimated hours left with the lid closed, which agents/apps it's watching, active holds, and the apps using the most power.",
             schema: schema([:])) { _ in CLI.send("status", [:]) },
        Tool(name: "ajar_keep_awake",
             description: "Keep the Mac awake, including with the lid closed, while you work. By default the hold ends when this Claude session ends or after 2 hours, whichever is first. Pass minutes for a fixed time, or pid to tie it to a process (e.g. a long build). Returns a hold id: call ajar_release as soon as the work is done. Battery limit and heat guard still apply.",
             schema: schema(["reason": prop("string", "Short reason shown to the user, e.g. 'Training the model'"),
                             "minutes": prop("number", "Optional. End automatically after this many minutes."),
                             "pid": prop("integer", "Optional. End automatically when this process exits.")], required: ["reason"])) { a in
            var args = a
            // Default: tied to this Claude session AND capped at 2 hours, so an idle session sitting at its prompt
            // can't keep a closed Mac awake in a bag indefinitely.
            if a["minutes"] == nil && a["pid"] == nil { args["pid"] = Int(getppid()); args["minutes"] = 120 }
            args["owner"] = Int(getppid())   // so ajar_release can end it, however it was tied
            return CLI.send("hold", args)
        },
        Tool(name: "ajar_release",
             description: "End a hold this session made with ajar_keep_awake so the Mac can sleep normally again. Omit hold_id to end all of this session's holds (never anyone else's).",
             schema: schema(["hold_id": prop("string", "Hold id to end")])) { a in
            // Holds from ajar_keep_awake are tied to the agent process that started this server (getppid()).
            if let id = a["hold_id"] as? String { return CLI.send("release_own", ["id": id, "pid": Int(getppid())]) }
            return CLI.send("release_pid", ["pid": Int(getppid())])
        },
        Tool(name: "ajar_set_mode",
             description: "Set Ajar's mode. auto: stay awake only while agents/apps are working (recommended). always: stay awake regardless (optionally for some minutes). off: normal Mac sleep.",
             schema: schema(["mode": prop("string", "off, auto (shown as When Busy: awake while agents work) or always", ["enum": ["off", "auto", "always"]]),
                             "minutes": prop("number", "For always: how long")], required: ["mode"])) { a in CLI.send("mode", a) },
        Tool(name: "ajar_set_preset",
             description: "What happens to other apps while the lid is closed. max_battery: pause them until the lid opens (music, calls and services agents use keep running). balanced: slow them to efficiency cores. full_speed: leave them. Simulators, background audio and Low Power Mode are separate settings (ajar_settings).",
             schema: schema(["preset": prop("string", "max_battery, balanced or full_speed", ["enum": ["max_battery", "balanced", "full_speed"]])], required: ["preset"])) { a in CLI.send("preset", a) },
        Tool(name: "ajar_set_app_rule",
             description: "Choose what one app does while the lid is closed: leave (runs normally), slow (efficiency cores only, about 1/4 the power), pause (frozen until the lid opens), or default (remove the override and follow the preset). Apps Ajar is keeping awake are never slowed or paused.",
             schema: schema(["app": prop("string", "App name or bundle id, e.g. 'Slack' or 'com.spotify.client'"),
                             "rule": prop("string", "leave, slow, pause or default", ["enum": ["leave", "slow", "pause", "default"]])], required: ["app", "rule"])) { a in CLI.send("rule", a) },
        Tool(name: "ajar_watch_app",
             description: "Add an app or command-line tool to Ajar's 'Keeps awake for' list, or remove it (remove: true). While it's busy the Mac stays awake with the lid closed. Use it for whatever the current task needs (e.g. add 'Google Chrome' while a browser task runs, remove it after). The reply includes the full list; ajar_status shows it too.",
             schema: schema(["app": prop("string", "App name ('Google Chrome'), bundle id ('com.google.Chrome'), .app path, or executable name ('ffmpeg')"),
                             "remove": prop("boolean", "true to remove it from the list")], required: ["app"])) { a in CLI.send("watch", a) },
        Tool(name: "ajar_add_agent",
             description: "Teach Ajar a new command-line agent or tool by executable name, so it stays awake while that tool is working.",
             schema: schema(["name": prop("string", "Display name"),
                             "executable": prop("string", "Process executable name, e.g. 'my-agent'"),
                             "idle_watts": prop("number", "Below this power the tool counts as idle (default 0.05)"),
                             "remove": prop("boolean", "Forget it")], required: ["name", "executable"])) { a in CLI.send("agent", a) },
        Tool(name: "ajar_settings",
             description: "List every Ajar setting with its current value, allowed values, what it does and any safety rule. Read this before changing settings.",
             schema: schema([:])) { _ in CLI.send("schema", [:]) },
        Tool(name: "ajar_set_setting",
             description: "Change one setting (see ajar_settings for all keys and what they do). Safety settings can only be made stricter from here: battery_floor can only go up and heat_guard can only be turned on. Ask the person before turning lock_on_close on (it brings back the lock screen).",
             schema: schema(["key": prop("string", "Setting key", ["enum": SettingsSchema.all.map(\.key)]),
                             "value": prop("string", "New value, e.g. '20', 'on', 'off', 'max_battery'")], required: ["key", "value"])) { a in
            var args = a; if let v = a["value"] { args["value"] = "\(v)" }
            return CLI.send("set", args)
        },
        Tool(name: "ajar_power",
             description: "Whole-Mac power right now (measured from the battery controller, also on the charger) and a list of what is using it with the setting that would cut each: screen kept on while closed, booted simulators and Xcode previews, apps holding the speakers, busy apps, Low Power Mode. Includes savings measured by ajar_power_test.",
             schema: schema([:])) { _ in CLI.send("power", [:], timeout: 10) },
        Tool(name: "ajar_power_test",
             description: "With the lid closed: switch all of Ajar's savings off, on, off, on and read the whole-Mac power over full 30 s updates of the battery controller, so you know what they're worth on this Mac (reported as unclear if the Mac's own load moved too much). About 4 minutes; agents keep running. detailed: true adds each saving on its own (about 12 minutes). Returns at once; call ajar_power afterwards (power_test: done). screen: true includes turning the screen off, which locks the Mac: ask the person first.",
             schema: schema(["detailed": prop("boolean", "Also measure each saving on its own (about 12 minutes). Default false."), "screen": prop("boolean", "Also measure the screen (locks the Mac). Default false.")])) { a in CLI.send("power_test", a) },
        Tool(name: "ajar_setup_prompt",
             description: "The recommended steps for setting Ajar up with the person. Use when asked to set up or tune Ajar.",
             schema: schema([:])) { _ in ["ok": true, "prompt": AIConnect.setupPrompt] },
        Tool(name: "ajar_energy",
             description: "List the apps using the most power right now and what each will do while the lid is closed.",
             schema: schema([:])) { _ in CLI.send("energy", [:]) },
        Tool(name: "ajar_measure_savings",
             description: "Estimate how much power the current while-closed rules save: slows/pauses the same apps for a few seconds and compares the energy macOS attributes to them before and after. A rough, short-window estimate.",
             schema: schema([:])) { _ in CLI.send("measure", [:], timeout: 20) },
        Tool(name: "ajar_get_config",
             description: "Read Ajar's full settings and the path of its config.json, which can also be edited directly (it reloads instantly).",
             schema: schema([:])) { _ in CLI.send("config", [:]) },
    ]

    static func run() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notifications need no answer

            var result: [String: Any]?
            var error: [String: Any]?
            switch method {
            case "initialize":
                let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
                let asked = params["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": supported.contains(asked) ? asked : supported[0],
                          "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "ajar", "version": "1.0"],
                          "instructions": "Ajar keeps this Mac awake with the lid closed and cuts power while it does. Call ajar_keep_awake at the start of long work so closing the lid won't stop you; it ends by itself when this session does. To tune it: ajar_settings lists every setting, ajar_power shows what's using power and which setting fixes it, ajar_power_test measures each saving with the lid closed. If asked to set Ajar up, follow ajar_setup_prompt."]
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                if let tool = tools.first(where: { $0.name == name }) {
                    let r = tool.call(args)
                    result = ["content": [["type": "text", "text": Wire.json(r)]], "isError": (r["ok"] as? Bool) == false]
                } else {
                    error = ["code": -32602, "message": "Unknown tool \(name)"]
                }
            default:
                error = ["code": -32601, "message": "Method not found: \(method)"]
            }
            var resp: [String: Any] = ["jsonrpc": "2.0", "id": id!]
            if let result { resp["result"] = result } else { resp["error"] = error ?? [:] }
            if let d = try? JSONSerialization.data(withJSONObject: resp) {
                FileHandle.standardOutput.write(d)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
        return 0
    }
}
