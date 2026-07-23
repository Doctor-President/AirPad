import XCTest

/// MD14 verify — drives a REAL synthesized tap into the note editor in the
/// Simulator (via the `-SPRCaretMeasure` fixture) so CC can confirm the caret
/// lands at the tap (not the end) with no device lap. The app writes the trace to
/// `Documents/caret_trace.log`, which CC reads via `simctl get_app_container`.
final class CaretTapTest: XCTestCase {

    /// The fix: tapping mid-note lands the caret at the tap offset (the note editor
    /// must fire `didChangeSelection` at an interior offset, like the controls).
    func testMidNoteTap() {
        let app = launched()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "note editor did not appear")
        XCTAssertTrue(app.textViews["controlTextView"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["controlNoScroll"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.2)

        // Real synthesized tap in the MIDDLE of the note editor's first line.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.06)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        // Same tap into the vanilla controls (the trustworthiness baseline).
        app.textViews["controlTextView"].coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).tap()
        Thread.sleep(forTimeInterval: 1.2)
        app.textViews["controlNoScroll"].coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.12)).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Regression: the fix must NOT stop typography from being applied on typing —
    /// a content change must still trigger the restyle (`applyInPlace`).
    func testTypingStillRestyles() {
        let app = launched()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "note editor did not appear")
        Thread.sleep(forTimeInterval: 1.2)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.06)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        editor.typeText("Z")
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SPRCaretMeasure", "YES"]
        app.launch()
        return app
    }
}
