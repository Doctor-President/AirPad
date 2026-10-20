import XCTest

/// live-30 (1) — the UIKit transcript keeps the end. Three rows, host-free (dead-port pairing; answers from
/// `-GauntletReplayB64`, no model):
///  1. 12 messages: the Chat view and the Librarian open on the last line, and ↓ lands on it again after scrolling up.
///  2. 200 messages (table, captions, sources, dated line, divider): the same, plus the Librarian panel still drags
///     half ↔ full.
///  3. A live answer: the end holds while it streams and while a table appears; asking while scrolled up doesn't move
///     the reader; ↓ then follows the answer to its end.
/// "On the last line" = the last answer's bottom is above the composer (the Ask / Message field).
final class ChatTranscriptEndUI: XCTestCase {
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[TranscriptEnd] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func field(_ app: XCUIApplication) -> XCUIElement {
        let pred = NSPredicate(format: "placeholderValue IN {'Ask', 'Message'} OR label IN {'Ask', 'Message'}")
        let f = app.textFields.matching(pred).firstMatch
        return f.exists ? f : app.textViews.matching(pred).firstMatch
    }
    private func visibleBottom(_ app: XCUIApplication) -> CGFloat {
        let f = field(app)
        return f.exists ? f.frame.minY - 8 : app.windows.firstMatch.frame.maxY
    }
    /// Is the element whose label contains `marker` fully above the composer (and on screen)?
    private func atEnd(_ app: XCUIApplication, _ marker: String) -> (ok: Bool, detail: String) {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        guard e.exists else { return (false, "'\(marker)' not on screen") }
        let f = e.frame, bottom = visibleBottom(app)
        return (f.maxY <= bottom + 1 && f.maxY > 0, String(format: "'%@' maxY=%.0f visible bottom=%.0f (short by %.0f)", marker, f.maxY, bottom, max(0, f.maxY - bottom)))
    }
    private func pullDown(_ app: XCUIApplication, times: Int) {   // the finger moves down = the transcript scrolls up
        for _ in 0..<times {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)))
        }
        Thread.sleep(forTimeInterval: 1)
    }
    private var deadHost: [String] {
        ["-DebugHostURL", "http://127.0.0.1:1", "-DebugHostSecret", "lab", "-DebugHostPubKey", Data(count: 32).base64EncodedString()]
    }

    /// Open + ↓ in the Chat view (a seeded chat from the Chats list).
    private func chatView(_ spec: String, name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedScrollChat", spec, "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll chat'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name): no seeded chat")
        row.tap()
        Thread.sleep(forTimeInterval: 2)
        let opened = atEnd(app, "END OF SCROLL CHAT")
        shot(app, "\(name)-chatview-opened")
        pullDown(app, times: 2)
        let arrow = app.buttons["chat.scrollToLatest"]
        let arrowShown = arrow.waitForExistence(timeout: 3)
        if arrowShown { arrow.tap(); Thread.sleep(forTimeInterval: 1.5) }
        let arrowed = atEnd(app, "END OF SCROLL CHAT")
        shot(app, "\(name)-chatview-arrow")
        note("\(name) Chat view: open \(opened.ok ? "AT END" : "SHORT") — \(opened.detail) · ↓ shown \(arrowShown) · ↓ \(arrowed.ok ? "AT END" : "SHORT") — \(arrowed.detail)")
        XCTAssertTrue(opened.ok, "\(name) Chat view opens short of the end — \(opened.detail)")
        XCTAssertTrue(arrowShown, "\(name) Chat view: no ↓ after scrolling up")
        XCTAssertTrue(arrowed.ok, "\(name) Chat view: ↓ lands short of the end — \(arrowed.detail)")
        app.terminate()
    }

    /// Open + ↓ in the Librarian (a seeded chat of `turns` turns, the panel at full). Returns the app for more checks.
    @discardableResult
    private func librarian(turns: Int, name: String, extra: [String] = [], keepOpen: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-EmbedCPUOnly", "-OpenMap", "-GauntletUI", "YES",
                               "-GauntletTapDir", "app-tmp", "-GauntletSeedChat", "\(turns)"] + deadHost + extra
        app.launch()
        let t0 = Date()
        while !field(app).exists && Date().timeIntervalSince(t0) < 60 { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(field(app).exists, "\(name): the Librarian chat didn't open")
        Thread.sleep(forTimeInterval: 2)
        let opened = atEnd(app, "End of seeded chat")
        shot(app, "\(name)-librarian-opened")
        pullDown(app, times: 2)
        let arrow = app.buttons["chat.scrollToLatest"]
        let arrowShown = arrow.waitForExistence(timeout: 3)
        if arrowShown { arrow.tap(); Thread.sleep(forTimeInterval: 1.5) }
        let arrowed = atEnd(app, "End of seeded chat")
        shot(app, "\(name)-librarian-arrow")
        note("\(name) Librarian: open \(opened.ok ? "AT END" : "SHORT") — \(opened.detail) · ↓ shown \(arrowShown) · ↓ \(arrowed.ok ? "AT END" : "SHORT") — \(arrowed.detail)")
        XCTAssertTrue(opened.ok, "\(name) Librarian opens short of the end — \(opened.detail)")
        XCTAssertTrue(arrowShown, "\(name) Librarian: no ↓ after scrolling up")
        XCTAssertTrue(arrowed.ok, "\(name) Librarian: ↓ lands short of the end — \(arrowed.detail)")
        if !keepOpen { app.terminate() }
        return app
    }

    func test1_OpenAndArrowLandOnTheLastLine_12() {
        chatView("12:prov", name: "m12")
        librarian(turns: 6, name: "m12")
    }

    func test2_OpenAndArrowLandOnTheLastLine_200_andThePanelDrags() {
        chatView("200:table,prov,sources,dated,divider", name: "m200")
        let app = librarian(turns: 100, name: "m200", keepOpen: true)
        // The panel still drags half ↔ full from its header (the transcript scrolls; the header moves the panel).
        let full = field(app).frame.minY
        let back = app.buttons["Back to Librarian home"]
        let backY0 = back.exists ? back.frame.minY : -1
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.105))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        Thread.sleep(forTimeInterval: 1.5)
        let topAfterDown = app.descendants(matching: .any).matching(identifier: "chat.transcript").firstMatch
        let transcriptTop = topAfterDown.exists ? topAfterDown.frame.minY : -1
        shot(app, "m200-librarian-half")
        let downEnd = atEnd(app, "End of seeded chat")
        let topNow = topAfterDown.exists ? topAfterDown.frame.minY : 400
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)).withOffset(CGVector(dx: 0, dy: topNow - 30))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        Thread.sleep(forTimeInterval: 1.5)
        let topAfterUp = topAfterDown.exists ? topAfterDown.frame.minY : -1
        shot(app, "m200-librarian-full-again")
        let upEnd = atEnd(app, "End of seeded chat")
        note(String(format: "m200 panel: field minY full=%.0f · back=%.0f · transcript top after drag down=%.0f, after drag up=%.0f · end after down %@ (%@) · after up %@ (%@)",
                    full, backY0, transcriptTop, topAfterUp, downEnd.ok ? "AT END" : "SHORT", downEnd.detail, upEnd.ok ? "AT END" : "SHORT", upEnd.detail))
        XCTAssertGreaterThan(transcriptTop - topAfterUp, 100, "the panel didn't drag half → full (transcript top \(transcriptTop) → \(topAfterUp))")
        XCTAssertTrue(downEnd.ok && upEnd.ok, "the end didn't hold through the panel drag — \(downEnd.detail) / \(upEnd.detail)")
        app.terminate()
    }

    /// Two streamed answers: prose, then a 24-row table, then the marker line; 120 / 220 ms between deltas (~7 / 13 s).
    private static func replay() -> String {
        func turn(_ k: Int) -> [String: Any] {
            var d: [[String]] = []
            // Every sentence distinct: the app's loop guard (correctly) stops an answer that repeats itself.
            let things = ["tides", "moorings", "dredger", "ferry", "slipway", "crane", "buoys", "pilot boat", "fog horn", "lock gates",
                          "fish market", "harbour wall", "lifeboat", "chandlery", "tug", "beacon", "breakwater", "jetty"]
            for p in 0..<6 {
                let a = things[(p * 3 + k) % things.count], b = things[(p * 3 + k + 1) % things.count], c = things[(p * 3 + k + 2) % things.count]
                for w in ["In week \(p + 1) of answer \(k) ", "the \(a) came first, ", "then the \(b) on day \(p + 2), ",
                          "and the \(c) closed out ", "the \(p + 1)th entry of the log.\n\n"] { d.append(["a", w]) }
            }
            d.append(["a", "| Week | High water | Low water |\n|---|---|---|\n"])
            for r in 1...24 { d.append(["a", "| \(r) | 06:\(10 + r) | 12:\(20 + r) |\n"]) }
            d.append(["a", "\nEND OF STREAMED ANSWER \(k)."])
            return ["deltas": d, "delayMs": k == 1 ? 120 : 220]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["turns": [turn(1), turn(2)]])
        return data.base64EncodedString()
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let f = field(app)
        f.tap()
        if !app.keyboards.element.waitForExistence(timeout: 3) { Thread.sleep(forTimeInterval: 1); f.tap() }
        f.typeText(text)
        app.buttons["Send"].tap()
    }

    func test3_TheEndHoldsWhileAnAnswerStreamsAndATableAppears() {
        let app = librarian(turns: 6, name: "stream", extra: ["-GauntletReplayB64", Self.replay()], keepOpen: true)
        let arrow = app.buttons["chat.scrollToLatest"], stop = app.buttons["Stop answer"]

        // (a) At the end, ask: the end holds as the answer streams and as its table appears.
        send(app, "What connections do you find between my ideas?")
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "no answer started")
        var samples = 0, arrowSeen = 0, tableSeenAtEnd = false
        let t0 = Date()
        while stop.exists && Date().timeIntervalSince(t0) < 60 {
            samples += 1
            if arrow.exists { arrowSeen += 1; shot(app, "stream-a-arrow-\(samples)") }
            if !tableSeenAtEnd, app.descendants(matching: .any).matching(identifier: "chatTable").firstMatch.exists, !arrow.exists { tableSeenAtEnd = true; shot(app, "stream-a-table") }
            Thread.sleep(forTimeInterval: 0.6)
        }
        Thread.sleep(forTimeInterval: 1.5)
        let endA = atEnd(app, "END OF STREAMED ANSWER 1")
        shot(app, "stream-a-done")
        note("stream (a): \(samples) samples while streaming, ↓ shown in \(arrowSeen) · table seen at the end: \(tableSeenAtEnd) · after: \(endA.ok ? "AT END" : "SHORT") — \(endA.detail)")
        XCTAssertEqual(arrowSeen, 0, "the end didn't hold while the answer streamed (↓ appeared in \(arrowSeen) of \(samples) samples)")
        XCTAssertTrue(tableSeenAtEnd, "the table never showed at the end")
        XCTAssertTrue(endA.ok, "the streamed answer ends short of the end — \(endA.detail)")

        // (b) Scrolled up, ask: the reader isn't moved. Then ↓: it follows the answer to its end.
        let f = field(app)
        if !app.keyboards.element.exists { f.tap(); _ = app.keyboards.element.waitForExistence(timeout: 3) }
        for _ in 0..<2 {   // short pulls above the keyboard (a pull into it would dismiss it)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)))
        }
        Thread.sleep(forTimeInterval: 1)
        if !app.keyboards.element.exists { f.tap(); _ = app.keyboards.element.waitForExistence(timeout: 3); Thread.sleep(forTimeInterval: 1) }
        let refs = app.staticTexts.allElementsBoundByIndex
            .filter { $0.frame.minY > 150 && $0.frame.maxY < f.frame.minY - 20 && $0.label.count > 20 }
        let ref = refs.first
        let refY0 = ref?.frame.minY ?? -1
        f.typeText("Which of those connections is the strongest, and why?")
        app.buttons["Send"].tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 15), "no second answer started")
        Thread.sleep(forTimeInterval: 3)
        let refY1 = ref?.frame.minY ?? -1
        let refLabel = String((ref?.label ?? "").prefix(40))
        let arrowWhileUp = arrow.exists
        shot(app, "stream-b-scrolled-up")
        note(String(format: "stream (b): reference line '%@' minY %.0f → %.0f after asking while scrolled up · ↓ shown %@", refLabel, refY0, refY1, arrowWhileUp ? "yes" : "no"))
        XCTAssertNotNil(ref, "no line on screen to watch")
        XCTAssertLessThanOrEqual(abs(refY1 - refY0), 2, "asking while scrolled up moved the reader (\(refY0) → \(refY1))")
        XCTAssertTrue(arrowWhileUp, "no ↓ while scrolled up")
        arrow.tap()
        Thread.sleep(forTimeInterval: 1)
        var arrowAgain = 0, followSamples = 0
        let t1 = Date()
        while stop.exists && Date().timeIntervalSince(t1) < 60 {
            followSamples += 1
            if arrow.exists { arrowAgain += 1 }
            Thread.sleep(forTimeInterval: 0.6)
        }
        Thread.sleep(forTimeInterval: 1.5)
        let endB = atEnd(app, "END OF STREAMED ANSWER 2")
        shot(app, "stream-b-done")
        note("stream (b): after ↓, \(followSamples) samples, ↓ shown again in \(arrowAgain) · after: \(endB.ok ? "AT END" : "SHORT") — \(endB.detail)")
        XCTAssertEqual(arrowAgain, 0, "after ↓ the transcript didn't follow the answer")
        XCTAssertTrue(endB.ok, "after ↓ the answer ends short of the end — \(endB.detail)")
        app.terminate()
    }

    /// Not one of the three end rows: the cell-hosted rows keep what the SwiftUI stack had — VoiceOver reads oldest →
    /// newest, the bubble's long-press Copy, the voice menu, and a table's full-screen viewer (presented by the
    /// transcript for its cell).
    func test4_CellsKeepTheirControlsAndReadingOrder() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedScrollChat", "12:table,prov,sources", "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll chat'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        Thread.sleep(forTimeInterval: 2)
        // Reading order: the accessibility tree lists the on-screen questions top to bottom.
        let texts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Scroll question' OR label BEGINSWITH 'Week '")).allElementsBoundByIndex
        let ys = texts.map { $0.frame.minY }
        let qs = texts.filter { $0.label.hasPrefix("Scroll question") }
        note("order: \(texts.map { String($0.label.prefix(18)) }) at y \(ys.map { Int($0) })")
        XCTAssertGreaterThanOrEqual(texts.count, 3)
        XCTAssertEqual(ys, ys.sorted(), "VoiceOver order isn't the screen's top-to-bottom order")
        // The voice menu.
        let voice = app.buttons.matching(identifier: "Choose voice").allElementsBoundByIndex.last
        voice?.tap()
        let best = app.buttons["Best available"].waitForExistence(timeout: 3) || app.staticTexts["Best available"].exists
        note("voice menu opened: \(best)")
        XCTAssertTrue(best, "the voice menu didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap(); Thread.sleep(forTimeInterval: 1)
        // The user bubble's long-press Copy.
        if let q = qs.last { q.press(forDuration: 1.2) }
        let copy = app.buttons["Copy"].waitForExistence(timeout: 3) || app.staticTexts["Copy"].exists
        note("bubble Copy menu: \(copy)")
        XCTAssertTrue(copy, "the bubble's long-press Copy didn't appear")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap(); Thread.sleep(forTimeInterval: 1)
        // The table (second-to-last answer): scroll up to its expand control, open it full screen.
        let expand = app.buttons["chatTableExpand"]
        var tries = 0
        while !(expand.exists && expand.isHittable) && tries < 8 { pullDown(app, times: 1); tries += 1 }
        XCTAssertTrue(expand.exists && expand.isHittable, "no table expand control")
        expand.tap()
        let full = app.descendants(matching: .any).matching(identifier: "chatTableFullScreen").firstMatch.waitForExistence(timeout: 4)
        shot(app, "table-full-screen")
        note("table full screen: \(full)")
        XCTAssertTrue(full, "the table's full-screen viewer didn't open")
        app.terminate()
    }
}
