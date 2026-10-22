import XCTest

/// live-32 (1)/(3) — LIVE web turns through the real Librarian (General): each chat in `LIVE_CHATS` (a JSON list of
/// question lists) is asked in a fresh launch, turn by turn, waiting for each answer's caption. Real search providers,
/// a real model (T's server, or a scratch Host's Ollama). What the turn did is in the app's `-WebTrace` file, which
/// `scripts/live/run.sh` collects and grades. The key arrives only through the runner's environment (`LIVE_KEY`).
final class LiveWebUI: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// live-33 — a question starting "LIB:" is asked in Library mode (it must not search).
    private func askGeneral(_ app: XCUIApplication, _ q0: String, first: Bool) {
        let library = q0.hasPrefix("LIB:")
        let q = library ? String(q0.dropFirst(4)) : q0
        if first && !library {
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
    }

    func testLiveChats() throws {
        guard let raw = env["LIVE_CHATS"], let data = raw.data(using: .utf8),
              let chats = try JSONSerialization.jsonObject(with: data) as? [[String]] else {
            throw XCTSkip("needs LIVE_CHATS (scripts/live/run.sh)")
        }
        let turnTimeout = Double(env["LIVE_TURN_TIMEOUT"] ?? "") ?? 300
        for (i, chat) in chats.enumerated() {
            let app = XCUIApplication()
            app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-OpenMap", "-GauntletUI", "YES", "-EmbedCPUOnly",
                                   "-LibrarianDetent", "full", "-WebTrace", "YES", "-webSearchEnabled", "YES", "-WikipediaLive", "YES"]
                + (env["LIVE_ARGS"] ?? "").split(separator: " ").map(String.init)
            if let k = env["LIVE_KEY"], !k.isEmpty, let arg = env["LIVE_KEY_ARG"] { app.launchArguments += [arg, k] }
            app.launch()
            // A turn is over when its Stop button has come and gone (an earlier answer's caption may have scrolled out
            // of the collection view, so counting captions misses the end of a later turn).
            let stop = app.buttons["Stop answer"]
            for (n, q) in chat.enumerated() {
                askGeneral(app, q, first: n == 0)
                let t0 = Date()
                _ = stop.waitForExistence(timeout: 15)
                while stop.exists && Date().timeIntervalSince(t0) < turnTimeout { Thread.sleep(forTimeInterval: 1) }
                let secs = Int(Date().timeIntervalSince(t0))
                let done = !stop.exists
                print("[LiveWeb] chat \(i + 1) turn \(n + 1): \(done ? "finished" : "STILL ANSWERING") after ~\(secs) s")
                if !done { break }
                Thread.sleep(forTimeInterval: 1.5)
            }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "live-chat-\(i + 1)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}
