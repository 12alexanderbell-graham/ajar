import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Waking a sleeping Mac on a schedule, and briefly while asleep to pick up a "wake" sent from the phone.
///
/// A Mac that's asleep is offline, so the phone can't reach it directly. Instead, just before macOS sleeps, Nocturnal
/// asks for a wake a while later (`pmset relative wake <seconds>`). When that wake comes with the lid still shut,
/// Nocturnal keeps the Mac up for a few seconds, reads any phone commands the relay held while it slept, and lets it
/// sleep again if nothing wants it awake. A fully shut-down Mac can't be woken this way (nothing is running).
///
/// pmset only accepts these fixed lengths through Nocturnal's sudoers entry (no wildcards), so a wake at a clock time
/// is reached in steps: each step is the longest that doesn't overshoot, and every step is also a check-in.
enum WakePlan {
    static let steps = [3600, 1800, 900, 300, 60]
    static let checkInChoices = [0, 15, 30, 60]
    /// How long a check-in keeps the Mac up to read the phone's commands.
    static let checkInSeconds: TimeInterval = 25
    /// Phone "wake" commands are honoured this long after they were sent (they wait at the relay while it sleeps).
    static let wakeMaxAge: TimeInterval = 3 * 3600

    /// Seconds until the next wake to ask macOS for, or nil for none. `untilWake` is the time left to a
    /// scheduled wake; `checkInMinutes` 0 means no check-ins.
    static func nextStep(untilWake: TimeInterval?, checkInMinutes: Int) -> Int? {
        var target: TimeInterval?
        if checkInMinutes > 0 { target = TimeInterval(checkInMinutes * 60) }
        if let w = untilWake { target = min(target ?? .infinity, max(60, w)) }
        guard let t = target else { return nil }
        return steps.first { TimeInterval($0) <= t + 30 } ?? 60
    }

    static func pmsetArgs(seconds: Int) -> [String] { ["relative", "wake", String(seconds)] }
}

/// macOS power events from IOKit. Unlike NSWorkspace's didWake, `systemHasPoweredOn` also arrives for dark wakes
/// (the lid-closed, screen-off wakes a scheduled wake produces).
final class PowerEvents {
    // iokit_common_msg(0x270 / 0x280 / 0x300): function-like macros that Swift doesn't import.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onPoweredOn: () -> Void

    init(onPoweredOn: @escaping () -> Void) {
        self.onPoweredOn = onPoweredOn
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(ctx, &port, { ctx, _, type, arg in
            guard let ctx else { return }
            let me = Unmanaged<PowerEvents>.fromOpaque(ctx).takeUnretainedValue()
            switch type {
            case PowerEvents.canSystemSleep, PowerEvents.systemWillSleep:
                IOAllowPowerChange(me.root, Int(bitPattern: arg))   // never veto or delay sleep here
            case PowerEvents.systemHasPoweredOn:
                DispatchQueue.main.async { me.onPoweredOn() }
            default: break
            }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if root != 0 { IOServiceClose(root) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// Pausing Time Machine's automatic backups while the lid is closed. Only if they were on; the marker file is the
/// journal (written before the change, so the watchdog switches backups back on if Nocturnal dies).
enum TimeMachine {
    static var marker: URL { StateFiles.dir.appendingPathComponent("timemachine-restore") }
    static var paused: Bool { StateFiles.exists(marker) }

    /// Automatic backups are on. Unreadable counts as off: then Nocturnal leaves Time Machine alone.
    static var autoBackupOn: Bool {
        Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.TimeMachine", "AutoBackup"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func pause() {
        guard !paused, autoBackupOn else { return }
        StateFiles.touch(marker)
        guard StateFiles.exists(marker) else { return }
        if Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/tmutil", "disable"]).code != 0 { StateFiles.remove(marker) }
    }

    /// True once backups are back on (or were never paused).
    @discardableResult
    static func resume() -> Bool {
        guard paused else { return true }
        guard Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/tmutil", "enable"]).code == 0 else { return false }
        StateFiles.remove(marker)
        return true
    }
}

/// Build tools an agent runs. Slowing the driver (cargo, make, xcodebuild) also covers the compilers it starts
/// afterwards: the efficiency-core policy is inherited by child processes.
enum BuildTools {
    static let names: Set<String> = [
        "swift-frontend", "swiftc", "swift-build", "swift-driver", "clang", "clang++", "cc", "c++", "ld", "ld64", "lld",
        "rustc", "cargo", "go", "javac", "kotlinc", "xcodebuild", "XCBBuildService", "make", "gmake", "ninja", "cmake",
        "esbuild", "gcc", "g++",
    ]
}

/// An external display is connected (the Mac keeps its graphics and display pipeline running for it).
enum Displays {
    static var externalConnected: Bool {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
