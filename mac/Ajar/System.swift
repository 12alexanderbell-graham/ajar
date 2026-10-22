import AppKit
import Foundation
import IOKit

/// Runs command-line tools. Output is read before waiting so a chatty tool can't deadlock the pipe.
nonisolated enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Starts a command and returns at once (for ones whose result doesn't matter, like `caffeinate -u`).
    static func spawn(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// pmset as root through the sudoers entry Setup installs. `-n` means it fails instead of prompting.
    @discardableResult
    static func pmsetRoot(_ args: [String]) -> Bool {
        let r = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + args)
        if r.code != 0 { NSLog("Nocturnal: pmset %@ failed (%d): %@", args.joined(separator: " "), r.code, r.out) }
        return r.code == 0
    }
}

/// Reads from the power-management root domain without spawning anything.
enum Registry {
    static func rootDomain(_ key: String) -> Any? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        return IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static var clamshellClosed: Bool { (rootDomain("AppleClamshellState") as? Bool) ?? false }

    /// "Closed" for Nocturnal's purposes: the lid is shut and no external display is in use. Lid shut with a
    /// monitor attached is a desk setup the person is actively using, so it must never trigger
    /// display-off, app slowing or sleep-when-done.
    static var lidClosed: Bool {
        guard clamshellClosed else { return false }
        return !NSScreen.screens.contains { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }
    static var sleepDisabled: Bool { (rootDomain("SleepDisabled") as? Bool) ?? false }
    /// MacBooks report a clamshell state; desktop Macs don't have the key at all.
    static let hasLid: Bool = rootDomain("AppleClamshellState") != nil
}

struct BatteryReading: Equatable {
    var percent: Int
    var watts: Double        // discharge power; 0 when not discharging
    var onAC: Bool
    var charging: Bool
    var minutesLeft: Int?    // macOS's own estimate, nil while it's still calculating
    /// Energy is leaving the battery. True on battery, and also on a charger too weak to keep up
    /// (a 5–15 W USB-C brick or a monitor's port), where `onAC` alone would hide a draining battery.
    var discharging: Bool { watts > 0.3 && !charging }
}

enum Battery {
    static func read() -> BatteryReading? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        func value(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        guard let cur = value("CurrentCapacity") as? Int, let mx = value("MaxCapacity") as? Int, mx > 0 else { return nil }
        let amps = (value("InstantAmperage") as? Int) ?? (value("Amperage") as? Int) ?? 0
        let volts = (value("Voltage") as? Int) ?? 0
        let onAC = (value("ExternalConnected") as? Bool) ?? false
        let t = value("TimeRemaining") as? Int
        let left: Int? = (!onAC && t != nil && t! > 0 && t! < 6000) ? t : nil
        return BatteryReading(percent: cur * 100 / mx,
                              watts: amps < 0 ? Double(-amps) * Double(volts) / 1_000_000 : 0,
                              onAC: onAC,
                              charging: (value("IsCharging") as? Bool) ?? false,
                              minutesLeft: left)
    }
}

/// Low Power Mode on the battery profile. Max-chip Macs call it `powermode` (0 auto, 1 low, 2 high),
/// others call it `lowpowermode` (0/1). Both use 1 for low.
struct PowerModeSetting: Equatable {
    let key: String
    let value: Int
}

enum PowerMode {
    static func battery() -> PowerModeSetting? {
        let out = Shell.run("/usr/bin/pmset", ["-g", "custom"]).out
        var inBattery = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("Power:") { inBattery = line.hasPrefix("Battery"); continue }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "powermode" || parts[0] == "lowpowermode", let v = Int(parts[1]) {
                return PowerModeSetting(key: String(parts[0]), value: v)
            }
        }
        return nil
    }
}

/// Small files the watchdog script also reads, so a crashed or hung Nocturnal never leaves sleep switched off.
enum StateFiles {
    static let dir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = support.appendingPathComponent("Nocturnal")
        let fresh = !FileManager.default.fileExists(atPath: u.path)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        // The app used to be called Ajar: carry its settings, history and Approve everything journal over once.
        if fresh {
            let old = support.appendingPathComponent("Ajar")
            for f in ["config.json", "safety.json", "stats.json", "auto-approve.json"] {
                try? FileManager.default.copyItem(at: old.appendingPathComponent(f), to: u.appendingPathComponent(f))
            }
        }
        return u
    }()
    static var hold: URL { dir.appendingPathComponent("hold") }                     // present while a hold is on
    static var alive: URL { dir.appendingPathComponent("alive") }                   // heartbeat while the app runs
    static var modeRestore: URL { dir.appendingPathComponent("powermode-restore") } // e.g. "powermode 0"
    static var paused: URL { dir.appendingPathComponent("paused") }                 // "pid<TAB>path" per line
    static var slowed: URL { dir.appendingPathComponent("slowed") }                 // "pid<TAB>path" per line
    static var watchdog: URL { dir.appendingPathComponent("watchdog.sh") }

    static func write(_ s: String, to u: URL) { try? s.write(to: u, atomically: true, encoding: .utf8) }
    /// Temp file, flushed to disk, then renamed: survives a crash or power loss at any point. For journals.
    static func writeDurably(_ data: Data, to u: URL, mode: Int? = nil) -> Bool {
        let tmp = u.appendingPathExtension("tmp\(getpid())")
        // Created with its final permissions, so a secret is never readable by others even for a moment.
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: mode.map { [.posixPermissions: $0] }),
              let h = try? FileHandle(forWritingTo: tmp) else { return false }
        do {
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            guard rename(tmp.path, u.path) == 0 else { try? FileManager.default.removeItem(at: tmp); return false }
            return true
        } catch {
            try? h.close()
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }
    static func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
    static func remove(_ u: URL) { try? FileManager.default.removeItem(at: u) }
    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    static func touch(_ u: URL) {
        if exists(u) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path) }
        else { write("", to: u) }
    }
}

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One-time install: a sudoers entry for exactly the pmset commands Nocturnal uses, and a LaunchAgent watchdog.
enum Setup {
    static let label = "com.alexander.nocturnal.watchdog"
    static let sudoersPath = "/private/etc/sudoers.d/nocturnal"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Nocturnal's own entry is in place and sudo accepts it (the old Ajar entry granted the same commands, so
    /// sudo alone can't tell them apart; Set Up replaces it).
    static var sudoReady: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
            && Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).code == 0
    }
    static var watchdogReady: Bool { FileManager.default.fileExists(atPath: plistURL.path) && StateFiles.exists(StateFiles.watchdog) }
    /// launchd actually has the watchdog loaded (files on disk aren't proof it runs). Spawns launchctl: call off the main thread.
    static var watchdogLoaded: Bool { Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).code == 0 }
    static var isReady: Bool { watchdogReady && sudoReady }
    /// The scheduled-wake commands were added after 1.0; an older sudoers entry lacks them until Set Up runs again.
    static var wakeReady: Bool {
        Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset"] + WakePlan.pmsetArgs(seconds: 900)).code == 0
            && Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/tmutil", "enable"]).code == 0
    }

    static let commands = [
        "-a disablesleep 1", "-a disablesleep 0",
        "-b powermode 0", "-b powermode 1", "-b powermode 2",
        "-b lowpowermode 0", "-b lowpowermode 1",
        "sleepnow",
    ].map { "/usr/bin/pmset " + $0 }
        + WakePlan.steps.map { "/usr/bin/pmset " + WakePlan.pmsetArgs(seconds: $0).joined(separator: " ") }
        + ["/usr/bin/tmutil disable", "/usr/bin/tmutil enable"]

    static func sudoersText(user: String) -> String {
        "# Installed by Nocturnal. Lets Nocturnal flip only these power switches without a password.\n"
        + "Cmnd_Alias NOCTURNAL_PMSET = " + commands.joined(separator: ", ") + "\n"
        + "\(user) ALL=(root) NOPASSWD: NOCTURNAL_PMSET\n"
    }

    static func install() throws {
        try installWatchdog()
        if !sudoReady || !wakeReady { try installSudoers() }
    }

    private static func installSudoers() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nocturnal-sudoers")
        try sudoersText(user: NSUserName()).write(to: tmp, atomically: true, encoding: .utf8)
        // Copy into a root-owned staging file first, validate THAT copy, then move it into place, so nothing
        // can swap the user-writable temp file between the check and the install. sudo ignores names with a dot.
        let staged = "/private/etc/sudoers.d/.nocturnal.staging"
        let cmd = "/bin/mkdir -p /private/etc/sudoers.d"
            + " && /usr/bin/install -m 0440 -o root -g wheel \(shellQuote(tmp.path)) \(staged)"
            + " && /usr/sbin/visudo -cf \(staged)"
            + " && /bin/mv -f \(staged) \(sudoersPath)"
            + " && " + cliLinkCommand
            // Leftovers from when the app was called Ajar: its sudoers entry, and its command if it's a link.
            + " && /bin/rm -f /private/etc/sudoers.d/ajar"
            + " && { [ ! -L /usr/local/bin/ajar ] || /bin/rm -f /usr/local/bin/ajar; }"
        try runAsAdmin(cmd, prompt: "Nocturnal needs your password once to control sleep while the lid is closed.")
        try? FileManager.default.removeItem(at: tmp)
        guard sudoReady else { throw SetupError(message: "Installed, but sudo isn't accepting it yet. Try Set up again.") }
        if !wakeReady { NSLog("Nocturnal: sudoers installed but the wake commands aren't accepted") }
    }

    static let cliPath = "/usr/local/bin/nocturnal"
    static var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliPath)) == Bundle.main.executablePath
    }
    private static var cliLinkCommand: String {
        "/bin/mkdir -p /usr/local/bin && /bin/ln -sf \(shellQuote(Bundle.main.executablePath ?? "/Applications/Nocturnal.app/Contents/MacOS/Nocturnal")) \(cliPath)"
    }

    /// Single-quote a path for /bin/sh, escaping any single quotes inside it.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Puts `nocturnal` on the PATH for terminals and Claude Code.
    static func installCLI() throws {
        try runAsAdmin(cliLinkCommand, prompt: "Nocturnal needs your password to install the nocturnal command.")
    }

    private static func runAsAdmin(_ cmd: String, prompt: String) throws {
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int
            throw SetupError(message: code == -128 ? "Setup cancelled." : (err[NSAppleScript.errorMessage] as? String ?? "Setup failed."))
        }
    }

    /// The launchd job runs this tiny script every minute. While the app's heartbeat is fresh, or there is none
    /// (Nocturnal quit cleanly and put everything back), it exits at once; with a stale heartbeat it hands over to the app binary (`Nocturnal cli watchdog`), which checks the heartbeat's pid and
    /// start time and undoes everything from the journal in Swift. No journal parsing in shell. If the app has
    /// been deleted, the script still lets the Mac sleep again.
    static var watchdogScript: String {
        let exe = Bundle.main.executablePath ?? "/Applications/Nocturnal.app/Contents/MacOS/Nocturnal"
        return """
        #!/bin/sh
        # Nocturnal watchdog (written by Nocturnal; refreshed each launch).
        D="$HOME/Library/Application Support/Nocturnal"
        EXE=\(shellQuote(exe))
        if [ -f "$D/alive" ]; then
          now=$(/bin/date +%s); beat=$(/usr/bin/stat -f %m "$D/alive")
          [ $((now - beat)) -lt 40 ] && exit 0
          # Stale heartbeat: the app died or hung. The app binary undoes everything from the journal.
          if [ -x "$EXE" ]; then exec "$EXE" cli watchdog; fi
        fi
        # No heartbeat: Nocturnal quit cleanly (or was deleted). Only a leftover hold can still need undoing.
        if [ -f "$D/hold" ]; then /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && /bin/rm -f "$D/hold"; fi
        exit 0
        """
    }

    /// Keeps the installed watchdog script in step with this version and this app's location.
    static func refreshWatchdogScript() {
        guard watchdogReady, StateFiles.read(StateFiles.watchdog) != watchdogScript else { return }
        try? watchdogScript.write(to: StateFiles.watchdog, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: StateFiles.watchdog.path)
    }

    static func installWatchdog() throws {
        let fm = FileManager.default
        // The old Ajar watchdog (same job, old name): stop and remove it.
        let oldLabel = "com.alexander.ajar.watchdog"
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(oldLabel)"])
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(oldLabel).plist"))
        try watchdogScript.write(to: StateFiles.watchdog, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: StateFiles.watchdog.path)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", StateFiles.watchdog.path],
            "StartInterval": 60,
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if r.code != 0 && !Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).out.contains(label) {
            throw SetupError(message: "Couldn't start the watchdog: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func uninstall() throws {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        StateFiles.remove(StateFiles.watchdog)
        var cmds: [String] = []
        if FileManager.default.fileExists(atPath: sudoersPath) || sudoReady { cmds.append("/bin/rm -f \(sudoersPath)") }
        if FileManager.default.fileExists(atPath: "/private/etc/sudoers.d/ajar") { cmds.append("/bin/rm -f /private/etc/sudoers.d/ajar") }
        if cliInstalled { cmds.append("/bin/rm -f \(cliPath)") }
        guard !cmds.isEmpty else { return }
        try runAsAdmin(cmds.joined(separator: " && "), prompt: "Nocturnal needs your password to remove its sleep permission and the nocturnal command.")
    }
}
