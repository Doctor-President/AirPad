import XCTest

/// 1.0r S0a/S0c — the forward-format probe. CC fakes a "future" library (versions above what this build
/// knows + unknown fields) inside the persistent `-UITestLibrary` scratch, then this test does what a user
/// on the older build would: open an entry, type into its note, leave. CC diffs the files on disk afterwards
/// (`scripts/forward_format/probe.sh`). The test itself asserts nothing about the files.
final class ForwardFormatProbe: XCTestCase {

    func testEditEntryInFutureLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestSampleLibrary", "-OpenFirstGradientEntry"]
        app.launch()
        let editor = app.textViews["noteEditor"]
        guard editor.waitForExistence(timeout: 30) else {
            // Read-only / refused: record what the screen shows instead of failing the run.
            print("FWDPROBE no-editor; texts=\(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))")
            return
        }
        Thread.sleep(forTimeInterval: 2.0)
        editor.tap()
        // The first tap can land while the detail is still settling; tap the end of the note until it takes focus.
        for dy in [0.95, 0.6, 0.2] where !app.keyboards.element.waitForExistence(timeout: 3) {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: dy)).tap()
        }
        editor.typeText(" FWDPROBE")
        Thread.sleep(forTimeInterval: 2.0)
        // The detail saves on close (`onDisappear` → saveIfChanged): close the entry the way a user does.
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap() } else { app.swipeRight(velocity: XCUIGestureVelocity(3000)) }
        Thread.sleep(forTimeInterval: 2.0)
        if editor.exists { app.swipeDown(velocity: XCUIGestureVelocity(3000)) }
        Thread.sleep(forTimeInterval: 4.0)
        print("FWDPROBE closed=\(!editor.exists)")
    }
}
