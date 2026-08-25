import XCTest

/// ws-entry-containers (4b) — verifies T's RULED three-single-purpose-target
/// gesture split on container entries (2026-08-24): name tap → expand/rename,
/// ⠿ grip LONG-PRESS ONLY → lift/drag, "..." TAP ONLY → options menu. Drives
/// REAL synthesized gestures on the `-SPINEGATE notes` fixture and reads a DEBUG
/// lift counter (`att:N`) surfaced in a `-REORDERHUD`-gated HUD. Observe, don't
/// infer. `notes` gate layout: card0 EXPANDED note, card1 COLLAPSED "Ingredients"
/// (~dy 0.32), card2 EXPANDED link. Trailing slots: "..." ~dx 0.79, grip ~dx 0.88.
final class HoldDragRepro: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SPINEGATE", "notes", "-REORDERHUD", "YES"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        return app
    }

    private func attach(_ msg: String) {
        let a = XCTAttachment(string: msg)
        a.lifetime = .keepAlways
        add(a)
    }

    /// The grip is the ONLY drag entry: grip long-press lifts; non-grip long-press
    /// (gutter / editor / name) never lifts. No duration-disambiguation elsewhere.
    func testGripIsTheOnlyDragEntry() {
        let app = launch()
        let hud = app.staticTexts["reorderHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "HUD missing")

        func hold(_ dx: CGFloat, _ dy: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).press(forDuration: 1.2)
            Thread.sleep(forTimeInterval: 0.7)
        }

        let start = hud.label
        hold(0.88, 0.32)            // collapsed row GRIP slot → must lift
        let afterGrip = hud.label
        hold(0.11, 0.22)            // expanded gutter (fill)  → must NOT lift
        hold(0.50, 0.22)            // expanded editor         → must NOT lift
        hold(0.40, 0.32)            // collapsed row NAME       → must NOT lift
        let afterNonGrip = hud.label

        let msg = "GRIP-ONLY — start=[\(start)] afterGrip=[\(afterGrip)] afterNonGrip=[\(afterNonGrip)]"
        attach(msg); print("REPRO_GRIP \(msg)")

        XCTAssertFalse(afterGrip.contains("att:0"), "grip long-press did NOT lift — \(msg)")
        XCTAssertEqual(afterNonGrip, afterGrip, "a NON-grip long-press lifted (should be single-purpose) — \(msg)")
    }

    /// Grip TAP → nothing (no lift, no menu). "..." TAP → options menu opens.
    func testGripTapInertAndOptionsMenuOpens() {
        let app = launch()
        let hud = app.staticTexts["reorderHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 6))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.32)).tap()   // grip TAP
        Thread.sleep(forTimeInterval: 0.6)
        let attAfterGripTap = hud.label
        let menuAfterGripTap = app.buttons["Delete"].exists

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.79, dy: 0.32)).tap()   // "..." TAP
        let menuAfterOptions = app.buttons["Delete"].waitForExistence(timeout: 2)

        let msg = "TAP — attAfterGripTap=[\(attAfterGripTap)] menuAfterGripTap=\(menuAfterGripTap) menuAfterOptionsTap=\(menuAfterOptions)"
        attach(msg); print("REPRO_TAP \(msg)")

        XCTAssertTrue(attAfterGripTap.contains("att:0"), "grip TAP lifted (should be inert) — \(msg)")
        XCTAssertFalse(menuAfterGripTap, "grip TAP opened a menu (grip must have no menu) — \(msg)")
        XCTAssertTrue(menuAfterOptions, "\"...\" TAP did not open the options menu — \(msg)")
    }

    /// "..." holds the SAME x-position across the collapse/expand transition
    /// (grip slot reserved in both states so it never reflows).
    func testOptionsFixedXAcrossFold() {
        let app = launch()
        _ = app.staticTexts["reorderHUD"].waitForExistence(timeout: 6)
        let opts = app.descendants(matching: .any).matching(identifier: "entryOptions")
        guard opts.count >= 2 else {
            XCTFail("expected ≥2 entryOptions buttons (expanded + collapsed), got \(opts.count)")
            return
        }
        let x0 = opts.element(boundBy: 0).frame.midX
        let x1 = opts.element(boundBy: 1).frame.midX
        let msg = "OPTIONS-X — a.midX=\(x0) b.midX=\(x1) delta=\(abs(x0 - x1)) count=\(opts.count)"
        attach(msg); print("REPRO_X \(msg)")
        XCTAssertLessThan(abs(x0 - x1), 1.5, "\"...\" reflowed across fold — \(msg)")
    }
}
