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
    /// 2026-10-17 brief — the sheet is an accordion, every section closed when it opens: open one to reach its controls.
    private func open(_ app: XCUIApplication, _ section: String) {
        let header = app.buttons["tunerSection-\(section)"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "the \(section) header")
        if header.value as? String != "open" { header.tap() }
    }
    /// The tuner's sliders move only from their knob (22 pt, inset 11 pt each end): drag it from one fraction of the
    /// range to another.
    private func dragKnob(_ slider: XCUIElement, from: Double, to: Double) {
        let w = slider.frame.width
        func at(_ f: Double) -> XCUICoordinate { slider.coordinate(withNormalizedOffset: CGVector(dx: (11 + f * (w - 22)) / w, dy: 0.5)) }
        at(from).press(forDuration: 0.05, thenDragTo: at(to))
    }
    /// Turn a tuner switch to `value` ("1" / "0"), tapping again only if a tap didn't take (parallel runs are slow).
    private func flip(_ sw: XCUIElement, to value: String) {
        for _ in 0..<3 where sw.value as? String != value {
            sw.switches.firstMatch.tap()
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline && sw.value as? String != value { Thread.sleep(forTimeInterval: 0.2) }
        }
    }
    static let sections = ["cardContent", "captureControls", "librarian", "peekPill", "searchPill", "askPill", "panelGrade",
                           "cards", "heroFade"]

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
        open(app, "librarian")
        // live-26 (1) — T's 2026-10-18 values: the panel on Liquid Glass, tint 20%, veil 30%; his frost numbers kept.
        XCTAssertTrue(app.segmentedControls["tunerPanelMode"].buttons["Liquid Glass"].isSelected, "the panel starts on Liquid Glass")
        XCTAssertEqual(readout(app, "glassTintStrength"), "20%", "T's glass tint")
        XCTAssertEqual(readout(app, "veil"), "30%", "T's reading veil")
        XCTAssertEqual(readout(app, "dimAmount"), "10.5%", "T's dim")
        shot(app, "sheet-default")
        app.segmentedControls["tunerPanelMode"].buttons["Frost"].tap()
        XCTAssertEqual(readout(app, "tint"), "0.51", "T's frost tint, kept")
        XCTAssertEqual(readout(app, "blur"), "0.58 passes")
        // live-26 — the card-content switch (the proposal ships; Before stays) and the hero fade at its baked shape.
        open(app, "cardContent")
        XCTAssertTrue(app.segmentedControls["tunerCardContent"].buttons["Proposal"].isSelected, "Card content starts on Proposal")
        XCTAssertTrue(app.segmentedControls["tunerCardContent"].buttons["Before"].exists, "Before stays in the tuner")
        open(app, "heroFade")
        // live-29 (B1) — T's 10-19 light fade: 0.25, curve 2, carried 15% into the body.
        XCTAssertEqual(readout(app, "fadeLength"), "0.25", "the baked fade length")
        XCTAssertEqual(readout(app, "fadeCurve"), "smootherstep", "the baked fade curve (2 reads as smootherstep)")
        XCTAssertEqual(readout(app, "fadeIntoBody"), "15%", "the baked Fade into body")
        open(app, "librarian")
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
        open(app, "cards")
        app.segmentedControls["tunerPalette"].buttons["L1"].tap()
        XCTAssertEqual(readout(app, "field"), "F2 · #E8E8E8", "L1's F2")
        app.buttons["tunerClose"].tap()
        sleep(1)
        shot(app, "live-palette-L1")
        chevron.tap()
        app.buttons["tunerReset"].tap()
        app.buttons["tunerReset"].tap()
        XCTAssertEqual(readout(app, "field"), "F2 · #F4F2ED", "Reset restores T's field")
        open(app, "librarian")
        // live-26: Reset = T's 10-18 values (the panel on Liquid Glass, tint 20%).
        XCTAssertTrue(app.segmentedControls["tunerPanelMode"].buttons["Liquid Glass"].isSelected, "Reset restores Liquid Glass")
        XCTAssertEqual(readout(app, "glassTintStrength"), "20%", "Reset restores T's tuned values")
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
        open(app, "librarian")
        let mode = app.segmentedControls["tunerPanelMode"]
        XCTAssertTrue(mode.buttons["Liquid Glass"].isSelected, "the panel starts on Liquid Glass (T's 10-18 values)")
        app.segmentedControls["tunerGlassVariant"].buttons["Clear"].tap()
        app.segmentedControls["tunerGlassTint"].buttons["Deep Klein"].tap()
        XCTAssertEqual(app.staticTexts["tunerGlassTint-hex"].firstMatch.label, "#0E2D61", "the tint shows its hex")
        dragKnob(app.descendants(matching: .any)["tunerSlider-glassTintStrength"].firstMatch, from: 0.20 / 0.80, to: 0.75)
        dragKnob(app.descendants(matching: .any)["tunerSlider-veil"].firstMatch, from: 0.30, to: 0.8)
        XCTAssertTrue(mode.buttons["Liquid Glass"].isSelected, "every glass control keeps the Liquid Glass mode")
        XCTAssertTrue(app.segmentedControls["tunerGlassVariant"].buttons["Clear"].isSelected, "the variant stuck")
        XCTAssertNotEqual(readout(app, "glassTintStrength"), "20%", "the tint strength moved")
        shot(app, "sheet-liquid-glass-tuned")
        let siri = app.buttons["tunerGlassPreset-siriPill"].firstMatch
        XCTAssertTrue(siri.waitForExistence(timeout: 5))
        siri.tap()
        XCTAssertTrue(siri.isSelected, "the Siri-style pill preset is marked once applied")
        XCTAssertTrue(mode.buttons["Liquid Glass"].isSelected, "a pill preset leaves the panel mode alone")
        // The preset sets all three pills (2026-10-17 brief).
        for pill in ["peek", "search"] {
            open(app, "\(pill)Pill")
            XCTAssertEqual(app.switches["tunerToggle-\(pill)Grade"].firstMatch.value as? String, "1", "the \(pill) grade is on")
            XCTAssertTrue(app.segmentedControls["tunerRimRest-\(pill)"].buttons["On"].isSelected, "the \(pill) rim is on at rest")
        }
        app.buttons["tunerCopy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 3), "Copy values ran")
        app.buttons["tunerClose"].tap()
        sleep(1)
        shot(app, "liquid-glass-clear-deep-klein-with-siri-pill")
    }

    /// 2026-10-17 brief (D) + (A) — T scrolled a lot and brushed sliders by accident (TF 202610170354). The sheet opens
    /// with every section closed; opening one closes the others; a swipe across a slider's track never moves it, a drag
    /// from its knob does; the lock freezes every control; the peek pill, search pill and Ask bar are tuned apart.
    func testSectionsStartClosedAndSlidersMoveOnlyByTheKnob() {
        let app = launch(["-OpenCardView", "-gridColumnCount", "2", "-LibrarianDetent", "half"])
        let h = handle(app)
        XCTAssertTrue(h.waitForExistence(timeout: 30))
        h.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearanceTunerSheet"].waitForExistence(timeout: 10), "the sheet opens")
        for s in Self.sections {
            XCTAssertTrue(app.buttons["tunerSection-\(s)"].firstMatch.exists, "the \(s) header")
            XCTAssertEqual(app.buttons["tunerSection-\(s)"].firstMatch.value as? String, "closed", "\(s) starts closed")
        }
        XCTAssertFalse(app.descendants(matching: .any)["tunerSlider-tint"].exists, "only headers: no slider is reachable")
        XCTAssertFalse(app.segmentedControls["tunerPanelMode"].exists, "only headers: no picker either")
        XCTAssertTrue(app.buttons["tunerCopy"].isHittable, "Copy values stays pinned")
        shot(app, "sheet-closed")

        // The accordion. live-26: the panel starts on Liquid Glass (T's 10-18 values); Frost shows the frost sliders.
        open(app, "librarian")
        app.segmentedControls["tunerPanelMode"].buttons["Frost"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tunerSlider-tint"].waitForExistence(timeout: 3))
        open(app, "peekPill")
        XCTAssertFalse(app.descendants(matching: .any)["tunerSlider-tint"].exists, "opening Peek pill closes Librarian surface")
        XCTAssertTrue(app.segmentedControls["tunerRimRest-peek"].exists, "the peek rim at rest")
        XCTAssertFalse(app.segmentedControls["tunerRimActive-peek"].exists, "the peek pill never answers")

        // Sliders: the track takes no touches; the knob drags. (live-26: the panel starts on Liquid Glass, so the tint.)
        open(app, "librarian")
        let tint = app.descendants(matching: .any)["tunerSlider-tint"].firstMatch
        XCTAssertEqual(readout(app, "tint"), "0.51")
        XCTAssertGreaterThan(tint.frame.width, 200, "the slider element has the row's real frame: \(tint.frame)")
        let track = tint.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        track.press(forDuration: 0.05, thenDragTo: tint.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        XCTAssertEqual(readout(app, "tint"), "0.51", "a swipe across the track leaves the value alone")
        dragKnob(tint, from: 0.51, to: 0.9)
        XCTAssertNotEqual(readout(app, "tint"), "0.51", "a drag from the knob moves it")
        let moved = readout(app, "tint")

        // The lock.
        app.buttons["tunerLock"].tap()
        XCTAssertFalse(tint.isEnabled, "locked: the slider is disabled")
        dragKnob(tint, from: Double(moved) ?? 0.9, to: 0.2)
        XCTAssertEqual(readout(app, "tint"), moved, "locked: a knob drag changes nothing")
        app.buttons["tunerLock"].tap()

        // A scroll swipe that starts on the track scrolls the sheet and leaves the value alone.
        let yBefore = tint.frame.minY
        tint.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: tint.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: -3)))
        sleep(2)
        XCTAssertLessThan(tint.frame.minY, yBefore - 20, "the swipe scrolled the sheet (\(yBefore) → \(tint.frame.minY))")
        XCTAssertEqual(readout(app, "tint"), moved, "and the value stayed")
        shot(app, "after-scroll-swipe-over-a-slider")
        app.buttons["tunerLock"].tap()
        open(app, "cards")
        XCTAssertTrue(app.descendants(matching: .any)["tunerSlider-field"].waitForExistence(timeout: 3), "locked: sections still open")
        shot(app, "sheet-locked")
        app.buttons["tunerLock"].tap()   // unlock

        // Per-pill looks: Peek's grade leaves Search alone; Ask mirrors Search until "Match Search" is off.
        open(app, "peekPill")
        flip(app.switches["tunerToggle-peekGrade"].firstMatch, to: "1")
        XCTAssertEqual(app.switches["tunerToggle-peekGrade"].firstMatch.value as? String, "1", "the peek grade is on")
        open(app, "searchPill")
        XCTAssertEqual(app.switches["tunerToggle-searchGrade"].firstMatch.value as? String, "0", "the search grade is not")
        // Search: off at rest, shimmer while answering.
        app.segmentedControls["tunerRimRest-search"].buttons["Off"].tap()
        app.segmentedControls["tunerRimActive-search"].buttons["Slow shimmer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["tunerSlider-searchRimActiveBrightness"].waitForExistence(timeout: 3),
                      "the shimmer's peak")
        open(app, "askPill")
        let match = app.switches["tunerToggle-askMatchesSearch"].firstMatch
        XCTAssertEqual(match.value as? String, "1", "Ask matches Search by default")
        XCTAssertFalse(app.segmentedControls["tunerRimRest-ask"].exists, "while matching, Ask has no controls of its own")
        flip(match, to: "0")
        XCTAssertTrue(app.segmentedControls["tunerRimRest-ask"].waitForExistence(timeout: 3), "let go, Ask has its own")
        XCTAssertTrue(app.segmentedControls["tunerRimRest-ask"].buttons["Off"].isSelected, "and starts from Search's values")
        XCTAssertTrue(app.segmentedControls["tunerRimActive-ask"].buttons["Slow shimmer"].isSelected)
        shot(app, "sheet-ask-own")
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
