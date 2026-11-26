import XCTest

/// ws-1.0-widget — the Pinned Entry Home Screen widget, proven with real events through the real system UI:
/// SpringBoard → add the widget → Edit Widget → pick an entry → read it → edit the entry in AirPad → see the widget
/// change → tap → land on the entry → delete the entry → the widget says so. Simulator only; the app runs on the
/// isolated `-UITestLibrary` (the Sample Library seeds into it), never a real library.
final class PinnedEntryWidgetUI: XCTestCase {

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() { continueAfterFailure = false }

    func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let s = XCTAttachment(screenshot: (app ?? springboard).screenshot())
        s.name = name; s.lifetime = .keepAlways; add(s)
    }

    func dump(_ name: String, _ app: XCUIApplication? = nil) {
        let a = XCTAttachment(string: (app ?? springboard).debugDescription)
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func launchAirPad(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    /// The Home Screen widgets AirPad has placed (an icon whose value is "Widget").
    func airpadWidgets() -> XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "identifier == 'AirPad' AND value == 'Widget'"))
    }

    /// Long-press empty Home Screen → Edit → Add Widget → AirPad → (page) → Add Widget → Done.
    func addWidget(medium: Bool) {
        let sb = springboard
        XCUIDevice.shared.press(.home); sleep(1)
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.5); sleep(1)
        XCTAssertTrue(sb.buttons["Edit"].waitForExistence(timeout: 5)); sb.buttons["Edit"].tap()
        XCTAssertTrue(sb.buttons["Add Widget"].waitForExistence(timeout: 5)); sb.buttons["Add Widget"].tap()
        // A fresh install can take a moment to reach the gallery: search for it, and reopen the gallery once if needed.
        var cell = sb.cells["AirPad"]
        if !cell.waitForExistence(timeout: 8) {
            if sb.buttons["close"].exists { sb.buttons["close"].tap(); sleep(5) }
            if sb.buttons["Edit"].waitForExistence(timeout: 3) { sb.buttons["Edit"].tap() }
            if sb.buttons["Add Widget"].waitForExistence(timeout: 5) { sb.buttons["Add Widget"].tap() }
            let search = sb.searchFields["Search Widgets"]
            if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("AirPad") }
            cell = sb.cells["AirPad"]
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "AirPad in the widget gallery"); cell.tap(); sleep(1)
        if medium {
            let preview = sb.buttons.matching(NSPredicate(format: "label == 'AirPad, Pinned Entry'")).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            preview.swipeLeft(); sleep(1)
        }
        let add = sb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap(); sleep(2)
        if sb.buttons["Done"].exists { sb.buttons["Done"].tap(); sleep(1) }
    }

    /// Touch and hold a widget → Edit Widget → Entry → search → pick → close the editor.
    /// Page the Home Screen until this widget is on screen.
    func bringIntoView(_ widget: XCUIElement) {
        let width = springboard.frame.width
        for _ in 0..<4 where !widget.isHittable {
            if widget.frame.minX >= width { springboard.swipeLeft() } else { springboard.swipeRight() }
            sleep(1)
        }
    }

    /// The AirPad widget whose width says small (≈ 170 pt) or medium (≈ 345 pt).
    func widget(small: Bool) -> XCUIElement? {
        let q = airpadWidgets()
        for i in 0..<q.count {
            let e = q.element(boundBy: i)
            if (e.frame.width < 250) == small { return e }
        }
        return nil
    }

    func tapWidget(_ text: String) {
        XCTAssertTrue(waitForWidget(text), "a widget showing \(text)")   // pages to it
        widgetShowing(text).tap()
    }

    func pick(_ widget: XCUIElement, _ title: String) {
        let sb = springboard
        bringIntoView(widget)
        widget.press(forDuration: 1.5)
        let edit = sb.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap(); sleep(2)
        shot("config-\(title)")
        // The configuration card's one row: tap its value ("Choose" or the current entry).
        let row = sb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Choose' OR label CONTAINS[c] 'Entry'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap(); sleep(2)
        let search = sb.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title); sleep(2)
        shot("picker-\(title)")
        let hit = sb.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "the picker's search finds \(title)"); hit.tap(); sleep(2)
        shot("picked-\(title)")
        // Close the configuration card: tap outside it (below), else Home.
        let card = sb.otherElements["Pinned Entry, AirPad"]
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap(); sleep(2)
        if card.exists { XCUIDevice.shared.press(.home); sleep(2) }
        XCTAssertFalse(card.exists, "the configuration card closed")
    }

    func widgetShowing(_ text: String) -> XCUIElement {
        airpadWidgets().containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A widget's content is only in the accessibility tree while its Home Screen page is on screen: look on this
    /// page, then the pages either side, until the timeout.
    func waitForWidget(_ text: String, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var step = 0
        while Date() < deadline {
            if widgetShowing(text).exists { return true }
            sleep(1)
            if widgetShowing(text).exists { return true }
            // left, right, right, left, …: visits the neighbours and comes back
            if step % 4 == 0 || step % 4 == 3 { springboard.swipeLeft() } else { springboard.swipeRight() }
            step += 1
            sleep(1)
        }
        shot("missing-\(text)")
        return false
    }

    func appShows(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// The whole flow, real events end to end. Expects an ERASED Simulator (the default library seeds the Sample
    /// Library on first launch; the Home Screen starts without AirPad widgets).
    func testPinnedEntryFlow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(15)   // the Sample Library seeds; the copy is written

        // 1. Add a small and a medium widget. Nothing chosen yet → the honest instruction.
        addWidget(medium: false)
        addWidget(medium: true)
        XCTAssertEqual(airpadWidgets().count, 2)
        XCTAssertTrue(waitForWidget("Pin an entry"), "not chosen yet: the widget says how")
        shot("1-added-not-chosen")

        // 2. Pick: small = a pure checklist, medium = text then a checklist.
        guard let small = widget(small: true) else { return XCTFail("no small widget") }
        pick(small, "nine shots")
        guard let medium = widget(small: false) else { return XCTFail("no medium widget") }
        pick(medium, "Sid's list")
        XCTAssertTrue(waitForWidget("nine shots"))
        XCTAssertTrue(waitForWidget("Sid's list"))
        XCTAssertTrue(waitForWidget("door, left open"), "the checklist's first row reads")
        shot("2-picked")
        dump("2-picked")

        // 3. Tap (warm: AirPad is running) → lands on that entry.
        tapWidget("Sid's list")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(appShows(app, "Sid's list"), "warm tap opens the entry")
        let editor = app.textViews["noteEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the entry's note is on screen")
        shot("3-warm-tap", app)

        // 4. Edit the entry in the app: add a word at the very start of the note, leave the entry.
        sleep(1)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.04)).tap()   // the first line
        if !app.keyboards.element.waitForExistence(timeout: 6) { editor.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "the note is focused")
        sleep(1)
        editor.typeKey(.upArrow, modifierFlags: .command)
        editor.typeText("Edited ")
        sleep(1)
        shot("4-editing", app)
        // A note's typed text is saved when editing ends (1.0 behaviour): leave the entry as a user does, by Back.
        let back = app.buttons["Back"].firstMatch
        if back.exists && back.isHittable { back.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.09)).tap() }
        sleep(3)
        shot("4-left-entry", app)
        let left = Date()
        XCUIDevice.shared.press(.home)
        let reached = waitForWidget("Edited")
        let a = XCTAttachment(string: String(format: "edit → widget: %.1f s after leaving the entry (polled ~1 s)", Date().timeIntervalSince(left)))
        a.name = "freshness"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(reached, "an edit made in the app reaches the widget without the user doing anything")
        shot("4-widget-after-edit")

        // 5. Cold: AirPad not running → tap the small widget → AirPad launches onto that entry.
        app.terminate()
        tapWidget("nine shots")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(appShows(app, "nine shots", timeout: 30), "cold tap opens the entry")
        shot("5-cold-tap", app)

        // 6. Delete the medium widget's entry in the app → the widget says it is gone.
        XCUIDevice.shared.press(.home); sleep(1)
        tapWidget("Sid's list")
        XCTAssertTrue(appShows(app, "Sid's list"))
        let menu = app.buttons["entryMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap(); sleep(1)
        let del = app.buttons["Delete"].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5)); del.tap(); sleep(1)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).element(boundBy: 0)
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        sleep(2)
        shot("6-deleted", app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForWidget("Entry not found"), "the deleted entry's widget says so")
        XCTAssertTrue(waitForWidget("nine shots"), "the other widget is untouched")
        shot("6-widget-after-delete")
    }
}
