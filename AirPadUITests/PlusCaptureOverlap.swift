import XCTest

/// live-24 (4) — on a REAL "+" tap (the canvas chrome's `captureButton`, not the `-RealCapturePlus` harness), does the
/// Librarian's search pill sit over the "+" Capture bar's Delete / Done? live-23 saw it in the harness only (which
/// clears `isCapturing` on purpose, a Brief CD device repro). Synthetic showcase entries (the Sample Library opens read-only, with no "+"), isolated scratch library.
/// Fails if the pill is on screen and hittable over either button, or if Done doesn't close the capture.
final class PlusCaptureOverlap: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testRealPlusTapNeverCoversDeleteOrDone() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedCardShowcase",
                               "-EmbedCPUOnly", "-OpenCardView", "-gridColumnCount", "2"]
        app.launch()

        let pill = app.textFields["Search"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "the Librarian's search pill is up on the canvas before \"+\"")
        let plus = app.buttons["captureButton"].firstMatch
        if !plus.waitForExistence(timeout: 5) {
            // `-OpenCardView` lands with the panel already at peek, so the router never hears a detent change and the
            // "+" (gated on `librarianAtPeek`) stays hidden. Open the Librarian and close it, as a person would.
            pill.tap()
            Thread.sleep(forTimeInterval: 1.2)
            // Drag the panel down by its grabber (at half it sits just above the middle of the screen).
            let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.532))
            grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        }
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "the canvas \"+\" should exist at peek")
        shot(app, "canvas-at-peek-with-plus")
        plus.tap()

        let editor = app.textViews["noteEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "\"+\" should open the capture editor")
        for _ in 0..<3 {
            editor.tap()
            if app.keyboards.element.waitForExistence(timeout: 3) { break }
        }
        editor.typeText("Ask the harbour office about the mooring.")
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 1.5)   // let the Librarian settle if anything would raise it
        shot(app, "plus-capture-with-note")

        let done = app.buttons["Done"].firstMatch
        let delete = app.buttons["Delete capture"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Done should show once the note has text")
        XCTAssertTrue(delete.exists, "Delete should show beside Done")

        let pillUp = pill.exists && pill.isHittable && !pill.frame.isEmpty
        let report = "pill exists=\(pill.exists) hittable=\(pill.exists && pill.isHittable) frame=\(pill.exists ? pill.frame : .zero) · "
            + "done=\(done.frame) delete=\(delete.frame)"
        let r = XCTAttachment(string: report); r.name = "frames"; r.lifetime = .keepAlways; add(r)
        print("[PlusCaptureOverlap] \(report)")
        XCTAssertFalse(pillUp && pill.frame.intersects(done.frame), "the Librarian pill covers Done — \(report)")
        XCTAssertFalse(pillUp && pill.frame.intersects(delete.frame), "the Librarian pill covers Delete — \(report)")

        // The behaviour: Done closes the capture (a covered Done opens the Librarian instead).
        done.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 8), "Done should close the \"+\" capture — \(report)")
        shot(app, "plus-capture-after-done")
    }
}
