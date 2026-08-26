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

/// ws-attributes-grid P2 — OBSERVE the arrange-mode gesture routing (defect 1). The
/// `-SPINEGATE arrange` gate renders real tiles with `isArranging:true`; the `arrHUD`
/// surfaces `d:` (grabber-drag callbacks) / `c:` (tile-tap cycles) / `r:` (reorders).
/// Drives a REAL drag from a tile's bottom-right grabber and a REAL tap on a tile centre,
/// and reads the HUD deltas. Observe, don't infer.
final class ArrangeGestureRepro: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SPINEGATE", "arrange"]
        app.launch()
        Thread.sleep(forTimeInterval: 2.5)
        return app
    }

    private func attach(_ msg: String) {
        let a = XCTAttachment(string: msg)
        a.lifetime = .keepAlways
        add(a)
    }

    private func win(_ app: XCUIApplication) -> XCUIElement { app.windows.firstMatch }
    private func pt(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        win(app).coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    private func tile(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "attrTile-\(id)").firstMatch
    }

    /// FIXED behaviour: a drag starting WITHIN the 44pt corner zone (but OFF the 26pt
    /// visual glyph) resizes → `d:` increments. And a plain tap on the tile BODY does
    /// NOTHING (no cycle) → `c:` stays 0.
    func testGrabberDragResizesAndBodyTapInert() {
        let app = launch()
        let hud = app.staticTexts["arrHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "arrHUD missing")
        let t = tile(app, "m-type")
        XCTAssertTrue(t.waitForExistence(timeout: 4), "tile not found")
        let f = t.frame

        // Drag from 18pt in from the corner — inside the 44pt hit zone, OUTSIDE the 26pt glyph.
        pt(app, f.maxX - 18, f.maxY - 18).press(forDuration: 0.12,
            thenDragTo: pt(app, f.maxX + 120, f.maxY + 120))
        Thread.sleep(forTimeInterval: 0.6)
        let afterDrag = hud.label

        // Tap the tile BODY centre — must be inert now.
        pt(app, f.midX, f.midY).tap()
        Thread.sleep(forTimeInterval: 0.4)
        let afterTap = hud.label

        let msg = "GRABBER-44 — afterZoneDrag=[\(afterDrag)] afterBodyTap=[\(afterTap)]"
        attach(msg); print("REPRO_FIX \(msg)")
        XCTAssertFalse(afterDrag.contains("d:0"), "grabber drag from the 44pt zone did NOT resize — \(msg)")
        XCTAssertTrue(afterTap.contains("c:0"), "tile-body tap cycled (should be inert) — \(msg)")
    }

    /// FIXED behaviour: a LONG-PRESS on the tile body then a drag onto another tile
    /// REORDERS → `r:` increments and the two tiles swap screen positions.
    func testBodyLongPressReorders() {
        let app = launch()
        let hud = app.staticTexts["arrHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "arrHUD missing")
        let a = tile(app, "m-type")     // slot 0 (top-left)
        let target = tile(app, "m-atk") // a lower slot
        XCTAssertTrue(a.waitForExistence(timeout: 4) && target.waitForExistence(timeout: 4), "tiles missing")
        let aY0 = a.frame.midY
        let fa = a.frame, ft = target.frame

        // Long-press tile A body, then drag onto the target tile.
        pt(app, fa.midX, fa.midY).press(forDuration: 0.7, thenDragTo: pt(app, ft.midX, ft.midY))
        Thread.sleep(forTimeInterval: 0.9)
        let afterReorder = hud.label
        let aY1 = a.frame.midY

        let msg = "REORDER — hud=[\(afterReorder)] m-type.midY \(Int(aY0))->\(Int(aY1))"
        attach(msg); print("REPRO_REORDER2 \(msg)")
        XCTAssertFalse(afterReorder.contains("r:0"), "long-press drag did NOT reorder — \(msg)")
        XCTAssertNotEqual(Int(aY0), Int(aY1), "m-type did not visually move after reorder — \(msg)")
    }
}
