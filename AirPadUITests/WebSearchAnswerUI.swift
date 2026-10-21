import XCTest

/// live-29 (B3) — T (Tavily): "Who is the current president of the United States" searched (3 results, "+ web") and still
/// showed "From the model's training data — may be out of date"; the question went to Tavily's NEWS topic first
/// (midterm articles); a snippet showed "#### Tags". Through the real Librarian on the runaway stub stack
/// (`scripts/runaway/run.sh`: a scratch Host → the fake Ollama, which stands in for both search APIs, logs which
/// endpoint / topic each request asked — GET /weblog — and answers this question citing none of its results).
/// For both providers: a general-web search first, "+ web", never the training-data line, "The search results didn't
/// confirm this." under the uncited answer, and no Markdown in the result rows.
final class WebSearchAnswerUI: XCTestCase {
    private var fakeURL: String { ProcessInfo.processInfo.environment["RUNAWAY_FAKE_URL"] ?? "http://127.0.0.1:11600" }

    private func launch(_ extra: [String], base: String? = nil) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M", "-WebSearchBaseURL", base ?? fakeURL]
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
        field.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); field.tap() }
        field.typeText(q)
        app.buttons["Send"].tap()
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[WebAnswer] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    /// The fake provider's request log for this question: [(provider, endpoint)] in order.
    private func requests(for q: String) -> [(String, String)] {
        guard let url = URL(string: fakeURL + "/weblog") else { return [] }
        let sem = DispatchSemaphore(value: 0); var out: [(String, String)] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                out = arr.filter { (($0["query"] as? String) ?? "").lowercased().contains("president") }
                    .map { (($0["provider"] as? String) ?? "", ($0["endpoint"] as? String) ?? "") }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    private func presidentRow(provider: String, keyArg: String) throws {
        let app = try launch([keyArg, "stub-key", "-webSearchEnabled", "YES", "-webSearchProvider", provider])
        let q = "Who is the current president of the United States?"
        askGeneral(app, q)
        let caption = app.descendants(matching: .any).matching(identifier: "chat.provenance").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 90), "no answer")
        Thread.sleep(forTimeInterval: 1)
        let anyText = { (p: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", p)).firstMatch }
        let dated = anyText("From the model's training data").exists
        let unconfirmed = anyText("The search results didn't confirm this").exists
        let markdown = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '####' OR label CONTAINS '### '")).firstMatch.exists
        let reqs = requests(for: q).filter { $0.0 == provider }
        note("\(provider): caption '\(caption.label)' · training-data line \(dated ? "SHOWN" : "none") · didn't-confirm \(unconfirmed ? "shown" : "MISSING") · markdown on screen \(markdown ? "YES" : "no") · requests \(reqs.map { $0.1 })")
        shot(app, "web-answer-\(provider)")
        XCTAssertTrue(caption.label.contains("+ web"), "it searched")
        XCTAssertFalse(dated, "after a search the training-data line never shows")
        XCTAssertTrue(unconfirmed, "an answer no result supports says the search didn't confirm it")
        XCTAssertFalse(markdown, "Markdown from a result showed")
        XCTAssertEqual(reqs.first?.1, provider == "tavily" ? "general" : "web", "an office-holder question searches the general web first")
    }

    // MARK: live-31 (3) — a current-state question on the Host path searches without being asked

    /// The fake's chat-request log: did each request's user turn carry the app's results, the system prompt the clause,
    /// any social / video host anywhere in it.
    private func chatlog() -> [[String: Any]] {
        guard let url = URL(string: fakeURL + "/chatlog") else { return [] }
        let sem = DispatchSemaphore(value: 0); var out: [[String: Any]] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { out = arr }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }
    private func allWeb() -> [String] {
        guard let url = URL(string: fakeURL + "/weblog") else { return [] }
        let sem = DispatchSemaphore(value: 0); var out: [String] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { out = arr.compactMap { $0["query"] as? String } }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }
    /// `HOSTWEB_RED=1` (TEST_RUNNER_HOSTWEB_RED) — the same rows on live-30's Host rule (`-HostWebLive30 YES`).
    private var hostRed: [String] { ProcessInfo.processInfo.environment["HOSTWEB_RED"] == "1" ? ["-HostWebLive30", "YES"] : [] }
    private func waitAnswers(_ app: XCUIApplication, _ n: Int) -> Bool {
        let captions = app.descendants(matching: .any).matching(identifier: "chat.provenance")
        let t0 = Date()
        while captions.count < n && Date().timeIntervalSince(t0) < 90 { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 1)
        return captions.count >= n
    }

    /// T (TF 202610201518, Host path): a list of the presidents, their parties and causes of death came back unsearched,
    /// leaving out one who died after the model's training. Synthetic: the app searches up front (its own query, the
    /// year rule), the results reach the model IN the turn as the app's search, social / video hosts never reach it, the
    /// answer cites them; the follow-up "which of them was the most recent to go?" is searched again.
    private func currentStateRow(provider: String, keyArg: String) throws {
        let app = try launch([keyArg, "stub-key", "-webSearchEnabled", "YES", "-webSearchProvider", provider] + hostRed)
        let before = (web: allWeb().count, chat: chatlog().count)
        let q = "Make a table of the US presidents, their parties and their causes of death"
        askGeneral(app, q)
        XCTAssertTrue(waitAnswers(app, 1), "no answer")
        let caption = app.descendants(matching: .any).matching(identifier: "chat.provenance").firstMatch.label
        let dated = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'From the model'")).firstMatch.exists
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Searched the web'")).firstMatch.exists
        let web1 = Array(allWeb().dropFirst(before.web)), chat1 = Array(chatlog().dropFirst(before.chat))
        shot(app, "current-state-\(provider)")
        note("\(provider) turn 1: caption '\(caption)' · search row \(row) · training-data line \(dated) · web queries \(web1) · model requests \(chat1)")
        XCTAssertTrue(caption.contains("+ web"), "the answer isn't from a search: '\(caption)'")
        XCTAssertTrue(row, "no 'Searched the web' row")
        XCTAssertFalse(dated, "the training-data line under a searched answer")
        XCTAssertTrue(web1.contains { $0.lowercased().contains("presidents") && $0.contains(String(Calendar.current.component(.year, from: Date()))) },
                      "the app didn't search up front with its own query (the year rule): \(web1)")
        XCTAssertEqual(chat1.first?["app_results"] as? Bool, true, "the results weren't in the model's turn: \(chat1.first ?? [:])")
        XCTAssertEqual(chat1.first?["clause"] as? Bool, true, "the system prompt doesn't say the results are the app's search")
        XCTAssertFalse(chat1.contains { $0["social"] as? Bool == true }, "a social / video host reached the model")

        let mid = (web: allWeb().count, chat: chatlog().count)
        let f = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")).firstMatch
        let field = f.exists ? f : app.textViews.matching(NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")).firstMatch
        field.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); field.tap() }
        field.typeText("And which of them was the most recent to go?")
        app.buttons["Send"].tap()
        XCTAssertTrue(waitAnswers(app, 2), "no follow-up answer")
        let web2 = Array(allWeb().dropFirst(mid.web)), chat2 = Array(chatlog().dropFirst(mid.chat))
        shot(app, "current-state-\(provider)-follow-up")
        note("\(provider) follow-up: web queries \(web2) · model requests \(chat2)")
        XCTAssertTrue(web2.contains { $0.lowercased().contains("presidents") && !$0.lowercased().contains("query") },
                      "the follow-up wasn't searched with the topic carried (a clean query): \(web2)")
        XCTAssertEqual(chat2.first?["app_results"] as? Bool, true, "the follow-up's results weren't in the model's turn")
        app.terminate()
    }
    func testTavilyCurrentStateList() throws { try currentStateRow(provider: "tavily", keyArg: "-TavilyTestKey") }
    func testBraveCurrentStateList() throws { try currentStateRow(provider: "brave", keyArg: "-BraveTestKey") }

    /// A provider that doesn't answer (a closed port): no search ran, so the answer carries the training-data line — never
    /// "the search results didn't confirm this", which claims a search.
    private func providerDownRow(provider: String, keyArg: String) throws {
        let app = try launch([keyArg, "stub-key", "-webSearchEnabled", "YES", "-webSearchProvider", provider] + hostRed,
                             base: "http://127.0.0.1:1")
        askGeneral(app, "Which world leaders have died since 2024?")
        XCTAssertTrue(waitAnswers(app, 1), "no answer")
        let anyText = { (p: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", p)).firstMatch.exists }
        let dated = anyText("From the model's training data"), unconfirmed = anyText("The search results didn't confirm this")
        shot(app, "provider-down-\(provider)")
        note("\(provider) down: training-data line \(dated) · didn't-confirm \(unconfirmed)")
        XCTAssertTrue(dated, "no search ran, but the answer doesn't say it's from training data")
        XCTAssertFalse(unconfirmed, "'didn't confirm' claims a search that never ran")
        app.terminate()
    }
    func testTavilyProviderDown() throws { try providerDownRow(provider: "tavily", keyArg: "-TavilyTestKey") }
    func testBraveProviderDown() throws { try providerDownRow(provider: "brave", keyArg: "-BraveTestKey") }

    func testTavilyPresidentQuestion() throws { try presidentRow(provider: "tavily", keyArg: "-TavilyTestKey") }
    func testBravePresidentQuestion() throws { try presidentRow(provider: "brave", keyArg: "-BraveTestKey") }
}
