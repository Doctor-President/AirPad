import XCTest

/// live-28 (A2) — Settings → Web search has a switch that keeps the key, and a provider picker (Tavily / Brave). Through
/// the real Librarian on the runaway stub stack (`scripts/runaway/run.sh`: a scratch Host from source → the fake Ollama,
/// which also stands in for both search APIs via `-WebSearchBaseURL` and logs every search request to web.jsonl).
/// Off with a key present → General answers as with no key: no search request (the script counts them), the dated
/// line, no "+ web". On → Brave is searched; Tavily picked → Tavily is searched. Synthetic questions; each row asks its
/// own so the script can attribute the requests. RED: `-WebSearchSwitchIgnored YES` (main's rule: a key → search).
final class WebSearchSwitchUI: XCTestCase {
    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let port = ProcessInfo.processInfo.environment["RUNAWAY_FAKE_URL"] ?? "http://127.0.0.1:11600"
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M", "-WebSearchBaseURL", port]
            + host.split(separator: " ").map(String.init) + extra
            + (ProcessInfo.processInfo.environment["WEBSWITCH_RED"] == "1" ? ["-WebSearchSwitchIgnored", "YES"] : [])
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
    private func caption(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.provenance").firstMatch
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[WebSwitch] \(s)") }

    /// Off, with a Brave key present: no search, the dated line, no "+ web".
    func testSwitchOffNeverSearches() throws {
        let app = try launch(["-BraveTestKey", "stub-key", "-webSearchEnabled", "NO"])
        askGeneral(app, "Make a table of the Lakeview harbour masters and whether each is living")
        XCTAssertTrue(caption(app).waitForExistence(timeout: 60), "no answer")
        let dated = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH \"From the model's training data\"")).firstMatch
        let datedShown = dated.waitForExistence(timeout: 5)
        note("off: caption '\(caption(app).label)' · dated line \(datedShown ? "shown" : "MISSING")")
        XCTAssertTrue(datedShown, "off answers as with no key: the 'may be out of date' line")
        XCTAssertFalse(caption(app).label.contains("+ web"), "off never searches")
    }

    /// On (Brave): the current-state question is searched.
    func testSwitchOnSearchesBrave() throws {
        let app = try launch(["-BraveTestKey", "stub-key", "-webSearchEnabled", "YES", "-webSearchProvider", "brave"])
        askGeneral(app, "Make a table of the Lakeview lock keepers and whether each is living")
        XCTAssertTrue(caption(app).waitForExistence(timeout: 90), "no answer")
        note("brave: caption '\(caption(app).label)'")
        XCTAssertTrue(caption(app).label.contains("+ web"), "on → it searched")
    }

    /// Tavily picked: the same question goes to Tavily.
    func testTavilySearches() throws {
        let app = try launch(["-TavilyTestKey", "stub-key", "-webSearchEnabled", "YES", "-webSearchProvider", "tavily"])
        askGeneral(app, "Make a table of the Lakeview ferry captains and whether each is living")
        XCTAssertTrue(caption(app).waitForExistence(timeout: 90), "no answer")
        note("tavily: caption '\(caption(app).label)'")
        XCTAssertTrue(caption(app).label.contains("+ web"), "Tavily → it searched")
    }
}
