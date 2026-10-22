import Foundation
import Network

/// Is the Mac online, and is it on an iPhone's Personal Hotspot?
///
/// Why the hotspot matters: an iPhone switches its hotspot off by itself after a while, and when that happens macOS
/// only turns it back on without asking if System Settings › Wi-Fi › "Ask to join hotspots" is set to Automatic.
/// On "Ask" it shows a prompt, which nobody can answer with the lid shut, so the Mac stays awake but offline until
/// the lid opens. Ajar can't change that setting (there's no API for it), so it says so while you're on a hotspot.
@MainActor
final class NetWatch {
    private let monitor = NWPathMonitor()
    private(set) var online = true
    /// macOS marks a phone's hotspot as an expensive network.
    private(set) var expensiveWiFi = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let pricey = ok && path.isExpensive && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async {
                guard let self, self.online != ok || self.expensiveWiFi != pricey else { return }
                self.online = ok
                self.expensiveWiFi = pricey
            }
        }
        monitor.start(queue: DispatchQueue(label: "ajar.netwatch"))
    }

    /// On a phone's hotspot: macOS flags it as expensive, and an iPhone hotspot also hands out 172.20.10.0/28.
    var onPhoneHotspot: Bool { expensiveWiFi || Self.inIPhoneHotspotRange }

    /// An iPhone Personal Hotspot hands out addresses in 172.20.10.0/28; nothing else commonly uses that range.
    nonisolated static var inIPhoneHotspotRange: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: a.pointee.ifa_name).hasPrefix("en") else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip & 0xFFFF_FFF0 == 0xAC14_0A00 { return true }   // 172.20.10.0/28
        }
        return false
    }

    /// System Settings › Wi-Fi, where "Ask to join hotspots" lives.
    static let wifiSettingsURL = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
}
