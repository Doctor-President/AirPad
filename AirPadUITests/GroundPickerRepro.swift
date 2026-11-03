import XCTest

/// 1.1-B fix-up (B) — T couldn't pick pure white for a custom background: it kept snapping to a grey. Drives the real
/// system colour picker (Background → Colour) toward white three ways (Grid tap, Spectrum drag, RGB sliders) on the
/// Sample Library, Pro on, dark appearance; the app logs every pick and what was stored (`[GROUNDPICK]`). Simulator.
final class GroundPickerRepro: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The dark side starts as a custom #111115 (no gradient), the same every run.
    static let start = "eyJkYXJrIjp7ImN1c3RvbSI6dHJ1ZSwiY29sb3IiOiIxMTExMTUiLCJncmFkaWVudCI6ZmFsc2UsImNvbG9yMiI6IjFEMUQyNiIsImFuZ2xlIjo5MCwiZG90IjoiRkZGRkZGIiwiZG90T3BhY2l0eSI6MC44MDl9LCJsaWdodCI6eyJjdXN0b20iOmZhbHNlLCJjb2xvciI6IkZGRUVFRCIsImdyYWRpZW50IjpmYWxzZSwiY29sb3IyIjoiRkZGOEVGIiwiYW5nbGUiOjkwLCJkb3QiOiIzQjM2MkYiLCJkb3RPcGFjaXR5IjowLjgwNX19"

    private func openPicker(_ mode: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MapGroundDebug", Self.start] + extra + ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-EmbedCPUOnly", "-OpenMap",
                               "-NoMapDebugHUD", "-ProUnlocked", "YES", "-OpenAppearancePanel", "-appearance.override", "dark"]
        app.launch()
        let tab = app.buttons["Background"].firstMatch   // 1.1-B fix-up (E): the sheet's Background tab
        if tab.waitForExistence(timeout: 20) { tab.tap() }
        let well = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Colour'")).firstMatch
        if !well.waitForExistence(timeout: 20) { shot(app, "no-colour-row") }
        if !well.isHittable { app.swipeUp() }
        well.tap()
        let seg = app.buttons[mode].firstMatch
        if seg.waitForExistence(timeout: 5) { seg.tap() } else { shot(app, "no-\(mode)") }
        Thread.sleep(forTimeInterval: 1)
        shot(app, "\(mode)-open")
        return app
    }

    func testGridWhite() {
        let app = openPicker("Grid")
        // the grid's top-left cell is white
        let grid = app.otherElements.matching(NSPredicate(format: "label CONTAINS[c] 'grid' OR identifier CONTAINS[c] 'grid'")).firstMatch
        let frame = grid.exists ? grid.frame : app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 8, dy: frame.minY + 8)).tap()
        Thread.sleep(forTimeInterval: 1); shot(app, "grid-after")
    }

    func testSpectrumDragToWhite() {
        let app = openPicker("Spectrum")
        let w = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: w.width * 0.5, dy: w.height * 0.72))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: w.width * 0.5, dy: w.height * 0.45))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: 200, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1); shot(app, "spectrum-after")
    }

    /// From #111115: Red, then Green, then Blue set to 100 % on the picker's sliders (through accessibility: XCUITest
    /// drags don't move them). White must be the result. Red alone (#FF1115) is a mid-tone, so the limit moves it.
    func testSlidersRGBToWhite() { rgbToWhite(old: false) }
    /// The same with the 1.1-B write-back (DEBUG `-GroundPickReadback YES`): the picker adopts the moved colour.
    func testSlidersRGBToWhiteOldReadback() { rgbToWhite(old: true) }

    private func rgbToWhite(old: Bool) {
        let app = openPicker("Sliders", extra: old ? ["-GroundPickReadback", "YES"] : [])
        let all = app.sliders.allElementsBoundByIndex
        let rgb = ["Red", "Green", "Blue"].compactMap { name in all.first { $0.label.localizedCaseInsensitiveContains(name) } }
        XCTAssertEqual(rgb.count, 3, "the picker's Red / Green / Blue sliders")
        NSLog("[GROUNDPICK-UI] %@ start: %@", old ? "OLD" : "NEW", rgb.map { ($0.value as? String) ?? "?" }.joined(separator: " "))
        for s in rgb {
            s.adjust(toNormalizedSliderPosition: 1.0)
            Thread.sleep(forTimeInterval: 0.8)
            NSLog("[GROUNDPICK-UI] %@ after %@: %@", old ? "OLD" : "NEW", s.label, rgb.map { ($0.value as? String) ?? "?" }.joined(separator: " "))
        }
        shot(app, "rgb-after-\(old ? "old" : "new")")
        let values = rgb.map { ($0.value as? String) ?? "?" }
        if old { XCTAssertNotEqual(values, ["100%", "100%", "100%"], "the old write-back keeps white out of reach") }
        else { XCTAssertEqual(values, ["100%", "100%", "100%"], "the sliders reach white") }
    }
}
