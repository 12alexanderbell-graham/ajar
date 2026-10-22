import CryptoKit
import Foundation

/// The pairing with one computer: its 256-bit key and the relay. Same protocol as Nocturnal on the computer
/// (Remote.swift on the Mac, remote.rs on Windows and Linux) and the phone page:
///  • two topic names derived from the key ("nocturnal-" + the first 24 hex digits of SHA-256(label ‖ key)):
///    one for commands, one for replies
///  • every message AES-256-GCM sealed with its topic name as associated data (nonce ‖ ciphertext ‖ tag, base64url)
/// The relay (ntfy) only ever sees sealed messages. The key never leaves this phone except in the Keychain.
nonisolated struct Pairing: Equatable, Sendable {
    static let defaultServer = "https://ntfy.sh"

    let key: Data
    let server: String

    var commandTopic: String { Self.topic("nocturnal/cmd/v1", key) }
    var replyTopic: String { Self.topic("nocturnal/reply/v1", key) }

    init?(key: Data, server: String? = nil) {
        guard key.count == 32 else { return nil }
        self.key = key
        self.server = server ?? Self.defaultServer
    }

    /// A full pairing link ("…#k=KEY&s=SERVER", the computer's QR code), just "k=…", or the bare key.
    init?(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = t.firstIndex(of: "#").map { String(t[t.index(after: $0)...]) } ?? t
        var fields: [String: String] = [:]
        for part in fragment.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        let keyText = fields["k"] ?? (t.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil ? t : nil)
        guard let keyText, let key = Base64URL.decode(keyText) else { return nil }
        // Only an https relay is accepted from a link: anything else would leave the sealed messages unprotected in transit.
        var server: String?
        if let s = fields["s"], s.hasPrefix("https://"), URL(string: s)?.host != nil {
            server = s.hasSuffix("/") ? String(s.dropLast()) : s
        }
        self.init(key: key, server: server)
    }

    static func topic(_ label: String, _ key: Data) -> String {
        let digest = SHA256.hash(data: Data(label.utf8) + key)
        return "nocturnal-" + digest.map { String(format: "%02x", $0) }.joined().prefix(24)
    }

    func seal(_ plaintext: Data, topic: String, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) -> String? {
        guard let box = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: Data(topic.utf8)),
              let combined = box.combined else { return nil }
        return Base64URL.encode(combined)
    }

    func open(_ message: String, topic: String) -> Data? {
        guard let raw = Base64URL.decode(message), raw.count >= 28, raw.count <= 65536,
              let box = try? AES.GCM.SealedBox(combined: raw) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(topic.utf8))
    }
}

nonisolated enum Base64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
