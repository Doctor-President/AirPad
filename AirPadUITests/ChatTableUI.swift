import XCTest

/// live-26 (3f) — a synthetic presidents-shaped 5 × 46 answer table (`-RenderTableAnswer 5x46`) on the real Librarian:
/// it's a grid that scrolls sideways with the first column staying put, a tap opens it full screen, the full screen turns
/// to landscape, and it offers Copy as Markdown / CSV. Stills attached (inline, scrolled, full screen, landscape).
final class ChatTableUI: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func testTableIsAGridThatScrollsAndOpensFullScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-EmbedCPUOnly", "-OpenCardView",
                               "-gridColumnCount", "2", "-RenderTableAnswer", "5x46"]
        app.launch()
        let table = app.descendants(matching: .any)["chatTable"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 30), "the answer's table renders as the grid")
        sleep(1); shot(app, "inline")
        // live-27 (4c) — the grid uses the full answer width (to the transcript's 16 pt margin) and shows an expand
        // control on its corner.
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(table.frame.maxX, window.maxX - 24, "the grid reaches the answer's right edge")
        XCTAssertTrue(app.buttons["chatTableExpand"].firstMatch.exists, "an expand control on the table's corner")
        // The first column stays put while the grid scrolls sideways: the "1" cell keeps its x, "Party" moves.
        let first = app.staticTexts["Ada Marlow"].firstMatch
        let firstNum = table.staticTexts.matching(NSPredicate(format: "label == '#'")).firstMatch
        XCTAssertTrue(first.exists || firstNum.exists)
        let headerX0 = firstNum.exists ? firstNum.frame.minX : 0
        table.swipeLeft(velocity: .slow)
        sleep(1); shot(app, "scrolled-sideways")
        if firstNum.exists { XCTAssertEqual(firstNum.frame.minX, headerX0, accuracy: 2, "the first column stays put") }
        // The expand control → full screen, then landscape.
        app.buttons["chatTableExpand"].firstMatch.tap()
        let copy = app.buttons["chatTableCopy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "a tap opens the table full screen")
        sleep(1); shot(app, "full-screen")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2); shot(app, "full-screen-landscape")
        // The table turned: its "President" header now runs down the portrait screen (taller than wide in portrait
        // coordinates), i.e. across the landscape one.
        let president = app.staticTexts["President"].firstMatch
        XCTAssertTrue(president.exists)
        XCTAssertGreaterThan(president.frame.height, president.frame.width, "the table is laid out sideways in landscape")
        copy.tap()
        let csv = app.buttons["Copy as CSV"].firstMatch
        XCTAssertTrue(csv.waitForExistence(timeout: 4) && app.buttons["Copy as Markdown"].exists, "Copy as Markdown / CSV offered")
        csv.tap()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Copied CSV'")).firstMatch.waitForExistence(timeout: 4))
        app.buttons["Done"].firstMatch.tap()
        sleep(2)
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "back to portrait after")
    }
}
