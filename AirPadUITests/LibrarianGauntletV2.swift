import XCTest

/// Brief CH-0 — Gauntlet v2: drive the REAL Librarian UI (Simulator → real Host → Ollama on this Mac)
/// and record what T would SEE, turn by turn. This test does not grade; it captures. For each row it
/// types the question into the Ask field and taps Send (or taps Retry / "Read it in full"), waits for
/// the app's render tap to write that turn's `turn-NNN.json`, then reads the on-screen answer, expands
/// and reads the citation chips, expands and reads the Thought-process block, and writes
/// `ui-<row>.json` beside it. `scripts/gauntlet/grade.py` grades the pair (+ the Host observe log).
///
/// Driven by a run config (`scripts/gauntlet/run.sh` writes it) passed as
/// `TEST_RUNNER_GAUNTLET_CONFIG=<abs path>`:
///   { "outDir": "...", "baseArgs": [...], "turnTimeoutSec": 900,
///     "groups": [ { "group": "g01", "args": [...],
///                   "turns": [ { "row": "...", "case": "...", "action": "send|retry|offer", "question": "..." } ] } ] }
/// One group = one app launch = one fresh chat (`-GauntletUI` resets it); its turns share the chat.
final class LibrarianGauntletV2: XCTestCase {

    struct Turn: Decodable { let row: String; let `case`: String; let action: String; let question: String }
    struct Group: Decodable { let group: String; let args: [String]; let turns: [Turn]; let eject: Bool? }
    struct Config: Decodable {
        let outDir: String
        let baseArgs: [String]
        let turnTimeoutSec: Double?
        let groups: [Group]
    }

    func testRunGauntlet() throws {
        guard let cfgPath = ProcessInfo.processInfo.environment["GAUNTLET_CONFIG"] else {
            throw XCTSkip("GAUNTLET_CONFIG not set — run via scripts/gauntlet/run.sh")
        }
        let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: cfgPath)))
        let out = URL(fileURLWithPath: cfg.outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let turnTimeout = cfg.turnTimeoutSec ?? 900

        for g in cfg.groups {
            // Adversarial A4 (cold auto-load): eject everything from Ollama BEFORE launching, so the first
            // question meets nothing resident. The grader verifies it really was cold (V7, from ps.log).
            var ejectedAt: Double? = nil
            if g.eject == true { ejectedAt = ejectAllModels() }
            let app = XCUIApplication()
            app.launchArguments = cfg.baseArgs + g.args + ["-OpenMap", "-GauntletUI", "YES", "-GauntletTapDir", cfg.outDir]
            app.launch()
            log("GROUP \(g.group) launched args=\(g.args)")
            for t in g.turns {
                let before = turnFiles(out)
                let t0 = Date()
                var note = ""
                switch t.action {
                case "look":
                    // No input: just let the screen settle and capture it (e.g. a REOPENED chat).
                    Thread.sleep(forTimeInterval: 8)
                case "offer":
                    let offer = app.buttons["Read it in full"]
                    if offer.waitForExistence(timeout: 10) { offer.tap() } else { note = "NO OFFER BUTTON" }
                case "retry":
                    // `-GauntletFailFirstSend` (group arg) makes this send fail on a dead port; then Retry.
                    ask(app, t.question)
                    _ = waitForTurnFiles(out, count: before.count + 1, timeout: 120)
                    let retry = app.buttons["Retry"]
                    if retry.waitForExistence(timeout: 15) { retry.tap() } else { note = "NO RETRY BUTTON (the forced failure did not surface)" }
                default:
                    ask(app, t.question)
                }
                let expected = before.count + (t.action == "retry" ? 2 : (t.action == "look" ? 0 : 1))
                hungNote = nil
                let hangsAtStart = hangMarkers(out)
                var ok = note.isEmpty ? waitForTurnFiles(out, count: expected, timeout: turnTimeout) : false
                if hangMarkers(out) > hangsAtStart { hungNote = hungNote ?? "APP HUNG — main thread stopped; the watchdog terminated it"; ok = false }
                if let h = hungNote { note = h }
                // The tap writes at turn end, a beat before the view commits — let the bubble settle.
                Thread.sleep(forTimeInterval: 1.5)
                let seq = turnFiles(out).count
                var rec: [String: Any] = ["row": t.row, "case": t.case, "group": g.group, "action": t.action,
                                          "question": t.question, "seq": seq, "turnCompleted": ok,
                                          "wallSec": Date().timeIntervalSince(t0)]
                if !note.isEmpty { rec["driverNote"] = note }
                if let e = ejectedAt { rec["ejectedAtEpoch"] = e; ejectedAt = nil }
                if hungNote == nil { rec.merge(captureScreen(app)) { a, _ in a } }
                write(rec, to: out.appendingPathComponent("ui-\(t.row).json"))
                log("ROW \(t.row) case=\(t.case) seq=\(seq) ok=\(ok) \(note)")
                if hungNote != nil { break }   // the app was terminated — the rest of this chat can't run
            }
            app.terminate()
        }
    }

    // MARK: driving

    private func ask(_ app: XCUIApplication, _ q: String) {
        let field = askField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Ask field never appeared")
        field.tap()
        field.typeText(q)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button missing")
        send.tap()
    }

    private func askField(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        let tf = app.textFields.matching(pred).firstMatch
        if tf.exists { return tf }
        let tv = app.textViews.matching(pred).firstMatch
        if tv.exists { return tv }
        return tf.waitForExistence(timeout: 20) ? tf : tv
    }

    /// POST keep_alive:0 for every loaded model, then wait until /api/ps is empty. Returns the epoch time
    /// the eject completed (nil if Ollama couldn't be reached / never emptied — V7 then ABORTS the row).
    private func ejectAllModels() -> Double? {
        let base = URL(string: "http://127.0.0.1:11434")!
        func get(_ path: String) -> [String: Any]? {
            var out: [String: Any]? = nil
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: base.appendingPathComponent(path)) { d, _, _ in
                out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }; sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
            return out
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let models = (get("api/ps")?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if models.isEmpty { log("EJECT done"); return Date().timeIntervalSince1970 }
            for m in models {
                var req = URLRequest(url: base.appendingPathComponent("api/generate"))
                req.httpMethod = "POST"
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": m, "keep_alive": 0])
                let sem = DispatchSemaphore(value: 0)
                URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
                _ = sem.wait(timeout: .now() + 20)
            }
            Thread.sleep(forTimeInterval: 2)
        }
        log("EJECT FAILED — models still resident")
        return nil
    }

    // MARK: on-screen capture

    private func captureScreen(_ app: XCUIApplication) -> [String: Any] {
        var r: [String: Any] = [:]
        // Bring the end of the latest answer (and its footer) into the materialised region.
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        let answers = app.descendants(matching: .any).matching(identifier: "chat.answer").allElementsBoundByIndex
        r["onScreenAnswer"] = answers.last?.label ?? NSNull()
        r["answerBubbleCount"] = answers.count
        r["errorBanner"] = app.buttons["Retry"].exists

        // Citation chips: expand the LATEST footer, read its rows, collapse it again so the next turn's
        // read can't pick up this message's rows.
        let showPred = NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' sources'")
        let shows = app.buttons.matching(showPred).allElementsBoundByIndex
        var chips: [String] = []
        if let show = shows.last, show.exists {
            r["sourcesHeader"] = show.label
            show.tap()
            Thread.sleep(forTimeInterval: 0.6)
            chips = app.descendants(matching: .any).matching(identifier: "chat.source").allElementsBoundByIndex.map { $0.label }
            let hide = app.buttons["Hide sources"]
            if hide.exists { hide.tap() }
        }
        r["onScreenChips"] = chips

        // Thought process: present only for the latest turn (ephemeral). Expand, read, collapse.
        let header = app.buttons["Thought process"]
        r["thoughtHeaderPresent"] = header.exists
        if header.exists {
            header.tap()
            Thread.sleep(forTimeInterval: 0.6)
            r["onScreenThought"] = app.descendants(matching: .any).matching(identifier: "chat.thought").firstMatch.label
            header.tap()
        }
        return r
    }

    // MARK: files

    private func turnFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("turn-") && $0.hasSuffix(".json") }.sorted()
    }

    private func waitForTurnFiles(_ dir: URL, count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let hangsBefore = hangMarkers(dir)
        while Date() < deadline {
            if turnFiles(dir).count >= count { return true }
            if hangMarkers(dir) > hangsBefore { hungNote = "APP HUNG — main thread stopped; the watchdog terminated it"; return false }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    /// Set when the orchestrator's watchdog killed a hung app during this row.
    private var hungNote: String? = nil
    private func hangMarkers(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("hung-") }.count
    }

    private func write(_ obj: [String: Any], to url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
    }

    private func log(_ s: String) { print("GAUNTLET_V2 \(s)") }
}
