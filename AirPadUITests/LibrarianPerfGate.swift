import XCTest

/// Brief CH follow-up perf gate — the eager-`VStack` transcript must stay fast on a LONG chat.
/// Seeds a 100-turn chat (`-GauntletSeedChat 100`, isolated `-UITestLibrary`, dead-port pairing), then:
///   1. open time (first open + a Back → Resume re-open), measured IN-APP from "open" to the transcript's
///      first committed layout, plus the longest main-thread stall in the 2 s after (`gauntlet.metrics`);
///   2. scroll hitches while dragging through the whole chat (XCTOSSignpostMetric.scrollDraggingMetric).
/// Extra launch args (e.g. `-FreezeLazyStack YES` for the pre-fix A/B) via TEST_RUNNER_PERF_EXTRA="a b c".
/// Results print as `PERF …` lines.
final class LibrarianPerfGate: XCTestCase {

    private func launch(_ app: XCUIApplication, extra: [String] = []) {
        let deadKey = Data(count: 32).base64EncodedString()
        var args = ["-UITestLibrary", "-UITestLibraryFresh", "-EmbedCPUOnly",
                    "-DebugHostURL", "http://127.0.0.1:1", "-DebugHostSecret", "lab", "-DebugHostPubKey", deadKey,
                    "-GauntletTapDir", "app-tmp", "-OpenMap", "-GauntletUI", "YES", "-GauntletSeedChat", "100"]
        if let e = ProcessInfo.processInfo.environment["PERF_EXTRA"], !e.isEmpty {
            args += e.split(separator: " ").map(String.init)
        }
        args += extra
        app.launchArguments = args
        app.launch()
    }

    private func metric(_ app: XCUIApplication, prefix: String, timeout: TimeInterval = 30) -> String? {
        let m = app.descendants(matching: .any).matching(identifier: "gauntlet.metrics").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if m.exists, m.label.hasPrefix(prefix) { return m.label }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    func testOpenAndScroll100TurnChat() { run(label: "split: lazy history + eager live exchange (option 1, production)", extra: []) }
    /// A/B baseline: the pre-fix LazyVStack on the same seeded chat (DEBUG `-FreezeLazyStack`).
    func testOpenAndScroll100TurnChatLazyBaseline() { run(label: "lazy-LazyVStack (pre-fix)", extra: ["-FreezeLazyStack", "YES"]) }

    private func run(label: String, extra: [String]) {
        let app = XCUIApplication()
        launch(app, extra: extra)
        print("PERF [\(label)] first-open \(metric(app, prefix: "open#1") ?? "TIMEOUT")")

        // Scroll hitches: drag (finger down) AND deceleration (the fling after release), both directions.
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        print("PERF [\(label)] measuring scroll")
        measure(metrics: [XCTOSSignpostMetric.scrollDraggingMetric, XCTOSSignpostMetric.scrollDecelerationMetric], options: opts) {
            for _ in 0..<4 { app.swipeDown(velocity: .fast) }
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }

        // Re-open: Back to the Librarian home, then Resume the chat.
        let back = app.buttons["Back to Librarian home"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
            let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resume chat'")).firstMatch
            if resume.waitForExistence(timeout: 8) {
                resume.tap()
                print("PERF [\(label)] re-open \(metric(app, prefix: "open#2") ?? "TIMEOUT")")
            } else { print("PERF [\(label)] re-open NO RESUME BUTTON") }
        } else { print("PERF [\(label)] re-open NO BACK BUTTON") }
        app.terminate()
    }
}
