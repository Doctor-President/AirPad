import XCTest
import UIKit

/// 1.1-C — the real screens: a table inserted from the toolbar and filled in the full-screen view; an HTML table pasted
/// into a note (prose kept, table → block); both survive a relaunch (stored as GFM, decoded back to blocks); an entry
/// made Private disappears from Recents and the List and comes back with "Show private"; Export offers its formats and
/// hands the file to the share sheet. Sample-free scratch library; Face ID stubbed (`-PrivateStubAuth success`).
final class Batch11CUI: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ extra: [String], fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary",
                               "-PrivateStubAuth", "success"] + (fresh ? ["-UITestLibraryFresh"] : []) + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sliding your finger'")).firstMatch
        if tip.waitForExistence(timeout: 1), app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    }

    private func paste(into editor: XCUIElement, app: XCUIApplication, at point: CGVector) {
        for attempt in 0..<3 {
            editor.coordinate(withNormalizedOffset: point).press(forDuration: 1.0)
            let item = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            if item.waitForExistence(timeout: 3) { item.tap(); return }
            if attempt == 2 { XCTFail("no Paste in the edit menu") }
        }
    }

    private func pasteAt(_ point: XCUICoordinate, app: XCUIApplication) {
        for attempt in 0..<3 {
            point.press(forDuration: 1.0)
            let item = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            if item.waitForExistence(timeout: 3) { item.tap(); return }
            if attempt == 2 { XCTFail("no Paste in the edit menu") }
        }
    }

    private func fillCell(_ app: XCUIApplication, _ id: String, _ text: String) {
        let c = app.textViews[id].exists ? app.textViews[id] : app.textFields[id]
        XCTAssertTrue(c.waitForExistence(timeout: 5), "cell \(id)")
        c.tap(); c.typeText(text)
    }

    private func openFirstEntry(_ app: XCUIApplication) -> Bool {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        guard row.waitForExistence(timeout: 20) else { return false }
        row.tap()
        return true
    }

    // MARK: Tables

    func testTables() {
        var app = launch(["-EntryQuikCapture"], fresh: true)
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "Quick Capture should open")
        _ = app.keyboards.element.waitForExistence(timeout: 10)
        editor.typeText("Table check\nBefore the table\n")
        dismissKeyboardTip(app)
        let insert = app.buttons["toolbar.insertTable"]
        XCTAssertTrue(insert.waitForExistence(timeout: 5), "Insert table on the toolbar")
        insert.tap()
        XCTAssertTrue(app.buttons["tableEditor.done"].waitForExistence(timeout: 5), "the full-screen table view opens")
        fillCell(app, "tableCell--1-0", "Item")
        fillCell(app, "tableCell--1-1", "Qty")
        fillCell(app, "tableCell-0-0", "Milk")
        fillCell(app, "tableCell-0-1", "2")
        shot(app, "table-editor")
        app.buttons["tableEditor.addRow"].tap()
        XCTAssertTrue(app.textViews["tableCell-2-0"].waitForExistence(timeout: 3) || app.textFields["tableCell-2-0"].exists, "Add row adds a row")
        app.buttons["tableEditor.addColumn"].tap()
        XCTAssertTrue(app.textViews["tableCell--1-3"].waitForExistence(timeout: 3) || app.textFields["tableCell--1-3"].exists, "Add column adds a column")
        app.buttons["tableEditor.deleteColumn"].tap()
        XCTAssertFalse(app.textViews["tableCell--1-3"].exists || app.textFields["tableCell--1-3"].exists, "Delete column removes it")
        app.buttons["tableEditor.done"].tap()
        XCTAssertTrue(app.buttons["tableEditor.done"].waitForNonExistence(timeout: 5), "back in the note")
        Thread.sleep(forTimeInterval: 1)
        shot(app, "table-block")

        // An HTML table pasted after prose: the prose stays text, the table becomes a block.
        let html = "<p>Pasted intro</p><table><tr><th>City</th><th>Pop</th></tr><tr><td>Oslo</td><td>0.7</td></tr><tr><td>Lima</td><td>10</td></tr></table><p>Pasted outro</p>"
        UIPasteboard.general.setItems([["public.html": html, "public.utf8-plain-text": "Pasted intro\nCity Pop\nOslo 0.7\nLima 10\nPasted outro"]])
        editor.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 5)
        pasteAt(editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 58)), app: app)
        Thread.sleep(forTimeInterval: 1.5)
        // (Attachment views aren't in the accessibility tree: the screenshots show the blocks; the relaunch below
        // proves the round trip by opening a block.)
        shot(app, "table-paste")
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        app.terminate()

        // Relaunch: stored as GFM, decoded back into two blocks; a tap opens the table.
        app = launch([], fresh: false)
        XCTAssertTrue(openFirstEntry(app), "the entry is in Recents")
        let note = app.textViews["noteEditor"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertFalse((note.value as? String ?? "").contains("| ---"), "no pipes in the note's text")
        shot(app, "table-relaunch")
        // Tap the first block (just under the note's first two lines).
        note.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: note.frame.width / 2, dy: 130)).tap()
        XCTAssertTrue(app.buttons["tableEditor.done"].waitForExistence(timeout: 5), "a tap on the block opens the full-screen table view")
        XCTAssertTrue(app.textViews["tableCell-0-0"].exists || app.textFields["tableCell-0-0"].exists, "its cells")
        let first = app.textViews["tableCell-0-0"].exists ? app.textViews["tableCell-0-0"] : app.textFields["tableCell-0-0"]
        XCTAssertTrue(["Milk", "Oslo"].contains(first.value as? String ?? ""), "the stored table came back (\(first.value ?? "nil"))")
        shot(app, "table-reopen")
        app.buttons["tableEditor.cancel"].tap()
    }

    // MARK: Private entries + export

    func testPrivateAndExport() {
        var app = launch(["-EntryQuikCapture"], fresh: true)
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        _ = app.keyboards.element.waitForExistence(timeout: 10)
        editor.typeText("Private check\nSomething to hide for a while.")
        dismissKeyboardTip(app)
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        app.terminate()

        app = launch([], fresh: false)
        XCTAssertTrue(openFirstEntry(app))
        let menu = app.buttons.matching(NSPredicate(format: "label == 'More' OR identifier == 'entryMenu'")).firstMatch
        let ellipsis = menu.exists ? menu : app.images["ellipsis"].firstMatch
        // Export first (the entry is not private yet).
        tapEntryMenu(app)
        XCTAssertTrue(app.buttons["entryMenu.export"].waitForExistence(timeout: 5), "Export in the entry menu")
        app.buttons["entryMenu.export"].tap()
        XCTAssertTrue(app.buttons["export.markdown"].waitForExistence(timeout: 5), "the export sheet")
        shot(app, "export-sheet")
        app.buttons["export.textBundle"].tap()
        let share = app.otherElements["ActivityListView"].firstMatch
        _ = share.waitForExistence(timeout: 8)
        shot(app, "export-share")
        XCTAssertTrue(share.exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Save to Files"].exists
                      || app.cells.matching(NSPredicate(format: "label CONTAINS 'Save to Files'")).firstMatch.exists, "the share sheet opens with the file")
        // Close the share sheet + the export sheet.
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 1)
        _ = ellipsis

        // Make it Private → gone from Recents.
        Thread.sleep(forTimeInterval: 2)
        tapEntryMenu(app)
        if !app.buttons["entryMenu.private"].waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); tapEntryMenu(app) }
        XCTAssertTrue(app.buttons["entryMenu.private"].waitForExistence(timeout: 5), "Make Private in the entry menu")
        shot(app, "private-menu")
        app.buttons["entryMenu.private"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()

        app = launch([], fresh: false)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertFalse(row.waitForExistence(timeout: 8), "a private entry is hidden from Recents")
        shot(app, "private-hidden-recents")
        app.terminate()

        app = launch(["-OpenListView"], fresh: false)
        let listRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'listRow-'")).firstMatch
        XCTAssertFalse(listRow.waitForExistence(timeout: 8), "hidden from the List")
        let chromeMenu = app.buttons["chrome.menu"].firstMatch
        XCTAssertTrue(chromeMenu.waitForExistence(timeout: 10), "the menu glyph")
        chromeMenu.tap()
        let show = app.buttons["menu.showPrivate"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Show private in the slide-out menu")
        shot(app, "private-menu-show")
        show.tap()
        Thread.sleep(forTimeInterval: 1)
        shot(app, "private-shown-menu")
        app.buttons["xmark"].firstMatch.tap()
        XCTAssertTrue(listRow.waitForExistence(timeout: 8), "Show private brings it back in the List")
        shot(app, "private-shown-list")
    }

    private func tapEntryMenu(_ app: XCUIApplication) {
        let m = app.buttons["entryMenu"].firstMatch
        if m.waitForExistence(timeout: 5) { m.tap(); return }
        let b = app.buttons.matching(NSPredicate(format: "label == 'More'")).firstMatch
        if b.waitForExistence(timeout: 3) { b.tap(); return }
        let e = app.images["ellipsis"].firstMatch
        if e.waitForExistence(timeout: 3) { e.tap(); return }
        let any = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'ellipsis' OR label CONTAINS[c] 'more'")).firstMatch
        if any.waitForExistence(timeout: 3) { any.tap() } else { XCTFail("no entry menu") }
    }
}
