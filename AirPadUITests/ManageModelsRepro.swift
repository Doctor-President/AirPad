import XCTest

/// Brief AM3 — the model-chip "Manage models" deep link must land on the paired **Mac
/// models screen** ("Your Mac"), NOT the Settings ROOT. Build M's AL2 fix was verified
/// only by a harness that JUMPS straight to the destination, so the real picker → onDismiss
/// → Settings presentation was never exercised; T reported it still lands on root.
///
/// This drives the REAL flow's mechanism via `-Screen managemodels` (a fixture that uses the
/// real `ModelPickerSheet` + real `SettingsView` with LibrarianSurface's exact two-sheet
/// `onDismiss` sequencing) + `-FakeHostPairing` (paired). It auto-opens the picker; the test
/// taps "Manage models" and asserts the Mac screen is visible. Observe, don't infer.
final class ManageModelsRepro: XCTestCase {

    func testManageModelsLandsOnMacScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "managemodels", "-FakeHostPairing", "YES"]
        app.launch()

        // The picker auto-opens; tap its "Manage models" row.
        let manage = app.buttons["Manage models"]
        XCTAssertTrue(manage.waitForExistence(timeout: 8), "‘Manage models’ row never appeared (picker didn’t open?)")
        manage.tap()

        // After the picker dismisses, Settings must present AND land on the Mac screen.
        // The Mac screen shows the "Your Mac" navigation title + an "Unpair this Mac" button;
        // the Settings ROOT shows the top-level rows (e.g. a "Web search" row) and NO "Your Mac".
        let macTitle = app.staticTexts["Your Mac"]
        let unpair = app.buttons["Unpair this Mac"]
        let onMacScreen = macTitle.waitForExistence(timeout: 8) || unpair.waitForExistence(timeout: 2)

        // Diagnostic: what DID show (root leaks a "Web search" row / the "Models" header)?
        let rootLeak = app.buttons["Web search"].exists || app.staticTexts["Web search"].exists
        let msg = "MANAGE-MODELS — onMacScreen=\(onMacScreen) rootLeak(WebSearchRowVisible)=\(rootLeak)"
        let a = XCTAttachment(string: msg); a.lifetime = .keepAlways; add(a)
        print("REPRO_MANAGE \(msg)")

        XCTAssertTrue(onMacScreen, "Manage models did NOT land on the Mac screen — \(msg)")
    }
}
