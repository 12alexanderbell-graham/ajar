import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Whole-Mac power, read from the battery controller's own telemetry: what the Mac actually draws, on battery or
/// on the charger. The per-app energy counters only cover CPU and GPU work; the display, memory, Wi-Fi and the
/// rest of the board were measured at about 15× more than all apps combined on a lid-closed M5 Max.
/// `PowerTelemetryData` isn't public API (Apple says it may change), so everything falls back to
/// voltage × current from the battery when it's missing.
struct PowerSample {
    /// Instantaneous system load, watts. Refreshes every few seconds.
    var watts: Double?
    /// Running totals the controller keeps; the difference between two samples is an exact average.
    var accumulated: Int64?
    var count: Int64?
    var at = Date()
}

enum PowerSensor {
    static func sample() -> PowerSample? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        if let t = IORegistryEntryCreateCFProperty(s, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            let load = (t["SystemLoad"] as? NSNumber)?.doubleValue ?? 0
            let acc = (t["AccumulatedSystemLoad"] as? NSNumber)?.int64Value
            let n = (t["SystemLoadAccumulatorCount"] as? NSNumber)?.int64Value
            if load > 0 { return PowerSample(watts: load / 1000, accumulated: acc, count: n) }
        }
        // Fallback: battery discharge only (unknown on the charger).
        func value(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
        let amps = value("InstantAmperage") ?? value("Amperage") ?? 0
        let volts = value("Voltage") ?? 0
        guard amps < 0, volts > 0 else { return nil }
        return PowerSample(watts: Double(-amps) * Double(volts) / 1_000_000)
    }

    /// Exact average watts between two samples when the controller's totals moved; otherwise the later reading.
    static func average(_ a: PowerSample, _ b: PowerSample) -> Double? {
        if let a0 = a.accumulated, let a1 = b.accumulated, let c0 = a.count, let c1 = b.count, c1 > c0, a1 >= a0 {
            return Double(a1 - a0) / Double(c1 - c0) / 1000
        }
        return b.watts
    }

    static var isMeasured: Bool { sample()?.accumulated != nil }
}

/// Work nobody can see while the lid is shut but that keeps the Mac's hardware busy: booted iOS simulators
/// (hundreds of processes each, plus their GPU host), Xcode previews, and background processes holding the
/// speakers open (which keeps the audio hardware powered even when silent).
enum BackgroundWork {
    struct Found {
        var simulators: [pid_t] = []
        var previews: [pid_t] = []
        var audio: [pid_t: String] = [:]   // pid → name
        /// xcodebuild, xctest or a UI test runner is going: the simulators are in use, so they're left alone.
        var testsRunning = false
        var simulatorDevices = 0
    }

    private static let previewNames: Set<String> = ["PreviewShellMac", "previewsd", "XCPreviewAgent", "PreviewShell"]
    /// Processes that only exist while tests drive a simulator (testmanagerd is resident, so it doesn't count).
    private static let testNames: Set<String> = ["xcodebuild", "xctest", "simctl", "XCTestAgent"]
    /// Simulator infrastructure Xcode itself talks to; freezing it would hang Xcode, not save power.
    private static let simServiceMarkers = ["CoreSimulatorService", "com.apple.CoreSimulator.", "SimulatorTrampoline"]

    static func scan(all: [pid_t]) -> Found {
        var f = Found()
        var children: [pid_t: [pid_t]] = [:]
        var names: [pid_t: String] = [:]
        var paths: [pid_t: String] = [:]
        var roots: [pid_t] = []
        for pid in all {
            guard let path = Procs.path(pid) else { continue }
            let name = (path as NSString).lastPathComponent
            paths[pid] = path; names[pid] = name
            if let pp = Procs.parent(pid) { children[pp, default: []].append(pid) }
            if name == "launchd_sim" { roots.append(pid) }
            if testNames.contains(name) || name.hasSuffix("-Runner") { f.testsRunning = true }
        }
        f.simulatorDevices = roots.count
        var sims = Set<pid_t>()
        for r in roots {
            var stack = [r]
            while let p = stack.popLast() { if sims.insert(p).inserted { stack.append(contentsOf: children[p] ?? []) } }
        }
        for (pid, path) in paths {
            let name = names[pid] ?? ""
            if simServiceMarkers.contains(where: { path.contains($0) }) { sims.remove(pid); continue }
            if name == "SimMetalHost" || path.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") { sims.insert(pid) }
            if previewNames.contains(name) && !sims.contains(pid) { f.previews.append(pid) }
        }
        f.simulators = Array(sims)
        f.audio = audioHolders(names: names)
        return f
    }

    /// Processes keeping an audio output open, read from macOS's power assertions: coreaudiod takes one on behalf
    /// of each client using the speakers or headphones ("Resources: audio-out").
    static func audioHolders(names: [pid_t: String] = [:]) -> [pid_t: String] {
        var out: [pid_t: String] = [:]
        var u: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&u) == kIOReturnSuccess, let d = u?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return out }
        for (owner, list) in d {
            for a in list {
                let resources = (a["ResourcesUsed"] as? [String]) ?? []
                let name = (a["AssertName"] as? String) ?? ""
                guard resources.contains(where: { $0.hasPrefix("audio-out") }) || name.contains(".context.preventuseridlesleep") else { continue }
                let pid = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? owner.int32Value
                guard pid > 1, pid != getpid() else { continue }
                let n = names[pid] ?? Procs.path(pid).map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
                if n == "coreaudiod" { continue }
                out[pid] = n
            }
        }
        return out
    }
}

/// Calls back the moment the lid opens or closes (IOPMrootDomain's general-interest messages), so Ajar doesn't
/// have to poll. Any message from the root domain triggers a re-read of the lid flag, which keeps this working
/// even if the private clamshell message number ever changes; the main loop still checks every few seconds.
final class LidWatcher {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        defer { IOObjectRelease(root) }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let r = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }, me, &notifier)
        guard r == KERN_SUCCESS else { IONotificationPortDestroy(port); self.port = nil; return nil }
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if let port { IONotificationPortDestroy(port) }
    }
}

/// Apps that must keep running with the lid shut even on Max Battery: music and calls (headphones, lid shut) are
/// left alone; services agents commonly talk to (containers, local models, databases, browsers an agent may be
/// driving) are slowed, never paused, so a running agent doesn't hang on them.
enum AppClasses {
    static let mediaAndCalls: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina",
        "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.tinyspeck.slackmacgap.huddle", "com.apple.VoiceMemos",
    ]
    static let agentServices: Set<String> = [
        "com.docker.docker", "dev.kdrag0n.MacVirt", "com.electron.ollama", "ai.elementlabs.lmstudio", "com.postgresapp.Postgres2",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
        "com.microsoft.edgemac", "com.apple.dt.Xcode", "com.utmapp.UTM", "com.parallels.desktop.console",
    ]
    /// Name fallback for services whose bundle id varies between versions.
    static func isAgentService(name: String) -> Bool {
        ["Docker", "OrbStack", "Ollama", "LM Studio", "Postgres", "Redis", "UTM", "Parallels"].contains { name.localizedCaseInsensitiveContains($0) }
    }
}
