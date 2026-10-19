import XCTest

/// live-29 (C1) — T: "in ANY chat once it reaches about 5 turns, scrolling stops short of the end; the ↓ arrow goes down a
/// bit, then springs back up". A seeded chat opens already laid out, so this row builds the chat LIVE, turn by turn,
/// through the real Librarian on the runaway stub stack (`scripts/runaway/run.sh`: a Host from source → the fake Ollama,
/// whose "harbour log turn k" answers are multi-paragraph Markdown ending "End of answer k."). After each answer it
/// checks the end three ways — as the answer lands, after the ↓ arrow, after a drag to the end — and reports the turn
/// (and message count) where it first fails. Geometry per change: `-ScrollGeoLog YES -StdoutToFile`.
final class ChatScrollLiveUI: XCTestCase {
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[ScrollLive] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func askField(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue IN {'Ask', 'Message'} OR label IN {'Ask', 'Message'}")
        let f = app.textFields.matching(pred).firstMatch
        return f.exists ? f : app.textViews.matching(pred).firstMatch
    }
    private func endState(_ app: XCUIApplication, turn k: Int) -> (visible: Bool, detail: String) {
        let last = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "End of answer \(k).")).firstMatch
        guard last.exists else { return (false, "answer \(k) not in the tree") }
        let bottom = askField(app).exists ? askField(app).frame.minY - 8 : app.windows.firstMatch.frame.maxY
        let f = last.frame
        return (f.maxY <= bottom + 1 && f.maxY > 0,
                String(format: "answer maxY=%.0f visible bottom=%.0f (short by %.0f)", f.maxY, bottom, max(0, f.maxY - bottom)))
    }

    func testLiveTurnsStayScrollableToTheEnd() throws {
        guard let host = ProcessInfo.processInfo.environment["RUNAWAY_HOST_ARGS"], !host.isEmpty else {
            throw XCTSkip("needs RUNAWAY_HOST_ARGS (scripts/runaway/run.sh)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-ResetLibrarianRoute", "YES", "-OpenMap",
                               "-GauntletUI", "YES", "-EmbedCPUOnly", "-LibrarianDetent", "full",
                               "-DebugHostModel", "qwen3:4b-instruct-2507-q4_K_M", "-ScrollGeoLog", "YES", "-StdoutToFile"]
            + host.split(separator: " ").map(String.init)
        app.launch()
        let lib = app.buttons["Library mode"]
        if lib.waitForExistence(timeout: 30) { lib.tap() }
        XCTAssertTrue(app.buttons["General mode"].waitForExistence(timeout: 5), "could not switch to General")
        var firstFail: String? = nil
        for k in 1...7 {
            let field = askField(app)
            XCTAssertTrue(field.waitForExistence(timeout: 10), "Ask field missing at turn \(k)")
            field.tap()
            if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); field.tap() }
            field.typeText("What does the harbour log turn \(k) say?")
            app.buttons["Send"].tap()
            // The answer finishes (no Stop control left), then a beat for the late rows (caption, actions).
            let stop = app.buttons["Stop answer"]
            _ = stop.waitForExistence(timeout: 10)
            let t0 = Date()
            while stop.exists && Date().timeIntervalSince(t0) < 90 { Thread.sleep(forTimeInterval: 0.5) }
            Thread.sleep(forTimeInterval: 2)
            if app.keyboards.element.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap(); Thread.sleep(forTimeInterval: 1) }
            let landed = endState(app, turn: k)
            // Up a little, then the ↓ arrow.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
            Thread.sleep(forTimeInterval: 1)
            let arrow = app.buttons["chat.scrollToLatest"]
            var arrowed: (visible: Bool, detail: String) = (true, "no ↓ arrow (chat shorter than the screen)")
            if arrow.waitForExistence(timeout: 2) {
                arrow.tap(); Thread.sleep(forTimeInterval: 2)
                arrowed = endState(app, turn: k)
                if !arrowed.visible { shot(app, "turn\(k)-arrow") }
            }
            for _ in 0..<5 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            }
            Thread.sleep(forTimeInterval: 2)
            let dragged = endState(app, turn: k)
            if !dragged.visible { shot(app, "turn\(k)-dragged") }
            let line = "turn \(k) (\(2 * k) messages): landed \(landed.visible ? "AT END" : "SHORT") — \(landed.detail) · arrow \(arrowed.visible ? "AT END" : "SHORT") — \(arrowed.detail) · drag \(dragged.visible ? "AT END" : "SHORT") — \(dragged.detail)"
            note(line)
            if firstFail == nil, !(arrowed.visible && dragged.visible) { firstFail = line }
        }
        shot(app, "turn7-final")
        XCTAssertNil(firstFail, "the chat stops short of the end: \(firstFail ?? "")")
    }
}
