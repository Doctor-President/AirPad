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

    /// 1.0r fix-up F2 — the Pro sheet's review screenshot on the BENCH build (Release + `-D PANBENCH`: the shipping UI, no
    /// DEBUG chrome or `-Screen` shortcut), reached by taps: the Map's ≡ menu → Settings → Appearance → a locked look.
    /// Full-screen grab (`XCUIScreen.main`; the caller overrides the status bar), saved as `pro-sheet-bench.png`.
    func testProSheetBench() throws {
        let session = try SKTestSession(configurationFileNamed: "AirPadPro")
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true

        let callouts = ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode",
                        "librarian.model", "entry.intro", "capture.title"].flatMap { ["-com.airpad.callouts.\($0)", "YES"] }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-NoMapDebugHUD", "-OpenMap",
                               "-pro.unlocked.v1", "NO", "-mapLook.v1", "flat"] + callouts
        app.launch()
        let menu = app.buttons["chrome.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 60), "the Map's menu")
        sleep(4)
        menu.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings")
        settings.tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 8), "Settings → Appearance")
        appearance.tap()
        let locked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mapLook-' AND identifier ENDSWITH '-glass'")).firstMatch
        for _ in 0..<8 where !(locked.exists && locked.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        XCTAssertTrue(locked.waitForExistence(timeout: 10), "a locked look in the Map look picker")
        locked.tap()
        let unlock = app.buttons["proUnlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "the Pro sheet")
        expectation(for: NSPredicate(format: "label CONTAINS '$'"), evaluatedWith: unlock); waitForExpectations(timeout: 20)
        sleep(2)
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "pro-sheet-bench"; a.lifetime = .keepAlways; add(a)
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("pro-sheet-bench.png"))
    }
}
