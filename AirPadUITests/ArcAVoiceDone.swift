import XCTest

/// Arc A — "Done drops the ghost title + summary" on a VOICE capture (T, TF 202610111032, iOS 26, Action Button).
/// The CD matrix only ever TYPED a note; T's failing path records voice. Same production entry points as the CD
/// matrix (`-EntryQuikCapture` = the deep-link/Action-Button `entryMode = .quikCapture` line; the real Voice button,
/// the real voice sheet, the real Done). Only the speech model is canned (`-StubVoiceTranscript`, the Simulator has
/// none) and the naming model is stubbed at a device-like latency (`-StubAuthorLatencyMs`). Every test reads what
/// Done PERSISTED (the node on disk), not the transient screen.
final class ArcAVoiceDone: XCTestCase {

    private let transcript = "Remind me to book the piano tuner before the recital next month and ask about the pedal squeak"

    private func baseArgs(_ latencyMs: Int) -> [String] {
        ["-StubAuthorModel", "-EmbedCPUOnly", "-UITestLibrary", "-StdoutToFile",
         "-StubVoiceTranscript", transcript, "-StubAuthorLatencyMs", String(latencyMs)]
    }

    private func launch(_ extra: [String], latencyMs: Int = 2500, fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        markBaseline()
        app.launchArguments = baseArgs(latencyMs) + (fresh ? ["-UITestLibraryFresh"] : []) + extra
        app.launch()
        return app
    }

    // MARK: - steps

    /// Quick Capture's note auto-focuses under `-EntryQuikCapture`; hide the keyboard so the capture bar is reachable.
    private func awaitCaptureScreen(_ app: XCUIApplication) {
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 20), "Quick Capture should open")
        hideKeyboard(app)
    }

    private func hideKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        let tip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sliding your finger'")).firstMatch
        if tip.exists, app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    }

    /// Voice button → the real voice sheet records → its Done → the (stubbed) transcript is saved by the real `saveNode`.
    private func recordVoice(_ app: XCUIApplication) {
        let voice = app.buttons["Voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10), "the Voice capture button should exist")
        voice.tap()
        addUIInterruptionMonitor(withDescription: "mic") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        app.tap()   // lets an interruption monitor fire if the mic prompt is up
        let stop = app.buttons["Done"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the voice sheet should be recording")
        Thread.sleep(forTimeInterval: 2.0)   // its Done enables after 1 s of audio
        shot(app, "voice-recording")
        stop.tap()
    }

    private func ghostShowing(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Suggested:'")).firstMatch
    }

    private func tapCaptureDone(_ app: XCUIApplication) {
        hideKeyboard(app)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "the capture's Done should exist")
        done.tap()
        // A2 — a missed tap must fail loudly: under `-RealCapturePlus` alone the Librarian pill sat over Done, the tap
        // opened the Librarian, and the live-8 "+" rows read the voice sheet's own write as Done's.
        XCTAssertTrue(app.textViews["noteEditor"].waitForNonExistence(timeout: 8), "Done should close the capture screen")
    }

    // MARK: - disk (Simulator: the runner can read the app's scratch container)

    private func persistedNodes() -> [[String: Any]] {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        var out: [[String: Any]] = []
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            for scratch in ["AirPadUITestScratch", "AirPadCorpusFixtureScratch"] {
            let dir = c.appendingPathComponent("Library/Caches/\(scratch)/nodes")
            for id in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if let d = try? Data(contentsOf: id.appendingPathComponent("node.json")),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { out.append(j) }
            }
            }
        }
        return out
    }

    /// Ids on disk before this test's capture (another app container or an earlier run can hold voice entries).
    private var baseline: Set<String> = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func markBaseline() { baseline = Set(persistedNodes().compactMap { $0["id"] as? String }) }

    private func newestVoiceNode() -> [String: Any]? {
        persistedNodes()
            .filter { !baseline.contains(($0["id"] as? String) ?? "") }
            .filter { (($0["items"] as? [[String: Any]]) ?? []).contains { ($0["type"] as? String) == "audio" } }
            .max { (($0["created_at"] as? String) ?? "") < (($1["created_at"] as? String) ?? "") }
    }

    private func describe(_ n: [String: Any]?) -> String {
        guard let n else { return "none" }
        let t = (n["title"] as? String) ?? "", s = (n["summary"] as? String) ?? ""
        let props = ((n["proposals"] as? [[String: Any]]) ?? []).map { "\($0["kind"] ?? "?")/\($0["state"] ?? "?")" }
        let items = ((n["items"] as? [[String: Any]]) ?? []).map { i -> String in
            let t = (i["type"] as? String) ?? "?"
            return t == "text" ? "text(\(((i["content"] as? String) ?? "").count))" : t
        }
        return "title=\(t.isEmpty ? "EMPTY" : "'\(t)'") src=\(n["title_source"] ?? "nil") summary=\(s.isEmpty ? "EMPTY" : "ok") "
            + "ssrc=\(n["summary_source"] ?? "nil") items=\(items) proposals=\(props)"
    }

    /// Poll the persisted voice node for Done's write; return the last state seen.
    private func awaitCommitted(timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any]?
        while Date() < deadline {
            last = newestVoiceNode()
            if let n = last, !((n["title"] as? String) ?? "").isEmpty, !((n["summary"] as? String) ?? "").isEmpty { return n }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return last
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    private func proposals(_ n: [String: Any]?) -> Int { ((n?["proposals"] as? [[String: Any]]) ?? []).count }
    private func str(_ n: [String: Any]?, _ k: String) -> String { (n?[k] as? String) ?? "" }

    /// One capture, end to end. `delegateOn` = Settings → "Name and describe new entries automatically".
    /// ON: Done names the entry (title + summary on disk). OFF (T's ruling, 2026-10-12): no ghost in capture,
    /// Done writes nothing, and the model's offer is kept for the lever.
    private func captureVoice(_ app: XCUIApplication, label: String, delegateOn: Bool, openVoice: (XCUIApplication) -> Void) {
        openVoice(app)
        recordVoice(app)
        if delegateOn {
            // A2 (T, TF 202610122311): with the setting ON the offer is a GHOST until Done — never written while capturing.
            let ghost = ghostShowing(app).waitForExistence(timeout: 90)
            Thread.sleep(forTimeInterval: 1.0)   // any eager write lands now
            let before = newestVoiceNode()
            print("[ArcA] \(label) ghost-before-Done=\(ghost) disk: \(describe(before))")
            XCTAssertTrue(ghost, "\(label): with the setting ON the proposal shows as a ghost while capturing")
            XCTAssertTrue(str(before, "title").isEmpty && str(before, "summary").isEmpty,
                          "\(label): nothing is committed before Done — \(describe(before))")
        } else {
            // Wait until the model's offer is on disk: if a ghost were going to show, it shows now.
            let deadline = Date().addingTimeInterval(90)   // the Simulator's on-CPU substrate step can take tens of seconds
            while Date() < deadline, proposals(newestVoiceNode()) == 0 { Thread.sleep(forTimeInterval: 0.5) }
            Thread.sleep(forTimeInterval: 1.0)
            let ghost = ghostShowing(app).exists
            print("[ArcA] \(label) ghost-before-Done=\(ghost) disk: \(describe(newestVoiceNode()))")
            XCTAssertFalse(ghost, "\(label): with the setting OFF no ghost may show in capture")
        }
        shot(app, "\(label)-before-Done")
        tapCaptureDone(app)
        let n: [String: Any]?
        if delegateOn {
            n = awaitCommitted(timeout: 30)
        } else {
            // Done's async pass has settled once its prune of the empty scaffold note is on disk.
            let deadline = Date().addingTimeInterval(30)
            var last = newestVoiceNode()
            while Date() < deadline, ((last?["items"] as? [[String: Any]]) ?? []).contains(where: {
                ($0["type"] as? String) == "text" && (($0["content"] as? String) ?? "").isEmpty }) {
                Thread.sleep(forTimeInterval: 0.5); last = newestVoiceNode()
            }
            Thread.sleep(forTimeInterval: 1)
            n = newestVoiceNode()
        }
        print("[ArcA] \(label) after-Done disk: \(describe(n))")
        shot(app, "\(label)-after-Done")
        if delegateOn {
            XCTAssertFalse(str(n, "title").isEmpty, "\(label): Done must commit a TITLE — \(describe(n))")
            XCTAssertFalse(str(n, "summary").isEmpty, "\(label): Done must commit a SUMMARY — \(describe(n))")
        } else {
            XCTAssertTrue(str(n, "title").isEmpty && str(n, "summary").isEmpty,
                          "\(label): with the setting OFF Done writes nothing — \(describe(n))")
            XCTAssertGreaterThan(proposals(n), 0, "\(label): the offer stays for the lever — \(describe(n))")
        }
    }

    private func quickCaptureVoice(_ app: XCUIApplication) { awaitCaptureScreen(app) }

    /// The regular "+" capture (`-RealCapturePlus` runs the exact "+" action: a capture node pushed in the entry
    /// editor). Its Voice lives in the entry's "+" menu.
    private func plusCaptureVoice(_ app: XCUIApplication) {
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 30), "the \"+\" capture editor should open")
        hideKeyboard(app)
        let add = app.buttons["entryAddButton"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the entry's + menu should exist")
        add.tap()
        let voice = app.buttons["Voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "the + menu should offer Voice")
    }

    private static let off = ["-library.autoNameCaptures", "<false/>"]
    /// The "+" capture with its capture flag held (the Librarian ducked, as on the real "+" path). `-RealCapturePlus`
    /// alone clears the flag (a Brief CD device repro), which raises the Librarian's pill over the capture's Done.
    private static let plus = ["-RealCapturePlus", "-RealCapturePlusKeepFlag"]

    // MARK: - rows: setting OFF (T's phone)

    /// Cold launch straight into Quick Capture (the Action Button order).
    func testOff_QC_cold() {
        let app = launch(["-EntryQuikCapture"] + Self.off)
        captureVoice(app, label: "off-QC-cold", delegateOn: false, openVoice: quickCaptureVoice)
    }

    /// T's acceptance for the OFF case: the offer is not lost — reopening the entry, the lever offers it.
    func testOff_QC_cold_leverOffersAfterReopen() {
        let app = launch(["-EntryQuikCapture"] + Self.off)
        captureVoice(app, label: "off-QC-reopen", delegateOn: false, openVoice: quickCaptureVoice)
        app.launchArguments = baseArgs(2500) + Self.off   // keep the library (no -Fresh)
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the capture should be in Recents")
        row.tap()
        XCTAssertTrue(app.buttons["Review proposals"].waitForExistence(timeout: 10),
                      "reopened, the lever should offer the kept title/summary")
        XCTAssertFalse(ghostShowing(app).exists, "a reopened entry never shows a ghost")
        shot(app, "off-QC-reopen-lever")
    }

    /// Warm: a second Quick Capture in the same launch (Action Button with the app already running).
    func testOff_QC_warm() {
        let app = launch(["-EntryQuikCapture"] + Self.off)
        captureVoice(app, label: "off-QC-warm-1", delegateOn: false, openVoice: quickCaptureVoice)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        markBaseline()
        app.open(URL(string: "airpad://quikcapture")!)
        captureVoice(app, label: "off-QC-warm-2", delegateOn: false, openVoice: quickCaptureVoice)
    }

    /// The regular "+" capture.
    func testOff_plus() {
        let app = launch(Self.plus + Self.off)
        captureVoice(app, label: "off-plus", delegateOn: false, openVoice: plusCaptureVoice)
    }

    // MARK: - rows: setting ON (the default)

    func testOn_QC_cold() {
        let app = launch(["-EntryQuikCapture"])
        captureVoice(app, label: "on-QC-cold", delegateOn: true, openVoice: quickCaptureVoice)
    }

    func testOn_QC_warm() {
        let app = launch(["-EntryQuikCapture"])
        captureVoice(app, label: "on-QC-warm-1", delegateOn: true, openVoice: quickCaptureVoice)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        markBaseline()
        app.open(URL(string: "airpad://quikcapture")!)
        captureVoice(app, label: "on-QC-warm-2", delegateOn: true, openVoice: quickCaptureVoice)
    }

    func testOn_plus() {
        let app = launch(Self.plus)
        captureVoice(app, label: "on-plus", delegateOn: true, openVoice: plusCaptureVoice)
    }

    /// Cold launch against a full-size library (the read-only fixture clone; every write lands in a scratch copy),
    /// so the initial load takes as long as a real one — the window the directive's load-race hypothesis names.
    func testOn_QC_cold_fullLibrary() {
        let fixture = NSHomeDirectory().components(separatedBy: "/Library/Developer")[0] + "/Developer/fixtures/tom-corpus-2026-09-21"
        let app = XCUIApplication()
        app.launchArguments = baseArgs(2500).filter { $0 != "-UITestLibrary" } + ["-CorpusFixture", fixture, "-EntryQuikCapture"]
        markBaseline()
        app.launch()
        captureVoice(app, label: "on-QC-cold-full", delegateOn: true, openVoice: quickCaptureVoice)
    }
}
