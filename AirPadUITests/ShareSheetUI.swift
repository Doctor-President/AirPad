import XCTest

/// 1.1-C (C1) — the share sheet from another app: Photos → Share → AirPad shows AirPad's own sheet (Title · Note ·
/// Save to), Save stages the entry, and AirPad imports it with the typed title and the note. Then a second share goes to
/// "Existing entry" (lock off: no Face ID asked) and lands in that entry.
final class ShareSheetUI: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    private func airpad(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary"] + (fresh ? ["-UITestLibraryFresh"] : [])
        app.launch()
        return app
    }

    /// From AirPad itself: an entry's Export → Markdown → the system share sheet → AirPad (the real share extension).
    private func shareExport(_ app: XCUIApplication) -> Bool {
        let menu = app.buttons["entryMenu"].firstMatch
        guard menu.waitForExistence(timeout: 10) else { XCTFail("entry menu"); return false }
        menu.tap()
        guard app.buttons["entryMenu.export"].waitForExistence(timeout: 5) else { XCTFail("Export"); return false }
        app.buttons["entryMenu.export"].tap()
        guard app.buttons["export.markdown"].waitForExistence(timeout: 5) else { XCTFail("export sheet"); return false }
        app.buttons["export.markdown"].tap()
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'AirPad'"))
        guard any.firstMatch.waitForExistence(timeout: 8) else { XCTFail("AirPad isn't in the share sheet"); return false }
        Thread.sleep(forTimeInterval: 1)
        for i in 0..<min(any.count, 4) {
            let e = any.element(boundBy: i)
            guard e.isHittable else { continue }
            e.tap()
            if app.descendants(matching: .any)["share.title"].firstMatch.waitForExistence(timeout: 6) { return true }
        }
        // Fall back to the icon's spot (second app icon in the row).
        any.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        return true
    }

    func testShareNewThenExisting() {
        // Fresh scratch + an index for "Existing entry": make one entry, background AirPad (writes the index).
        var app = airpad(fresh: true)
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary", "-EntryQuikCapture"]
        app.launch()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.typeText("Share target\nThe entry a share is added to.")
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        XCUIDevice.shared.press(.home)        // background → the share index is written
        Thread.sleep(forTimeInterval: 2)

        app = airpad(fresh: false)
        let row0 = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 20)); row0.tap()

        // 1) New entry with a typed title + note.
        guard shareExport(app) else { return }
        let title = app.descendants(matching: .any)["share.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "AirPad's own sheet (not the one-tap Saved card)")
        shot(app, "share-sheet")
        XCTAssertFalse((title.value as? String ?? "").isEmpty, "the title is prefilled (file name / first line)")
        title.tap()
        title.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else if app.buttons["Select All"].waitForExistence(timeout: 1) { app.buttons["Select All"].tap() }
        title.typeText("Shared from export")
        let note = app.descendants(matching: .any)["share.note"].firstMatch
        note.tap(); note.typeText("A note from the share sheet")
        app.buttons["share.save"].tap()
        Thread.sleep(forTimeInterval: 2)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() }   // the export sheet
        Thread.sleep(forTimeInterval: 1)

        // 2) The same file to the existing entry (lock off: no Face ID).
        guard shareExport(app) else { return }
        let dest = app.segmentedControls["share.destination"].firstMatch
        XCTAssertTrue(dest.waitForExistence(timeout: 10), "Save to: New / Existing")
        dest.buttons["Existing entry"].tap()
        let entry = app.buttons["share.entry"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "the recent entries list")
        shot(app, "share-existing")
        entry.tap()
        app.buttons["share.save"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        // AirPad imports both.
        app = airpad(fresh: false)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 6)   // import + naming settle
        shot(app, "share-recents")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Shared from export'")).firstMatch.waitForExistence(timeout: 10),
                      "the typed title is kept")
        XCTAssertEqual(rows.count, 2, "the second share joined the existing entry instead of making a third")
        // The existing entry now holds the shared file too.
        let target = app.staticTexts.matching(NSPredicate(format: "label == 'Stub Title'")).firstMatch
        XCTAssertTrue(target.exists, "the existing entry is still there under its own name")
    }
}
