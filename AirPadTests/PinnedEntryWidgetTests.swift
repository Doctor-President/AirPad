import XCTest
@testable import AirPad

/// ws-1.0-widget — the Pinned Entry widget's saved copy (written on change, removed on delete, survives relaunch,
/// never holds a private entry or anything while the Face ID lock is on), the picker's query and what a widget shows.
@MainActor
final class PinnedEntryWidgetTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL { dir.appendingPathComponent("Widget/pinned-entries.json") }
    private var reloads = 0

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-\(UUID().uuidString)")
        reloads = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writer() -> PinnedEntryMirrorWriter {
        PinnedEntryMirrorWriter(fileURL: fileURL, reload: { [weak self] in self?.reloads += 1 })
    }

    private func node(_ id: String, title: String = "", text: String? = nil, updated: TimeInterval = 0,
                      isPrivate: Bool = false, summary: String = "") -> Node {
        let at = Date(timeIntervalSince1970: 1_700_000_000 + updated)
        var items: [NodeItem] = []
        if let text { items.append(NodeItem(id: "\(id)-note", type: .text, createdAt: at, content: text)) }
        var n = Node(id: id, createdAt: at, updatedAt: at, title: title, summary: summary, tags: [], items: items)
        n.isPrivate = isPrivate
        return n
    }

    // MARK: - The copy's content

    func testChecklistKeepsTickedStateAndDropsMarkdown() {
        let e = PinnedEntryMirrorWriter.entry(for: node("a", title: "To do",
            text: "- \\[x] **Buy** milk\n- \\[ ] Call [the bank](https://example.com)\n\n[ ] bare\n# Later\n- a bullet\nplain *text*"))
        XCTAssertEqual(e.title, "To do")
        XCTAssertEqual(e.lines, [
            .init(kind: .check, done: true, text: "Buy milk"),
            .init(kind: .check, done: false, text: "Call the bank"),
            .init(kind: .check, done: false, text: "bare"),
            .init(kind: .heading, text: "Later"),
            .init(kind: .bullet, text: "a bullet"),
            .init(kind: .text, text: "plain text"),
        ])
    }

    func testUntitledEntryUsesItsFirstLineOnce() {
        let e = PinnedEntryMirrorWriter.entry(for: node("u", text: "## First line\nsecond"))
        XCTAssertEqual(e.title, "First line")
        XCTAssertEqual(e.lines.map(\.text), ["second"])
        XCTAssertEqual(PinnedEntryMirrorWriter.entry(for: node("v")).title, "Untitled")
        XCTAssertEqual(PinnedEntryMirrorWriter.entry(for: node("w", summary: "A **short** summary")).lines,
                       [.init(kind: .text, text: "A short summary")], "no text: the summary stands in")
    }

    func testLinesAndLengthsAreCapped() {
        let long = (1...40).map { "line \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n")
        let e = PinnedEntryMirrorWriter.entry(for: node("c", title: "Caps", text: long))
        XCTAssertEqual(e.lines.count, PinnedEntryMirror.maxLines)
        XCTAssertEqual(e.lines.count + e.more, 40, "the rows not kept are counted for \"+N more\"")
        XCTAssertTrue(e.lines.allSatisfy { $0.text.count <= PinnedEntryMirror.maxLineLength })
    }

    func testPrivateEntriesNeverInTheCopyAndLockEmptiesIt() {
        let w = writer()
        let nodes = [node("pub", title: "Public", text: "x", updated: 1), node("priv", title: "Secret", text: "y", isPrivate: true)]
        let m = w.build(nodes: nodes, locked: false, font: "lato")
        XCTAssertEqual(m.entries.map(\.id), ["pub"])
        let locked = w.build(nodes: nodes, locked: true, font: "lato")
        XCTAssertTrue(locked.locked)
        XCTAssertTrue(locked.entries.isEmpty)
        let data = PinnedEntryMirrorFile.encode(locked)!
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Public"), "nothing of the library while locked")
    }

    func testNewestChangeFirst() {
        let m = writer().build(nodes: [node("old", title: "Old", updated: 1), node("new", title: "New", updated: 9),
                                       node("mid", title: "Mid", updated: 5)], locked: false, font: "lato")
        XCTAssertEqual(m.entries.map(\.id), ["new", "mid", "old"])
    }

    // MARK: - Written on change, removed on delete, survives relaunch

    func testWrittenOnChangeOnlyAndReadBack() {
        let w = writer()
        var nodes = [node("a", title: "To do", text: "- \\[ ] one")]
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato"))
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(w.write(nodes: nodes, locked: false, font: "lato"), "same content: no write, no reload")
        XCTAssertEqual(reloads, 1)

        nodes[0].items[0].content = "- \\[x] one"   // the tick, made in the app
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato"))
        XCTAssertEqual(reloads, 2)
        let m = PinnedEntryMirrorFile.read(at: fileURL)
        XCTAssertEqual(m?.entries.first?.lines, [.init(kind: .check, done: true, text: "one")])
    }

    func testChangesTheWidgetDoesNotShowWriteNothing() {
        let w = writer()
        var nodes = [node("a", title: "A", text: "one")]
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato"))
        nodes[0].tags = ["x"]                       // not shown by the widget
        nodes[0].contentEmbedding = [0.1, 0.2]      // a backfill
        XCTAssertFalse(w.write(nodes: nodes, locked: false, font: "lato"))
        XCTAssertFalse(w.lastBuildChanged)
        XCTAssertEqual(reloads, 1)
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato"), "the lock empties it")
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato"), "and unlocking brings it back")
        XCTAssertEqual(reloads, 3)
    }

    /// A large library (3,000 entries, ~2 KB of text each): the first build, and the pass that runs after every store
    /// change (nothing changed for the widget). Logged, with a loose ceiling so a regression shows.
    func testLargeLibraryCost() {
        let body = (1...40).map { "- \\[ ] item \($0) with a few words of text in it" }.joined(separator: "\n")
        let nodes = (0..<3000).map { node("n\($0)", title: "Entry \($0)", text: body, updated: Double($0)) }
        let w = writer()
        var t = Date()
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato"))
        let first = Date().timeIntervalSince(t)
        t = Date()
        XCTAssertFalse(w.write(nodes: nodes, locked: false, font: "lato"))
        let again = Date().timeIntervalSince(t)
        let size = (try? Data(contentsOf: fileURL).count) ?? 0
        print("[PinnedEntryWidgetTests] 3000 entries: first \(Int(first * 1000)) ms, unchanged pass \(Int(again * 1000)) ms, file \(size / 1024) KB")
        XCTAssertLessThan(again, 0.1, "the pass after an unrelated store change stays cheap")
    }

    func testRemovedOnDelete() {
        let w = writer()
        w.write(nodes: [node("a", title: "A", updated: 1), node("b", title: "B")], locked: false, font: "lato")
        w.write(nodes: [node("b", title: "B")], locked: false, font: "lato")
        let m = PinnedEntryMirrorFile.read(at: fileURL)
        XCTAssertEqual(m?.entries.map(\.id), ["b"])
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: m), .missing)
    }

    func testSurvivesRelaunch() {
        let nodes = [node("a", title: "Kept", text: "line")]
        writer().write(nodes: nodes, locked: false, font: "sourceSerif4")
        // A new process: a fresh writer and a fresh read find the same copy, and an unchanged library rewrites nothing.
        let again = writer()
        XCTAssertEqual(PinnedEntryMirrorFile.read(at: fileURL)?.entries.first?.title, "Kept")
        XCTAssertEqual(PinnedEntryMirrorFile.read(at: fileURL)?.font, "sourceSerif4")
        XCTAssertFalse(again.write(nodes: nodes, locked: false, font: "sourceSerif4"))
        XCTAssertEqual(reloads, 1)
    }

    func testUnknownVersionReadsAsNotSetUp() {
        var m = PinnedEntryMirror()
        m.version = 99
        XCTAssertNil(PinnedEntryMirrorFile.decode(PinnedEntryMirrorFile.encode(m)!))
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: nil), .notSetUp)
    }

    // MARK: - The picker (entity query) and what a widget shows

    func testPickerSuggestsRecentAndSearchesTitleAndFirstLine() {
        let m = writer().build(nodes: [node("t", title: "To do", text: "- \\[ ] buy café beans", updated: 3),
                                       node("r", title: "Recipes", text: "Bread", updated: 2),
                                       node("n", title: "Notes", text: "nothing", updated: 1)],
                               locked: false, font: "lato")
        XCTAssertEqual(m.suggestions(limit: 2).map(\.id), ["t", "r"])
        XCTAssertEqual(m.search("recipe").map(\.id), ["r"])
        XCTAssertEqual(m.search("CAFE").map(\.id), ["t"], "first line, case and accents ignored")
        XCTAssertEqual(m.search("  ").map(\.id), ["t", "r", "n"])
        XCTAssertTrue(m.search("zzz").isEmpty)
    }

    func testDisplayStates() {
        let full = writer().build(nodes: [node("a", title: "A")], locked: false, font: "lato")
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: full), .entry(full.entries[0]))
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: nil, mirror: full), .notChosen)
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "gone", mirror: full), .missing)
        let empty = PinnedEntryMirror()
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: nil, mirror: empty), .emptyLibrary)
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: empty), .emptyLibrary)
        var locked = PinnedEntryMirror(); locked.locked = true
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: locked), .locked)
    }

    func testEntryLinkRoundTrips() {
        let url = WidgetEntryLink.url(for: "2C1F-entry id")!
        XCTAssertEqual(url.scheme, "airpad")
        XCTAssertEqual(WidgetEntryLink.entryID(from: url), "2C1F-entry id")
        XCTAssertNil(WidgetEntryLink.entryID(from: URL(string: "airpad://quikcapture")!))
    }
}
