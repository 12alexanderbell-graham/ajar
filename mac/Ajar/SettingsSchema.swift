import Foundation

/// Every setting Ajar has, described once. The `ajar settings` command, the MCP tools, `ajar set` and the docs for
/// AI agents all read this table, so an agent can discover, explain and change any setting without guessing.
/// Safety rules live in the setters: commands can make the battery limit and heat guard stricter, never looser.
struct SettingSpec {
    let key: String
    let type: String              // bool, int, enum, string
    let allowed: [String]?        // enum values, or a range like "0-80"
    let category: String
    let description: String
    var note: String? = nil
    let get: (Config) -> Any
    let set: (inout Config, Any) -> String?   // nil = applied; otherwise why not
}

enum SettingsSchema {
    static func bool(_ v: Any) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        switch (v as? String)?.lowercased() { case "on", "true", "yes", "1": return true; case "off", "false", "no", "0": return false; default: return nil }
    }
    static func int(_ v: Any) -> Int? {
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite && abs(d) < 1_000_000 ? Int(d) : nil }
        // nan, inf and 1e400 all parse as Doubles and would crash Int(_:).
        guard let d = (v as? String).flatMap({ Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }),
              d.isFinite, abs(d) < 1_000_000 else { return nil }
        return Int(d)
    }
    static func toggle(_ key: String, _ category: String, _ description: String, note: String? = nil, _ path: WritableKeyPath<Config, Bool>) -> SettingSpec {
        SettingSpec(key: key, type: "bool", allowed: ["on", "off"], category: category, description: description, note: note,
                    get: { $0[keyPath: path] }, set: { c, v in guard let b = bool(v) else { return "on or off" }; c[keyPath: path] = b; return nil })
    }

    static let all: [SettingSpec] = [
        SettingSpec(key: "mode", type: "enum", allowed: ["auto", "on", "off"], category: "When to stay awake",
                    description: "auto (shown as When Busy): awake only while an agent or watched app is working. on (Always): awake until turned off. off: normal sleep (explicit holds still work).",
                    get: { $0.mode.rawValue }, set: { c, v in
                        guard let m = (v as? String).flatMap(CommandCenter.parseMode) else { return "auto, on or off" }
                        // Remember the mode to go back to, the same as choosing Always in the panel.
                        if m == .on && c.mode != .on { c.modeBeforeAlways = c.mode; c.alwaysUntil = nil }
                        if m != .on { c.alwaysUntil = nil; c.modeBeforeAlways = nil }
                        c.mode = m   // already on: a timer that's running stays
                        return nil }),
        SettingSpec(key: "preset", type: "enum", allowed: ["max_battery", "balanced", "full_speed"], category: "While the lid is closed",
                    description: "What happens to other apps with the lid shut. max_battery: pause them (music, calls and services agents use keep going). balanced: slow them to efficiency cores. full_speed: leave them.",
                    get: { ["longest": "max_battery", "balanced": "balanced", "speed": "full_speed"][$0.preset.rawValue] ?? "balanced" },
                    set: { c, v in guard let p = (v as? String).flatMap(CommandCenter.parsePreset) else { return "max_battery, balanced or full_speed" }; c.preset = p; return nil }),
        toggle("pause_simulators", "While the lid is closed", "Freeze booted iOS simulators and Xcode previews until the lid opens. Skipped while xcodebuild or UI tests run.", \.pauseSimulators),
        toggle("screen_off", "While the lid is closed", "Switch the built-in screen fully off while the lid is closed without sleeping it, so there is no lock screen. Experimental: if macOS refuses, or locks the Mac anyway (some Macs do), Ajar switches back to the dark screen by itself and turns this off. Ignored when lock_on_close is on.", \.screenOffNoLock),
        toggle("shut_down_simulators", "While the lid is closed", "Shut booted simulators down when the lid closes instead of pausing them. Frees all their memory and power; they don't come back by themselves. Skipped while tests run.", \.shutDownSimulators),
        toggle("pause_background_audio", "While the lid is closed", "Freeze background processes that hold the speakers open (keeps the audio hardware powered even when silent). Music and call apps are never touched.", \.pauseBackgroundAudio),
        SettingSpec(key: "check_in_minutes", type: "enum", allowed: ["0", "15", "30", "60"], category: "While asleep",
                    description: "With the lid shut and the Mac asleep, wake it every this many minutes for about 25 seconds to pick up a wake sent from the phone, then sleep again. 0 = off. Costs a little battery per check-in; a fully shut-down Mac can't be woken.",
                    get: { $0.checkInMinutes }, set: { c, v in
                        guard let n = int(v), WakePlan.checkInChoices.contains(n) else { return "0, 15, 30 or 60" }
                        c.checkInMinutes = n; return nil }),
        toggle("slow_builds", "While the lid is closed", "Experimental: run the agent's build tools (compilers, linkers, cargo, xcodebuild, make) on the efficiency cores. Builds take several times longer; it saves power per second but not always energy per build.", \.slowBuildsWhileClosed),
        toggle("pause_time_machine", "While the lid is closed", "Pause Time Machine's automatic backups while the lid is closed (every file an agent changes queues backup work); they switch back on when the lid opens.", \.pauseTimeMachine),
        toggle("low_power", "While the lid is closed", "Turn on Low Power Mode while the lid is closed; your setting comes back when it opens.", \.lowPowerWhileClosed),
        toggle("lock_on_close", "While the lid is closed", "on: the screen turns fully off (the biggest single saving, but macOS asks for your password when you open the lid). off: the screen stays on at zero brightness so there is no lock screen.",
               note: "Ask the person before turning this on: it changes what they see when they open the lid.", \.lockOnClose),
        SettingSpec(key: "battery_floor", type: "int", allowed: ["0-80"], category: "Safety",
                    description: "Sleep when the battery reaches this percent (0 = never stop for battery).",
                    note: "Can only be raised from commands; lowering it is the person's call in Ajar's Settings.",
                    get: { $0.batteryFloor }, set: { c, v in
                        guard let n = int(v) else { return "a number 0-80" }
                        let x = min(80, max(0, n))
                        guard x >= c.batteryFloor else { return "to be lowered in Ajar itself (it can only be raised from here)" }
                        c.batteryFloor = x; return nil }),
        SettingSpec(key: "heat_guard", type: "bool", allowed: ["on", "off"], category: "Safety",
                    description: "With the lid shut: strictest rules when the Mac gets hot, sleep if it stays hot for 5 minutes or gets critical.",
                    note: "Can only be turned on from commands.",
                    get: { $0.heatGuard }, set: { c, v in
                        guard let b = bool(v) else { return "on or off" }
                        guard b else { return "to be turned off in Ajar's Settings (it can only be turned on from here)" }
                        c.heatGuard = true; return nil }),
        SettingSpec(key: "only_on_power", type: "bool", allowed: ["on", "off"], category: "Safety",
                    description: "Only stay awake while the charger is covering the load.",
                    note: "Can only be turned on from commands.",
                    get: { $0.onlyOnPower }, set: { c, v in
                        guard let b = bool(v) else { return "on or off" }
                        guard b || !c.onlyOnPower else { return "to be turned off in Ajar's Settings (it can only be turned on from here)" }
                        c.onlyOnPower = b; return nil }),
        SettingSpec(key: "quiet_minutes", type: "int", allowed: ["1-240"], category: "When to stay awake",
                    description: "In auto mode, sleep after an agent has been quiet this many minutes.",
                    get: { $0.quietMinutes }, set: { c, v in guard let n = int(v) else { return "a number 1-240" }; c.quietMinutes = min(240, max(1, n)); return nil }),
        toggle("sleep_when_done", "When to stay awake", "In auto mode, let the Mac sleep once the work stops.", \.sleepWhenDone),
        toggle("claude_app", "When to stay awake", "Count the Claude app (Cowork, computer use) as an agent.", \.countClaudeApp),
        toggle("downloads", "When to stay awake", "Count apps that ask macOS to stay awake (downloads, exports, builds).", \.countRequests),
        toggle("notify_done", "Notifications", "Notification when an agent that was busy goes idle.", \.notifyDone),
        toggle("done_chime", "Notifications", "Play a sound as well (audible with the lid shut).", \.doneChime),
        SettingSpec(key: "ntfy_topic", type: "string", allowed: nil, category: "Notifications",
                    description: "ntfy.sh topic for phone alerts when work goes idle; empty turns them off.",
                    get: { $0.ntfyTopic }, set: { c, v in
                        let s = String(describing: v).trimmingCharacters(in: .whitespaces)
                        // Alerts go wherever this topic points, so only Ajar's own Settings can set it; commands may turn it off.
                        guard s.isEmpty else { return "to be set in Ajar's Settings (commands can only turn it off)" }
                        c.ntfyTopic = s; return nil }),
        SettingSpec(key: "menubar", type: "enum", allowed: MenuBarText.allCases.map(\.rawValue), category: "Appearance",
                    description: "Text next to the menu bar icon.",
                    get: { $0.menuBarText.rawValue }, set: { c, v in guard let m = (v as? String).flatMap(MenuBarText.init) else { return MenuBarText.allCases.map(\.rawValue).joined(separator: ", ") }; c.menuBarText = m; return nil }),
        toggle("live_lid_icon", "Appearance", "The menu bar icon's lid follows the real lid angle.", \.liveLidIcon),
        toggle("notch_island", "Appearance", "Short announcements in a notch island.", \.notchIsland),
        toggle("show_in_dock", "Appearance", "Show Ajar in the Dock.", \.showInDock),
        toggle("hotkey", "Appearance", "⌃⌥⌘A cycles the mode.", \.hotkey),
        SettingSpec(key: "appearance", type: "enum", allowed: AppearanceChoice.allCases.map(\.rawValue), category: "Appearance",
                    description: "Light, dark or match the system.",
                    get: { $0.appearance.rawValue }, set: { c, v in guard let a = (v as? String).flatMap(AppearanceChoice.init) else { return "system, light or dark" }; c.appearance = a; return nil }),
    ]

    /// Not plain settings: lists changed through their own commands.
    static let lists: [[String: String]] = [
        ["name": "app_rules", "how": "ajar rule <app> leave|slow|pause|default  (MCP: ajar_set_app_rule)", "what": "Per-app override of the preset while the lid is closed."],
        ["name": "watched_apps", "how": "ajar watch <app> / ajar unwatch <app>  (MCP: ajar_watch_app)", "what": "Apps or tools that keep the Mac awake while busy."],
        ["name": "custom_agents", "how": "MCP: ajar_add_agent", "what": "Command-line agents Ajar doesn't know yet, by executable name."],
        ["name": "track_only", "how": "phone panel or menu", "what": "Agents shown but not keeping the Mac awake."],
    ]

    static func spec(_ key: String) -> SettingSpec? {
        let k = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let aliases = ["screen_off_when_closed": "screen_off", "screen_off_no_lock": "screen_off", "low_power_mode": "low_power", "battery_limit": "battery_floor"]
        return all.first { $0.key == (aliases[k] ?? k) }
    }

    static func describe(_ c: Config) -> [String: Any] {
        ["settings": all.map { s -> [String: Any] in
            var d: [String: Any] = ["key": s.key, "type": s.type, "category": s.category, "description": s.description, "value": s.get(c)]
            if let a = s.allowed { d["allowed"] = a }
            if let n = s.note { d["note"] = n }
            return d
        }, "lists": lists, "config_file": Config.url.path,
         "how_to_change": "ajar set <key> <value>, MCP ajar_set_setting, or edit config.json (camelCase keys, reloads instantly)."]
    }
}
