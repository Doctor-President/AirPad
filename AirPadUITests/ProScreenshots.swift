import XCTest
import StoreKitTest

/// pro-build — the App Review screenshots for the in-app purchases: the Pro sheet (opened by tapping a locked look in
/// Settings → Appearance → Map look) and Settings → Support AirPad, with the products from StoreKit/AirPadPro.storekit.
/// Writes PNGs to $PRO_SHOTS (xcodebuild: TEST_RUNNER_PRO_SHOTS=<dir>). Appearance is set by the caller.
final class ProScreenshots: XCTestCase {
    private var out: String { ProcessInfo.processInfo.environment["PRO_SHOTS"] ?? NSTemporaryDirectory() }
    private func save(_ app: XCUIApplication, _ name: String) throws {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", screen, "-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly",
                               "-pro.unlocked.v1", "NO", "-mapLook.v1", "flat"]
        app.launch()
        return app
    }

    func testProSheetAndTipJar() throws {
        let session = try SKTestSession(configurationFileNamed: "AirPadPro")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true

        let app = launch("settings-appearance")
        let locked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mapLook-' AND identifier ENDSWITH '-glass'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 30), "a locked look in the Map look picker")
        try save(app, "settings-map-look")
        locked.tap()
        let unlock = app.buttons["proUnlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "the Pro sheet")
        let priced = NSPredicate(format: "label CONTAINS '$'")
        expectation(for: priced, evaluatedWith: unlock); waitForExpectations(timeout: 15)
        sleep(1)
        try save(app, "pro-sheet")
        app.terminate()

        let tips = launch("settings-support")
        let small = tips.buttons["tip-small"]
        XCTAssertTrue(small.waitForExistence(timeout: 30), "the tip jar")
        expectation(for: priced, evaluatedWith: small); waitForExpectations(timeout: 15)
        sleep(1)
        try save(tips, "support-airpad-tips")
    }
}
