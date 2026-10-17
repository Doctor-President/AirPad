import XCTest

/// live-22 (2) — the on-device appearance tuner (TestFlight only; in DEBUG with `-AppearanceTuner YES`), on the real
/// screens: its handle floats over every view T judges (Map, Card, vertical cards, the grid, List, Recents, entry
/// detail, the open Librarian); a touch anywhere else still reaches the app; the sheet edits live (a preset moves the
/// readouts); Copy values puts the JSON on the pasteboard; Reset restores T's picks; a long-press hides the handle.
/// Sample Library in a scratch library. Simulator.
final class AppearanceTunerUI: XCTestCase {

    static let base = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-AppearanceTuner", "YES",
                       "-AppearanceTunerReset", "YES"]

    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.base + extra
        app.launch()
        return app
    }
    private func handle(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "appearanceTunerHandle").firstMatch
    }
    private func readout(_ app: XCUIApplication, _ id: String) -> String {
        app.staticTexts["tunerReadout-\(id)"].firstMatch.label
    }

    func testHandleFloatsOverEveryView() {
        let views: [(String, [String])] = [
            ("map", ["-OpenMap"]),
            ("card", ["-OpenCardView", "-gridColumnCount", "1"]),
            ("vertical", ["-OpenCardView", "-gridColumnCount", "4"]),
            ("grid", ["-OpenCardView", "-gridColumnCount", "2"]),
            ("list", ["-OpenListView"]),
            ("recents", []),
            ("entry", ["-OpenCardView", "-OpenFirstGradientEntry"]),
            ("librarian-open", ["-OpenCardView", "-gridColumnCount", "2", "-LibrarianDetent", "full"]),
        ]
        for (name, args) in views {
            let app = launch(args)
            let h = handle(app)
            XCTAssertTrue(h.waitForExistence(timeout: 30), "the handle on \(name)")
            sleep(4)   // the view settles (entry push, panel detent)
            XCTAssertTrue(h.isHittable, "the handle is on top on \(name)")
            shot(app, "handle-\(name)")
            app.terminate()
        }
    }

    func testTouchesOutsideTheTunerReachTheApp() {
        let app = launch(["-OpenListView"])
        XCTAssertTrue(handle(app).waitForExistence(timeout: 30))
        let row = app.staticTexts["A year of this"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a List row")
        row.tap()
        XCTAssertTrue(app.buttons["Add tag"].firstMatch.waitForExistence(timeout: 15), "the tap opened the entry")
        XCTAssertTrue(handle(app).isHittable, "and the handle is still there over the entry")
        shot(app, "passthrough-entry")
    }

    func testSheetEditsLiveCopiesAndResets() {
        let app = launch(["-OpenCardView", "-gridColumnCount", "2", "-LibrarianDetent", "half"])
        let h = handle(app)
        XCTAssertTrue(h.waitForExistence(timeout: 30))
        h.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearanceTunerSheet"].waitForExistence(timeout: 10), "the sheet opens")
        XCTAssertEqual(app.staticTexts["tunerEditingMode"].label, "Editing Light — follows the system")
        XCTAssertEqual(readout(app, "tint"), "0.35", "Today's tint")
        XCTAssertEqual(readout(app, "blur"), "1.00 pass")
        shot(app, "sheet-today")
        app.buttons["tunerPreset-frost50"].tap()
        XCTAssertEqual(readout(app, "tint"), "0.50", "Frost 50% moves the tint")
        XCTAssertEqual(readout(app, "blur"), "2.00 passes", "heavy blur")
        XCTAssertEqual(readout(app, "saturation"), "40%", "saturation pulled down")
        shot(app, "sheet-frost50")
        // The runner may not read the pasteboard on iOS 27 (paste authorization), so the test checks the copy ran;
        // the JSON itself is read from the Mac side afterwards (`xcrun simctl pbpaste`) and its shape is a self-test row.
        app.buttons["tunerCopy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3), "Copy values ran")
        // A palette switch re-renders the field, cards and dots behind the sheet with no reload (the still is read for
        // the field hex afterwards: L1's F2 is #E8E8E8).
        app.buttons["tunerClose"].tap()
        let chevron = app.descendants(matching: .any).matching(identifier: "appearanceTunerHandle").firstMatch
        chevron.tap()
        app.segmentedControls["tunerPalette"].buttons["L1"].tap()
        XCTAssertEqual(readout(app, "field"), "F2 · #E8E8E8", "L1's F2")
        app.buttons["tunerClose"].tap()
        sleep(1)
        shot(app, "live-palette-L1")
        chevron.tap()
        app.buttons["tunerReset"].tap()
        app.buttons["tunerReset"].tap()
        XCTAssertEqual(readout(app, "tint"), "0.35", "Reset restores Today")
        XCTAssertEqual(readout(app, "field"), "F2 · #F4F2ED", "Reset restores T's field")
        app.buttons["tunerClose"].tap()
        XCTAssertTrue(h.waitForExistence(timeout: 5), "closing returns to the handle")
    }

    func testLongPressHidesUntilRelaunch() {
        let app = launch(["-OpenCardView", "-gridColumnCount", "2"])
        let h = handle(app)
        XCTAssertTrue(h.waitForExistence(timeout: 30))
        h.press(forDuration: 1.2)
        XCTAssertTrue(h.waitForNonExistence(timeout: 5), "hidden after a long-press")
        app.terminate()
        let again = launch(["-OpenCardView", "-gridColumnCount", "2"])
        XCTAssertTrue(handle(again).waitForExistence(timeout: 30), "back on the next launch")
    }
}
