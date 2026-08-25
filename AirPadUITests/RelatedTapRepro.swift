import XCTest

/// ws-entry-containers item 5 — verifies whether the F3 regression still reproduces:
/// the keyboard-dismiss tap-catcher eating the FIRST tap on a Related NavigationLink
/// while a note is focused. The `-SPINEGATE related` fixture applies
/// `.dismissKeyboardOnTapOutside()` exactly as `NodeDetailView` does, so this is a
/// faithful check of the F3 fix (`KeyboardDismissTapCatcher cancelsTouchesInView =
/// false`). Observe, don't infer. Seeds: note "Roasted tomato base…" + related
/// "Confit garlic method" / "Sourdough, day 3" → nav destination renders "dest".
final class RelatedTapRepro: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SPINEGATE", "related"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.0)
        return app
    }

    private func relatedLink(_ app: XCUIApplication) -> XCUIElement {
        let byButton = app.buttons["Confit garlic method"]
        return byButton.exists ? byButton : app.staticTexts["Confit garlic method"]
    }

    private func attach(_ msg: String) {
        let a = XCTAttachment(string: msg); a.lifetime = .keepAlways; add(a)
    }

    /// The F3 scenario: note FOCUSED (keyboard up), then ONE tap on a Related link.
    /// F3 present ⇒ the first tap dismisses the keyboard and does NOT navigate.
    func testFirstTapNavigatesWithKeyboardUp() {
        let app = launch()
        let link = relatedLink(app)
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Related link not found (render check failed)")

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "note editor not found")
        editor.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let kbUp = app.keyboards.firstMatch.waitForExistence(timeout: 3)

        link.tap()   // FIRST tap
        let navigated = app.staticTexts["dest"].waitForExistence(timeout: 2.5)

        let msg = "F3 — keyboardUp=\(kbUp) navigatedOnFirstTap=\(navigated)"
        attach(msg); print("REPRO_F3 \(msg)")
        XCTAssertTrue(kbUp, "keyboard didn't come up — not exercising F3 — \(msg)")
        XCTAssertTrue(navigated, "FIRST tap on Related link did NOT navigate — F3 regression present — \(msg)")
    }

    /// Control: keyboard DOWN → the link must always navigate (rules out a dead link
    /// / bad fixture, so a keyboard-up failure is unambiguously the F3 mechanism).
    func testControlNavigatesWithKeyboardDown() {
        let app = launch()
        let link = relatedLink(app)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let navigated = app.staticTexts["dest"].waitForExistence(timeout: 2.5)
        let msg = "F3-CONTROL — navigatedKeyboardDown=\(navigated)"
        attach(msg); print("REPRO_F3C \(msg)")
        XCTAssertTrue(navigated, "Related link didn't navigate even with keyboard down — \(msg)")
    }
}
