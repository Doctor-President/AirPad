import XCTest

/// live-29 (C1) — T (device, TF 202610191107): in ANY chat of about 5 turns or more, the transcript won't scroll to the end;
/// the ↓ arrow goes down a bit and the view springs back up. Seeded chats (`-UITestSeedScrollChat "<n>:<elements>"`, the
/// Chat view from the Chats list): on open, after the ↓ arrow, and after a drag to the end, the last answer's last line
/// ("END OF SCROLL CHAT.") must be fully visible above the composer. Geometry per change goes to stdout
/// (`-ScrollGeoLog YES -StdoutToFile`) for the report.
final class ChatScrollEndUI: XCTestCase {
    private func note(_ s: String) { let a = XCTAttachment(string: s); a.lifetime = .keepAlways; add(a); print("[ScrollEnd] \(s)") }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// The bottom of the visible transcript: the composer's top (the Ask field), else the window's bottom.
    private func visibleBottom(_ app: XCUIApplication) -> CGFloat {
        let pred = NSPredicate(format: "placeholderValue IN {'Ask', 'Message'} OR label IN {'Ask', 'Message'}")
        let field = app.textFields.matching(pred).firstMatch.exists ? app.textFields.matching(pred).firstMatch
            : app.textViews.matching(pred).firstMatch
        return field.exists ? field.frame.minY - 8 : app.windows.firstMatch.frame.maxY
    }
    /// The last answer (the one that ends "END OF SCROLL CHAT.") and where its bottom sits vs the visible bottom.
    private func endState(_ app: XCUIApplication) -> (visible: Bool, detail: String) {
        let last = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'END OF SCROLL CHAT'")).firstMatch
        guard last.exists else { return (false, "last answer not in the tree") }
        let f = last.frame, bottom = visibleBottom(app)
        let ok = f.maxY <= bottom + 1 && f.maxY > 0
        return (ok, String(format: "last answer maxY=%.0f visible bottom=%.0f (short by %.0f)", f.maxY, bottom, max(0, f.maxY - bottom)))
    }

    private func run(_ spec: String, name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedScrollChat", spec,
                               "-ScrollGeoLog", "YES", "-StdoutToFile", "-EmbedCPUOnly"]
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll chat'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name): no seeded chat")
        row.tap()
        Thread.sleep(forTimeInterval: 3)
        let opened = endState(app)
        shot(app, "\(name)-opened")
        // Scroll up (two short pulls — a pull from the very top would dismiss the Chats sheet), then the ↓ arrow.
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        Thread.sleep(forTimeInterval: 1)
        let arrow = app.buttons["chat.scrollToLatest"]
        var arrowed = (visible: false, detail: "no ↓ arrow")
        if arrow.waitForExistence(timeout: 3) {
            arrow.tap()
            Thread.sleep(forTimeInterval: 2)
            arrowed = endState(app)
            shot(app, "\(name)-arrow")
        } else if opened.visible == false {
            arrowed = (false, "no ↓ arrow while not at the end")
        } else {
            arrowed = (true, "short chat: no ↓ arrow needed")
        }
        // Drag to the end and let go.
        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        Thread.sleep(forTimeInterval: 2)
        let dragged = endState(app)
        shot(app, "\(name)-dragged")
        note("\(name) [\(spec)]: opened \(opened.visible ? "AT END" : "SHORT") — \(opened.detail) · arrow \(arrowed.visible ? "AT END" : "SHORT") — \(arrowed.detail) · drag \(dragged.visible ? "AT END" : "SHORT") — \(dragged.detail)")
        XCTAssertTrue(opened.visible, "\(name): opens short of the end — \(opened.detail)")
        XCTAssertTrue(arrowed.visible, "\(name): the ↓ arrow lands short of the end — \(arrowed.detail)")
        XCTAssertTrue(dragged.visible, "\(name): a drag to the end doesn't stay there — \(dragged.detail)")
        app.terminate()
    }

    // The message-count boundary first (plain answers, with the provenance captions every live answer has).
    func test08() { run("8:prov", name: "m08") }
    func test10() { run("10:prov", name: "m10") }
    func test12() { run("12:prov", name: "m12") }
    // Then size and every element.
    func test30() { run("30:prov", name: "m30") }
    func test30All() { run("30:table,prov,sources,dated,divider", name: "m30all") }
    func test80All() { run("80:table,prov,sources,dated,divider", name: "m80all") }
    func test200All() { run("200:table,prov,sources,dated,divider", name: "m200all") }
    func test10Plain() { run("10", name: "m10plain") }
    func test12Table() { run("12:table", name: "m12table") }
    func test12Sources() { run("12:sources", name: "m12sources") }
    func test12Dated() { run("12:dated", name: "m12dated") }
}
