import CoreGraphics
import Foundation
import IOKit.hid

/// Built-in display brightness, through the same private framework the brightness keys use.
enum Brightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: Get? = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setFn: Set? = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    private static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func get() -> Float? {
        guard let id = builtIn, let getFn else { return nil }
        var v: Float = -1
        return getFn(id, &v) == 0 && v >= 0 ? v : nil
    }

    @discardableResult
    static func set(_ v: Float) -> Bool {
        guard let id = builtIn, let setFn else { return false }
        return setFn(id, min(1, max(0, v))) == 0
    }

    /// Present while Ajar has the screen dimmed for a closed lid; holds the brightness to put back.
    static var restoreFile: URL { StateFiles.dir.appendingPathComponent("brightness-restore") }

    /// Dims to zero, remembering the old level on disk first so a crash can't leave the screen black.
    static func dimForClosedLid() {
        guard !StateFiles.exists(restoreFile), let cur = get() else { return }
        StateFiles.write(String(cur), to: restoreFile)
        set(0)
    }

    /// Keeps the saved level if setting it fails, so the next try (the app, or the watchdog) still knows it.
    static func restore() {
        guard let s = StateFiles.read(restoreFile) else { return }
        let target: Float
        if let v = Float(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0.02 { target = v } else { target = 0.5 }
        if set(target) { StateFiles.remove(restoreFile) }
    }
}

/// The lid angle sensor in recent MacBooks (the one Bendy and lid-plane use). Degrees, 0 = shut.
final class LidSensor {
    private var device: IOHIDDevice?

    init() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                    "PrimaryUsagePage": 0x0020, "PrimaryUsage": 0x008A]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let d = (IOHIDManagerCopyDevices(m) as? Swift.Set<IOHIDDevice>)?.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = d
    }

    var available: Bool { device != nil }

    func angle() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &len) == kIOReturnSuccess, len >= 3 else { return nil }
        let deg = Double(Int(report[1]) | (Int(report[2]) << 8))
        return deg <= 360 ? deg : nil
    }
}

/// Turns the built-in display fully off without sleeping it, through the same private WindowServer call display
/// managers use (CGSConfigureDisplayEnabled, as in blackoutd, BetterDisplay and Lunar). A display that's
/// configured off isn't "asleep", so macOS doesn't show the lock screen afterwards. A marker file is written
/// before the change, so the next launch or the watchdog turns it back on if Ajar dies while it's off.
enum DisplayPower {
    private typealias Configure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configure: Configure? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")
        .map { unsafeBitCast($0, to: Configure.self) }

    static var available: Bool { configure != nil }
    static var marker: URL { StateFiles.dir.appendingPathComponent("display-off") }

    private static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func set(_ id: CGDirectDisplayID, enabled: Bool) -> CGError {
        guard let configure else { return .notImplemented }
        var config: CGDisplayConfigRef?
        if enabled {   // a no-op transaction first keeps the compositor healthy before turning the display back on
            if CGBeginDisplayConfiguration(&config) == .success { _ = CGCompleteDisplayConfiguration(config, .forSession) }
        }
        guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }
        let err = configure(config, id, enabled)
        guard err == .success else { CGCancelDisplayConfiguration(config); return err }
        // For this login session only: logging out always brings the display back, whatever happens to Ajar.
        return CGCompleteDisplayConfiguration(config, .forSession)
    }

    /// Off. True only when macOS took it (it may refuse to switch off the only display).
    static func turnOffBuiltIn() -> Bool {
        guard available, let id = builtIn else { return false }
        StateFiles.write("\(id)", to: marker)
        let err = set(id, enabled: false)
        if err == .success || err == .illegalArgument { return true }
        StateFiles.remove(marker)
        return false
    }

    /// Back on if Ajar turned it off (marker present). Keeps the marker if macOS refused, so it's retried.
    @discardableResult
    static func restoreBuiltIn() -> Bool {
        guard StateFiles.exists(marker) else { return true }
        let saved = StateFiles.read(marker).flatMap { CGDirectDisplayID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let id = builtIn ?? saved else { return false }
        let err = set(id, enabled: true)
        if err == .success || err == .illegalArgument { StateFiles.remove(marker); return true }   // illegalArgument: already on
        return false
    }
}
