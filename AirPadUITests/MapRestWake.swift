import XCTest

/// Map in-place fix R1 — the paused Map must wake for real input (Sample scratch library, Simulator).
/// 1. at rest → swipe → the Map moved (and paused again);  2. at rest → Settings → Appearance → Map look Glass → back on
/// the Map, the orbs wear Glass. Stills go to $MAPREST_OUT; the app's `-MapRestLog` console names each wake.
final class MapRestWake: XCTestCase {
    private var out: String { ProcessInfo.processInfo.environment["MAPREST_OUT"] ?? NSTemporaryDirectory() }

    private func shot(_ app: XCUIApplication, _ name: String) throws {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        try s.pngRepresentation.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
    }

    func testWakeOnSwipeAndLookChange() throws {
        let callouts = ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode",
                        "librarian.model", "entry.intro", "capture.title"].flatMap { ["-com.airpad.callouts.\($0)", "YES"] }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-NoMapDebugHUD", "-OpenMap",
                               "-ProUnlocked", "YES", "-MapRestLog", "-MapNoHalo", "-appearance.override", "dark",
                               "-mapLook.v1", "flat"] + callouts
        app.launch()
        let menu = app.buttons["chrome.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 60), "the Map's menu")
        sleep(8)                                   // settled, then paused
        try shot(app, "1-rest")

        // 1. Swipe on the Map's ground (middle of the screen) from rest.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(4)                                   // coast, settle, pause again
        try shot(app, "2-after-swipe")

        // 2. Change the Map look in Settings → Appearance while the Map is at rest underneath.
        menu.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings")
        settings.tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Appearance'")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 8), "Settings → Appearance")
        appearance.tap()
        let glass = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'mapLook-' AND identifier ENDSWITH '-glass'")).firstMatch
        for _ in 0..<8 where !(glass.exists && glass.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        XCTAssertTrue(glass.waitForExistence(timeout: 10), "Glass in the Map look picker")
        glass.tap()
        sleep(2)
        try shot(app, "3-picked-glass")
        for _ in 0..<3 where !menu.isHittable { app.swipeDown(velocity: .fast); sleep(2) }
        sleep(4)
        try shot(app, "4-map-glass")
    }
}
