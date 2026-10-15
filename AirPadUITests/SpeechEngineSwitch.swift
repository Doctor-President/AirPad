import XCTest

/// live-12 (2) — the TestFlight-only "Speech engine (testing)" switch, through the real About screen (DEBUG offers it, as
/// TestFlight's sandbox receipt does): long-press the version → five choices (no server one) → a pick persists across a
/// relaunch → back to Automatic. The App Store gate itself is `-SpeechEngineTestingSelfTest`.
final class SpeechEngineSwitch: XCTestCase {

    private func openPanel() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "settings-about", "-UITestLibrary"]
        app.launch()
        let version = app.staticTexts["aboutVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: 20), "About shows the version")
        version.press(forDuration: 1.0)
        XCTAssertTrue(app.navigationBars["Speech engine (testing)"].waitForExistence(timeout: 5), "long-press opens the switch")
        return app
    }

    private func selected(_ app: XCUIApplication) -> [String] {
        ["automatic", "speech", "dictation", "olderRecognizer", "unavailable"].filter {
            app.buttons["speechEngine-\($0)"].isSelected
        }
    }

    func testSwitch_fiveChoices_pickPersists_backToAutomatic() {
        var app = openPanel()
        let ids = ["automatic", "speech", "dictation", "olderRecognizer", "unavailable"]
        for id in ids { XCTAssertTrue(app.buttons["speechEngine-\(id)"].exists, "choice \(id)") }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'speechEngine-'")).count, 5,
                       "exactly the five on-device choices")
        XCTAssertEqual(selected(app), ["automatic"], "starts on Automatic")
        app.buttons["speechEngine-dictation"].tap()
        XCTAssertEqual(selected(app), ["dictation"])
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "speech-engine-switch"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()

        app = openPanel()
        XCTAssertEqual(selected(app), ["dictation"], "the pick survives a relaunch")
        app.buttons["speechEngine-automatic"].tap()
        XCTAssertEqual(selected(app), ["automatic"], "back to Automatic")
        app.terminate()
    }
}
