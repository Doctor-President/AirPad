import XCTest

/// Recorder redesign — RENDER ONLY (T, 2026-10-13). Quick Capture → Voice with a synthetic live feed
/// (`-StubLiveTranscript`: words arrive as if spoken; no microphone, the take is a generated tone). Stills at the
/// start, mid-stream, a full block (older lines fading under the waveform) and the end state after Done.
/// Appearance + screen recording are set by the caller. Synthetic content, isolated library.
final class RecorderRender: XCTestCase {

    private let spoken = "Remember to water the fern on the landing before Friday. The tall one by the window needs a bigger pot, "
        + "so pick up some compost and a terracotta pot on the way home. Ask next door whether they still want the cuttings."

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testRenderRecorder() {
        let app = XCUIApplication()
        app.launchArguments = ["-EntryQuikCapture", "-UITestLibrary", "-UITestLibraryFresh", "-StubAuthorModel", "-EmbedCPUOnly",
                               "-StubLiveTranscript", spoken]
        app.launch()
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 20), "Quick Capture should open")
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        let voice = app.buttons["Voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()
        XCTAssertTrue(app.staticTexts["recorderTimer"].waitForExistence(timeout: 10), "the recorder should be up")
        Thread.sleep(forTimeInterval: 1.2); shot(app, "r1-start")
        Thread.sleep(forTimeInterval: 3.5); shot(app, "r2-streaming")
        Thread.sleep(forTimeInterval: 6.0); shot(app, "r3-block-fading")
        Thread.sleep(forTimeInterval: 3.0); shot(app, "r4-before-done")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.textViews["voiceTranscript"].waitForExistence(timeout: 10) || app.textFields["voiceTranscript"].waitForExistence(timeout: 2),
                      "after Done the Voice item holds the live words")
        Thread.sleep(forTimeInterval: 4.0)   // the ghost title/summary arrive (stub model)
        shot(app, "r5-after-done")
    }
}
