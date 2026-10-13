import XCTest

/// Arc B — RENDER FIRST (T, 2026-10-12): drive the voice-transcript flow through the real entry screen and keep a
/// still at every step for T to judge (collapsed / expanded Voice item, tap-to-edit, the "Edited" mark, the "…" menu
/// with Restore + Extract, the extracted text item appearing). Appearance is set on the Simulator by the caller
/// (`simctl ui … appearance`); the caller also records the screen. Synthetic seeded entry, isolated library.
final class ArcBVoiceTranscriptRender: XCTestCase {

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 2) { hide.tap() }
        else if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }   // the entry screen's keyboard pill
        else if app.keyboards.element.exists {
            // Plain keyboard (no format bar): tap the hero, outside any field.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
    }

    func testRenderTranscriptFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedVoiceEntry", "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded entry should be in Recents")
        Thread.sleep(forTimeInterval: 1)
        row.tap()
        let transcript = app.textViews["voiceTranscript"].exists ? app.textViews["voiceTranscript"] : app.textFields["voiceTranscript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "the Voice item shows its transcript")
        Thread.sleep(forTimeInterval: 1.5)   // waveform peaks load
        shot(app, "01-voice-expanded")

        // Collapse, then expand again (the Voice item's chevron is the first one on the screen).
        let chevron = app.buttons.matching(NSPredicate(format: "identifier == 'chevron.right' OR label == 'Forward'")).firstMatch
        if chevron.waitForExistence(timeout: 3) {
            chevron.tap(); Thread.sleep(forTimeInterval: 0.8)
            shot(app, "02-voice-collapsed")
            chevron.tap(); Thread.sleep(forTimeInterval: 0.8)
        }

        // Tap to edit, same as a note.
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85)).tap()   // caret at the end, as a person would
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), "tapping the transcript edits it")
        shot(app, "03-transcript-editing")
        transcript.typeText(" Call them first.")
        shot(app, "04-transcript-typed")
        hideKeyboard(app)
        XCTAssertTrue(app.staticTexts["voiceEditedMark"].waitForExistence(timeout: 5), "an edited transcript shows 'Edited'")
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "05-edited-mark")

        // The Voice item's "…" menu: Extract as text · Append to… · Restore original.
        let options = app.buttons.matching(identifier: "entryOptions").element(boundBy: 0)
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        XCTAssertTrue(app.buttons["Extract as text"].waitForExistence(timeout: 5), "the menu offers Extract as text")
        XCTAssertTrue(app.buttons["Restore original"].exists, "an edited transcript offers Restore original")
        shot(app, "06-menu")
        if app.buttons["Append to…"].exists {
            app.buttons["Append to…"].tap(); Thread.sleep(forTimeInterval: 0.6)
            shot(app, "07-menu-append-to")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // close without choosing
            Thread.sleep(forTimeInterval: 0.6)
            options.tap()
            _ = app.buttons["Extract as text"].waitForExistence(timeout: 5)
        }
        app.buttons["Extract as text"].tap()
        Thread.sleep(forTimeInterval: 0.25)
        shot(app, "08-extracted-highlight")
        Thread.sleep(forTimeInterval: 2.0)
        shot(app, "09-extracted-settled")

        // Restore original: the mark goes, the recognised words come back.
        options.tap()
        XCTAssertTrue(app.buttons["Restore original"].waitForExistence(timeout: 5))
        app.buttons["Restore original"].tap()
        XCTAssertTrue(app.staticTexts["voiceEditedMark"].waitForNonExistence(timeout: 5), "Restore original clears 'Edited'")
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "10-restored")
    }
}
