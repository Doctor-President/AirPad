import XCTest

/// live-32 (A1) — T: "the regenerate button at the end of an answer sometimes does nothing" (seen before live-31 too).
/// Through the real Librarian on the stub stack (`scripts/runaway/run.sh`): tap ↻ (or the error banner's Retry) and
/// check the fake model got a NEW request for the same question — after a plain answer, after a web answer (the turn
/// carries a "Searched the web" row), after a failed web turn (the banner), after Stop; and in the Chat view.
final class RegenerateUI: XCTestCase {
    private var fakeURL: String { ProcessInfo.processInfo.environment["RUNAWAY_FAKE_URL"] ?? "http://127.0.0.1:11600" }

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap", "-GauntletUI", "YES",
                               "-EmbedCPUOnly", "-LibrarianDetent", "full", "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M",
                               "-WebSearchBaseURL", fakeURL] + host.split(separator: " ").map(String.init) + extra
        app.launch()
        return app
    }
    private func field(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        let f = app.textFields.matching(pred).firstMatch
        return f.waitForExistence(timeout: 5) ? f : app.textViews.matching(pred).firstMatch
    }
    private func ask(_ app: XCUIApplication, _ q: String, general: Bool = true) {
        if general {
            let lib = app.buttons["Library mode"]
            if lib.waitForExistence(timeout: 30) { lib.tap() }
            XCTAssertTrue(app.buttons["General mode"].waitForExistence(timeout: 5), "could not switch to General")
        }
        let f = field(app); f.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); f.tap() }
        f.typeText(q)
        app.buttons["Send"].tap()
    }
    private func waitDone(_ app: XCUIApplication, timeout: Double = 60) {
        let stop = app.buttons["Stop answer"]
        _ = stop.waitForExistence(timeout: 8)
        let t0 = Date()
        while stop.exists && Date().timeIntervalSince(t0) < timeout { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 1.5)
    }
    private func requests(_ q: String) -> Int {
        guard let url = URL(string: fakeURL + "/chatlog") else { return 0 }
        let sem = DispatchSemaphore(value: 0); var n = 0
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // every model request (a Library turn's user content is a packet, not the question; a re-ask is a new one)
                n = arr.count
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return n
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[Regenerate] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    /// Tap ↻ on the latest answer; did a new request for `q` reach the model within `wait` seconds?
    private func regenerate(_ app: XCUIApplication, _ q: String, _ label: String, wait: Double = 25) -> Bool {
        Thread.sleep(forTimeInterval: 3)   // the chat's title request (after the first answer) lands before the count
        let before = requests(q)
        let down = app.buttons["Scroll to the latest message"]   // a long answer: ↻ is below the fold, as for T
        if down.exists { down.tap(); Thread.sleep(forTimeInterval: 1.5) }
        let r = app.buttons["Regenerate response"].firstMatch
        let shown = r.waitForExistence(timeout: 10)
        var hittable = false
        if shown {
            hittable = r.isHittable
            if !hittable {   // what covers it? (the elements whose frames hold ↻'s centre)
                let c = CGPoint(x: r.frame.midX, y: r.frame.midY)
                let over = app.descendants(matching: .any).allElementsBoundByIndex.prefix(400)
                    .filter { $0.frame.contains(c) && $0.frame.width < 430 }.map { "\($0.elementType.rawValue):\($0.identifier)/\($0.label.prefix(24)) \($0.frame.integral)" }
                note("\(label): ↻ at \(r.frame.integral) not hittable; elements at its centre: \(over)")
                // A hosted cell's accessibility frame can be stale after the transcript settles (live-31: ".global frames
                // in cells"); a small drag makes the collection view lay out again, then the frame is fresh.
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 12)))
                Thread.sleep(forTimeInterval: 1.5)
                hittable = r.isHittable
                note("\(label): after a 12 pt drag ↻ at \(r.frame.integral), hittable \(hittable)")
            }
            if hittable { r.tap() } else {
                // The reported frame isn't where ↻ is drawn (the Chats sheet: ~18 pt above — ChatViewCitationUI; a settled
                // Librarian transcript: ~55 pt below, under the model pill). Tap where a finger would: from the reported
                // spot upward, never onto the pill below it; the first tap that re-asks is where ↻ really is.
                // live-33: the frame is read once — a re-ask starts with the query rewrite, so ↻ goes before the count moves.
                let frame = r.frame
                for dy in [0.0, 18, -18, -36, -46, -55, -64] where requests(q) <= before && r.exists {
                    let p = CGPoint(x: frame.midX, y: frame.midY + dy)
                    if dy > 0 && app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model '")).firstMatch.frame.contains(p) { continue }
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
                    Thread.sleep(forTimeInterval: 1.5)
                    if requests(q) > before || !r.exists { note("\(label): the tap that re-asked was \(Int(dy)) pt from ↻'s reported centre") }
                }
            }
        }
        let t0 = Date()
        while requests(q) <= before && Date().timeIntervalSince(t0) < wait { Thread.sleep(forTimeInterval: 0.5) }
        let ok = requests(q) > before
        shot(app, "regenerate-\(label)")
        note("\(label): ↻ shown \(shown) (hittable \(hittable)) · new request \(ok) (\(before) → \(requests(q)))")
        return ok
    }

    func testRegenerateAfterPlainAnswer() throws {
        let app = try launch(["-webSearchEnabled", "NO"])
        let q = "What is a tide pool?"
        ask(app, q); waitDone(app)
        XCTAssertTrue(regenerate(app, q, "plain"), "↻ after a plain answer did nothing")
        app.terminate()
    }

    func testRegenerateAfterWebAnswer() throws {
        let app = try launch(["-webSearchEnabled", "YES", "-TavilyTestKey", "stub-key", "-webSearchProvider", "tavily"])
        let q = "Who is the current First Minister of the Lakeview Republic?"
        ask(app, q); waitDone(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Searched the web'")).firstMatch.exists,
                      "no search row (not a web turn)")
        XCTAssertTrue(regenerate(app, q, "web"), "↻ after a web answer did nothing")
        app.terminate()
    }

    /// The model fails after the search row was added: the banner's Retry must re-ask.
    func testRetryAfterFailedWebTurn() throws {
        let app = try launch(["-webSearchEnabled", "YES", "-TavilyTestKey", "stub-key", "-webSearchProvider", "tavily"])
        let q = "Who is the current flaky First Minister of the Lakeview Republic?"
        ask(app, q); waitDone(app)
        let retry = app.buttons["Retry"].firstMatch
        let shown = retry.waitForExistence(timeout: 20)
        let before = requests(q)
        if shown { retry.tap() }
        let t0 = Date()
        while requests(q) <= before && Date().timeIntervalSince(t0) < 25 { Thread.sleep(forTimeInterval: 0.5) }
        shot(app, "retry-after-failed-web-turn")
        note("failed web turn: Retry shown \(shown) · new request \(requests(q) > before) (\(before) → \(requests(q)))")
        XCTAssertTrue(shown, "no Retry after the failure")
        XCTAssertTrue(requests(q) > before, "Retry after a failed web turn did nothing")
        app.terminate()
    }

    func testRegenerateAfterStop() throws {
        let app = try launch(["-webSearchEnabled", "NO"])
        let q = "List every lighthouse slowly"
        ask(app, q)
        let stop = app.buttons["Stop answer"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "never streamed")
        Thread.sleep(forTimeInterval: 3); stop.tap(); Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(regenerate(app, q, "after-stop"), "↻ after Stop did nothing")
        let stop2 = app.buttons["Stop answer"].firstMatch
        if stop2.exists { stop2.tap() }   // the re-ask may already be over
        app.terminate()
    }

    /// The Chat view (the Chats list → a chat): ↻ on its answer re-asks.
    func testRegenerateInChatView() throws {
        let app = try launch(["-OpenChatsList", "-UITestSeedChats", "-webSearchEnabled", "NO"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'What connections'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded chat in the Chats list")
        row.tap(); Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(regenerate(app, "What connections do you find between my ideas?", "chat-view", wait: 40), "↻ in the Chat view did nothing")
        app.terminate()
    }
}
