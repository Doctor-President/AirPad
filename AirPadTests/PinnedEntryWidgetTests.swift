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
    // MARK: - widget fix-up 1 · the locked tile says how AirPad unlocks

    func testLockedCopyCarriesHowItUnlocksAndNothingElse() {
        let w = writer()
        let nodes = [node("a", title: "Public", text: "x")]
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", unlock: "faceID"))
        let m = PinnedEntryMirrorFile.read(at: fileURL)
        XCTAssertEqual(m?.locked, true)
        XCTAssertEqual(m?.unlock, "faceID")
        XCTAssertEqual(m?.entries.isEmpty, true, "still no entries while locked: the picker stays empty")
        XCTAssertEqual(m?.search("Public").isEmpty, true)
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: m), .locked)
        // The phone's method changing (Face ID turned off → passcode) rewrites the locked copy; the same one doesn't.
        XCTAssertFalse(w.write(nodes: nodes, locked: true, font: "lato", unlock: "faceID"))
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", unlock: nil))
        XCTAssertNil(PinnedEntryMirrorFile.read(at: fileURL)?.unlock)
        // Unlocked, the copy never carries it (its bytes are as before the fix-up).
        XCTAssertTrue(w.write(nodes: nodes, locked: false, font: "lato", unlock: "faceID"))
        let open = PinnedEntryMirrorFile.readData(at: fileURL).map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(open.contains("unlock"))
    }

    func testCopyWithoutUnlockStillReads() {
        // A copy written by 673ace87 (no `unlock` key) reads as a plain lock, not as "Open AirPad".
        let old = #"{"entries":[],"font":"lato","locked":true,"version":1}"#
        let m = PinnedEntryMirrorFile.decode(Data(old.utf8))
        XCTAssertEqual(m?.locked, true)
        XCTAssertNil(m?.unlock)
        XCTAssertEqual(PinnedEntryMirror.unlockSymbol(m?.unlock), "lock.fill")
    }

    func testUnlockGlyphAndSentence() {
        XCTAssertEqual(PinnedEntryMirror.unlockSymbol("faceID"), "faceid")
        XCTAssertEqual(PinnedEntryMirror.unlockSymbol("touchID"), "touchid")
        XCTAssertEqual(PinnedEntryMirror.unlockSymbol("opticID"), "opticid")
        XCTAssertEqual(PinnedEntryMirror.unlockSymbol("somethingNew"), "lock.fill")
        XCTAssertEqual(PinnedEntryMirrorWriter.unlockKind(.faceID), "faceID")
        XCTAssertEqual(PinnedEntryMirrorWriter.unlockKind(.touchID), "touchID")
        XCTAssertEqual(PinnedEntryMirrorWriter.unlockKind(.opticID), "opticID")
        XCTAssertNil(PinnedEntryMirrorWriter.unlockKind(.passcode))
        XCTAssertNil(PinnedEntryMirrorWriter.unlockKind(.none))
        XCTAssertEqual(PinnedEntryMirror.lockedAccessibilityLabel("faceID"),
                       "AirPad is locked. Open AirPad and unlock it with Face ID to read your entries.")
        XCTAssertEqual(PinnedEntryMirror.lockedAccessibilityLabel(nil), "AirPad is locked. Open AirPad to read your entries.")
    }

    // MARK: - widget fix-up 2 · the locked widget is a per-widget choice

    func testAllowedIDsOnlyShrinkWhileLocked() {
        // Locked (Face ID not passed in this run): a switch flipped on adds nothing; one flipped off removes.
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: ["a"], configuredShow: ["a", "b"], unlocked: false), ["a"])
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: ["a", "b"], configuredShow: ["b"], unlocked: false), ["b"])
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: [], configuredShow: ["a"], unlocked: false), [])
        // Unlocked: exactly the widgets' choice.
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: [], configuredShow: ["a", "b"], unlocked: true), ["a", "b"])
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: ["a", "c"], configuredShow: ["b"], unlocked: true), ["b"])
        XCTAssertEqual(PinnedEntryMirror.allowedIDs(current: ["a"], configuredShow: [], unlocked: true), [])
    }

    func testLockedAllowedPlan() {
        var lockedCopy = PinnedEntryMirror(); lockedCopy.locked = true
        lockedCopy.entries = [PinnedEntryMirrorWriter.entry(for: node("a", title: "A"))]
        let open = writer().build(nodes: [node("a", title: "A"), node("b", title: "B")], locked: false, font: "lato")
        // The lock just turned on (the copy on disk isn't locked, or there is none): the empty locked copy, at once,
        // whatever is known about the widgets.
        XCTAssertEqual(PinnedEntryMirrorWriter.lockedAllowed(disk: open, configuredShow: ["a", "b"], libraryLoaded: true, unlocked: true), [])
        XCTAssertEqual(PinnedEntryMirrorWriter.lockedAllowed(disk: nil, configuredShow: nil, libraryLoaded: false, unlocked: true), [])
        // Already locked: wait for the library and the widgets' choices; then add only when unlocked.
        XCTAssertNil(PinnedEntryMirrorWriter.lockedAllowed(disk: lockedCopy, configuredShow: nil, libraryLoaded: true, unlocked: true))
        XCTAssertNil(PinnedEntryMirrorWriter.lockedAllowed(disk: lockedCopy, configuredShow: ["a"], libraryLoaded: false, unlocked: true))
        XCTAssertEqual(PinnedEntryMirrorWriter.lockedAllowed(disk: lockedCopy, configuredShow: ["a", "b"], libraryLoaded: true, unlocked: false), ["a"])
        XCTAssertEqual(PinnedEntryMirrorWriter.lockedAllowed(disk: lockedCopy, configuredShow: ["b"], libraryLoaded: true, unlocked: false), [])
        XCTAssertEqual(PinnedEntryMirrorWriter.lockedAllowed(disk: lockedCopy, configuredShow: ["a", "b"], libraryLoaded: true, unlocked: true), ["a", "b"])
    }

    func testLockedCopyHoldsOnlyTheAllowedEntriesNeverAPrivateOne() {
        let w = writer()
        let nodes = [node("a", title: "Shown", text: "- \\[ ] milk", updated: 2), node("b", title: "Hidden", text: "x", updated: 1),
                     node("p", title: "Secret", text: "y", isPrivate: true)]
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", unlock: "faceID", allowed: ["a", "p"]))
        let m = PinnedEntryMirrorFile.read(at: fileURL)
        XCTAssertEqual(m?.locked, true)
        XCTAssertEqual(m?.entries.map(\.id), ["a"], "only the allowed entry; a private one never, even if a widget asks")
        let text = PinnedEntryMirrorFile.readData(at: fileURL).map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(text.contains("Hidden")); XCTAssertFalse(text.contains("Secret"))
        // The picker while locked lists only what is in the copy.
        XCTAssertEqual(m?.suggestions().map(\.title), ["Shown"])
        XCTAssertTrue(m?.search("Hidden").isEmpty ?? false)
        // Freshness: an edit to the shown entry rewrites the copy; an edit to a hidden one doesn't.
        var edited = nodes
        edited[1].items[0].content = "changed"
        XCTAssertFalse(w.write(nodes: edited, locked: true, font: "lato", unlock: "faceID", allowed: ["a"]))
        edited[0].items[0].content = "- \\[x] milk"
        XCTAssertTrue(w.write(nodes: edited, locked: true, font: "lato", unlock: "faceID", allowed: ["a"]))
        XCTAssertEqual(PinnedEntryMirrorFile.read(at: fileURL)?.entries.first?.lines, [.init(kind: .check, done: true, text: "milk")])
        // Swapping one allowed entry for another (same count) rewrites; back to none empties it at once.
        XCTAssertTrue(w.write(nodes: edited, locked: true, font: "lato", unlock: "faceID", allowed: ["b"]))
        XCTAssertEqual(PinnedEntryMirrorFile.read(at: fileURL)?.entries.map(\.id), ["b"])
        XCTAssertTrue(w.write(nodes: edited, locked: true, font: "lato", unlock: "faceID", allowed: []))
        XCTAssertEqual(PinnedEntryMirrorFile.read(at: fileURL)?.entries.isEmpty, true)
    }

    func testLockedWriteComparesWithTheCopyOnDisk() {
        // The extension may cut the copy behind the writer's back; the writer compares with the file, not its memory.
        let w = writer()
        let nodes = [node("a", title: "A", text: "x", updated: 2), node("b", title: "B", text: "y", updated: 1)]
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", allowed: ["a", "b"]))
        let cut = PinnedEntryMirrorFile.read(at: fileURL)!.pruned(keeping: ["a"])
        PinnedEntryMirrorFile.write(PinnedEntryMirrorFile.encode(cut)!, to: fileURL)
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", allowed: ["a"]) == false,
                      "the file already holds exactly that: nothing to write")
        XCTAssertTrue(w.write(nodes: nodes, locked: true, font: "lato", allowed: ["a", "b"]),
                      "a stale memory of the old bytes doesn't stop a write")
    }

    func testDisplayFollowsTheWidgetsOwnSwitch() {
        let w = writer()
        let nodes = [node("a", title: "A", text: "x")]
        let open = w.build(nodes: nodes, locked: false, font: "lato")
        // Lock off: the switch changes nothing.
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", showWhenLocked: true, mirror: open), .entry(open.entries[0]))
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", showWhenLocked: false, mirror: open), .entry(open.entries[0]))
        // Lock on, the entry in the copy (another widget shows it).
        let locked = w.build(nodes: nodes, locked: true, font: "lato", allowed: ["a"])
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", showWhenLocked: false, mirror: locked), .locked,
                       "a hidden widget never reads the entry, even when the copy holds it")
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", showWhenLocked: true, mirror: locked), .shownWhileLocked(locked.entries[0]))
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "b", showWhenLocked: true, mirror: locked), .lockedNotYetShown)
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: nil, showWhenLocked: true, mirror: locked), .locked)
        XCTAssertEqual(PinnedEntryMirror.display(chosenID: "a", mirror: locked), .locked, "default: hidden")
        XCTAssertEqual(PinnedEntryMirror.notYetShownAccessibilityLabel("faceID"),
                       "AirPad is locked. Open AirPad and unlock it with Face ID to show this entry.")
    }

    func testExtensionCutOnlyRemoves() {
        let w = writer()
        let nodes = [node("a", title: "A", updated: 2), node("b", title: "B", updated: 1)]
        let locked = w.build(nodes: nodes, locked: true, font: "lato", allowed: ["a", "b"])
        XCTAssertEqual(locked.pruned(keeping: ["b", "c"]).entries.map(\.id), ["b"], "never adds c")
        XCTAssertEqual(locked.pruned(keeping: []).entries, [])
        let open = w.build(nodes: nodes, locked: false, font: "lato")
        XCTAssertEqual(open.pruned(keeping: []), open, "an unlocked copy is left alone")
    }

    func testShowIDsFromConfigurations() {
        XCTAssertEqual(PinnedEntryConfigurations.reduce([("a", true), ("b", false), (nil, true), ("c", true)]),
                       .init(show: ["a", "c"], settled: true))
        // The system's twin right after a switch is flipped (old + new value, either order): a hide wins, unsettled.
        XCTAssertEqual(PinnedEntryConfigurations.reduce([("a", false), ("a", true)]), .init(show: [], settled: false))
        XCTAssertEqual(PinnedEntryConfigurations.reduce([("a", true), ("a", false), ("b", true)]), .init(show: ["b"], settled: false))
        XCTAssertEqual(PinnedEntryConfigurations.reduce([("a", true), ("a", true)]), .init(show: ["a"], settled: true))
        XCTAssertEqual(PinnedEntryConfigurations.reduce([]), .init(show: [], settled: true))
        XCTAssertEqual(PinnedEntryIntent().showWhenLocked, false, "a widget placed before this build is hidden")
    }

    func testOpenCopyUnchangedByTheLockFields() {
        // Lock off: the copy's bytes carry no `unlock` and the `allowed` list is ignored.
        let w = writer()
        let nodes = [node("a", title: "A"), node("b", title: "B")]
        XCTAssertEqual(w.build(nodes: nodes, locked: false, font: "lato", unlock: "faceID", allowed: ["a"]).entries.count, 2)
        XCTAssertNil(w.build(nodes: nodes, locked: false, font: "lato", unlock: "faceID").unlock)
    }
}
