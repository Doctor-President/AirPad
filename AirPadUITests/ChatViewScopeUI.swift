import XCTest

/// live-27 (4b) — the Chat view has the Librarian's General / Library toggle (no "Private" pill), and both surfaces
/// route the same way: General → the general-knowledge line under a factual answer (no web key, Apple Intelligence
/// stubbed); Library → the read receipt. The toggle is one setting: flipped in the Chat view, the Librarian shows it.
/// Synthetic questions, isolated library.
final class ChatViewScopeUI: XCTestCase {
    private func field(_ app: XCUIApplication, _ placeholder: String) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue == %@ OR label == %@", placeholder, placeholder)
        let tf = app.textFields.matching(pred).firstMatch
        if tf.waitForExistence(timeout: 20) { return tf }
        return app.textViews.matching(pred).firstMatch
    }
    private func send(_ app: XCUIApplication, _ f: XCUIElement, _ q: String) {
        f.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); f.tap() }
        f.typeText(q)
        let s = app.buttons["Send"].firstMatch; XCTAssertTrue(s.waitForExistence(timeout: 5)); s.tap()
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testChatViewHasTheLibrarianScopeToggleAndRoutesTheSame() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-ClearHostPairing", "YES",
                               "-StubAnswerModels", "apple", "-OpenMap", "-OpenChatsList", "-GauntletUI", "YES", "-EmbedCPUOnly",
                               "-librarianCorpusAware", "YES"]
        app.launch()
        let new = app.buttons["chats.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 20)); new.tap()
        let chatField = field(app, "Message")
        XCTAssertTrue(chatField.waitForExistence(timeout: 20), "the Chat view's composer")
        XCTAssertFalse(app.staticTexts["Private"].exists, "no Private pill")
        let toggle = app.buttons["chat.scopeToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Chat view shows the Librarian's scope toggle")
        XCTAssertEqual(toggle.label, "Library mode")
        shot(app, "chat-view-library")
        // Library → the read receipt, like the Librarian.
        send(app, chatField, "What did I note about the tide pools?")
        XCTAssertTrue(app.descendants(matching: .any)["chat.readReceipt"].firstMatch.waitForExistence(timeout: 40),
                      "a Library turn in the Chat view reads the library (receipt)")
        // General → the general-knowledge line under a factual answer.
        toggle.tap()
        XCTAssertTrue(app.buttons["chat.scopeToggle"].label == "General mode")
        send(app, chatField, "What is a tide pool?")
        // The line sits under the answer, below the fold once the keyboard is up: bring it into view.
        let gk = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'From the model' AND label CONTAINS 'general knowledge'")).firstMatch
        var seen = gk.waitForExistence(timeout: 8)
        for _ in 0..<6 where !seen {
            app.swipeUp(velocity: .slow); seen = gk.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(seen, "a General turn in the Chat view routes like the Librarian's General")
        app.swipeDown(velocity: .slow)
        shot(app, "chat-view-general")
        // One setting: the Librarian shows General too.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if app.buttons["Done"].waitForExistence(timeout: 5) { app.buttons["Done"].tap() }
        let lib = app.buttons["librarian.scopeToggle"]
        XCTAssertTrue(lib.waitForExistence(timeout: 15) && lib.label == "General mode", "the Librarian shows the same scope")
        shot(app, "librarian-general")
    }
}
