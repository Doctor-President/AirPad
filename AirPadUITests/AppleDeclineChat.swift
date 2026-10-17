import XCTest

/// live-23 (5b) — Apple Intelligence declines a General question honestly, and the decline doesn't stick. The
/// Simulator has no Apple Intelligence: `-StubOnDeviceModel YES -StubOnDeviceRefusal YES` stands in — a "presidents"
/// question gets T's verbatim refusal; any other answer says how many refusals were in the history it was SENT.
final class AppleDeclineChat: XCTestCase {
    private func askField(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        let tf = app.textFields.matching(pred).firstMatch
        if tf.waitForExistence(timeout: 30) { return tf }
        return app.textViews.matching(pred).firstMatch
    }
    private func ask(_ app: XCUIApplication, _ q: String) {
        let f = askField(app); f.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); f.tap() }
        f.typeText(q)
        let send = app.buttons["Send"]; XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testDeclineIsHonestAndDoesNotStick() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-ClearHostPairing", "YES",
                               "-StubOnDeviceModel", "YES", "-StubOnDeviceRefusal", "YES", "-OpenMap", "-GauntletUI", "YES",
                               "-EmbedCPUOnly"]
        app.launch()
        _ = askField(app)
        if app.buttons["Library mode"].exists { app.buttons["Library mode"].tap() }   // → General
        ask(app, "Give me a table of US presidents by year and party")
        let declined = app.descendants(matching: .any)["chat.declined"]
        XCTAssertTrue(declined.waitForExistence(timeout: 30), "the decline shows as a decline")
        XCTAssertTrue(declined.label.contains("Apple Intelligence declined this"), declined.label)
        XCTAssertFalse(app.descendants(matching: .any)["chat.generalKnowledge"].exists, "no general-knowledge label under a decline")
        XCTAssertTrue(app.buttons["chat.declined.retry"].exists, "Try again is one tap away")
        XCTAssertTrue(app.buttons["chat.declined.switchModel"].exists, "Switch model is one tap away")
        shot(app, "declined")
        app.buttons["chat.declined.switchModel"].tap()
        XCTAssertTrue(app.buttons["picker.appleIntelligence"].waitForExistence(timeout: 10), "Switch model opens the model picker")
        shot(app, "picker-from-decline")
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)
        ask(app, "Is that because you don't know that information, or you can't make tables?")
        let answer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'History refusals: 0'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the follow-up was sent with NO refusal in its history")
        shot(app, "follow-up")
    }
}
