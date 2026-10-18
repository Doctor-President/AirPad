import XCTest

/// live-26 (4) — the App Store look check: the same views, the same synthetic content (the Sample Library a fresh install
/// seeds), shot from the App Store configuration and from the TestFlight one (whose tuner starts at T's 2026-10-18 values),
/// for a pixel diff per view. Release builds have no DEBUG hooks, so this drives the real chrome: the view switcher, the
/// search pill. Appearance is set by the caller (`simctl ui appearance`); first-run callouts are marked shown beforehand.
final class AppStoreLookStills: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
    private func switchTo(_ app: XCUIApplication, _ label: String) {
        let view = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View:'")).firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 30), "the view switcher")
        view.tap()
        let item = app.buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(label) item")
        item.tap()
    }

    func testShootTheSameViews() {
        let app = XCUIApplication()
        app.launch()
        sleep(8)
        // A fresh install opens on Recents (empty); Back → the Dashboard → the Sample Library's "Library".
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 10) { back.tap(); sleep(3) }
        shot(app, "dashboard")
        let library = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Library,'")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15), "the Sample Library's Library")
        library.tap(); sleep(6)
        switchTo(app, "Card"); sleep(5); shot(app, "card")
        switchTo(app, "List"); sleep(4); shot(app, "list")
        switchTo(app, "Map"); sleep(8); shot(app, "map")
        let pill = app.textFields["Search"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.swipeUp(velocity: .slow)
        sleep(3); shot(app, "librarian")
    }
}
