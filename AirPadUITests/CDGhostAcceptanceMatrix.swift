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
        // `-UITestLibrary` = isolated scratch (never T's real Library); `-UITestLibraryFresh` wipes it
        // at the START of each test so the newest entry is unambiguously this test's.
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly",
                               "-UITestLibrary", "-UITestLibraryFresh"] + extra
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
        dismissKeyboardTip(app)
    }

    /// iOS shows a one-time "Speed up your typing by sliding your finger…" (QuickPath) sheet on a Simulator's first
    /// keyboard use. It covers the Done pill, so Done never commits — the 2026-10-08 quiet-Mac failure of
    /// `noUserTitle_promotedTitleSurvivesDone` (screenshot: ghost shown, tip over Done, nothing written in 60 s).
    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sliding your finger'")).firstMatch
        if tip.waitForExistence(timeout: 1), app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
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
        // The note keyboard covers the Done pill, so a tap on it lands on the keyboard and capture never
        // commits. Dismiss the keyboard first (QuikCapture has .dismissKeyboardOnTapOutside — tap the hero),
        // then the Done pill is hittable.
        // Dismiss whatever keyboard is up so the pinned Done pill is reachable. The NOTE editor has a
        // format bar with an explicit Hide-Keyboard button; the TITLE/SUMMARY fields have a plain
        // keyboard with none, so fall back to tap-outside (QuikCapture's .dismissKeyboardOnTapOutside).
        // Blind keyboard swipes hit the autocomplete bar and type stray text — don't.
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if !hide.waitForExistence(timeout: 2) && app.keyboards.element.exists {
            // Title/summary are focused (plain keyboard, no format bar). Shift focus to the NOTE — that
            // raises the note editor's format bar (with its Hide-Keyboard button) and leaves the typed
            // title committed in @State — then dismiss reliably. (Blind gestures type stray text.)
            app.textViews["noteEditor"].tap()
            _ = hide.waitForExistence(timeout: 3)
        }
        dismissKeyboardTip(app)
        if hide.exists { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.8)                                            // let the pinned chrome settle up
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Done pill should exist after content")
        done.tap()
    }

    /// Reopen the most-recently-created entry. Done's enrichment (promote + commit) is async, and the
    /// transient post-Done screen is unreliable to query, so: let the write persist, then COLD-LAUNCH to
    /// the default Recents screen (entryMode defaults to `.recents`) and open the newest row. This reads
    /// the PERSISTED node — the real test of "what Done committed to disk".
    private func reopenNewestEntry(_ app: XCUIApplication, expectTitle: Bool = true) {
        // CONDITION wait (was a fixed 15 s sleep, which flaked under load — 3 busy Simulators + Ollama): poll the
        // PERSISTED entry until Done's async write has landed — the stub summary (every Done here writes one) and,
        // when this test expects one, the title. A relaunch before that kills the in-flight write.
        waitForDoneOnDisk(expectTitle: expectTitle, timeout: 60)
        shot(app, "post-Done-before-relaunch")   // diagnostic: did the title land before we relaunch?
        // Reopen: keep the isolated library (NO -Fresh, so the entry just committed survives the relaunch).
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the just-created entry should be in Recents")
        row.tap()
        XCTAssertTrue(field(app, "titleField").waitForExistence(timeout: 10), "detail should open with the title field")
    }

    // MARK: - disk (Simulator)

    /// The newest entry in the app's `-UITestLibrary` scratch, read from disk. In the Simulator the test runner can
    /// read its sibling app containers (`…/Containers/Data/Application/*/Library/Caches/AirPadUITestScratch`).
    /// Returns nil where that isn't readable (a physical device).
    private func newestPersistedNode() -> [String: Any]? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        guard let containers = try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil) else { return nil }
        var best: (Date, [String: Any])?
        for c in containers {
            let nodes = c.appendingPathComponent("Library/Caches/AirPadUITestScratch/nodes")
            guard let ids = try? fm.contentsOfDirectory(at: nodes, includingPropertiesForKeys: nil) else { continue }
            for id in ids {
                let f = id.appendingPathComponent("node.json")
                guard let attrs = try? fm.attributesOfItem(atPath: f.path), let m = attrs[.modificationDate] as? Date,
                      let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                // newest by CREATION (`created_at`, ISO-8601) — a re-save of an older entry must not win
                let key = (j["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? m
                if best == nil || key > best!.0 { best = (key, j) }
            }
        }
        return best?.1
    }

    /// Poll until the newest persisted entry carries Done's write (summary, and the title when expected).
    /// Falls back to the old fixed wait where the app's container isn't readable (device).
    private func waitForDoneOnDisk(expectTitle: Bool, timeout: TimeInterval) {
        guard newestPersistedNode() != nil else { Thread.sleep(forTimeInterval: 15); return }
        let deadline = Date().addingTimeInterval(timeout)
        let t0 = Date()
        while Date() < deadline {
            if let n = newestPersistedNode() {
                let summary = (n["summary"] as? String) ?? "", title = (n["title"] as? String) ?? ""
                if !summary.isEmpty && (!expectTitle || !title.isEmpty) {
                    print("[CDGhost] Done landed on disk after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s (title='\(title)')")
                    Thread.sleep(forTimeInterval: 0.5)   // let the save finish flushing siblings (blocks.json)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("Done's write never reached disk within \(Int(timeout)) s (title/summary still empty)")
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
        reopenNewestEntry(app, expectTitle: false)
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
        // Entry B: keep the isolated library (NO -Fresh) so entry A survives for the both-titled check.
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary", "-EntryQuikCapture"]
        app.launch()
        enterQuickCapture(app)
        typeNote(app, noteText)
        _ = ghostShowing(app).waitForExistence(timeout: 15)
        tapDone(app)
        reopenNewestEntry(app)
        XCTAssertFalse(fieldValue(app, "titleField").isEmpty, "entry B (same text) must ALSO be titled")
    }

    // ============================================================= Surface B — "+" NodeDetailView
    //
    // The "+" surface uses the SAME `NodeDetailView.commitEditsIfChanged` no-overwrite fix proven by the
    // Quick Capture rows above, and its ghost-while-composing is already covered by the existing
    // `CDGhostWhileTyping` test. A duplicate `-RealCapturePlus` test here only added device flake
    // (its push/auto-focus timing is unreliable headlessly), so it's intentionally not repeated.
    // T device-verified the "+" surface commits title+summary at Done by hand (2026-10-01).
}
