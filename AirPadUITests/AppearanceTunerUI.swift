import XCTest

/// live-22 (2) — the on-device appearance tuner (TestFlight only; in DEBUG with `-AppearanceTuner YES`), on the real
/// screens: its handle floats over every view T judges (Map, Card, vertical cards, the grid, List, Recents, entry
/// detail, the open Librarian); a touch anywhere else still reaches the app; the sheet edits live (a preset moves the
/// readouts); Copy values puts the JSON on the pasteboard; Reset restores T's picks; a long-press hides the handle.
/// Sample Library in a scratch library. Simulator.
final class AppearanceTunerUI: XCTestCase {

    // live-23: fresh, so a scratch library another run seeded (the card showcase) can't keep the sample from seeding.
    static let base = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-EmbedCPUOnly", "-AppearanceTuner", "YES",
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
        XCTAssertEqual(readout(app, "tint"), "0.85", "T's tuned tint (live-23 default)")
        XCTAssertEqual(readout(app, "blur"), "1.74 passes")
        // live-23 — the card-content switch (Today by default) and the hero fade at its baked shape.
        XCTAssertTrue(app.segmentedControls["tunerCardContent"].buttons["Today"].isSelected, "Card content starts on Today")
        XCTAssertEqual(readout(app, "fadeLength"), "0.60", "the baked fade length")
        XCTAssertEqual(readout(app, "fadeCurve"), "smoothstep", "the baked fade curve")
        shot(app, "sheet-default")
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
        XCTAssertEqual(readout(app, "tint"), "0.85", "Reset restores T's tuned values")
        XCTAssertEqual(readout(app, "field"), "F2 · #F4F2ED", "Reset restores T's field")
        app.buttons["tunerClose"].tap()
        XCTAssertTrue(h.waitForExistence(timeout: 5), "closing returns to the handle")
    }

    /// live-24 (1)+(2) — T found every slider kicked the old "Liquid Glass" preset out to Custom. Now Liquid Glass is a
    /// panel mode: its variant, tint colour, tint strength and veil all move without leaving it; the Siri-style pill
    /// preset turns the pill grade + rim on and is marked as chosen.
    func testLiquidGlassModeStaysGlassAndPresetsApply() {
        let app = launch(["-OpenCardView", "-gridColumnCount", "2", "-LibrarianDetent", "half"])
        let h = handle(app)
        XCTAssertTrue(h.waitForExistence(timeout: 30))
        h.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearanceTunerSheet"].waitForExistence(timeout: 10), "the sheet opens")
        let mode = app.segmentedControls["tunerPanelMode"]
        XCTAssertTrue(mode.buttons["Frost"].isSelected, "the panel starts as T's frost")
        mode.buttons["Liquid Glass"].tap()
        app.segmentedControls["tunerGlassVariant"].buttons["Clear"].tap()
        app.segmentedControls["tunerGlassTint"].buttons["Deep Klein"].tap()
        XCTAssertEqual(app.staticTexts["tunerGlassTint-hex"].firstMatch.label, "#0E2D61", "the tint shows its hex")
        app.sliders["tunerSlider-glassTintStrength"].adjust(toNormalizedSliderPosition: 0.75)
        app.sliders["tunerSlider-veil"].adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertTrue(mode.buttons["Liquid Glass"].isSelected, "every glass control keeps the Liquid Glass mode")
        XCTAssertTrue(app.segmentedControls["tunerGlassVariant"].buttons["Clear"].isSelected, "the variant stuck")
        XCTAssertNotEqual(readout(app, "glassTintStrength"), "40%", "the tint strength moved")
        shot(app, "sheet-liquid-glass-tuned")
        let siri = app.buttons["tunerGlassPreset-siriPill"].firstMatch
        XCTAssertTrue(siri.waitForExistence(timeout: 5))
        siri.tap()
        XCTAssertTrue(siri.isSelected, "the Siri-style pill preset is marked once applied")
        XCTAssertEqual(app.switches["tunerToggle-pillGrade"].firstMatch.value as? String, "1", "the pill grade is on")
        XCTAssertEqual(app.switches["tunerToggle-pillRim"].firstMatch.value as? String, "1", "the rim is on")
        XCTAssertTrue(mode.buttons["Liquid Glass"].isSelected, "a pill preset leaves the panel mode alone")
        app.buttons["tunerCopy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3), "Copy values ran")
        app.buttons["tunerClose"].tap()
        sleep(1)
        shot(app, "liquid-glass-clear-deep-klein-with-siri-pill")
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
