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

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M", "-WebSearchBaseURL", fakeURL]
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

    func testTavilyPresidentQuestion() throws { try presidentRow(provider: "tavily", keyArg: "-TavilyTestKey") }
    func testBravePresidentQuestion() throws { try presidentRow(provider: "brave", keyArg: "-BraveTestKey") }
}
