import XCTest

/// live-13 (1) — the tier-3 device row, on a REAL iPhone only (skipped in the Simulator, which has no speech model).
/// The switch's stored value forces "Older recognizer"; the real microphone hears synthetic speech the Mac plays aloud
/// (CC starts the clip when this prints "[DeviceTier] recording"); the real recorder Done saves; the saved transcript in
/// the Voice item must hold every word the recorder showed — the words T's TF 202610140852 check lost. Not in
/// `ui_hostfree.txt` (it needs the Mac's speaker and a phone).
final class DeviceRecorderTier: XCTestCase {

    private func words(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    private func record(engine: String, label: String, seconds: TimeInterval, minWords: Int) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device-only: the Simulator has no speech model")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-UITestLibrary", "-UITestLibraryFresh", "-EntryQuikCapture",
                               "-speechEngineTesting", engine]
        app.launch()
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 20), "Quick Capture should open")
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        let voice = app.buttons["Voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10), "the Voice capture button should exist")
        voice.tap()
        addUIInterruptionMonitor(withDescription: "mic") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.tap()
        XCTAssertTrue(app.staticTexts["recorderTimer"].waitForExistence(timeout: 15), "the recorder should be up")
        print("[DeviceTier] recording \(label)")
        let live = app.descendants(matching: .any).matching(identifier: "liveTranscript").firstMatch
        var shown = "", peak = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 2)
            if live.exists { shown = live.label; peak = max(peak, words(shown)) }
        }
        let note = app.staticTexts["recorderTestingEngine"]
        let engineNote = note.exists ? note.label : "none"
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "\(label)-before-Done"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].firstMatch.tap()
        let field = app.descendants(matching: .any).matching(identifier: "voiceTranscript").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the Voice item shows in the capture")
        let saved = (field.value as? String) ?? ""
        print("[DeviceTier] \(label) engine='\(engineNote)' shownAtDone=\(words(shown)) peakShown=\(peak) saved=\(words(saved))")
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "\(label)-after-Done"; after.lifetime = .keepAlways; add(after)
        XCTAssertGreaterThanOrEqual(words(saved), words(shown), "\(label): saved holds every word shown at Done")
        XCTAssertGreaterThanOrEqual(words(saved), peak - 2, "\(label): no words shown during the take were lost")
        XCTAssertGreaterThanOrEqual(words(saved), minWords, "\(label): the take's words were saved (\(words(saved)))")
        #endif
    }

    /// 71 s of synthetic speech with 2.5–3 s pauses, crossing the 50 s rotation.
    func testDevice_olderRecognizer_realMic_savesEveryWord() throws {
        try record(engine: "olderRecognizer", label: "tier3", seconds: 85, minWords: 100)
    }

    /// The same take on Automatic (tier 1, `.fastResults`): saved = shown through the one text path.
    func testDevice_automatic_realMic_savesEveryWord() throws {
        try record(engine: "automatic", label: "automatic", seconds: 85, minWords: 100)
    }
}
