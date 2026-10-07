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
        /// Physical device: no Mac paths. The tap writes inside the app (`app-tmp`), turn completion is read
        /// off the UI (answer-bubble count), a hang is the app's own self-watchdog exiting it, and results
        /// go to the test log as `GAUNTLET_V2 RESULT {json}` lines.
        let device: Bool?
        /// Device mode: the app's `-GauntletSelfWatchdog` seconds (the driver waits this + 15 s on the app's
        /// RUN STATE — no UI query — after each send, so a hung app exits before anything queries it).
        let watchdogSec: Double?
    }

    func testRunGauntlet() throws {
        let env = ProcessInfo.processInfo.environment
        let cfgData: Data
        if let b = env["GAUNTLET_CONFIG_B64"], let d = Data(base64Encoded: b) { cfgData = d }
        else if let cfgPath = env["GAUNTLET_CONFIG"] { cfgData = try Data(contentsOf: URL(fileURLWithPath: cfgPath)) }
        else { throw XCTSkip("GAUNTLET_CONFIG(_B64) not set — run via scripts/gauntlet/run.sh / lab.sh / lab_device.sh") }
        let cfg = try JSONDecoder().decode(Config.self, from: cfgData)
        let isDevice = cfg.device == true
        let out = URL(fileURLWithPath: cfg.outDir, isDirectory: true)
        if !isDevice { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let turnTimeout = cfg.turnTimeoutSec ?? 900

        for g in cfg.groups {
            // Adversarial A4 (cold auto-load): eject everything from Ollama BEFORE launching, so the first
            // question meets nothing resident. The grader verifies it really was cold (V7, from ps.log).
            var ejectedAt: Double? = nil
            if g.eject == true { ejectedAt = ejectAllModels() }
            let app = XCUIApplication()
            app.launchArguments = cfg.baseArgs + g.args + ["-OpenMap", "-GauntletUI", "YES", "-GauntletTapDir", isDevice ? "app-tmp" : cfg.outDir]
            // CH ruling 9 — the LIVE Brave run: T's key arrives only through the test runner's environment
            // (`TEST_RUNNER_GAUNTLET_BRAVE_KEY`), never through the run config, so it is never written to a file.
            if let k = env["GAUNTLET_BRAVE_KEY"], !k.isEmpty { app.launchArguments += ["-BraveTestKey", k] }
            app.launch()
            log("GROUP \(g.group) launched args=\(g.args)")
            for t in g.turns {
                let before = isDevice ? [] : turnFiles(out)
                let answersBefore = isDevice ? app.descendants(matching: .any).matching(identifier: "chat.answer").count : 0
                let lastAnswerBefore = isDevice ? (screenOrdered(app.descendants(matching: .any).matching(identifier: "chat.answer")).last?.label ?? "") : ""
                let t0 = Date()
                var note = ""
                var mode: String? = nil
                switch t.action {
                case "look":
                    // No input: just let the screen settle and capture it (e.g. a REOPENED chat).
                    Thread.sleep(forTimeInterval: 8)
                case "general":
                    // CH ruling 9 — the pillar rows through the REAL UI: tap the Library toggle over to General
                    // (the gauntlet launch resets it to Library), then ask. The mode reached is recorded (V5).
                    if !app.buttons["General mode"].exists {
                        let lib = app.buttons["Library mode"]
                        if lib.waitForExistence(timeout: 15) { lib.tap() }
                    }
                    if app.buttons["General mode"].waitForExistence(timeout: 5) {
                        mode = "general"
                        ask(app, t.question)
                    } else { note = "NO MODE TOGGLE (could not switch to General)" }
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
                var ok: Bool
                if isDevice {
                    // A hung app exits (self-watchdog) within watchdogSec; waiting on the run STATE never
                    // queries the accessibility tree, so the dying app can't fail the whole test mid-query.
                    if t.action != "look", app.wait(for: .notRunning, timeout: (cfg.watchdogSec ?? 30) + 15) {
                        hungNote = "APP HUNG — the in-app self-watchdog exited the app (main thread stalled)"
                    }
                    ok = (note.isEmpty && hungNote == nil) ? waitForAnswers(app, count: answersBefore + (t.action == "look" ? 0 : 1), orLastLabelNot: t.action == "look" ? nil : lastAnswerBefore, timeout: turnTimeout) : false
                    if app.state != .runningForeground { hungNote = "APP HUNG — the in-app self-watchdog exited the app (main thread stalled)"; ok = false }
                } else {
                    ok = note.isEmpty ? waitForTurnFiles(out, count: expected, timeout: turnTimeout) : false
                }
                if hangMarkers(out) > hangsAtStart { hungNote = hungNote ?? "APP HUNG — main thread stopped; the watchdog terminated it"; ok = false }
                if let h = hungNote { note = h }
                // The tap writes at turn end, a beat before the view commits — let the bubble settle.
                Thread.sleep(forTimeInterval: 1.5)
                let seq = turnFiles(out).count
                var rec: [String: Any] = ["row": t.row, "case": t.case, "group": g.group, "action": t.action,
                                          "question": t.question, "seq": seq, "turnCompleted": ok,
                                          "wallSec": Date().timeIntervalSince(t0)]
                if !note.isEmpty { rec["driverNote"] = note }
                if let m = mode { rec["mode"] = m }
                if let e = ejectedAt { rec["ejectedAtEpoch"] = e; ejectedAt = nil }
                if hungNote == nil { rec.merge(captureScreen(app, row: t.row, out: isDevice ? nil : out)) { a, _ in a } }
                if hungNote == nil, isDevice, app.state != .runningForeground {
                    hungNote = "APP HUNG — the in-app self-watchdog exited the app during capture"; note = hungNote!; rec["driverNote"] = note
                }
                if isDevice {
                    let summary: [String: Any] = ["row": t.row, "ok": ok && hungNote == nil, "note": note,
                                                  "answerChars": (rec["onScreenAnswer"] as? String)?.count ?? 0,
                                                  "bubbles": rec["answerBubbleCount"] ?? 0, "wallSec": rec["wallSec"] ?? 0]
                    if let d = try? JSONSerialization.data(withJSONObject: summary), let s = String(data: d, encoding: .utf8) { log("RESULT \(s)") }
                }
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

    /// Matches top-to-bottom as they sit ON SCREEN. Never trust accessibility-index order for "the latest":
    /// the freeze fix's split stack (lazy history + eager latest exchange) lists the latest exchange first.
    private func screenOrdered(_ q: XCUIElementQuery) -> [XCUIElement] {
        q.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func captureScreen(_ app: XCUIApplication, row: String, out: URL?) -> [String: Any] {
        var r: [String: Any] = [:]
        // Dismiss the keyboard first: while it is up the composer rides over the end of the chat and covers the
        // latest footer, so 'Show N sources' is on-screen by frame but NOT hittable (CH-A UI ×1, screenshot
        // proven). `ask()` taps the field again before every question, so this is safe.
        let donePred = NSPredicate(format: "label == 'Done' OR identifier == 'Done'")
        r["doneButtons"] = screenOrdered(app.descendants(matching: .any).matching(donePred)).map { e -> [String: Any] in
            ["y": Int(e.frame.minY), "hittable": e.isHittable, "type": e.elementType.rawValue]
        }
        r["doneTree"] = app.debugDescription.split(separator: "\n").filter { $0.contains("Done") || $0.contains("Toolbar") }.prefix(12).map(String.init)
        if app.keyboards.firstMatch.exists {
            r["kbButtons"] = app.keyboards.firstMatch.buttons.allElementsBoundByIndex.prefix(60).map { "\($0.identifier)|\($0.label)|\(Int($0.frame.minY))" }
            r["kbOther"] = app.keyboards.firstMatch.debugDescription.split(separator: "\n").filter { $0.contains("Done") || $0.contains("Dismiss") || $0.contains("Hide") || $0.contains("dismiss") }.prefix(10).map(String.init)
        }
        var how = "none"
        // OPT-IN ONLY (`TEST_RUNNER_GAUNTLET_KB_DISMISS=1`): dismissing the keyboard after a long multi-turn chat
        // triggers a REAL app layout loop (findings/keyboard-dismiss-layout-loop.md — 2 of 3 runs froze in BX),
        // which kills the run. By default the keyboard stays up and a covered footer is recorded as unreachable.
        if ProcessInfo.processInfo.environment["GAUNTLET_KB_DISMISS"] == "1", app.keyboards.firstMatch.exists {
            let tries: [(String, () -> Void)] = [
                ("done", {
                    if let d = self.screenOrdered(app.descendants(matching: .any).matching(donePred)).last(where: { $0.isHittable }) { d.tap() }
                }),
                ("hideKey", {
                    for id in ["Hide keyboard", "keyboard.chevron.compact.down", "Dismiss"] where app.keyboards.buttons[id].exists {
                        app.keyboards.buttons[id].tap(); break
                    }
                }),
            ]
            r["kbFrame"] = "\(app.keyboards.firstMatch.frame)"
            for (name, act) in tries + [("doneBar", {
                // The keyboard accessory "Done" is NOT in the accessibility tree (iOS 27 out-of-process keyboard).
                // Screenshot-measured on this Simulator: Done bar = y 555–612pt, keyboard keys start at 655pt, the
                // SUGGESTION bar sits between them (a tap at kb.minY−29 hit a suggestion and TYPED "I'm" into Ask).
                // Only tap when the layout is exactly the measured one; otherwise record and move on.
                let kb = app.keyboards.firstMatch.frame, w = app.windows.firstMatch.frame
                guard Int(kb.minY) == 655, Int(w.width) == 440 else { return }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: w.maxX - 45, dy: kb.minY - 72)).tap()
            })] where app.keyboards.firstMatch.exists {
                act(); Thread.sleep(forTimeInterval: 0.7)
                if !app.keyboards.firstMatch.exists { how = name }
            }
        }
        r["keyboardDismissedBy"] = how
        r["askFieldAfterDismiss"] = app.textFields.firstMatch.exists ? (app.textFields.firstMatch.value as? String ?? "") : "?"
        r["keyboardUpAtCapture"] = app.keyboards.firstMatch.exists
        // Bring the end of the latest answer (and its footer) into the materialised region.
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        // ★ Ordered by ON-SCREEN position, never by accessibility index: since the follow-up freeze fix
        // (`8dd63e1`: lazy history + an eager latest exchange below it) the accessibility tree lists the
        // LATEST exchange FIRST, so `.last` read the PREVIOUS answer on every follow-up row (CH-A triage,
        // proven with a screenshot: the screen was right, the capture was wrong). Same for the sources button.
        let answers = screenOrdered(app.descendants(matching: .any).matching(identifier: "chat.answer"))
        // `TEST_RUNNER_GAUNTLET_SHOTS=1` — capture DIAGNOSTICS: what is actually ON SCREEN (a screenshot) plus
        // every answer element's frame + label head, top to bottom (CH-A triage: follow-up rows read
        // the PREVIOUS answer after the freeze fix — screen truth vs accessibility order).
        if let out, ProcessInfo.processInfo.environment["GAUNTLET_SHOTS"] == "1" {
            try? app.screenshot().pngRepresentation.write(to: out.appendingPathComponent("screen-\(row).png"))
            r["answerElements"] = answers.map { e -> [String: Any] in
                let f = e.frame
                return ["y": Int(f.minY), "h": Int(f.height), "hittable": e.isHittable, "head": String(e.label.prefix(60))]
            }
        }
        r["onScreenAnswer"] = answers.last?.label ?? NSNull()
        r["answerBubbleCount"] = answers.count
        r["errorBanner"] = app.buttons["Retry"].exists

        // Citation chips: expand the LATEST footer, read its rows, collapse it again so the next turn's
        // read can't pick up this message's rows.
        let showPred = NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' sources'")
        let shows = screenOrdered(app.buttons.matching(showPred))
        r["showElements"] = shows.map { e -> [String: Any] in
            ["y": Int(e.frame.minY), "hittable": e.isHittable, "label": e.label]
        }
        r["window"] = Int(app.windows.firstMatch.frame.height)
        var chips: [String] = []
        // Only a footer BELOW the latest answer belongs to it: when the latest answer has no sources, the lowest
        // footer on screen is the PREVIOUS answer's (CH-A instruct BXe read a stale "Show 1 sources").
        let latestTop = answers.last?.frame.minY ?? -.greatestFiniteMagnitude
        if let show = shows.last, show.exists, show.frame.minY > latestTop {
            r["sourcesHeader"] = show.label
            // Now that the LATEST footer is picked (not the previous one), on a long answer it can still sit
            // below the fold after the fast swipes — a tap on a non-hittable element FAILS the whole run (CH-A
            // UI ×1: all four sets died on 'Show 1 sources' at y≈1230–1730). Scroll until hittable; else record.
            if reach(show, app, up: true) {
                show.tap()
                Thread.sleep(forTimeInterval: 0.6)
                chips = app.descendants(matching: .any).matching(identifier: "chat.source").allElementsBoundByIndex.map { $0.label }
                let hide = app.buttons["Hide sources"]
                if hide.exists && hide.isHittable { hide.tap() }
            } else {
                r["sourcesUnreachable"] = true
            }
        }
        r["onScreenChips"] = chips

        // Thought process: present only for the latest turn (ephemeral). Expand, read, collapse.
        let header = app.buttons["Thought process"]
        r["thoughtHeaderPresent"] = header.exists
        if header.exists {
            if reach(header, app, up: false) {
                header.tap()
                Thread.sleep(forTimeInterval: 0.6)
                r["onScreenThought"] = app.descendants(matching: .any).matching(identifier: "chat.thought").firstMatch.label
                if header.isHittable { header.tap() }
            } else {
                r["thoughtUnreachable"] = true
            }
        }
        return r
    }

    /// Scrolls (slowly, so it settles) until `e` is hittable. `up` = the element is below the fold.
    private func reach(_ e: XCUIElement, _ app: XCUIApplication, up: Bool) -> Bool {
        for _ in 0..<12 {
            if e.exists && e.isHittable { return true }
            if up { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return e.exists && e.isHittable
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

    /// Device mode: turn completion read off the UI. A hung app blocks the query until the in-app
    /// self-watchdog exits it; then `app.state` is no longer foreground and the row is recorded as a hang.
    private func waitForAnswers(_ app: XCUIApplication, count: Int, orLastLabelNot previous: String? = nil, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state != .runningForeground { return false }
            let q = app.descendants(matching: .any).matching(identifier: "chat.answer")
            if q.count >= count { return true }
            // A lazy transcript drops off-screen bubbles from the a11y tree, so the count can stay flat even
            // though a new answer landed — a changed LAST answer is the same signal.
            if let previous, let last = screenOrdered(q).last?.label, !last.isEmpty, last != previous { return true }
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


/// CH ruling 5 (T 2026-10-07) — off-pillar Librarian features stay in V1 only if they're GREEN in the inventory
/// pass. This is that pass for the ones a Simulator can check without a model: read-aloud (Play → Pause → Play on a
/// seeded answer) and the Chats list's rename + delete (long-press menu). Dictation (needs a microphone) and pin-to-
/// entry are not covered here. No Host needed: `-GauntletSeedChat` seeds a persisted two-turn chat.
final class OffPillarSmoke: XCTestCase {

    func testReadAloudTogglesPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletSeedChat", "2"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chat.answer").firstMatch.waitForExistence(timeout: 30),
                      "seeded answer never appeared")
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "no read-aloud Play button under the answer")
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10), "Play did not start read-aloud (no Pause)")
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 10), "Pause did not stop read-aloud")
        app.terminate()
    }

    func testChatsListRenameAndDelete() throws {
        // 1. seed + persist a chat
        let seed = XCUIApplication()
        seed.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletSeedChat", "2"]
        seed.launch()
        XCTAssertTrue(seed.descendants(matching: .any).matching(identifier: "chat.answer").firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        seed.terminate()
        // 2. open the Chats list, rename the newest chat, then delete it
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20), "Chats list never opened")
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no chat row")
        let before = app.cells.count
        row.press(forDuration: 1.2)
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename in the long-press menu")
        rename.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no rename field")
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("Smoke renamed chat\n")
        let ok = app.buttons["Save"].firstMatch.exists ? app.buttons["Save"].firstMatch : app.buttons["OK"].firstMatch
        if ok.exists { ok.tap() }
        XCTAssertTrue(app.staticTexts["Smoke renamed chat"].waitForExistence(timeout: 5), "rename did not show in the list")
        app.cells.containing(.staticText, identifier: "Smoke renamed chat").firstMatch.press(forDuration: 1.2)
        let del = app.buttons["Delete"].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5), "no Delete in the long-press menu")
        del.tap()
        XCTAssertTrue(app.staticTexts["Smoke renamed chat"].waitForNonExistence(timeout: 5), "deleted chat still listed")
        XCTAssertEqual(app.cells.count, before - 1)
        app.terminate()
    }
}
