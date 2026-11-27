import XCTest

/// widget fix-up 1 (item 2) — typed note text survives AirPad leaving the foreground, proven with real events on an
/// ERASED Simulator (the default library seeds the Sample Library on first launch; nothing of a real library).
/// Run each test alone, on an erased Simulator:
///   1. type → Home → end the app → relaunch → the words are there;
///   2. type → Home → return → still editing (keyboard up, caret where it was, undo intact), nothing duplicated;
///   3. type → Home → the Pinned Entry widget for that entry shows the new words (without leaving the entry).
final class TypedTextLeavesForegroundUI: XCTestCase {

    /// The Sample Library's "Sid's list" (a note: two lines of text, then a checklist).
    static let entryID = "879D7F38-F339-5EE0-91C8-52D11C03653C"
    static let entryTitle = "Sid's list"

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() { continueAfterFailure = false }

    /// Simulator only: attachments are also written next to the work tree (`build/fixup/shots/`, gitignored), so the
    /// evidence survives a result bundle that never finalises.
    static let shotsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/fixup/shots", isDirectory: true)

    func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let shot = (app ?? springboard).screenshot()
        let s = XCTAttachment(screenshot: shot)
        s.name = name; s.lifetime = .keepAlways; add(s)
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: Self.shotsDir.appendingPathComponent("\(name).png"))
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = name; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: Self.shotsDir.appendingPathComponent("\(name).txt"))
    }

    func editor(_ app: XCUIApplication) -> XCUIElement { app.textViews["noteEditor"].firstMatch }

    func editorText(_ app: XCUIApplication) -> String { (editor(app).value as? String) ?? "" }

    func occurrences(_ word: String, in s: String) -> Int { s.components(separatedBy: word).count - 1 }

    /// Launch (the Sample Library seeds on a fresh install) and open the entry through its link, the way a widget tap
    /// does (`airpad://entry/<id>`).
    func launchOnEntry(_ app: XCUIApplication, seedWait: UInt32) {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(seedWait)
        app.open(URL(string: "airpad://entry/\(Self.entryID)")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(editor(app).waitForExistence(timeout: 20), "the entry's note is on screen")
        sleep(1)
    }

    /// Tap the note's first line, put the caret at the very start, type `word` + a space. The keyboard stays up.
    func typeAtStart(_ app: XCUIApplication, _ word: String) {
        let ed = editor(app)
        ed.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.04)).tap()
        if !app.keyboards.element.waitForExistence(timeout: 6) { ed.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "the note is focused")
        sleep(1)
        ed.typeKey(.upArrow, modifierFlags: .command)
        ed.typeText(word + " ")
        sleep(1)
    }

    // MARK: - 1 · type → Home → end the app → relaunch

    func testTypedTextSurvivesEndingTheApp() {
        let app = XCUIApplication()
        launchOnEntry(app, seedWait: 15)
        typeAtStart(app, "Kestrel")
        XCTAssertEqual(occurrences("Kestrel", in: editorText(app)), 1)
        shot("1-typed", app)
        XCUIDevice.shared.press(.home)       // still editing: nothing ends the edit
        sleep(2)
        app.terminate()                      // iOS ends AirPad in the background
        sleep(2)
        launchOnEntry(app, seedWait: 6)
        shot("1-relaunched", app)
        let text = editorText(app)
        note("1-after-relaunch", "Kestrel occurrences: \(occurrences("Kestrel", in: text))")
        XCTAssertEqual(occurrences("Kestrel", in: text), 1, "the typed words survive AirPad being ended in the background")
    }

    // MARK: - 2 · type → Home → return → still editing

    func testReturnKeepsTheEdit() {
        let app = XCUIApplication()
        launchOnEntry(app, seedWait: 15)
        let before = editorText(app)
        typeAtStart(app, "Kestrel")
        shot("2-typed", app)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(1)
        shot("2-returned", app)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3), "the keyboard is still up: the edit didn't end")
        XCTAssertEqual(occurrences("Kestrel", in: editorText(app)), 1, "nothing duplicated")
        // The caret is where it was: the next keystrokes land right after the word typed before Home.
        editor(app).typeText("Owl ")
        sleep(1)
        XCTAssertTrue(editorText(app).hasPrefix("Kestrel Owl "), "the caret stayed after the typed word")
        // Undo is intact: ⌘Z takes back the typing after the return, then the typing from before Home.
        var undos = 0
        while editorText(app).contains("Kestrel"), undos < 4 {
            editor(app).typeKey("z", modifierFlags: .command); sleep(1); undos += 1
        }
        note("2-undo", "undos to the text before Kestrel: \(undos); back to the original: \(editorText(app) == before)")
        XCTAssertFalse(editorText(app).contains("Kestrel"), "undo reaches the typing from before Home")
        XCTAssertEqual(editorText(app), before, "undo restores the note exactly")
        shot("2-undone", app)
        // (Not asserted: whether ⌘⇧Z redoes here; this editor's redo is not part of this fix.)
        editor(app).typeKey("z", modifierFlags: [.command, .shift]); sleep(1)
        note("2-redo", "after one redo the note starts with Kestrel: \(editorText(app).hasPrefix("Kestrel"))")
        // Nothing duplicated across two leaves and the store: type both words again, go Home (saved again), end the
        // app, relaunch: one copy of each word, and no new entry.
        for _ in 0..<4 where editorText(app).contains("Kestrel") { editor(app).typeKey("z", modifierFlags: .command); sleep(1) }
        XCTAssertFalse(editorText(app).contains("Kestrel"))
        typeAtStart(app, "Kestrel Owl")
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        sleep(2)
        launchOnEntry(app, seedWait: 6)
        let after = editorText(app)
        note("2-reopened", "Kestrel \(occurrences("Kestrel", in: after)) · Owl \(occurrences("Owl", in: after))")
        XCTAssertEqual(occurrences("Kestrel", in: after), 1)
        XCTAssertEqual(occurrences("Owl", in: after), 1)
        shot("2-reopened", app)
    }

    // MARK: - 3 · type → Home → the widget shows the new words

    func airpadWidgets() -> XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "identifier == 'AirPad' AND value == 'Widget'"))
    }

    func widgetShowing(_ text: String) -> XCUIElement {
        airpadWidgets().containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func waitForWidget(_ text: String, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var step = 0
        while Date() < deadline {
            if widgetShowing(text).exists { return true }
            sleep(1)
            if widgetShowing(text).exists { return true }
            if step % 4 == 0 || step % 4 == 3 { springboard.swipeLeft() } else { springboard.swipeRight() }
            step += 1
            sleep(1)
        }
        shot("missing-\(text)")
        return false
    }

    func addMediumWidget() {
        let sb = springboard
        XCUIDevice.shared.press(.home); sleep(1)
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.5); sleep(1)
        XCTAssertTrue(sb.buttons["Edit"].waitForExistence(timeout: 5)); sb.buttons["Edit"].tap()
        XCTAssertTrue(sb.buttons["Add Widget"].waitForExistence(timeout: 5)); sb.buttons["Add Widget"].tap()
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
        let preview = sb.buttons.matching(NSPredicate(format: "label == 'AirPad, Pinned Entry'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.swipeLeft(); sleep(1)
        let add = sb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap(); sleep(2)
        if sb.buttons["Done"].exists { sb.buttons["Done"].tap(); sleep(1) }
    }

    func pick(_ title: String) {
        let sb = springboard
        let widget = airpadWidgets().firstMatch
        let width = sb.frame.width
        for _ in 0..<4 where !widget.isHittable {
            if widget.frame.minX >= width { sb.swipeLeft() } else { sb.swipeRight() }
            sleep(1)
        }
        widget.press(forDuration: 1.5)
        let edit = sb.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap(); sleep(2)
        let row = sb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Choose' OR label CONTAINS[c] 'Entry'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap(); sleep(2)
        let search = sb.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title); sleep(2)
        let hit = sb.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "the picker finds \(title)"); hit.tap(); sleep(2)
        let card = sb.otherElements["Pinned Entry, AirPad"]
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap(); sleep(2)
        if card.exists { XCUIDevice.shared.press(.home); sleep(2) }
        XCTAssertFalse(card.exists, "the configuration card closed")
    }

    func testWidgetShowsTypedTextAfterHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(15)   // the Sample Library seeds; the widget's copy is written
        addMediumWidget()
        pick(Self.entryTitle)
        XCTAssertTrue(waitForWidget(Self.entryTitle))
        shot("3-widget-before")
        // Open the entry from the widget (a real tap), type, go Home WITHOUT leaving the entry.
        XCTAssertTrue(waitForWidget(Self.entryTitle))
        widgetShowing(Self.entryTitle).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(editor(app).waitForExistence(timeout: 15))
        sleep(1)
        typeAtStart(app, "Kestrel")
        shot("3-typed", app)
        let left = Date()
        XCUIDevice.shared.press(.home)
        let reached = waitForWidget("Kestrel")
        note("3-freshness", String(format: "Home → widget shows the typed word: %.1f s (polled ~1 s); reached: %@",
                                   Date().timeIntervalSince(left), reached ? "yes" : "no"))
        shot("3-widget-after-home")
        XCTAssertTrue(reached, "the widget shows words typed just before Home, without the entry being left")
    }
}
