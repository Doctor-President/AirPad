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
                    "-GauntletTapDir", "app-tmp", "-OpenMap", "-GauntletUI", "YES",
                    "-GauntletSeedChat", ProcessInfo.processInfo.environment["PERF_TURNS"] ?? "100"]
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

    private func frames(_ app: XCUIApplication) -> (frames: Int, hitches: Int, hitchMs: Double, t: Double)? {
        let l = app.descendants(matching: .any).matching(identifier: "gauntlet.frames").firstMatch
        guard l.waitForExistence(timeout: 5) else { return nil }
        var d: [String: Double] = [:]
        for kv in l.label.split(separator: " ") { let p = kv.split(separator: "="); if p.count == 2 { d[String(p[0])] = Double(p[1]) } }
        guard let f = d["frames"], let h = d["hitches"], let ms = d["hitchMs"], let t = d["t"] else { return nil }
        return (Int(f), Int(h), ms, t)
    }

    func testOpenAndScroll100TurnChat() { run(label: "FREEZE FIX (production): all eager ≤ 40 messages, else option 1", extra: []) }
    /// A/B baseline for the freeze fix: option 1 (lazy history + eager latest exchange only).
    func testOpenAndScroll100TurnChatSplitBaseline() { run(label: "split: lazy history + eager live exchange (option 1)", extra: ["-TranscriptEagerAll", "0"]) }
    /// A/B baseline: the pre-fix LazyVStack on the same seeded chat (DEBUG `-FreezeLazyStack`).
    func testOpenAndScroll100TurnChatLazyBaseline() { run(label: "lazy-LazyVStack (pre-fix)", extra: ["-FreezeLazyStack", "YES"]) }

    private func run(label: String, extra: [String]) {
        let app = XCUIApplication()
        launch(app, extra: extra)
        print("PERF [\(label)] first-open \(metric(app, prefix: "open#1") ?? "TIMEOUT")")

        // Scroll hitches: drag (finger down) AND deceleration (the fling after release), both directions.
        let opts = XCTMeasureOptions(); opts.iterationCount = 5
        print("PERF [\(label)] measuring scroll")
        let f0 = frames(app)
        measure(metrics: [XCTOSSignpostMetric.scrollDraggingMetric, XCTOSSignpostMetric.scrollDecelerationMetric], options: opts) {
            for _ in 0..<4 { app.swipeDown(velocity: .fast) }
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }
        Thread.sleep(forTimeInterval: 1)
        let f1 = frames(app)
        // Simulator main-thread frame pacing over the whole scroll window (the device-only hitch metrics are absent here).
        if let a = f0, let b = f1, b.t > a.t {
            let secs = b.t - a.t
            print(String(format: "PERF [\(label)] scroll frames: %.1f fps · %d hitches · %.0f ms/s hitch time over %.1f s",
                         Double(b.frames - a.frames) / secs, b.hitches - a.hitches, (b.hitchMs - a.hitchMs) / secs, secs))
        } else { print("PERF [\(label)] scroll frames: NO FRAME METER") }

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
