import XCTest

/// live-28 (1) — every Host answer is capped, through the REAL path: the Librarian UI → a scratch Host from source → a
/// FAKE Ollama (`scripts/runaway/fake_ollama.py`, synthetic text), driven by `scripts/runaway/run.sh`. The question
/// picks the fake's behaviour: "presidents" repeats one row forever; "every lighthouse" writes new rows until
/// `num_predict` stops it; "slowly" writes at 5 tokens/s and ignores `num_predict` (the turn limit, shortened here by
/// `-AnswerWallClockSec 25`); a tide-pool question is a normal short answer. Each stopped answer keeps what arrived and
/// shows "Stopped: the answer ran too long"; Stop mid-answer keeps what arrived with "Stopped".
/// Config: `TEST_RUNNER_RUNAWAY_HOST_ARGS` = the scratch Host's `-DebugHost…` args.
final class RunawayAnswerUI: XCTestCase {
    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M"]
            + host.split(separator: " ").map(String.init) + extra
        app.launch()
        return app
    }
    private func askGeneral(_ app: XCUIApplication, _ q: String) {
        let lib = app.buttons["Library mode"]
        if lib.waitForExistence(timeout: 30) { lib.tap() }
        XCTAssertTrue(app.buttons["General mode"].waitForExistence(timeout: 5), "could not switch to General")
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        var field = app.textFields.matching(pred).firstMatch
        if !field.waitForExistence(timeout: 5) { field = app.textViews.matching(pred).firstMatch }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ask field missing")
        field.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); field.tap() }
        field.typeText(q)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[Runaway] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        // The keyboard away (its "Done" bar), then the end of the answer into view (coordinates, as ChatProvenanceUI).
        if app.keyboards.element.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.607)).tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        Thread.sleep(forTimeInterval: 1.5)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private var stoppedLine: (XCUIApplication) -> XCUIElement {
        { $0.descendants(matching: .any).matching(identifier: "chat.stopped").firstMatch }
    }
    /// What the kept answer shows: its table's row count (an answer table is its own element, "chatTable") or its text.
    private func answerText(_ app: XCUIApplication) -> String {
        let table = app.descendants(matching: .any)["chatTable"].firstMatch
        if table.exists { return table.label.isEmpty ? "table" : table.label }
        return app.descendants(matching: .any).matching(identifier: "chat.answer").allElementsBoundByIndex
            .max(by: { $0.frame.minY < $1.frame.minY })?.label ?? ""
    }

    /// One capped row: ask, then the line must appear within `within` seconds, under an answer that kept what arrived.
    private func capped(_ q: String, within: TimeInterval, name: String, extra: [String] = []) throws {
        let app = try launch(extra)
        askGeneral(app, q)
        let t0 = Date()
        let line = stoppedLine(app)
        let ok = line.waitForExistence(timeout: within)
        let sec = Date().timeIntervalSince(t0)
        note("\(name): \(ok ? "stopped" : "NOT stopped") after \(String(format: "%.1f", sec)) s · line \(ok ? "'\(line.label)'" : "–") · kept: \(answerText(app).prefix(60))")
        shot(app, "runaway-\(name)")
        XCTAssertTrue(ok, "\(name): no stopped line within \(Int(within)) s")
        XCTAssertEqual(line.label, "Stopped: the answer ran too long")
        XCTAssertFalse(answerText(app).isEmpty, "\(name): the answer that arrived was not kept")
        XCTAssertFalse(app.buttons["Stop answer"].exists, "\(name): the turn is still running")
    }

    /// The fake repeats one row forever: the loop guard stops it within seconds.
    func testLoopStopsWithTheLine() throws { try capped("Make a table of US presidents and whether each is living", within: 60, name: "loop") }
    /// New rows forever: Ollama's num_predict (the table budget, 4,096) ends it, finish_reason "length".
    func testBudgetStopsWithTheLine() throws { try capped("Make a table of every lighthouse on the coast", within: 150, name: "budget") }
    /// Slow and deaf to num_predict: the turn limit ends it (25 s here, 300 s in the app).
    func testTurnLimitStopsWithTheLine() throws {
        try capped("Slowly list every lighthouse you know", within: 60, name: "turn-limit", extra: ["-AnswerWallClockSec", "25"])
    }

    /// Stop mid-answer: what arrived stays, with "Stopped"; the Ask bar is back to normal.
    func testStopMidAnswer() throws {
        let app = try launch()
        askGeneral(app, "Make a table of every lighthouse on the coast")
        let stop = app.buttons["Stop answer"]
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "no Stop while the answer streams")
        let answers = app.descendants(matching: .any).matching(identifier: "chat.answer")
        _ = answers.firstMatch.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 3)
        stop.tap()
        let t0 = Date()
        let line = stoppedLine(app)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "Stop left no line")
        note("stop: ended \(String(format: "%.1f", Date().timeIntervalSince(t0))) s after the tap · line '\(line.label)' · kept: \(answerText(app).prefix(60))")
        shot(app, "runaway-stop")
        XCTAssertEqual(line.label, "Stopped")
        XCTAssertFalse(answerText(app).isEmpty, "Stop dropped what had arrived")
        XCTAssertFalse(stop.exists, "Stop is still showing after the turn ended")
    }

    /// A normal answer is untouched: no line, no Stop left over.
    func testNormalAnswerUntouched() throws {
        let app = try launch()
        askGeneral(app, "What is a tide pool?")
        let answered = app.descendants(matching: .any).matching(identifier: "chat.provenance").firstMatch.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 2)
        note("normal: \(answered ? "answered" : "NO ANSWER") · stopped line \(stoppedLine(app).exists ? "SHOWN" : "none")")
        XCTAssertTrue(answered, "no answer")
        XCTAssertFalse(stoppedLine(app).exists, "a normal answer shows a stopped line")
        XCTAssertFalse(app.buttons["Stop answer"].exists)
    }
}
