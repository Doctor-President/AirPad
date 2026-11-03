import XCTest

/// 1.1-D — the user's-own-server screens, tapped for real against the FAKE Ollama (`scripts/server/ui_test.sh` starts
/// it and passes TEST_RUNNER_FAKE_OLLAMA=http://127.0.0.1:<port>). Settings → Your own models shows what answered;
/// its Models screen loads a model (which becomes the pick, ✓), ejects it, and downloads a curated model with progress;
/// the pill's quick switcher lists the server's models and picks one. Skipped without the fake.
final class ServerModelsUI: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        // Each test starts from a fresh fake server (nothing loaded, the two starting models).
        guard let fake, let u = URL(string: fake + "/_fake/reset") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"
        let done = expectation(description: "reset")
        URLSession.shared.dataTask(with: r) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
    }

    private var fake: String? { ProcessInfo.processInfo.environment["FAKE_OLLAMA"] }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", screen, "-DebugEndpointURL", fake ?? "", "-airpadLibrarianRoute", "endpoint",
                               "-UITestLibrary", "-UITestLibraryFresh", "-EmbedCPUOnly"]
        app.launch()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
    private func label(_ app: XCUIApplication, contains s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testSettingsLoadEjectDownload() throws {
        try XCTSkipIf(fake == nil, "needs the fake Ollama (scripts/server/ui_test.sh)")
        let app = launch("settings-advanced")
        let row = app.buttons["settings.serverModels"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the detected-server row")
        XCTAssertTrue(label(app, contains: "Ollama 0.13.2").exists, "Settings names what answered")
        shot(app, "advanced")
        row.tap()
        XCTAssertTrue(app.staticTexts["server.kind"].waitForExistence(timeout: 10))

        // Load Llama 3.2 → it becomes the pick (loaded, ✓) and its action turns into Eject.
        let llama = app.buttons["modelAction.llama3.2:latest"]
        XCTAssertTrue(llama.waitForExistence(timeout: 10))
        XCTAssertEqual(llama.label, "Load")
        llama.tap()
        let eject = NSPredicate(format: "label == 'Eject'")
        expectation(for: eject, evaluatedWith: llama); waitForExpectations(timeout: 15)
        XCTAssertTrue(label(app, contains: "Chats use Llama 3.2").exists, "the header names the new pick")
        XCTAssertTrue(label(app, contains: "Context 20,480 tokens").exists, "the loaded window is shown")
        shot(app, "loaded")

        // Eject it → Load again.
        llama.tap()
        expectation(for: NSPredicate(format: "label == 'Load'"), evaluatedWith: llama); waitForExpectations(timeout: 15)

        // Download the recommended 4B → it moves to Installed (its action becomes Load).
        let q4 = app.buttons["modelAction.qwen3:4b-instruct-2507-q4_K_M"]
        XCTAssertTrue(q4.waitForExistence(timeout: 5))
        XCTAssertEqual(q4.label, "Download")
        q4.tap()
        expectation(for: NSPredicate(format: "label ENDSWITH '%'"), evaluatedWith: q4); waitForExpectations(timeout: 10)
        shot(app, "downloading")
        expectation(for: NSPredicate(format: "label == 'Load'"), evaluatedWith: q4); waitForExpectations(timeout: 20)

        // A refused download shows the server's own words.
        let q30 = app.buttons["modelAction.qwen3:30b-a3b-instruct-2507-q4_K_M"]
        q30.tap()
        XCTAssertTrue(label(app, contains: "not enough disk space").waitForExistence(timeout: 10), "the refusal, verbatim")
        shot(app, "refused")
    }

    func testQuickSwitcherPicksAServerModel() throws {
        try XCTSkipIf(fake == nil, "needs the fake Ollama (scripts/server/ui_test.sh)")
        let app = launch("modelpicker")
        let row = app.buttons["picker.endpoint.llama3.2:latest"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the server's models are listed")
        shot(app, "switcher")
        row.tap()
        // The pick persists: relaunch and Llama 3.2 carries the ✓ (loaded by the pick).
        app.terminate()
        let again = launch("modelpicker")
        let picked = again.buttons["picker.endpoint.llama3.2:latest"]
        XCTAssertTrue(picked.waitForExistence(timeout: 15))
        XCTAssertTrue(label(again, contains: "Loaded · Context 20,480 tokens").waitForExistence(timeout: 10), "loaded by the pick")
        shot(again, "picked")
    }
}
