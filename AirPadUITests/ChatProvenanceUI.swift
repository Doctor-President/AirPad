import XCTest

/// live-27 (4) — every answer says which model wrote it, and a model switch mid-chat shows a quiet divider. The
/// Simulator has neither Apple Intelligence nor a Mac: `-StubAnswerModels "apple,qwen3:4b-instruct-2507-q4_K_M"` makes
/// the first answer Apple Intelligence's and the second the Host's qwen, through the real send path. Light + dark
/// (`-appearance.override`). Synthetic questions, isolated library. Stills attached.
final class ChatProvenanceUI: XCTestCase {
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

    private func run(_ appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-ClearHostPairing", "YES",
                               "-StubAnswerModels", "apple,qwen3:4b-instruct-2507-q4_K_M", "-OpenMap", "-GauntletUI", "YES",
                               "-EmbedCPUOnly", "-appearance.override", appearance, "-LibrarianDetent", "full"]
        app.launch()
        _ = askField(app)
        if app.buttons["Library mode"].exists { app.buttons["Library mode"].tap() }   // → General
        ask(app, "What is a tide pool?")
        let captions = app.descendants(matching: .any).matching(identifier: "chat.provenance")
        XCTAssertTrue(captions.firstMatch.waitForExistence(timeout: 30), "the answer says who wrote it")
        XCTAssertTrue(captions.firstMatch.label.contains("Apple Intelligence"), captions.firstMatch.label)
        XCTAssertFalse(app.descendants(matching: .any)["chat.modelSwitch"].exists, "no divider before the first answer")
        ask(app, "And why do they matter?")
        let second = captions.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 30), "the second answer says who wrote it")
        XCTAssertTrue(second.label.contains("· Host"), second.label)
        let divider = app.descendants(matching: .any)["chat.modelSwitch"]
        XCTAssertTrue(divider.waitForExistence(timeout: 5), "a model switch mid-chat shows a divider")
        XCTAssertTrue(divider.label.hasPrefix("Switched to "), divider.label)
        // The keyboard away (its "Done" bar), then scroll the transcript to the latest answer (coordinates: the bar's
        // Done and the jump button aren't reported hittable under the panel).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.607)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
        Thread.sleep(forTimeInterval: 2)
        shot(app, "provenance-\(appearance)")
    }

    func testEveryAnswerSaysWhoWroteItLight() { run("light") }
    func testEveryAnswerSaysWhoWroteItDark() { run("dark") }
}
