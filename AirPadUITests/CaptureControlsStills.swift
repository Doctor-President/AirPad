import XCTest

/// live-23 (5c) — capture controls, Today vs Liquid Glass (`-CaptureControls glass`), as stills from the REAL screens:
/// Quick Capture empty (Cancel) and with a note (Delete + Done), the voice recorder (Done + Cancel), and "+" Capture
/// with a note. Appearance is set by the caller (`simctl ui appearance`). Synthetic content, isolated library. It also
/// checks the controls still work in glass: Done on the recorder saves, Done on Quick Capture closes it.
final class CaptureControlsStills: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
    /// Tap until the editor has the keyboard (a tap can land before the editor is ready to take focus).
    private func type(_ app: XCUIApplication, _ editor: XCUIElement, _ text: String) {
        for _ in 0..<3 {
            editor.tap()
            if app.keyboards.element.waitForExistence(timeout: 3) { break }
        }
        editor.typeText(text)
    }
    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
    }

    private func run(glass: Bool) {
        let mode = glass ? "glass" : "today"
        var base = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-StubAuthorModel", "-EmbedCPUOnly",
                    "-StubLiveTranscript", "Pick up the prints on Thursday and ask about the rescan."]
        if glass { base += ["-CaptureControls", "glass"] }

        // Quick Capture
        let app = XCUIApplication()
        app.launchArguments = base + ["-EntryQuikCapture"]
        app.launch()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "Quick Capture should open")
        hideKeyboard(app)
        Thread.sleep(forTimeInterval: 1); shot(app, "\(mode)-quickcapture-empty")
        type(app, editor, "Darkroom list: fixer, stop bath, two boxes of paper.")
        hideKeyboard(app)
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), "Done appears with content")
        XCTAssertTrue(app.buttons["Delete capture"].exists, "Delete appears with content")
        Thread.sleep(forTimeInterval: 1); shot(app, "\(mode)-quickcapture-content")

        // The recorder
        app.buttons["Voice"].firstMatch.tap()
        addUIInterruptionMonitor(withDescription: "mic") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.tap()
        XCTAssertTrue(app.staticTexts["recorderTimer"].waitForExistence(timeout: 15), "the recorder should be up")
        Thread.sleep(forTimeInterval: 3); shot(app, "\(mode)-recorder")
        XCTAssertTrue(app.buttons["Cancel"].exists, "the recorder's Cancel")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.textViews["voiceTranscript"].waitForExistence(timeout: 10) || app.textFields["voiceTranscript"].waitForExistence(timeout: 2),
                      "Done on the recorder saves the voice item")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "Done closes Quick Capture")
        app.terminate()

        // "+" Capture
        app.launchArguments = base + ["-RealCapturePlus"]
        app.launch()
        let plusEditor = app.textViews["noteEditor"]
        XCTAssertTrue(plusEditor.waitForExistence(timeout: 30), "+ Capture should open")
        type(app, plusEditor, "Ask the harbour office about the mooring.")
        hideKeyboard(app)
        Thread.sleep(forTimeInterval: 1); shot(app, "\(mode)-plus-capture-content")
        app.terminate()
    }

    func testTodayStills() { run(glass: false) }
    func testGlassStills() { run(glass: true) }
}
