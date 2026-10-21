import XCTest

/// live-32 (2) — T (TF 202610210043, his server model + Tavily): the presidents table stopped at Biden; the follow-up
/// correction was searched as written and dismissed Wikipedia as "not dated news"; the model thought out loud. Through the
/// real Librarian on the stub stack (`scripts/runaway/run.sh`), with the invented Lakeview Republic, whose First Minister
/// changed in March 2026: the web results are stale, the Wikipedia stand-in's article names the new holder, the fake model
/// answers from whatever evidence its request carries, and the LM Studio-style server thinks unless told not to.
/// RED: `WEBEV_RED=1` (TEST_RUNNER_WEBEV_RED) → `-Live31Web YES`.
final class WebEvidenceUI: XCTestCase {
    private var fakeURL: String { ProcessInfo.processInfo.environment["RUNAWAY_FAKE_URL"] ?? "http://127.0.0.1:11600" }
    private var red: [String] { ProcessInfo.processInfo.environment["WEBEV_RED"] == "1" ? ["-Live31Web", "YES"] : [] }
    private let q1 = "Who is the current First Minister of the Lakeview Republic?"

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full", "-webSearchEnabled", "YES",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M", "-WebSearchBaseURL", fakeURL]
            + host.split(separator: " ").map(String.init) + red + extra
        app.launch()
        return app
    }
    private func ask(_ app: XCUIApplication, _ q: String, first: Bool) {
        if first {
            let lib = app.buttons["Library mode"]
            if lib.waitForExistence(timeout: 30) { lib.tap() }
            XCTAssertTrue(app.buttons["General mode"].waitForExistence(timeout: 5), "could not switch to General")
        }
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        var field = app.textFields.matching(pred).firstMatch
        if !field.waitForExistence(timeout: 5) { field = app.textViews.matching(pred).firstMatch }
        field.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); field.tap() }
        field.typeText(q)
        app.buttons["Send"].tap()
        let stop = app.buttons["Stop answer"]
        _ = stop.waitForExistence(timeout: 10)
        let t0 = Date()
        while stop.exists && Date().timeIntervalSince(t0) < 90 { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 1.5)
    }
    private func get(_ path: String) -> [[String: Any]] {
        guard let url = URL(string: fakeURL + path) else { return [] }
        let sem = DispatchSemaphore(value: 0); var out: [[String: Any]] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { out = arr }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }
    private func shown(_ app: XCUIApplication, _ s: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch.exists
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[WebEvidence] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// No search key: Wikipedia alone grounds the current-holder question (keyless), with the app's User-Agent; the row says so.
    func testWikipediaWithoutAKey() throws {
        let w0 = get("/weblog").count
        let app = try launch([])
        ask(app, q1, first: true)
        let wiki = get("/weblog").dropFirst(w0).filter { $0["provider"] as? String == "wikipedia" }
        let current = shown(app, "Ilsa Vane"), stale = shown(app, "Mara Quill")
        shot(app, "wikipedia-no-key")
        note("no key: wikipedia requests \(wiki.map { "\($0["endpoint"] ?? "")".prefix(60) }) · Ilsa Vane \(current) · Mara Quill \(stale) · row \(shown(app, "Read Wikipedia"))")
        XCTAssertFalse(wiki.isEmpty, "Wikipedia wasn't asked")
        XCTAssertTrue(wiki.allSatisfy { ($0["endpoint"] as? String ?? "").contains("AirPad/") }, "the request doesn't name the app")
        XCTAssertTrue(shown(app, "Read Wikipedia"), "no 'Read Wikipedia' row")
        XCTAssertTrue(current, "the answer doesn't name the current holder")
        XCTAssertFalse(stale, "the answer names the former holder")
        app.terminate()
    }

    /// With a key (Tavily stub, stale results): the Wikipedia passage is [1], the turn has no "no article from today"; the
    /// correction is searched as a follow-up (the topic's current state), not as its own words.
    func testTavilyEvidenceAndCorrection() throws {
        let w0 = get("/weblog").count, c0 = get("/chatlog").count
        let app = try launch(["-TavilyTestKey", "stub-key", "-webSearchProvider", "tavily"])
        ask(app, q1, first: true)
        // the answer turn's request (the app makes other model calls too — a warm-up, a title)
        let chat1 = get("/chatlog").dropFirst(c0).filter { $0["app_results"] as? Bool == true }
        let current = shown(app, "Ilsa Vane")
        let w1 = get("/weblog").count
        ask(app, "you're not showing the current First Minister. Mara Quill is no longer First Minister", first: false)
        let web2 = get("/weblog").dropFirst(w1).filter { $0["provider"] as? String == "tavily" }.compactMap { $0["query"] as? String }
        let web1 = get("/weblog").dropFirst(w0).prefix(w1 - w0).map { "\($0["provider"] ?? "")" }
        shot(app, "evidence-and-correction")
        note("tavily: turn 1 providers \(web1) · model request \(chat1.first ?? [:]) · Ilsa Vane \(current) · turn 2 queries \(web2)")
        XCTAssertEqual(chat1.first?["wikipedia"] as? Bool, true, "the Wikipedia passage wasn't in the model's turn")
        XCTAssertEqual(chat1.first?["computed_fact"] as? Bool, false, "a current-state question got the today's-news framing")
        XCTAssertTrue(current, "the answer doesn't name the current holder")
        XCTAssertTrue(web2.contains { $0.lowercased().contains("first minister") && !$0.lowercased().contains("you're") },
                      "the correction was searched as its own words: \(web2)")
        app.terminate()
    }

    /// The Server route (an LM Studio-style thinking model): a web turn asks for reasoning off, and no thinking reaches the answer.
    func testServerThinkingOff() throws {
        let c0 = get("/chatlog").count
        let app = try launch(["-TavilyTestKey", "stub-key", "-webSearchProvider", "tavily", "-ClearHostPairing", "YES",
                              "-airpadLibrarianRoute", "endpoint", "-DebugEndpointURL", fakeURL])
        ask(app, q1, first: true)
        let all = get("/chatlog").dropFirst(c0).filter { $0["route"] as? String == "server" }
        let server = all.filter { $0["app_results"] as? Bool == true }   // the web turn's requests
        let leaked = shown(app, "Thinking Process")
        shot(app, "server-thinking-off")
        note("server: all requests \(all.map { "\($0["reasoning_effort"] ?? "nil"): \("\($0["user_head"] ?? "")".prefix(50))" }) · thinking in the answer \(leaked) · Ilsa Vane \(shown(app, "Ilsa Vane"))")
        XCTAssertFalse(server.isEmpty, "the server wasn't asked the web turn")
        XCTAssertTrue(server.allSatisfy { $0["reasoning_effort"] as? String == "none" }, "the web turn didn't ask for thinking off")
        XCTAssertFalse(leaked, "the model's thinking reached the answer")
        app.terminate()
    }
}
