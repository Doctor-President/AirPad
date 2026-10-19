import XCTest

/// live-28 (3) — in the Chat view a citation opens its entry (live-27 (4b) left it a no-op).
/// live-29 (B2) — T: pushing the entry inside the Chat view's own stack "is wrong". A citation tap presents the app's
/// normal Detail View exactly as a Librarian citation does: the Chats sheet closes, the surface underneath (here the
/// Map) pushes the entry's Detail View, and Back returns to that surface — not to the chat. The seeded chat
/// (`-UITestSeedChats`: an answer citing the seeded entry, isolated library) → its sources → tap the source.
final class ChatViewCitationUI: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testChatViewCitationOpensItsEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedChats",
                               "-GauntletUI", "YES", "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What connections'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded chat in the Chats list")
        row.tap()
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH 'sources'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15), "the answer lists its sources")
        // In this sheet XCUITest reports the controls ~18 pt above where they're drawn (and not hittable): tap at the
        // reported spot, then a little lower, until the expected result shows.
        Thread.sleep(forTimeInterval: 2)
        func tapUntil(_ e: XCUIElement, _ done: () -> Bool) {
            for dy in [0.0, 9, 18, 27] where !done() {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: e.frame.midX, dy: e.frame.midY + dy)).tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        tapUntil(show) { app.buttons["Hide sources"].exists }
        let source = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Seeded entry'")).firstMatch   // the source row
        XCTAssertTrue(source.waitForExistence(timeout: 5), "a source row")
        shot(app, "chatview-sources")
        let detailTitle0 = app.descendants(matching: .any)["titleField"]
        tapUntil(source) { detailTitle0.exists }
        let detailTitle = app.descendants(matching: .any)["titleField"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 10), "tapping a citation in the Chat view opens its entry")
        shot(app, "chatview-citation-opened")
        let shown = (detailTitle.value as? String) ?? detailTitle.label
        XCTAssertEqual(shown, "Seeded entry", "the opened entry is the cited one")
        // live-29 (B2) — the standard Detail View, not a push inside the chat: the Chats sheet is gone (its chat's pin
        // button and the Chats list's title with it).
        Thread.sleep(forTimeInterval: 1.5)
        let sheetChrome = app.buttons["Pin chat to an entry"].exists || app.buttons["Change pinned entry"].exists
            || app.navigationBars["Chats"].exists
        XCTAssertFalse(sheetChrome, "the entry opened inside the Chat view's own stack (the Chats sheet is still up)")
        // The detail's own round back button, top left (there is no navigation bar there).
        let back = app.buttons["Back"].firstMatch
        if back.exists && back.isHittable { back.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.09)).tap() }
        Thread.sleep(forTimeInterval: 1.5)
        shot(app, "chatview-citation-back")
        XCTAssertFalse(app.descendants(matching: .any)["titleField"].exists, "Back left the detail up")
        XCTAssertFalse(show.exists || app.buttons["Hide sources"].exists,
                       "Back returned to the chat; a Librarian citation's Back returns to the surface underneath")
    }
}
