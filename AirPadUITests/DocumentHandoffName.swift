import XCTest

/// live-17 — T (TF 202610142134, 6 screenshots): tapping a document opened a viewer titled with the STORED file's UUID
/// name ("F1062A75-5970-…", "C4BDC027-DC8E-…") instead of the document's real name, which its card shows correctly.
/// Seen on a PDF and an HTML file. Its Share button hands the same UUID-named file to the recipient.
///
/// On the real screens: seeded synthetic documents stored under UUID names (`-UITestSeedDocumentEntries`), opened from
/// the entry — a single PDF (the single-document body) and an HTML page + a PDF in a two-document gallery (the gallery
/// tiles). Asserts:
///   - the viewer's title bar shows the display name, and no UUID;
///   - what the viewer is handed (its title, and the file its own Share button sends) is `<display name>.<ext>`;
///   - the item's "…" → Share hands the share sheet a file named `<display name>.<ext>`.
/// `DocumentHandoffProbe` logs what the viewer and the share sheet were handed (read from the app's stdout file).
/// Synthetic content only; scratch library. Simulator.
final class DocumentHandoffName: XCTestCase {

    static let base = ["-UITestLibrary", "-UITestSeedDocumentEntries", "-StdoutToFile", "-DocumentHandoffProbe",
                       "-EmbedCPUOnly", "-StubAuthorModel"]

    struct Doc { let node: String; let id: String; let ext: String; let display: String }
    static let docs = [
        Doc(node: "uitest-doc-single", id: "F1062A75-5970-4E1B-9C3A-2B7D51C0A001", ext: "pdf", display: "Harbour Survey Notes"),
        Doc(node: "uitest-doc-gallery", id: "C4BDC027-DC8E-4F7A-8E21-6A0B3D9E0002", ext: "html", display: "Tide Table Primer"),
        Doc(node: "uitest-doc-gallery", id: "9B2E4D61-0C7A-4B85-A3F9-1E6D2C8B0003", ext: "pdf", display: "Mooring Checklist"),
    ]

    override func setUp() { continueAfterFailure = true }   // every document reports

    // MARK: - Harness (same stdout-file pattern as HeroHeaderFlash)

    private static func appCaches() -> URL? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let caches = c.appendingPathComponent("Library/Caches")
            if fm.fileExists(atPath: caches.appendingPathComponent("AirPadUITestScratch").path) { return caches }
        }
        return nil
    }

    private static func clearLog() {
        if let log = appCaches()?.appendingPathComponent("stdout.log") { try? Data().write(to: log) }
    }

    private static func probe(_ kind: String, _ doc: String) -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
            .filter { $0.contains("[DocHandoff] \(kind) ") && $0.contains("doc=\(doc) ") }
    }

    private static func field(_ line: String, _ name: String) -> String {
        guard let r = line.range(of: " \(name)=") else { return "" }
        let rest = line[r.upperBound...]
        let next = ["title=", "file=", "files="].compactMap { rest.range(of: " " + $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<next])
    }

    /// Every label on screen, from one snapshot (querying elements one by one races the share sheet's own updates).
    private static func labels(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [String] = []
        func walk(_ e: XCUIElementSnapshot) {
            if !e.label.isEmpty { out.append(e.label) }
            e.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func launch(fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.base + (fresh ? ["-UITestLibraryFresh"] : [])
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens `doc`'s entry and returns its open target, scrolled into view.
    private func openEntry(_ app: XCUIApplication, _ doc: Doc) -> XCUIElement {
        let row = app.buttons["entryRow-\(doc.node)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(doc.node) is on Recents")
        row.tap()
        let target = app.descendants(matching: .any).matching(identifier: "documentOpen-\(doc.id)").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15), "\(doc.display): its open target")
        for _ in 0..<3 where !target.isHittable {
            app.descendants(matching: .any).matching(identifier: "documentOpen-\(Self.docs[1].id)").firstMatch.swipeLeft()
        }
        return target
    }

    /// Closes the viewer / share sheet and checks the named copy was removed (none left on disk).
    private func closeAndCheckReleased(_ app: XCUIApplication, _ doc: Doc, button: String) {
        let close = app.buttons[button].firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() } else { app.swipeDown(velocity: .fast) }
        let deadline = Date().addingTimeInterval(8)
        var released: [String] = []
        while Date() < deadline {
            released = Self.probe("released", doc.id)
            if !released.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[DocumentHandoffName] \(button) \(doc.display) released: \(released)")
        XCTAssertTrue(released.last?.hasSuffix(" left=0") == true, "\(doc.display): the named copy is removed when it closes (\(released))")
    }

    // MARK: - Rows

    func testViewerTitleIsTheDocumentsName() {
        let seeding = launch(fresh: true)
        XCTAssertTrue(seeding.buttons["entryRow-uitest-doc-gallery"].waitForExistence(timeout: 60), "seeded")
        seeding.terminate()
        for doc in Self.docs {
            let app = launch()
            let target = openEntry(app, doc)
            Self.clearLog()
            target.tap()
            let bar = app.navigationBars.firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 15), "\(doc.display): the viewer opened")
            Thread.sleep(forTimeInterval: 2)
            let labels = bar.staticTexts.allElementsBoundByIndex.map(\.label) + [bar.identifier]
            print("[DocumentHandoffName] viewer \(doc.display) title bar=\(labels)")
            shot(app, "viewer-\(doc.display)")
            XCTAssertTrue(labels.contains(doc.display), "\(doc.display): the viewer's title bar shows the name (saw \(labels))")
            XCTAssertFalse(labels.contains { $0.contains(String(doc.id.prefix(8))) }, "\(doc.display): no UUID in the title bar (saw \(labels))")
            let handed = Self.probe("preview", doc.id).last ?? Self.probe("preview", doc.display).last ?? ""
            print("[DocumentHandoffName] viewer \(doc.display) handed: \(handed)")
            XCTAssertEqual(Self.field(handed, "file"), "\(doc.display).\(doc.ext)",
                           "\(doc.display): the viewer (and its own Share) is handed <name>.<ext> (\(handed))")
            closeAndCheckReleased(app, doc, button: "Done")
            app.terminate()
        }
    }

    func testShareHandsTheDocumentsName() {
        let seeding = launch(fresh: true)
        XCTAssertTrue(seeding.buttons["entryRow-uitest-doc-gallery"].waitForExistence(timeout: 60), "seeded")
        seeding.terminate()
        for doc in Self.docs {
            let app = launch()
            _ = openEntry(app, doc)
            let menu = app.descendants(matching: .any).matching(identifier: "documentMenu-\(doc.id)").firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "\(doc.display): its options menu")
            Self.clearLog()
            menu.tap()
            let share = app.buttons["Share"].firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 5), "\(doc.display): the menu offers Share")
            share.tap()
            Thread.sleep(forTimeInterval: 3)   // the share sheet loads its header + targets
            shot(app, "share-\(doc.display)")
            let sheetTexts = Self.labels(app)
            print("[DocumentHandoffName] share \(doc.display) sheet texts=\(sheetTexts.prefix(12))")
            let handed = Self.probe("share", doc.id).last ?? Self.probe("share", doc.display).last ?? ""
            print("[DocumentHandoffName] share \(doc.display) handed: \(handed)")
            XCTAssertEqual(Self.field(handed, "files"), "\(doc.display).\(doc.ext)",
                           "\(doc.display): the share sheet is handed <name>.<ext> (\(handed))")
            XCTAssertFalse(sheetTexts.contains { $0.contains(String(doc.id.prefix(8))) }, "\(doc.display): no UUID on the share sheet (saw \(sheetTexts))")
            XCTAssertTrue(sheetTexts.contains(doc.display), "\(doc.display): the share sheet's header shows the name (saw \(sheetTexts.prefix(6)))")
            closeAndCheckReleased(app, doc, button: "Close")
            app.terminate()
        }
    }
}
