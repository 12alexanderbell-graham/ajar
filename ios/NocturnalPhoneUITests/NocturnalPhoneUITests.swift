import XCTest

/// Runs the demo and walks every control, saving screenshots of each screen.
final class NocturnalPhoneUITests: XCTestCase {
    @MainActor
    func testDemoWalkthrough() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let status = app.staticTexts["status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(status.label.contains("Keeps working"), status.label)
        attach(app, "home")
        app.buttons["Always"].tap()
        XCTAssertTrue(app.buttons["1 hour"].waitForExistence(timeout: 3), app.debugDescription)
        attach(app, "always")
        app.buttons["Off"].tap()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Sleeps normally'").evaluate(with: status) || waitFor(status, "Sleeps normally"), status.label)
        attach(app, "off")
        app.buttons["Sleep now"].tap()
        attach(app, "confirm-sleep")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 3))
        attach(app, "settings")
    }

    @MainActor
    func testPairScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-unpaired"]
        app.launch()
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 5))
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText("hello\n")
        XCTAssertTrue(app.staticTexts["That doesn't look like a Nocturnal pairing code."].waitForExistence(timeout: 3))
        attach(app, "pair")
    }

    @MainActor private func waitFor(_ e: XCUIElement, _ text: String) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: 3) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
