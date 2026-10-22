import CryptoKit
import Foundation
import Testing
@testable import NocturnalPhone

/// The protocol must match the computer and the phone page byte for byte: these vectors are the same ones the
/// Rust tests and the page's harness use.
@MainActor
struct ProtocolTests {
    let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    @Test func topicsMatchTheComputer() throws {
        let p = try #require(Pairing(text: key))
        #expect(p.commandTopic == "nocturnal-112e75d0b83e40403eac24d9")
        #expect(p.replyTopic == "nocturnal-afcff4a1cb6fca045ee40662")
    }

    @Test func sealsLikeTheComputer() throws {
        let p = try #require(Pairing(text: key))
        let nonce = try AES.GCM.Nonce(data: Data(0..<12))
        // Sealed by Python's `cryptography` (AESGCM) with the same key, nonce and topic.
        #expect(p.seal(Data(#"{"cmd":"panel"}"#.utf8), topic: p.commandTopic, nonce: nonce) == "AAECAwQFBgcICQoLPCC1dqHH-Dn9IPnu3csFkc4ysiLaG2BIkJuYeoGy0w")
    }

    @Test func opensOnlyWithTheRightTopic() throws {
        let p = try #require(Pairing(text: key))
        let sealed = try #require(p.seal(Data("hi".utf8), topic: p.replyTopic))
        #expect(p.open(sealed, topic: p.replyTopic) == Data("hi".utf8))
        #expect(p.open(sealed, topic: p.commandTopic) == nil)
        let other = try #require(Pairing(key: Data(repeating: 7, count: 32)))
        #expect(other.open(sealed, topic: p.replyTopic) == nil)
    }

    @Test func readsEveryPairingForm() throws {
        #expect(Pairing(text: "https://nocturnal.tools/remote/#k=\(key)")?.server == "https://ntfy.sh")
        #expect(Pairing(text: "k=\(key)&s=https%3A%2F%2Frelay.example.com%2Fntfy")?.server == "https://relay.example.com/ntfy")
        #expect(Pairing(text: "k=\(key)&s=http://insecure.example.com")?.server == "https://ntfy.sh")
        #expect(Pairing(text: "hello") == nil)
        #expect(Pairing(text: "k=AAAA") == nil)
    }

    @Test func decodesCurrentAndOlderPanels() throws {
        let new = #"{"host":"Mac","keeps":true,"mode":"on","numbers":{"pct":82,"w":3.1,"h":19.25,"plugged":false},"agents":[{"id":"claude-code","name":"Claude Code","state":"waiting"}]}"#
        let p = try JSONDecoder().decode(Panel.self, from: Data(new.utf8))
        #expect(p.figures?.pct == 82 && p.figures?.w == 3.1)
        #expect(p.agentLine == "Claude Code is waiting for you")
        let old = #"{"host":"Old","batteryLine":"64% · about 6 h 05 min with the lid closed","watts":4.2,"agents":[{"id":"a","name":"A","working":true},{"id":"b","name":"B","working":true}],"checkIn":"oops"}"#
        let o = try JSONDecoder().decode(Panel.self, from: Data(old.utf8))
        #expect(o.figures?.pct == 64)
        #expect(abs((o.figures?.h ?? 0) - 6.0833) < 0.01)
        #expect(o.agentLine == "2 agents are working")
        #expect(o.checkIn == nil, "a field of the wrong type falls back instead of hiding the whole status")
    }

    @Test func theDemoAnswersLikeAComputer() {
        let d = DemoComputer()
        #expect(d.handle("mode", ["mode": "off"]).panel?.keeps == false)
        #expect(d.handle("set", ["key": "battery_floor", "value": 5]).ok == false)
        #expect(d.handle("schema", [:]).settings?.contains { $0.key == "heat_guard" } == true)
        #expect(d.handle("rule", ["app": "com.google.Chrome", "rule": "pause"]).panel?.apps.first?.rule == "pause")
        #expect(d.handle("release", ["id": "h1"]).panel?.holdList.isEmpty == true)
    }

    @Test func readsEverySettingKind() {
        // The Mac sends the check-in interval as an enum of numbers; it must still show.
        let s = Setting(["key": "check_in_minutes", "type": "enum", "value": NSNumber(value: 15), "allowed": ["0", "15", "30", "60"]])
        #expect(s?.text == "15")
        #expect(Setting(["key": "menubar", "type": "enum", "value": "battery", "allowed": ["none", "battery"]])?.text == "battery")
        #expect(Setting(["key": "quiet_minutes", "type": "int", "value": NSNumber(value: 5)])?.int == 5)
    }

    @Test func decodesTheAppsTab() throws {
        let j = #"{"apps":[{"id":"com.a","name":"A","w":1.5,"rule":"slow","custom":true}],"holdList":[{"id":"x","reason":"Export"}],"sessions":[{"when":"Today","line":"2 h closed"}],"agents":[{"id":"c","name":"C","sleepsIn":4}],"wakeFor":30}"#
        let p = try JSONDecoder().decode(Panel.self, from: Data(j.utf8))
        #expect(p.apps.first?.custom == true && p.holdList.count == 1 && p.sessions.count == 1)
        #expect(p.agents.first?.sleepsIn == 4 && p.wakeFor == 30)
    }
}
