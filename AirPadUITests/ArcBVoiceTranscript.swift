import XCTest

/// Arc B — "Append to…" on the real entry screen (T will try it on device; RED-first here): the transcript lands at
/// the END of the chosen note, the Voice item's own transcript is left as it is, and Restore original only ever
/// touches the Voice item. Synthetic seeded entry (`-UITestSeedVoiceEntry`), isolated library; reads the node on disk.
final class ArcBVoiceTranscript: XCTestCase {

    private let seeded = "Pick up the prints from the lab on Thursday, and ask whether they can rescan the second roll at a higher resolution."
    private let noteBefore = "Darkroom list\nFixer, stop bath, two boxes of paper."

    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launchIntoEntry() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedVoiceEntry", "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded entry should be in Recents")
        Thread.sleep(forTimeInterval: 1)
        row.tap()
        XCTAssertTrue(transcriptField(app).waitForExistence(timeout: 10), "the Voice item shows its transcript")
        return app
    }

    private func transcriptField(_ app: XCUIApplication) -> XCUIElement {
        app.textViews["voiceTranscript"].exists ? app.textViews["voiceTranscript"] : app.textFields["voiceTranscript"]
    }

    private func hideKeyboard(_ app: XCUIApplication) {
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
    }

    private func voiceMenu(_ app: XCUIApplication) {
        let options = app.buttons.matching(identifier: "entryOptions").element(boundBy: 0)
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
    }

    private func appendToDarkroomList(_ app: XCUIApplication) {
        voiceMenu(app)
        XCTAssertTrue(app.buttons["Append to…"].waitForExistence(timeout: 5), "the Voice item's menu offers Append to…")
        app.buttons["Append to…"].tap()
        let target = app.buttons["Darkroom list"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Append to… lists the entry's note")
        target.tap()
    }

    // MARK: - disk

    private func entryOnDisk() -> [String: Any]? {
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        var best: ([String: Any], Date)?
        for c in (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let f = c.appendingPathComponent("Library/Caches/AirPadUITestScratch/nodes/uitest-voice-entry/node.json")
            guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || m > best!.1 { best = (j, m) }
        }
        return best?.0
    }
    private func items() -> [[String: Any]] { (entryOnDisk()?["items"] as? [[String: Any]]) ?? [] }
    private func voice() -> [String: Any]? { items().first { ($0["id"] as? String) == "uitest-voice-audio" } }
    private func note() -> String { (items().first { ($0["id"] as? String) == "uitest-voice-note" }?["content"] as? String) ?? "" }

    /// Poll the disk until `ok` holds (the store writes asynchronously).
    private func eventually(_ timeout: TimeInterval = 8, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; Thread.sleep(forTimeInterval: 0.3) }
        return ok()
    }

    // MARK: - rows

    /// Append to… → the note's END; the Voice item unchanged; then edit → Restore original touches the Voice item only.
    func testAppendTo_landsAtEnd_restoreLeavesNote() {
        let app = launchIntoEntry()
        appendToDarkroomList(app)
        XCTAssertTrue(eventually { note() == noteBefore + "\n\n" + seeded },
                      "the transcript lands at the end of the chosen note (note len \(note().count))")
        XCTAssertEqual(voice()?["transcript"] as? String, seeded, "the Voice item's transcript is unchanged")
        XCTAssertNil(voice()?["transcript_original"], "appending doesn't mark the Voice item edited")
        XCTAssertFalse(app.staticTexts["voiceEditedMark"].exists, "no 'Edited' after an append")

        // Edit the transcript, then Restore original: the Voice item goes back; the note keeps what was appended.
        let field = transcriptField(app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85)).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        field.typeText(" Call first.")
        hideKeyboard(app)
        XCTAssertTrue(eventually { (voice()?["transcript"] as? String) == seeded + " Call first." }, "the edit commits")
        voiceMenu(app)
        XCTAssertTrue(app.buttons["Restore original"].waitForExistence(timeout: 5))
        app.buttons["Restore original"].tap()
        XCTAssertTrue(eventually { (voice()?["transcript"] as? String) == seeded && voice()?["transcript_original"] == nil },
                      "Restore original brings back the recognised words")
        XCTAssertEqual(note(), noteBefore + "\n\n" + seeded, "Restore original never touches the note")
    }

    /// The person edits the transcript and goes straight to the "…" menu (keyboard still up): what is appended is
    /// what they see — the EDITED words — and the Voice item keeps the edit.
    func testAppendTo_afterEditStillTyping() {
        let app = launchIntoEntry()
        let field = transcriptField(app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85)).tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        field.typeText(" Call first.")
        appendToDarkroomList(app)   // no keyboard dismissal first
        let edited = seeded + " Call first."
        XCTAssertTrue(eventually { note().hasSuffix(edited) },
                      "the appended text is the edited transcript (note ends with the edit: \(note().hasSuffix(edited)), with the original: \(note().hasSuffix(seeded)))")
        XCTAssertTrue(eventually { (voice()?["transcript"] as? String) == edited }, "the Voice item keeps the edit")
    }
}
