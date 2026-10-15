import XCTest
import UIKit

/// live-15 (1) — T's device: a capture, then an imported 11-page PDF got a title about neither (it echoed the naming
/// prompt's own example) and no summary — the naming call saw only the file name. On the REAL screens: a typed Quick
/// Capture → Done, THEN a new capture whose document comes through the system Files picker (Document button), or through
/// the Files app's share sheet into the AirPad extension. The entry's title + summary must come from the PDF's own text
/// (`-StubEchoInput` names an entry from the words its naming call was given), carry none of the earlier capture's
/// words, and be set together. The synthetic PDF is placed in the Simulator's "On My iPhone" storage. Simulator only.
final class DocumentImportNaming: XCTestCase {

    static let captureText = "Orchard notes the frost arrived early so the apple harvest moved forward and the pickers worked the hillside rows"
    static let captureTerms = ["orchard", "frost", "apple", "harvest", "pickers", "hillside"]
    static let pdfTerms = ["breakwater", "survey", "lighthouse", "keepers", "tides", "beacon", "harbour", "tide", "heights", "storms", "season", "maintenance"]
    static let pages = [
        "Breakwater Survey. The lighthouse keepers logged the spring tides along the northern breakwater every evening.",
        "Beacon maintenance: the keepers replaced the beacon lens and recorded tide heights at the harbour mouth.",
        "Summary of the season: the breakwater held through four storms; the lighthouse beacon never failed.",
    ]

    /// The model stub that names from its input, the scratch library, auto-name ON (T's setting).
    static let base = ["-StubAuthorModel", "-StubEchoInput", "-EmbedCPUOnly", "-UITestLibrary", "-library.autoNameCaptures", "<true/>"]

    override func setUp() { continueAfterFailure = false }

    // MARK: - Harness

    /// The Simulator's "On My iPhone" folder (the Files local-storage app group), found from the runner's own container.
    private static func onMyIPhone() -> URL? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: NSHomeDirectory())
        while dir.lastPathComponent != "Containers", dir.path != "/" { dir.deleteLastPathComponent() }
        let groups = dir.appendingPathComponent("Shared/AppGroup")
        for g in (try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let meta = g.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            if let d = NSDictionary(contentsOf: meta), (d["MCMMetadataIdentifier"] as? String) == "group.com.apple.FileProvider.LocalStorage" {
                return g.appendingPathComponent("File Provider Storage")
            }
        }
        return nil
    }

    private static func placePDF(named name: String) throws {
        guard let folder = onMyIPhone() else { throw XCTSkip("no On My iPhone storage in this Simulator") }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 400)).pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                (text as NSString).draw(in: CGRect(x: 20, y: 20, width: 360, height: 360), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).pdf"), options: .atomic)
    }

    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-EntryQuikCapture"] + (fresh ? ["-UITestLibraryFresh"] : [])
        app.launch()
        XCTAssertTrue(app.textViews["noteEditor"].waitForExistence(timeout: 20), "Quick Capture should open")
        return app
    }

    /// Capture 1: type a note → Done, and wait until it is named (the earlier capture T made before importing). Quick
    /// Capture writes its entry when it opens, so the entry is found by its words, not as "new since launch".
    private func typedCapture() -> String {
        let app = launch(fresh: true)
        _ = app.keyboards.element.waitForExistence(timeout: 10)
        app.textViews["noteEditor"].typeText(Self.captureText)
        Self.hideKeyboard(app)
        app.buttons["Done"].firstMatch.tap()
        func capture() -> [String: Any]? {
            OneEntryInvariant.scratchNodes().first { n in
                ((n["items"] as? [[String: Any]]) ?? []).contains { (($0["content"] as? String) ?? "").contains("Orchard notes") }
            }
        }
        let named = OneEntryInvariant.eventually(20) { !((capture()?["title"] as? String) ?? "").isEmpty }
        print("[DocumentImportNaming] capture found=\(capture() != nil) named=\(named)")
        XCTAssertTrue(named, "the typed capture is named")
        app.terminate()
        return (capture()?["id"] as? String) ?? ""
    }

    /// The keyboard's own toolbar can carry a "Done": put the keyboard away first so Done is the capture's.
    static func hideKeyboard(_ app: XCUIApplication) {
        let tip = app.buttons["Continue"].firstMatch
        if tip.exists { tip.tap() }
        let hide = app.buttons["keyboard.chevron.compact.down"]
        if hide.waitForExistence(timeout: 3) { hide.tap() }
        _ = app.keyboards.element.waitForNonExistence(timeout: 5)
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)) }

    /// The document entry's committed title + summary: about the PDF, none of the capture, both set.
    private func assertNamedFromPDF(_ label: String, excluding earlier: Set<String>) {
        var node: [String: Any]?
        let ok = OneEntryInvariant.eventually(30) {
            node = OneEntryInvariant.scratchNodes().first { n in
                !earlier.contains((n["id"] as? String) ?? "")
                    && ((n["items"] as? [[String: Any]]) ?? []).contains { ($0["type"] as? String) == "document" }
            }
            let s = (node?["summary"] as? String) ?? ""
            return !s.isEmpty
        }
        let title = (node?["title"] as? String) ?? "", summary = (node?["summary"] as? String) ?? ""
        let tHits = Self.pdfTerms.filter { words(title).contains($0) }, sHits = Self.pdfTerms.filter { words(summary).contains($0) }
        let leaked = Self.captureTerms.filter { words(title + " " + summary).contains($0) }
        print("[DocumentImportNaming] \(label) found=\(node != nil) titled=\(!title.isEmpty) titlePDFTerms=\(tHits.count) summaryChars=\(summary.count) summaryPDFTerms=\(sHits.count) captureTerms=\(leaked.count)")
        XCTAssertTrue(ok, "\(label): the document entry gets a summary (title \"\(title)\")")
        XCTAssertFalse(tHits.isEmpty, "\(label): the title comes from the PDF's text (got \"\(title)\")")
        XCTAssertFalse(sHits.isEmpty, "\(label): the summary comes from the PDF's text")
        XCTAssertTrue(leaked.isEmpty, "\(label): nothing from the earlier capture (\(leaked))")
    }

    // MARK: - Rows

    func testFilesPicker_afterCapture_namesFromThePDF() throws {
        try Self.placePDF(named: "quarterly-brief")
        let first = typedCapture()
        let earlier = OneEntryInvariant.scratchIDs().union([first])

        let app = launch(fresh: false)
        Self.hideKeyboard(app)
        let doc = app.buttons["Document"].firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 10), "the Document capture button")
        doc.tap()
        // The system picker (a remote view): Browse → On My iPhone → the file → Open.
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 10) { browse.tap() }
        let local = app.staticTexts["On My iPhone"].firstMatch
        if local.waitForExistence(timeout: 5) { local.tap() }
        let file = app.staticTexts["quarterly-brief"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the synthetic PDF in On My iPhone")
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(OneEntryInvariant.eventually(15) {
            OneEntryInvariant.scratchNodes().contains { n in
                !earlier.contains((n["id"] as? String) ?? "")
                    && ((n["items"] as? [[String: Any]]) ?? []).contains { ($0["type"] as? String) == "document" }
            }
        }, "the picked PDF lands in the capture")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "files-before-Done"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].firstMatch.tap()
        assertNamedFromPDF("files-picker", excluding: earlier)
    }

    func testShareSheet_afterCapture_namesFromThePDF() throws {
        try Self.placePDF(named: "harbour-brief")
        let first = typedCapture()
        let earlier = OneEntryInvariant.scratchIDs().union([first])

        // The Files app → On My iPhone → long-press the PDF → Share → AirPad.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        let browse = files.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 10) { browse.tap() }
        let local = files.staticTexts["On My iPhone"].firstMatch
        if local.waitForExistence(timeout: 5) { local.tap() }
        let file = files.staticTexts["harbour-brief"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the synthetic PDF in On My iPhone")
        file.press(forDuration: 1.2)
        let share = files.buttons["Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Share in the file's menu")
        share.tap()
        let target = files.descendants(matching: .any).matching(NSPredicate(format: "label == 'AirPad'")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "AirPad in the share sheet")
        target.tap()
        Thread.sleep(forTimeInterval: 4)   // the extension stages the item and closes itself
        let shot = XCTAttachment(screenshot: files.screenshot()); shot.name = "share-after-AirPad"; shot.lifetime = .keepAlways; add(shot)
        files.terminate()

        // AirPad imports the share inbox at launch / foreground and names it.
        let app = XCUIApplication()
        app.launchArguments = Self.base
        app.launch()
        assertNamedFromPDF("share-sheet", excluding: earlier)
    }
}
