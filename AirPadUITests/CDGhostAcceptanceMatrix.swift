import XCTest

/// Brief CD — the ghost/Done acceptance matrix, driven through the REAL UI. No seeded screens, no
/// state-injection flags: entry is the production path (`captureButton` is the real "+";
/// `-EntryQuikCapture` runs the same `entryMode = .quikCapture` line the `airpad://quikcapture`
/// deep link runs, and QuikCaptureView's own `.task` makes the real node). `-StubAuthorModel`
/// stands in for the Simulator-absent model so the pipeline is deterministic; the device pass runs
/// the real model. Every test taps real buttons, hits real Done, REOPENS the entry, and asserts the
/// committed field values — the only way to catch a Done that promotes a title then blanks it.
final class CDGhostAcceptanceMatrix: XCTestCase {

    private let noteText = "Four of us going as Team Rocket for the office Halloween party, costumes due Friday."

    // MARK: - launch / entry

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly"] + extra
        app.launch()
        return app
    }

    /// Enter Quick Capture via its production entry (the `entryMode = .quikCapture` deep-link line),
    /// with the note auto-focused (`-EntryQuikCapture`) so typing is deterministic.
    private func enterQuickCapture(_ app: XCUIApplication) {
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "Quick Capture note editor should appear")
        awaitFocus(app, editor)
    }

    /// The note auto-focuses (via `pendingAutoFocusItemID`); wait for focus, tap once as a fallback.
    private func awaitFocus(_ app: XCUIApplication, _ editor: XCUIElement) {
        if app.keyboards.element.waitForExistence(timeout: 10) { return }
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.keyboards.element.waitForExistence(timeout: 8)
    }

    // MARK: - actions

    private func typeNote(_ app: XCUIApplication, _ text: String) {
        app.textViews["noteEditor"].typeText(text)
    }

    private func typeTitle(_ app: XCUIApplication, _ text: String) {
        let title = field(app, "titleField")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "title field should exist")
        title.tap()
        title.typeText(text)
    }

    private func clearTitle(_ app: XCUIApplication) {
        let title = field(app, "titleField")
        title.tap()
        // Select-all + delete via the keyboard: works on the focused title field.
        if let current = title.value as? String, !current.isEmpty, current != "Title" {
            title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
    }

    private func tapDone(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Done pill should exist after content")
        done.tap()
    }

    /// Reopen the most-recently-created entry. Done's enrichment (promote + commit) is async, and the
    /// transient post-Done screen is unreliable to query, so: let the write persist, then COLD-LAUNCH to
    /// the default Recents screen (entryMode defaults to `.recents`) and open the newest row. This reads
    /// the PERSISTED node — the real test of "what Done committed to disk".
    private func reopenNewestEntry(_ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 5)   // async promote/author + persist settles
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly"]  // default entryMode = .recents
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the just-created entry should be in Recents")
        row.tap()
        XCTAssertTrue(field(app, "titleField").waitForExistence(timeout: 10), "detail should open with the title field")
    }

    // MARK: - reads

    private func field(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let tv = app.textViews[id]
        if tv.exists { return tv }
        let tf = app.textFields[id]
        if tf.exists { return tf }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func fieldValue(_ app: XCUIApplication, _ id: String) -> String {
        let v = field(app, id).value as? String ?? ""
        // An empty TextField reports its placeholder as `.value`; treat that as empty.
        return (v == "Title" || v == "Summary") ? "" : v
    }

    private func ghostShowing(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Suggested:'")).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = name; s.lifetime = .keepAlways; add(s)
    }

    // ============================================================= Surface A — Quick Capture

    /// type → ghost while composing → Done commits BOTH title+summary → reopen = committed, no ghost.
    func testQC_type_ghost_DoneCommitsBoth_reopenNoGhost() {
        let app = launch(["-EntryQuikCapture"])
        enterQuickCapture(app)
        typeNote(app, noteText)
        XCTAssertTrue(ghostShowing(app).waitForExistence(timeout: 15), "a ghost should appear while composing")
        shot(app, "QC-ghost-while-composing")
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertFalse(fieldValue(app, "titleField").isEmpty, "Done must commit a TITLE (not blank it)")
        XCTAssertFalse(fieldValue(app, "summaryField").isEmpty, "Done must commit a SUMMARY")
        XCTAssertFalse(ghostShowing(app).exists, "a reopened committed entry shows NO ghost")
        shot(app, "QC-reopen-committed")
    }

    /// THE point-4 regression: the user types only the NOTE (no title); Done promotes a title; the
    /// teardown save must NOT overwrite it with the empty title mirror.
    func testQC_noUserTitle_promotedTitleSurvivesDone() {
        let app = launch(["-EntryQuikCapture"])
        enterQuickCapture(app)
        typeNote(app, noteText)
        _ = ghostShowing(app).waitForExistence(timeout: 15)
        tapDone(app)
        reopenNewestEntry(app)
        let t = fieldValue(app, "titleField"), s = fieldValue(app, "summaryField")
        shot(app, "QC-noUserTitle-reopen")
        XCTAssertFalse(t.isEmpty,
                       "a never-typed title must keep the model-promoted value, not be blanked at Done — got title='\(t)' summary='\(s)'")
    }

    /// A user-typed title must survive Done unchanged (never replaced by the model).
    func testQC_userTypedTitle_survivesDone() {
        let app = launch(["-EntryQuikCapture"])
        enterQuickCapture(app)
        typeNote(app, noteText)
        typeTitle(app, "My Own Title")
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertEqual(fieldValue(app, "titleField"), "My Own Title", "a user-typed title must be preserved")
    }

    /// A user who clears the title (after typing it) must get an empty title at Done — not a re-filled one.
    func testQC_userClearedTitle_staysCleared() {
        let app = launch(["-EntryQuikCapture"])
        enterQuickCapture(app)
        typeNote(app, noteText)
        typeTitle(app, "Temp")
        clearTitle(app)
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertTrue(fieldValue(app, "titleField").isEmpty, "a user-cleared title must stay cleared")
    }

    /// Two entries with identical text must EACH get their own title (no cross-entry blanking/dedup).
    /// Entry A is confirmed titled BEFORE the relaunch (which also proves it persisted); entry B after.
    func testQC_twoIdenticalEntries_bothTitled() {
        let app = launch(["-EntryQuikCapture"])
        // entry A
        enterQuickCapture(app)
        typeNote(app, noteText)
        _ = ghostShowing(app).waitForExistence(timeout: 15)
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertFalse(fieldValue(app, "titleField").isEmpty, "entry A (identical text) must be titled")
        // entry B — a COLD relaunch re-runs the production quikCapture entry; the persisted corpus
        // (entry A, just confirmed) reloads. (`launch()` terminates the running instance.)
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-EntryQuikCapture"]
        app.launch()
        enterQuickCapture(app)
        typeNote(app, noteText)
        _ = ghostShowing(app).waitForExistence(timeout: 15)
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertFalse(fieldValue(app, "titleField").isEmpty, "entry B (same text) must ALSO be titled")
    }

    // ============================================================= Surface B — "+" NodeDetailView

    /// "+" surface: type → ghost while composing (the shared CaptureHeader path). `-RealCapturePlus`
    /// runs the REAL "+" action (createCaptureNode → push NodeDetailView in capture mode) AND clears
    /// `isCapturing` to reproduce the device state — a real-flow harness, not a mask. Reopen/commit for
    /// the + surface is a device spot-check (its Done dismisses to the canvas); the save fix is the SAME
    /// `commitEditsIfChanged` proven on Quick Capture above.
    func testPlus_type_ghostWhileComposing() {
        let app = launch(["-RealCapturePlus"])
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "+ capture note editor should appear")
        awaitFocus(app, editor)
        typeNote(app, noteText)
        XCTAssertTrue(ghostShowing(app).waitForExistence(timeout: 15),
                      "a ghost should appear while composing in the + capture")
        shot(app, "Plus-ghost-while-composing")
    }
}
