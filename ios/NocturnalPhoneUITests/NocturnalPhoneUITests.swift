import UIKit
import XCTest

/// Walks every control in the demo and the pairing screens, checking what each one does and saving a screenshot of
/// each state (attached to the test, and written to dist/review/phone when the Mac's folder is reachable).
final class NocturnalPhoneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testDemoWalkthrough() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let headline = app.staticTexts["headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(headline.label.contains("Keeps working"), headline.label)
        sleep(1)
        shot(app, "01-home")

        // The band: tap the 2 hour stop.
        let band = app.descendants(matching: .any)["band"].firstMatch
        XCTAssertTrue(band.exists, app.debugDescription)
        tapStop(band, 3)
        XCTAssertTrue(wait(app.staticTexts["readout"], contains: "Until"), app.staticTexts["readout"].label)
        shot(app, "02-two-hours")

        // Drag the lens to Always.
        let from = band.coordinate(withNormalizedOffset: CGVector(dx: 3.5 / 7, dy: 0.5))
        let to = band.coordinate(withNormalizedOffset: CGVector(dx: 6.5 / 7, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertTrue(wait(app.staticTexts["readout"], contains: "Always"), app.staticTexts["readout"].label)
        shot(app, "03-always")

        // Sleep now waits with an Undo; the band already shows where it lands (When busy, not Always).
        app.buttons["main"].tap()
        let undo = app.buttons["undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(wait(app.staticTexts["readout"], contains: "Sleeps in"), app.staticTexts["readout"].label)
        shot(app, "04-sleep-undo")
        undo.tap()
        XCTAssertTrue(wait(app.staticTexts["readout"], contains: "Always"), app.staticTexts["readout"].label)

        // Sleep for real: once the Undo runs out it says Asleep straight away, the ground goes to night and the
        // band rests until it wakes.
        app.buttons["main"].tap()
        XCTAssertTrue(wait(headline, contains: "Asleep", timeout: 8), headline.label)
        XCTAssertTrue(wait(app.staticTexts["readout"], contains: "Asleep"), app.staticTexts["readout"].label)
        XCTAssertTrue((band.value as? String ?? "").contains("unavailable"), "\(band.value ?? "")")
        sleep(1)
        shot(app, "05-asleep")

        // Settings say it's asleep and stay put until it wakes.
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["It's asleep. Settings change once it wakes."].waitForExistence(timeout: 3), app.debugDescription)
        sleep(1)
        shot(app, "05b-asleep-settings")
        app.buttons["settings"].tap()
        sleep(1)

        // Wake it: the demo answers at once (a real sleeping computer picks it up at its next check-in).
        XCTAssertEqual(app.buttons["main"].label, "Wake it")
        app.buttons["main"].tap()
        XCTAssertTrue(wait(headline, contains: "Keeps working", timeout: 4), headline.label)
        sleep(1)
        shot(app, "06-woken")

        // Settings grow out of the gear; pull up for the whole screen; tap the gear to close.
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["Keeps it awake"].waitForExistence(timeout: 3), app.debugDescription)
        sleep(1)
        shot(app, "07-settings-half")
        let sheetPoint = app.staticTexts["Keeps it awake"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sheetPoint.press(forDuration: 0.05, thenDragTo: sheetPoint.withOffset(CGVector(dx: 0, dy: -380)))
        sleep(1)
        shot(app, "08-settings-full")
        app.swipeUp()
        sleep(1)
        shot(app, "09-settings-scrolled")
        app.swipeUp()
        sleep(1)
        shot(app, "10-settings-bottom")
        XCTAssertTrue(app.buttons["forget"].exists)
        XCTAssertTrue(app.staticTexts["Busy apps"].exists || app.staticTexts["On the computer"].exists, app.debugDescription)
        app.buttons["settings"].tap()
        sleep(1)
        XCTAssertFalse(app.staticTexts["Keeps it awake"].isHittable)
        shot(app, "11-settings-closed")

        // Exit the demo.
        app.buttons["exitDemo"].tap()
        XCTAssertTrue(app.buttons["demo"].waitForExistence(timeout: 3), app.debugDescription)
        sleep(1)
        shot(app, "12-after-demo")
    }

    @MainActor
    func testPairScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-unpaired"]
        app.launch()
        XCTAssertTrue(app.buttons["next"].waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        shot(app, "20-welcome")
        app.buttons["next"].tap()
        XCTAssertTrue(app.buttons["type"].waitForExistence(timeout: 3), app.debugDescription)
        sleep(1)
        shot(app, "21-pair")
        UIPasteboard.general.string = "not a code"
        app.buttons["paste"].tap()
        // iOS asks once whether the app may paste.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Paste", "Allow"] where springboard.buttons[label].waitForExistence(timeout: 2) {
            springboard.buttons[label].tap()
            break
        }
        shot(app, "21b-after-paste")
        // Either the pasted text is refused, or (if the simulator kept the clipboard to itself) it asks for a copy.
        XCTAssertTrue(wait(app.staticTexts["pairError"], contains: "code"), app.debugDescription)
        app.buttons["type"].tap()
        let field = app.textFields["codeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("hello\n")
        XCTAssertTrue(wait(app.staticTexts["pairError"], contains: "isn't a Nocturnal pairing code"), app.debugDescription)
        shot(app, "22-pair-error")
        app.buttons["back"].tap()
        XCTAssertTrue(app.buttons["demo"].waitForExistence(timeout: 3))
        app.buttons["demo"].tap()
        XCTAssertTrue(app.staticTexts["headline"].waitForExistence(timeout: 3))
    }

    /// Clean screenshots for the website and the App Store: the demo without Exit Demo, reading "Live".
    @MainActor
    func testMarketingShots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-marketing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["headline"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["exitDemo"].exists)
        sleep(2)
        shot(app, "m1-home")
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["Keeps it awake"].waitForExistence(timeout: 3), app.debugDescription)
        sleep(2)
        shot(app, "m2-settings")
    }

    // MARK: Helpers

    @MainActor private func tapStop(_ band: XCUIElement, _ i: Int) {
        band.coordinate(withNormalizedOffset: CGVector(dx: (Double(i) + 0.5) / 7, dy: 0.5)).tap()
    }

    @MainActor private func wait(_ e: XCUIElement, contains text: String, timeout: TimeInterval = 3) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: timeout) == .completed
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        // The simulator shares the Mac's disk: also drop it where the review can be picked up.
        let dir = URL(fileURLWithPath: NSHomeDirectory().components(separatedBy: "/Library/Developer").first ?? NSHomeDirectory())
            .appendingPathComponent("Developer/Nocturnal/dist/review/phone")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
    }
}
