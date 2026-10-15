import XCTest
import UIKit

/// live-11 (2) — T: pasting long copied text "glitched" and the auto-title took ~10 s. Pastes SYNTHETIC text of five sizes
/// through the real edit menu (Paste), into (a) a Quick Capture note and (b) an existing entry's note, and reads the app's
/// `-PasteProbe` (main-thread stalls, paste → naming → ghost). The test is silent for the probe's 8 s window after the
/// paste (an XCUITest query runs on the app's main thread). Targets: no stall ≥ 250 ms; in Quick Capture the ghost
/// title lands within ~1 s of the paste (`-StubAuthorModel` at its 150 ms default stands in for the model) and naming
/// reads a capped slice. Each row prints one `[LongPaste]` line for the report.
final class LongPaste: XCTestCase {

    static let sizes = [500, 2_000, 5_000, 10_000, 20_000]
    /// The naming read cap the fix states (`AIService.namingContentCap`) + the " […]" marker.
    static let namingCap = 3_200 + 4
    static let stallLimitMs = 250
    static let ghostLimitMs = 1_000

    override func setUp() { continueAfterFailure = true }

    /// Deterministic synthetic prose with paragraph breaks, `n` characters. No real content.
    static func synthetic(_ n: Int) -> String {
        let words = ["orchard", "lantern", "river", "copper", "meadow", "violin", "harbour", "pepper", "granite",
                     "compass", "thistle", "ember", "sparrow", "willow", "quartz", "saffron", "tide", "marble"]
        var s = "", i = 0, sentence = 0
        while s.count < n {
            s += words[i % words.count]; i += 7
            if i % 11 == 0 { s += ". "; sentence += 1; if sentence % 6 == 0 { s += "\n\n" } } else { s += " " }
        }
        return String(s.prefix(n))
    }

    private func launch(_ extra: [String], fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly", "-UITestLibrary", "-PasteProbe"]
            + (fresh ? ["-UITestLibraryFresh"] : []) + extra
        app.launch()
        return app
    }

    private func probe(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["pasteProbe"].label
    }

    private func value(_ key: String, in s: String) -> Int {
        guard let r = s.range(of: "\(key)=") else { return -1 }
        return Int(s[r.upperBound...].prefix { $0.isNumber || $0 == "-" }) ?? -1
    }

    /// Long-press the editor and choose Paste from the edit menu (the path a person takes).
    private func paste(into editor: XCUIElement, app: XCUIApplication, at point: CGVector = CGVector(dx: 0.3, dy: 0.3)) {
        for attempt in 0..<3 {
            editor.coordinate(withNormalizedOffset: point).press(forDuration: 1.0)
            let item = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            if item.waitForExistence(timeout: 3) { item.tap(); return }
            if attempt == 2 { XCTFail("no Paste in the edit menu") }
        }
    }

    /// No queries for the probe's whole window: every XCUITest query snapshots the app's accessibility tree ON ITS MAIN
    /// THREAD, and with 20k characters in the note that snapshot alone stalls it for 100–200 ms (seen in the trace).
    private func quiet() { Thread.sleep(forTimeInterval: 9) }

    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sliding your finger'")).firstMatch
        if tip.waitForExistence(timeout: 1), app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    }

    private func report(_ surface: String, _ n: Int, _ p: String, ghostExpected: Bool) {
        print("[LongPaste] \(surface) chars=\(n) \(p)")
        let a = XCTAttachment(string: p); a.name = "\(surface)-\(n)"; a.lifetime = .keepAlways; add(a)
        let seen = value("paste", in: p)   // + a smart space either side of a mid-line paste
        XCTAssertTrue(seen >= n && seen <= n + 2, "\(surface) \(n): the probe saw the whole paste (\(seen))")
        let stallMax = value("stallMax", in: p)
        XCTAssertLessThan(stallMax, Self.stallLimitMs, "\(surface) \(n): main thread stalled \(stallMax) ms")
        guard ghostExpected else { return }
        let ghost = value("ghost", in: p), chars = value("namingChars", in: p)
        XCTAssertTrue(ghost >= 0 && ghost <= Self.ghostLimitMs, "\(surface) \(n): ghost at \(ghost) ms (target ≤ \(Self.ghostLimitMs))")
        let shimmer = value("shimmer", in: p)
        XCTAssertTrue(shimmer >= 0 && shimmer <= Self.ghostLimitMs + 200, "\(surface) \(n): ghost shimmer at \(shimmer) ms")
        XCTAssertTrue(chars > 0 && chars <= Self.namingCap, "\(surface) \(n): naming read \(chars) chars (cap \(Self.namingCap))")
    }

    // MARK: - (a) Quick Capture note

    private func quickCapture(_ n: Int) {
        UIPasteboard.general.string = Self.synthetic(n)
        let app = launch(["-EntryQuikCapture"])
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "Quick Capture should open")
        _ = app.keyboards.element.waitForExistence(timeout: 10)
        dismissKeyboardTip(app)
        Thread.sleep(forTimeInterval: 1.5)   // settle: launch work is not the paste's
        paste(into: editor, app: app)
        quiet()
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "QC-\(n)"; s.lifetime = .keepAlways; add(s)
        report("QC", n, probe(app), ghostExpected: true)
    }

    func testQC_00500() { quickCapture(500) }
    func testQC_02000() { quickCapture(2_000) }
    func testQC_05000() { quickCapture(5_000) }
    func testQC_10000() { quickCapture(10_000) }
    func testQC_20000() { quickCapture(20_000) }

    // MARK: - (b) an existing entry's note

    /// Make one titled entry (Quick Capture, a short typed note, Done), relaunch, open it, paste at the end of its note.
    private func existingItem(_ n: Int) {
        var app = launch(["-EntryQuikCapture"])
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "Quick Capture should open")
        _ = app.keyboards.element.waitForExistence(timeout: 10)
        editor.typeText("Seed note\nA body line for the paste check, long enough to press into the middle of it.")
        dismissKeyboardTip(app)
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["Done"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)     // Done's write lands
        app.terminate()

        UIPasteboard.general.string = Self.synthetic(n)
        app = launch([], fresh: false)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded entry should be in Recents")
        row.tap()
        let note = app.textViews["noteEditor"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the entry's note should show")
        note.tap()
        _ = app.keyboards.element.waitForExistence(timeout: 8)
        dismissKeyboardTip(app)
        Thread.sleep(forTimeInterval: 1.5)
        paste(into: note, app: app, at: CGVector(dx: 0.5, dy: 0.8))   // the body line, not the title line
        quiet()
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = "Existing-\(n)"; s.lifetime = .keepAlways; add(s)
        report("Existing", n, probe(app), ghostExpected: false)
    }

    func testExisting_00500() { existingItem(500) }
    func testExisting_02000() { existingItem(2_000) }
    func testExisting_05000() { existingItem(5_000) }
    func testExisting_10000() { existingItem(10_000) }
    func testExisting_20000() { existingItem(20_000) }
}
