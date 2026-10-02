import XCTest

/// Brief CE — the Quick Capture CONTROL (Control Center / Lock Screen) must open AirPad straight into
/// Quick Capture, not Recents. Driven through the REAL system UI: SpringBoard → Control Center → tap the
/// "Quick Capture" control → assert the app foregrounds showing the Quick Capture note editor.
///
/// PRECONDITION (one-time, by T): the "Quick Capture" control must be ADDED to Control Center — XCUITest
/// can't add it. If absent, the test fails at "control present" (a setup failure, not a routing failure).
///
/// This test CREATES NOTHING (it asserts the surface appears, never types/Done), so it can't write to the
/// real Library. Where the app IS launched by the harness (warm setup) it uses the isolated
/// `-UITestLibrary`; a cold control-launch is a system launch (no args) but, being read-only here, is safe.
final class CEControlRouting: XCTestCase {

    private let airpadBundleID = "com.doctorpresident.airpad"
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var airpad: XCUIApplication { XCUIApplication(bundleIdentifier: airpadBundleID) }

    override func setUp() { continueAfterFailure = false }

    /// Open Control Center: swipe down from the top-RIGHT (notched iPhone).
    private func openControlCenter() {
        let sb = springboard
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
          .press(forDuration: 0.1, thenDragTo: sb.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)))
        // Control Center is up when its controls are present; give it a beat.
        _ = sb.otherElements["ControlCenterView"].waitForExistence(timeout: 3)
    }

    /// Find the Quick Capture control in Control Center. The label wraps to two lines ("Quick\nCapture"),
    /// so match the words independently, across every element type Control Center controls use.
    private func quickCaptureControl() -> XCUIElement {
        let sb = springboard
        let pred = NSPredicate(format: "label CONTAINS[c] 'Quick' AND label CONTAINS[c] 'Capture'")
        for q in [sb.buttons, sb.cells, sb.switches, sb.otherElements, sb.staticTexts] {
            let e = q.matching(pred).firstMatch
            if e.waitForExistence(timeout: 2) { return e }
        }
        return sb.descendants(matching: .any).matching(pred).firstMatch
    }

    private func assertLandedInQuickCapture(_ ctx: String) {
        // The Quick Capture surface is identified by the note editor (DEBUG a11y id, shared by capture).
        let editor = airpad.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15),
                      "\(ctx): the Control must open AirPad into QUICK CAPTURE (noteEditor), not Recents")
        let shot = XCTAttachment(screenshot: airpad.screenshot())
        shot.name = "CE-\(ctx)"; shot.lifetime = .keepAlways; add(shot)
    }

    // COLD: app not running → tap the Control → Quick Capture.
    func testControlCenter_cold_opensQuikCapture() {
        airpad.terminate()                       // cold
        openControlCenter()
        let control = quickCaptureControl()
        XCTAssertTrue(control.exists, "the 'Quick Capture' control must be present in Control Center (add it once)")
        control.tap()
        assertLandedInQuickCapture("cold")
    }

    // WARM: app running (backgrounded on Library) → tap the Control → Quick Capture (not Recents).
    func testControlCenter_warmOnLibrary_opensQuikCapture() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary"]  // isolated library for the warm instance
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCUIDevice.shared.press(.home)            // background it on the Library
        openControlCenter()
        let control = quickCaptureControl()
        XCTAssertTrue(control.exists, "the 'Quick Capture' control must be present in Control Center (add it once)")
        control.tap()
        assertLandedInQuickCapture("warm")
    }
}
