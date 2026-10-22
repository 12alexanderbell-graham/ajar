import Foundation

enum Mode: String, CaseIterable, Codable {
    case off, auto, on
    var label: String { switch self { case .off: "Off"; case .auto: "When Busy"; case .on: "Always" } }
}

enum Preset: String, CaseIterable, Identifiable, Codable {
    case longest, balanced, speed
    var id: String { rawValue }
    var label: String { switch self { case .longest: "Max Battery"; case .balanced: "Balanced"; case .speed: "Full Speed" } }
    var detail: String {
        switch self {
        case .longest: "Pauses other apps until you open the lid (music, calls and services agents use keep going)"
        case .balanced: "Slows other apps"
        case .speed: "Leaves apps alone (your per-app rules still apply)"
        }
    }
}

enum AppRule: String, CaseIterable, Codable {
    case leave, slow, pause
    var label: String { switch self { case .leave: "Leave"; case .slow: "Slow"; case .pause: "Pause" } }
    var menuTitle: String {
        switch self { case .leave: "Leave Running"; case .slow: "Slow Down"; case .pause: "Pause Until Opened" }
    }
}

enum MenuBarText: String, CaseIterable, Codable {
    case none, battery, watts, timeLeft, timer
    var label: String {
        switch self {
        case .none: "Icon Only"; case .battery: "Battery %"; case .watts: "Watts"
        case .timeLeft: "Battery Time Left (Lid Closed)"; case .timer: "Always Timer Countdown"
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Codable {
    case system, light, dark
    var label: String { switch self { case .system: "Match System"; case .light: "Light"; case .dark: "Dark" } }
}

/// An agent the person (or their Claude) taught Ajar about.
struct CustomAgent: Codable, Hashable {
    var name: String
    var executables: [String]
    var idleWatts: Double?
}

/// Everything you can change, in one JSON file at ~/Library/Application Support/Ajar/config.json.
/// Ajar reloads it the moment it changes, so a person, a script or Claude can edit it directly.
/// Every key is optional when written by hand; anything missing keeps its default.
struct Config: Codable, Equatable {
    var mode: Mode = .auto
    var preset: Preset = .balanced
    var lowPowerWhileClosed = true
    var sleepWhenDone = true
    var quietMinutes = 5
    var batteryFloor = 15
    var heatGuard = true
    var onlyOnPower = false
    var countClaudeApp = true
    var countRequests = true
    var watchedApps: [WatchedApp] = []
    var appRules: [String: AppRule] = [:]
    var customAgents: [CustomAgent] = []
    var menuBarText: MenuBarText = .none
    /// Off by default: the notch island is opt-in.
    var notchIsland = false
    var showInDock = false
    var hotkey = true
    var appearance: AppearanceChoice = .system
    /// Notification when an agent finishes a job.
    var notifyDone = true
    /// A soft chime as well, audible across the room with the lid shut.
    var doneChime = false
    /// System sound name for the chime.
    var chimeSound = "Glass"
    /// ntfy.sh topic for phone alerts; empty = off.
    var ntfyTopic = ""
    /// Closing the lid: false keeps the screen on at zero brightness so there's no lock screen on reopen;
    /// true turns the screen off, which locks if macOS is set to.
    var lockOnClose = false
    /// Freeze booted iOS simulators and Xcode previews while the lid is closed (not during tests).
    var pauseSimulators = true
    /// Freeze background processes holding the speakers open while the lid is closed (not music or calls).
    var pauseBackgroundAudio = true
    /// With the lid closed, switch the built-in display fully off (configured off, not asleep: no lock screen).
    /// Ignored when lockOnClose is on. Falls back to the dark screen if macOS won't do it.
    var screenOffNoLock = false
    /// Shut booted simulators down when the lid closes instead of freezing them (frees everything; they don't
    /// come back by themselves).
    var shutDownSimulators = false
    /// Agent kinds shown in the list but never keeping the Mac awake.
    var trackOnly: [String] = []
    /// The menu bar icon's lid follows the real lid angle.
    var liveLidIcon = true
    /// End of a timed "Always", in Unix seconds. Stored next to `mode` in the same file so the two can never
    /// disagree after a crash: a timed Always can't turn into a forever Always.
    var alwaysUntil: Double?
    /// The mode to go back to when a timed Always ends.
    var modeBeforeAlways: Mode?
    /// While asleep with the lid shut, wake every this many minutes (0, 15, 30 or 60) to pick up a "wake" from the
    /// phone. 0 = off. Each check-in keeps the Mac up for about 25 seconds.
    var checkInMinutes = 0
    /// A one-off scheduled wake, in Unix seconds: the Mac wakes then and stays awake for `wakeForMinutes`.
    var wakeAt: Double?
    var wakeForMinutes = 30
    /// Experimental: with the lid closed, run the agent's build tools (compilers, linkers, cargo, xcodebuild…) on the
    /// efficiency cores. Builds take several times longer; whether that saves energy overall depends on the job.
    var slowBuildsWhileClosed = false
    /// Pause Time Machine's automatic backups while the lid is closed (an agent's file changes trigger them).
    var pauseTimeMachine = true
    /// The person says Wi-Fi › "Ask to join hotspots" is on Automatic, so Ajar stops reminding them on a hotspot.
    var hotspotAutomatic = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        preset = (try? c.decodeIfPresent(Preset.self, forKey: .preset)) ?? d.preset
        lowPowerWhileClosed = (try? c.decodeIfPresent(Bool.self, forKey: .lowPowerWhileClosed)) ?? d.lowPowerWhileClosed
        sleepWhenDone = (try? c.decodeIfPresent(Bool.self, forKey: .sleepWhenDone)) ?? d.sleepWhenDone
        quietMinutes = min(240, max(1, (try? c.decodeIfPresent(Int.self, forKey: .quietMinutes)) ?? d.quietMinutes))
        batteryFloor = min(80, max(0, (try? c.decodeIfPresent(Int.self, forKey: .batteryFloor)) ?? d.batteryFloor))
        heatGuard = (try? c.decodeIfPresent(Bool.self, forKey: .heatGuard)) ?? d.heatGuard
        onlyOnPower = (try? c.decodeIfPresent(Bool.self, forKey: .onlyOnPower)) ?? d.onlyOnPower
        countClaudeApp = (try? c.decodeIfPresent(Bool.self, forKey: .countClaudeApp)) ?? d.countClaudeApp
        countRequests = (try? c.decodeIfPresent(Bool.self, forKey: .countRequests)) ?? d.countRequests
        watchedApps = (try? c.decodeIfPresent([WatchedApp].self, forKey: .watchedApps)) ?? d.watchedApps
        appRules = (try? c.decodeIfPresent([String: AppRule].self, forKey: .appRules)) ?? d.appRules
        customAgents = (try? c.decodeIfPresent([CustomAgent].self, forKey: .customAgents)) ?? d.customAgents
        menuBarText = (try? c.decodeIfPresent(MenuBarText.self, forKey: .menuBarText)) ?? d.menuBarText
        notchIsland = (try? c.decodeIfPresent(Bool.self, forKey: .notchIsland)) ?? d.notchIsland
        showInDock = (try? c.decodeIfPresent(Bool.self, forKey: .showInDock)) ?? d.showInDock
        hotkey = (try? c.decodeIfPresent(Bool.self, forKey: .hotkey)) ?? d.hotkey
        appearance = (try? c.decodeIfPresent(AppearanceChoice.self, forKey: .appearance)) ?? d.appearance
        notifyDone = (try? c.decodeIfPresent(Bool.self, forKey: .notifyDone)) ?? d.notifyDone
        doneChime = (try? c.decodeIfPresent(Bool.self, forKey: .doneChime)) ?? d.doneChime
        chimeSound = (try? c.decodeIfPresent(String.self, forKey: .chimeSound)) ?? d.chimeSound
        ntfyTopic = String(((try? c.decodeIfPresent(String.self, forKey: .ntfyTopic)) ?? d.ntfyTopic).prefix(64))
        lockOnClose = (try? c.decodeIfPresent(Bool.self, forKey: .lockOnClose)) ?? d.lockOnClose
        pauseSimulators = (try? c.decodeIfPresent(Bool.self, forKey: .pauseSimulators)) ?? d.pauseSimulators
        pauseBackgroundAudio = (try? c.decodeIfPresent(Bool.self, forKey: .pauseBackgroundAudio)) ?? d.pauseBackgroundAudio
        screenOffNoLock = (try? c.decodeIfPresent(Bool.self, forKey: .screenOffNoLock)) ?? d.screenOffNoLock
        shutDownSimulators = (try? c.decodeIfPresent(Bool.self, forKey: .shutDownSimulators)) ?? d.shutDownSimulators
        trackOnly = (try? c.decodeIfPresent([String].self, forKey: .trackOnly)) ?? d.trackOnly
        liveLidIcon = (try? c.decodeIfPresent(Bool.self, forKey: .liveLidIcon)) ?? d.liveLidIcon
        alwaysUntil = (try? c.decodeIfPresent(Double.self, forKey: .alwaysUntil)).flatMap { $0.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        modeBeforeAlways = (try? c.decodeIfPresent(Mode.self, forKey: .modeBeforeAlways)).flatMap { $0 == .on ? nil : $0 }
        let ci = (try? c.decodeIfPresent(Int.self, forKey: .checkInMinutes)) ?? d.checkInMinutes
        checkInMinutes = WakePlan.checkInChoices.contains(ci) ? ci : d.checkInMinutes
        wakeAt = (try? c.decodeIfPresent(Double.self, forKey: .wakeAt)).flatMap { $0.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        slowBuildsWhileClosed = (try? c.decodeIfPresent(Bool.self, forKey: .slowBuildsWhileClosed)) ?? d.slowBuildsWhileClosed
        pauseTimeMachine = (try? c.decodeIfPresent(Bool.self, forKey: .pauseTimeMachine)) ?? d.pauseTimeMachine
        hotspotAutomatic = (try? c.decodeIfPresent(Bool.self, forKey: .hotspotAutomatic)) ?? d.hotspotAutomatic
        wakeForMinutes = min(24 * 60, max(5, (try? c.decodeIfPresent(Int.self, forKey: .wakeForMinutes)) ?? d.wakeForMinutes))
    }

    static var url: URL { StateFiles.dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    /// The file exists but isn't a JSON object: kept aside under a dated name instead of being silently
    /// overwritten with defaults. Returns the backup's file name.
    static func setAsideIfBroken() -> String? {
        guard let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) == nil else { return nil }
        let name = "config.broken-\(Int(Date().timeIntervalSince1970)).json"
        try? FileManager.default.copyItem(at: url, to: StateFiles.dir.appendingPathComponent(name))
        return name
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

/// A request to stay awake from the command line, an MCP client or a script.
/// Ends when its time runs out, when the process it's tied to exits, or when released.
struct Hold: Codable, Identifiable, Equatable {
    var id: String
    var reason: String
    var until: Date?
    var pid: Int32?
    var created = Date()
    /// The agent session that made it (MCP): it may end its own holds, whatever they're tied to.
    var owner: Int32?

    /// Start time of `pid` when the hold was made: the hold ends if the pid now belongs to another process.
    var pidStart: UInt64?

    var isAlive: Bool {
        if let until, Date() > until { return false }
        if let pid {
            // After a restart the pid belongs to something else entirely.
            if created < Self.bootTime { return false }
            guard let now = Procs.startTime(pid) else { return false }
            if let s = pidStart, s != now { return false }
        }
        return true
    }

    static let bootTime: Date = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }()
}

/// Watches config.json and calls back when someone else edits it.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let onChange: () -> Void
    private var lastStamp: String?

    /// Modification time, size and inode of config.json (an atomic replace changes the inode).
    private static func stamp() -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: Config.url.path) else { return nil }
        return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(a[.size] ?? 0)-\(a[.systemFileNumber] ?? 0)"
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        start()
    }

    /// Watch the folder, not the file: editors and JSONEncoder replace the file atomically, which a file watch misses.
    private func start() {
        let fd = open(StateFiles.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        // The folder also holds the 2-second heartbeat and other state files: only react when config.json itself
        // changed, instead of re-reading it every 2 seconds.
        lastStamp = Self.stamp()
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.stamp()
            guard now != self.lastStamp else { return }
            self.lastStamp = now
            self.onChange()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    deinit { source?.cancel() }
}
