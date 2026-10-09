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
            app.launchArguments = cfg.baseArgs + g.args + ["-OpenMap", "-GauntletUI", "YES", "-ResetLibrarianRoute", "YES", "-GauntletTapDir", isDevice ? "app-tmp" : cfg.outDir]
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
                var statusSeen: String? = nil
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
                        // CH (T 2026-10-09) — the live tool status line while a tool runs (`-WebSearchMockDelayMs`
                        // makes the mock slow enough to see). Recorded, not asserted here; the grader reads it.
                        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Searching the web' OR label BEGINSWITH 'Reading '")).firstMatch
                        if status.waitForExistence(timeout: 8) { statusSeen = status.label }
                    } else { note = "NO MODE TOGGLE (could not switch to General)" }
                case "library":
                    // CH C2b (T 2026-10-09) — back to Library INSIDE the same chat (Library → General → Library).
                    if !app.buttons["Library mode"].exists {
                        let gen = app.buttons["General mode"]
                        if gen.waitForExistence(timeout: 15) { gen.tap() }
                    }
                    if app.buttons["Library mode"].waitForExistence(timeout: 5) {
                        mode = "library"
                        ask(app, t.question)
                    } else { note = "NO MODE TOGGLE (could not switch back to Library)" }
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
                if let st = statusSeen { rec["statusSeen"] = st }
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
                // iOS 27 Sim puts the keyboard at 653 pt; `askFieldAfterDismiss` records any stray typing.
                // Only tap when the layout is exactly the measured one; otherwise record and move on.
                let kb = app.keyboards.firstMatch.frame, w = app.windows.firstMatch.frame
                guard abs(Int(kb.minY) - 655) <= 3, Int(w.width) == 440 else { return }   // 27: 653
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
/// entry are not covered here. No Host needed: `-GauntletSeedChat` seeds the answers read aloud.
final class OffPillarSmoke: XCTestCase {

    func testReadAloudTogglesPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletSeedChat", "2"]
        app.launch()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no read-aloud Play button under the seeded answer")
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 10), "Play did not start read-aloud (no Pause)")
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 10), "Pause did not stop read-aloud")
        app.terminate()
    }

    /// CH item 4 — Copy answer: tap the footer's Copy on the LATEST answer. The pasteboard is checked from outside the
    /// app (`xcrun simctl pbpaste` after the run, against a sentinel planted before it — no cross-app paste prompt).
    func testCopyAnswerToPasteboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletSeedChat", "2"]
        app.launch()
        let copies = app.buttons.matching(NSPredicate(format: "label == 'Copy message'"))
        XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 30), "no Copy under the seeded answers")
        let last = copies.allElementsBoundByIndex.filter { $0.isHittable }.max(by: { $0.frame.minY < $1.frame.minY })
        XCTAssertNotNil(last, "no hittable Copy button")
        last?.tap()
        Thread.sleep(forTimeInterval: 1.5)
        print("CONTINUE_COPY copy tapped")
        app.terminate()
    }

    /// CH item 4 — Continue: a stopped-early answer (`-GauntletSeedPartial`) resumes through a real model and stops
    /// being partial. Needs a scratch Host: `TEST_RUNNER_CC_HOST_ARGS="-DebugHostURL … -DebugHostSecret … -DebugHostPubKey …"`.
    func testContinueResumesStoppedAnswer() throws {
        guard let host = ProcessInfo.processInfo.environment["CC_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs CC_HOST_ARGS (a scratch Host)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletTapDir", "app-tmp", "-GauntletSeedChat", "2", "-GauntletSeedPartial", "YES"]
            + host.split(separator: " ").map(String.init)
        app.launch()
        let cont = app.buttons["Continue the answer"]
        XCTAssertTrue(cont.waitForExistence(timeout: 30), "no Continue on the stopped-early answer")
        let answers = app.descendants(matching: .any).matching(identifier: "chat.answer")
        func lastAnswerChars() -> Int { answers.allElementsBoundByIndex.max(by: { $0.frame.minY < $1.frame.minY })?.label.count ?? 0 }
        let before = lastAnswerChars()
        cont.tap()
        let stopped = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Stopped early'")).firstMatch
        let deadline = Date().addingTimeInterval(240)
        var done = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 3)
            if !stopped.exists && !cont.exists && !app.staticTexts["Resuming…"].exists { done = true; break }
            if cont.exists && cont.isEnabled && Date().timeIntervalSince(deadline.addingTimeInterval(-240)) > 20 { break } // dropped again
        }
        let after = lastAnswerChars()
        print("CONTINUE_COPY continue done=\(done) answerChars \(before)→\(after)")
        XCTAssertTrue(done, "the answer is still 'Stopped early' after Continue")
        XCTAssertGreaterThan(after, before, "Continue added no text")
        app.terminate()
    }

    /// Pin a chat to an entry and unpin it again (the Chats list's long-press "Pin to entry…" → the entry picker).
    /// Same scratch-library precondition as the rename/delete test.
    func testChatPinToEntryAndUnpin() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20), "Chats list never opened")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'What connections'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no chat row")
        func menu(_ title: String) -> XCUIElement {
            row.press(forDuration: 1.2)
            return app.buttons[title].firstMatch
        }
        var pin = menu("Pin to entry…")
        if !pin.waitForExistence(timeout: 3) {
            // already pinned from an earlier run → unpin first, so the test starts unpinned
            app.tap(); let change = menu("Change pin…")
            XCTAssertTrue(change.waitForExistence(timeout: 5)); change.tap()
            XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5)); app.buttons["Unpin"].tap()
            pin = menu("Pin to entry…")
        }
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "no 'Pin to entry…' in the long-press menu")
        pin.tap()
        XCTAssertTrue(app.navigationBars["Pin chat to an entry"].waitForExistence(timeout: 5), "entry picker never opened")
        // The picker's list is the LAST collection view (the Chats list is still underneath the sheet).
        let lists = app.collectionViews
        let entry = lists.element(boundBy: max(0, lists.count - 1)).buttons.firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no entry to pin to")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Pin chat to an entry"].waitForNonExistence(timeout: 5), "picker did not dismiss")
        let change = menu("Change pin…")
        XCTAssertTrue(change.waitForExistence(timeout: 5), "the pin did not stick (menu still says 'Pin to entry…')")
        change.tap()
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5), "no Unpin for a pinned chat")
        app.buttons["Unpin"].tap()
        XCTAssertTrue(menu("Pin to entry…").waitForExistence(timeout: 5), "unpin did not stick")
        app.terminate()
    }

    func testChatsListRenameAndDelete() throws {
        // Runs in the ISOLATED UI-test scratch library (`-UITestLibrary`: a throwaway caches container that never
        // touches a real library), which holds the chats earlier gauntlet captures left there (a fresh Simulator
        // needs that scratch copied in first — PRECONDITION: ≥ 1 chat titled 'What connections…'). (A chat seeded under
        // -GauntletUI is not persisted — the seed path is not the product path, so it isn't used here.)
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20), "Chats list never opened")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'What connections'"))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no chat row")
        row.press(forDuration: 1.2)
        let rename = app.buttons["Rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "no Rename in the long-press menu")
        rename.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no rename field")
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 5) + "Smoke renamed chat")
        let save = app.alerts.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "no Save in the rename alert")
        save.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Smoke renamed chat'")).firstMatch.waitForExistence(timeout: 5), "rename did not show in the list")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Smoke renamed chat'")).firstMatch.press(forDuration: 1.2)
        let del = app.buttons["Delete"].firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 5), "no Delete in the long-press menu")
        del.tap()
        // A chat pinned to an entry asks first ("Delete pinned chat?").
        if app.alerts.buttons["Delete"].firstMatch.waitForExistence(timeout: 2) { app.alerts.buttons["Delete"].firstMatch.tap() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Smoke renamed chat'")).firstMatch.waitForNonExistence(timeout: 5), "deleted chat still listed")
        app.terminate()
    }
}


/// CH Session 2, items 2–3 (inventory C4 / C4a) through the REAL Librarian, against a scratch Host
/// (`TEST_RUNNER_CC_HOST_ARGS`). The script sets the Host's residency + residents per case (`TEST_RUNNER_C4A_CASE`).
final class ModelPillChecks: XCTestCase {

    private func launch(_ extra: [String]) throws -> XCUIApplication {
        guard let host = ProcessInfo.processInfo.environment["CC_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs CC_HOST_ARGS (a scratch Host)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-GauntletTapDir", "app-tmp"]
            + host.split(separator: " ").map(String.init) + extra
        app.launch()
        return app
    }

    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model ' OR label == 'No model loaded'")).firstMatch
    }

    private func toGeneralAndAsk(_ app: XCUIApplication, _ q: String) {
        let lib = app.buttons["Library mode"]
        if lib.waitForExistence(timeout: 20) { lib.tap() }
        XCTAssertTrue(app.buttons["General mode"].waitForExistence(timeout: 5), "could not switch to General")
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        var field = app.textViews.matching(pred).firstMatch
        if !field.waitForExistence(timeout: 5) { field = app.textFields.matching(pred).firstMatch }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ask field missing")
        field.tap(); field.typeText(q)
        app.buttons["Send"].tap()
    }

    private func waitForAnswer(_ app: XCUIApplication, timeout: TimeInterval = 180) -> String? {
        let answers = app.descendants(matching: .any).matching(identifier: "chat.answer")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let a = answers.allElementsBoundByIndex.max(by: { $0.frame.minY < $1.frame.minY }), a.label.count > 1,
               !app.buttons["Stop"].exists { return a.label }
            Thread.sleep(forTimeInterval: 2)
        }
        return nil
    }

    /// C4 — a very long model name must fade inside the pill; the Library/General toggle and Thinking keep their
    /// size (one line each — T's screenshot had "Library" wrapped one syllable per line), and the raw tag never shows.
    func testLongNameNeverSqueezesNeighbours() throws {
        let long = "Qwen3 30B-A3B Instruct 2507 · Extended Context Long Name Edition"
        let app = try launch(["-GauntletPillName", long])
        let lib = app.buttons["Library mode"]
        XCTAssertTrue(lib.waitForExistence(timeout: 30), "no Library toggle")
        let p = pill(app)
        XCTAssertTrue(p.waitForExistence(timeout: 20), "no model pill")
        Thread.sleep(forTimeInterval: 2)
        let think = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Thinking'")).firstMatch
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["C4_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pill-long.png"))
        }
        print("C4 frames library=\(lib.frame) pill=\(p.frame) thinking=\(think.exists ? "\(think.frame)" : "absent") label=\(p.label)")
        XCTAssertLessThan(lib.frame.height, 40, "Library toggle wrapped (taller than one line)")
        XCTAssertGreaterThan(lib.frame.width, 60, "Library toggle squeezed")
        XCTAssertLessThanOrEqual(p.frame.width, 230, "the pill did not cap its long name")
        XCTAssertFalse(p.frame.intersects(lib.frame), "pill overlaps the Library toggle")
        if think.exists {
            XCTAssertLessThan(think.frame.height, 40, "Thinking control wrapped")
            XCTAssertFalse(p.frame.intersects(think.frame), "pill overlaps Thinking")
        }
        app.terminate()
    }

    /// C4 — the `-PillGallery` harness (fake catalog, a Thinking-toggleable model): next to the long name, every
    /// "Library" chip and every Thinking control stays one line, and no pill overlaps its neighbours.
    func testGalleryLongNameKeepsThinking() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PillGallery"]
        app.launch()
        let pills = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model Qwen3 30B-A3B Instruct 2507'"))
        XCTAssertTrue(pills.firstMatch.waitForExistence(timeout: 30), "no long-name gallery row")
        Thread.sleep(forTimeInterval: 1)
        if let dir = ProcessInfo.processInfo.environment["C4_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pill-gallery.png"))
        }
        let thinks = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Thinking'")).allElementsBoundByIndex
        let libs = app.staticTexts.matching(NSPredicate(format: "label == 'Library'")).allElementsBoundByIndex
        for p in pills.allElementsBoundByIndex {
            let row = p.frame.insetBy(dx: -400, dy: 0)   // same-row neighbours
            let t = thinks.first { row.intersects($0.frame) }
            print("C4 gallery pill=\(p.frame) thinking=\(t.map { "\($0.frame)" } ?? "absent")")
            XCTAssertNotNil(t, "Thinking disappeared next to the long name")
            if let t { XCTAssertLessThan(t.frame.height, 40); XCTAssertFalse(p.frame.intersects(t.frame), "pill overlaps Thinking") }
            XCTAssertLessThanOrEqual(p.frame.width, 230, "the pill did not cap its long name")
        }
        for l in libs { XCTAssertLessThan(l.frame.height, 30, "a Library chip wrapped") }
        app.terminate()
    }

    /// C4a — the cases the script prepares on the scratch Host (residency + residents):
    ///   A "pick-resident"  Always-ready; pick = Instruct (resident, off-manifest); curated qwen3:4b NOT resident. T's bug.
    ///   B "autoload"       Always-ready; pick = a model that is NOT resident → the ask loads it and answers.
    ///   C "handson"        Hands-on; pick NOT resident → banner with "Load and ask" → tap → answer.
    func testAskWithPickedModel() throws {
        let env = ProcessInfo.processInfo.environment
        let c = env["C4A_CASE"] ?? "pick-resident"
        let pick = env["C4A_PICK"] ?? "qwen3:4b-instruct-2507-q4_K_M"
        let app = try launch(["-airpadUserPickedHostModel", pick])
        let p = pill(app)
        XCTAssertTrue(p.waitForExistence(timeout: 30), "no model pill")
        Thread.sleep(forTimeInterval: 3)
        let pillBefore = p.label
        XCTAssertFalse(pillBefore.contains(":"), "the pill shows a raw tag: \(pillBefore)")
        if c == "pick-resident" { XCTAssertTrue(pillBefore.hasSuffix(", loaded"), "pick is resident but the pill says \(pillBefore)") }
        // (autoload: no pre-check — in Always-ready the panel's warm-on-open ping already loads the pick, and wins the race
        // to the pill on 26.5/27; the script checks the Host log for the 409 → load instead.)
        else if c == "handson" { XCTAssertTrue(pillBefore.hasSuffix("not loaded yet"), "pick is NOT resident but the pill says \(pillBefore)") }
        toGeneralAndAsk(app, "In one sentence: what is the capital of France?")
        if c == "handson" {
            let load = app.buttons["Load and ask"]
            XCTAssertTrue(load.waitForExistence(timeout: 60), "Hands-on: no 'Load and ask' in the banner")
            load.tap()
        }
        let answer = waitForAnswer(app)
        let pillAfter = p.label
        print("C4A case=\(c) pillBefore=\(pillBefore) pillAfter=\(pillAfter) answer=\(answer?.prefix(80) ?? "NONE")")
        XCTAssertNotNil(answer, "no answer (case \(c))")
        XCTAssertTrue(answer?.localizedCaseInsensitiveContains("Paris") == true, "answer doesn't name Paris")
        XCTAssertTrue(pillAfter.hasSuffix(", loaded"), "after answering, the pill says \(pillAfter)")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No model is loaded'")).firstMatch.exists,
                       "a not-loaded banner is still showing")
        app.terminate()
    }
}


/// C2c / C4b2 (T device 2026-10-09: after unpairing, the pill still showed the raw Host tag and a question hung on
/// "Thinking…" forever; Apple Intelligence was unreachable in practice). The ROUTE through the real UI: Apple
/// Intelligence picked in the model menu WITHOUT unpairing, back to the Mac, then Unpair → the pill re-derives at once
/// and the next ask answers on-device; and a dead Host fails fast. The Simulator has no Apple Intelligence, so
/// `-StubOnDeviceModel YES` stands in for it (a canned answer) — the on-device model itself is the device check.
/// Config via the runner environment: `TEST_RUNNER_C2C_HOSTARGS` = the scratch Host's `-DebugHost…` args.
final class C2cAppleIntelligenceRoute: XCTestCase {
    private func hostArgs() -> [String] {
        (ProcessInfo.processInfo.environment["C2C_HOSTARGS"] ?? "").split(separator: " ").map(String.init)
    }
    private func askField(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        let tf = app.textFields.matching(pred).firstMatch
        if tf.waitForExistence(timeout: 20) { return tf }
        return app.textViews.matching(pred).firstMatch
    }
    private func ask(_ app: XCUIApplication, _ q: String) {
        let f = askField(app); f.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); f.tap() }
        f.typeText(q)
        let send = app.buttons["Send"]; XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
    }
    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model ' OR label == 'No model loaded'")).firstMatch
    }
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("C2C \(s)") }
    private func answer(_ app: XCUIApplication, containing s: String, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'chat.answer' AND label CONTAINS %@", s)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    private func stubAnswered(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Apple Intelligence on this iPhone (stub)'")).firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// C4b2 — Apple Intelligence in the model menu (still paired), then back to the Mac model.
    func testPickAppleIntelligenceAndBack() {
        let app = XCUIApplication()
        app.launchArguments = hostArgs() + ["-ResetLibrarianRoute", "YES", "-StubOnDeviceModel", "YES", "-OpenMap", "-GauntletUI", "YES", "-EmbedCPUOnly"]
        app.launch()
        let p = pill(app)
        XCTAssertTrue(p.waitForExistence(timeout: 30), "model pill missing")
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model Qwen'")).firstMatch.waitForExistence(timeout: 20)
        note("paired pill: \(pill(app).label)")
        pill(app).tap()
        let ai = app.buttons["picker.appleIntelligence"]
        XCTAssertTrue(ai.waitForExistence(timeout: 10), "Apple Intelligence is not in the model menu")
        ai.tap()
        let aiPill = app.buttons["Model Apple Intelligence, on this iPhone"]
        XCTAssertTrue(aiPill.waitForExistence(timeout: 10), "pill didn't switch to Apple Intelligence: \(pill(app).label)")
        ask(app, "What is 17 times 23?")
        let routed = stubAnswered(app, timeout: 30)
        note("picked Apple Intelligence: pill ✓ · answer \(routed ? "from Apple Intelligence ✓" : "NOT from Apple Intelligence")")
        XCTAssertTrue(routed, "the ask didn't route to Apple Intelligence")
        aiPill.tap()
        let macRow = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Qwen3 4B' AND NOT (label BEGINSWITH 'Model ')")).firstMatch
        XCTAssertTrue(macRow.waitForExistence(timeout: 15), "no Mac model row in the picker")
        let use = app.buttons["Use"].firstMatch
        if use.waitForExistence(timeout: 5) { use.tap() } else {
            macRow.tap()
            let load = app.buttons.matching(identifier: "Load").firstMatch; if load.waitForExistence(timeout: 3) { load.tap() }
        }
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model Qwen'")).firstMatch
        let ok = back.waitForExistence(timeout: 60)
        note("back to the Mac: \(ok ? back.label : pill(app).label)")
        XCTAssertTrue(ok, "pill didn't come back to the Mac model")
    }

    /// C2c — T's case: a real (Keychain) pairing, Unpair in Settings → the label re-derives at once and the next ask
    /// answers on-device, never a stale Host tag or an endless "Thinking…".
    func testUnpairRoutesToAppleIntelligence() {
        let app = XCUIApplication()
        app.launchArguments = ["-ResetLibrarianRoute", "YES", "-FakeHostPairing", "YES", "-StubOnDeviceModel", "YES", "-OpenMap", "-GauntletUI", "YES", "-EmbedCPUOnly"]
        app.launch()
        let p = pill(app)
        XCTAssertTrue(p.waitForExistence(timeout: 30), "model pill missing (not paired?)")
        note("paired pill: \(p.label)")
        p.tap()
        let manage = app.buttons["Manage models"]; XCTAssertTrue(manage.waitForExistence(timeout: 10)); manage.tap()
        let unpair = app.buttons["Unpair this Mac"]; XCTAssertTrue(unpair.waitForExistence(timeout: 10)); unpair.tap()
        // close Settings (and the picker under it) until the composer is back on top
        for _ in 0..<3 where app.buttons["BackButton"].exists { app.buttons["BackButton"].tap(); Thread.sleep(forTimeInterval: 0.8) }
        for _ in 0..<3 {
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap(); Thread.sleep(forTimeInterval: 1.2) } else { break }
        }
        if app.otherElements["Sheet Grabber"].exists || app.buttons["Sheet Grabber"].exists { app.swipeDown(velocity: .fast); Thread.sleep(forTimeInterval: 1) }
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Answering with Apple Intelligence'")).firstMatch
        let ok = label.waitForExistence(timeout: 10)
        let any = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Answering with'")).firstMatch
        note("after unpair (no focus, no relaunch): \(ok ? "Answering with Apple Intelligence" : (any.exists ? any.label : "no model label"))")
        XCTAssertTrue(ok, "after unpairing, the label is not Apple Intelligence")
        let t0 = Date()
        ask(app, "What is 2 plus 2?")
        let routed = stubAnswered(app, timeout: 30)
        note(String(format: "unpaired ask: %@ in %.1f s", routed ? "answered by Apple Intelligence" : "NO on-device answer", Date().timeIntervalSince(t0)))
        XCTAssertTrue(routed, "after unpairing the ask didn't answer on-device")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }

    /// C2c device check (T 2026-10-09, short): on T's iPhone, pick Apple Intelligence in the model menu (no unpairing),
    /// ask one General and one Library question, time both, then route back to the Mac (relaunch with the reset arg).
    func testOnDeviceAppleIntelligenceLibrarian() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES"]
        app.launch()
        let p = pill(app)
        XCTAssertTrue(p.waitForExistence(timeout: 30), "model pill missing")
        note("start pill: \(p.label)")
        p.tap()
        let ai = app.buttons["picker.appleIntelligence"]
        XCTAssertTrue(ai.waitForExistence(timeout: 15), "Apple Intelligence is not in the model menu on this iPhone")
        ai.tap()
        XCTAssertTrue(app.buttons["Model Apple Intelligence, on this iPhone"].waitForExistence(timeout: 10), "pill didn't switch")
        func timedAsk(_ q: String, general: Bool) {
            if general, app.buttons["Library mode"].exists { app.buttons["Library mode"].tap() }
            if !general, app.buttons["General mode"].exists { app.buttons["General mode"].tap() }
            let before = app.descendants(matching: .any).matching(identifier: "chat.answer").count
            let t0 = Date()
            ask(app, q)
            let ans = app.descendants(matching: .any).matching(identifier: "chat.answer")
            var done = false
            while Date().timeIntervalSince(t0) < 120 {
                if ans.count > before, app.buttons["Copy"].exists || !app.staticTexts["Thinking…"].exists { done = true; break }
                if app.buttons["Retry"].exists { break }
                Thread.sleep(forTimeInterval: 1)
            }
            let txt = ans.count > before ? ans.element(boundBy: ans.count - 1).label : "—"
            note(String(format: "%@ · %@ · %.1f s · %@", general ? "General" : "Library", done ? "answered" : (app.buttons["Retry"].exists ? "ERROR banner" : "NO ANSWER"),
                        Date().timeIntervalSince(t0), String(txt.prefix(160))))
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(done, "\(q) — no answer from Apple Intelligence")
        }
        timedAsk("What is the capital of Australia?", general: true)
        timedAsk("What have I written about coffee?", general: false)
        app.terminate()
        // route back to the Mac — undo the pick
        app.launchArguments = ["-ResetLibrarianRoute", "YES", "-OpenMap"]
        app.launch()
        Thread.sleep(forTimeInterval: 4)
        note("restored pill: \(pill(app).exists ? pill(app).label : "—")")
        app.terminate()
    }

    /// A paired Mac that isn't there (`-FakeHostPairing`: a tunnel address with no Host behind it) — the ask must fail fast
    /// with a clear message, never an endless "Thinking…".
    func testDeadHostFailsFast() {
        let app = XCUIApplication()
        app.launchArguments = ["-FakeHostPairing", "YES", "-OpenMap", "-GauntletUI", "YES", "-EmbedCPUOnly"]
        app.launch()
        let t0 = Date()
        ask(app, "Hello there")
        let retry = app.buttons["Retry"]
        let failed = retry.waitForExistence(timeout: 120)
        let dt = Date().timeIntervalSince(t0)
        let banner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'reach' OR label CONTAINS[c] 'offline' OR label CONTAINS[c] 'respond'")).firstMatch
        note(String(format: "dead host: failed=%@ after %.1f s · message: %@", failed ? "yes" : "NO", dt, banner.exists ? banner.label : "—"))
        XCTAssertTrue(failed && dt < 15, String(format: "a dead Host took %.1f s to fail (or never did)", dt))
    }
}
