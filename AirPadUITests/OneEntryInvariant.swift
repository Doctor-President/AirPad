import XCTest

/// A3 (T, TF 202610131010) — one capture is ONE entry, everywhere. An Action Button capture left two rows in Recents
/// (one stale and untitled) and a blank card in Card view while the disk held one titled entry: the launch load and the
/// capture's own insert both put the node in the store. The capture suites only checked the fields on disk, which is
/// how it passed. Every capture row now also checks:
///   - exactly ONE new entry on disk;
///   - the live store (read through `-StoreProbe`) holds no duplicate ids and exactly the library on disk;
///   - the committed title is the same in the store, on disk, in Recents, in Card view and in List view.
/// Titles are never printed — only counts and matches.
enum OneEntryInvariant {

    /// Every entry in the Simulator's scratch libraries (the runner can read its sibling app containers).
    static func scratchNodes() -> [[String: Any]] {
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

    static func scratchIDs() -> Set<String> { Set(scratchNodes().compactMap { $0["id"] as? String }) }

    /// Ids on disk in the library (scratch container) that holds `id`.
    static func diskLibraryIDs(holding id: String) -> Set<String> {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            for scratch in ["AirPadUITestScratch", "AirPadCorpusFixtureScratch"] {
                let dir = c.appendingPathComponent("Library/Caches/\(scratch)/nodes")
                guard fm.fileExists(atPath: dir.appendingPathComponent("\(id)/node.json").path) else { continue }
                let ids = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { fm.fileExists(atPath: dir.appendingPathComponent("\($0)/node.json").path) }
                return Set(ids)
            }
        }
        return []
    }

    /// The live store, read through `-StoreProbe`: (node count, unique-id count, id → committed title).
    static func storeProbe(_ app: XCUIApplication) -> (count: Int, unique: Int, titles: [String: String])? {
        let probe = app.descendants(matching: .any)["storeProbe"]
        guard probe.waitForExistence(timeout: 5) else { return nil }
        let nums = probe.label.split(separator: " ").compactMap { Int($0.split(separator: "=").last ?? "") }
        guard nums.count == 2 else { return nil }
        var titles: [String: String] = [:]
        for line in ((probe.value as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { titles[String(parts[0])] = String(parts[1]) }
        }
        return (nums[0], nums[1], titles)
    }

    static func eventually(_ timeout: TimeInterval, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; Thread.sleep(forTimeInterval: 0.5) }
        return ok()
    }

    /// Run on Recents right after a capture's Done (both Quick Capture and the "+" capture land there). Leaves the app
    /// in the Library canvas, List view.
    static func assert(_ app: XCUIApplication, in test: XCTestCase, label: String, baseline: Set<String>,
                       file: StaticString = #filePath, line: UInt = #line) {
        let newIDs = scratchIDs().subtracting(baseline)
        XCTAssertEqual(newIDs.count, 1, "\(label): one capture adds exactly ONE entry on disk (found \(newIDs.count))", file: file, line: line)
        guard let id = newIDs.first,
              let n = scratchNodes().first(where: { ($0["id"] as? String) == id }) else { return }
        let title = (n["title"] as? String) ?? ""
        let disk = diskLibraryIDs(holding: id)

        // Store == disk, no duplicate ids, same title. (Give the async tail a moment to settle.)
        var p = storeProbe(app)
        _ = eventually(10) { p = storeProbe(app); return p.map { $0.count == $0.unique && Set($0.titles.keys) == disk } ?? false }
        let storeIDs = Set(p?.titles.keys.map { $0 } ?? [])
        print("[ArcA3] \(label) store nodes=\(p?.count ?? -1) unique=\(p?.unique ?? -1) disk=\(disk.count) "
              + "store⊖disk=\(storeIDs.subtracting(disk).count) disk⊖store=\(disk.subtracting(storeIDs).count) "
              + "storeTitle==disk:\(p?.titles[id] == title)")
        XCTAssertNotNil(p, "\(label): the store probe should be readable", file: file, line: line)
        XCTAssertEqual(p?.count, p?.unique, "\(label): the store holds NO duplicate ids (nodes=\(p?.count ?? -1) unique=\(p?.unique ?? -1))", file: file, line: line)
        XCTAssertEqual(storeIDs, disk, "\(label): the store holds exactly the library on disk (+1 per capture)", file: file, line: line)
        XCTAssertEqual(p?.titles[id], title, "\(label): the store's committed title equals the disk's", file: file, line: line)

        // Recents: one row for the entry, showing the committed title.
        let rows = app.buttons.matching(identifier: "entryRow-\(id)")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "\(label): Recents lists the entry", file: file, line: line)
        let showsTitle: () -> Bool = { rows.firstMatch.exists && (title.isEmpty || rows.firstMatch.label.contains(title)) }
        let recentsOK = eventually(10) { rows.count == 1 && showsTitle() }
        print("[ArcA3] \(label) recents rows=\(rows.count) showsTitle=\(showsTitle())")
        XCTAssertTrue(recentsOK, "\(label): Recents shows ONE row for the entry, with its committed title (rows=\(rows.count))", file: file, line: line)
        shot(app, test, "\(label)-recents")

        // Card view, then List view (the user's Library canvas — the Sample Library pane has a "Library" row too).
        let back = app.buttons["Back"].exists ? app.buttons["Back"] : app.buttons["chevron.backward"]
        if back.waitForExistence(timeout: 5) { back.tap() }
        let library = app.buttons.matching(identifier: "collectionRow-_corpus").firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "\(label): the Dashboard's Library row", file: file, line: line)
        library.tap()
        for (mode, prefix) in [("Card", "cardTile-"), ("List", "listRow-")] {
            let switcher = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View: '")).firstMatch
            XCTAssertTrue(switcher.waitForExistence(timeout: 10), "\(label): the view switcher", file: file, line: line)
            if switcher.label != "View: \(mode)" {
                switcher.tap()
                let item = app.buttons[mode].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 5), "\(label): the switcher offers \(mode)", file: file, line: line)
                item.tap()
            }
            let els = app.descendants(matching: .any).matching(identifier: "\(prefix)\(id)")
            if !els.firstMatch.waitForExistence(timeout: 10) {
                let any = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                print("[ArcA3] \(label) \(mode.lowercased()) entry not on screen; visible \(prefix)*=\(any.count)")
            }
            let titled: () -> Bool = {
                guard els.firstMatch.exists else { return false }
                return title.isEmpty || els.firstMatch.label.contains(title)
                    || els.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", title)).count > 0
            }
            let ok = eventually(5) { els.count == 1 && titled() }
            print("[ArcA3] \(label) \(mode.lowercased()) elements=\(els.count) showsTitle=\(titled())")
            XCTAssertTrue(ok, "\(label): \(mode) view shows ONE element for the entry, with its committed title (found \(els.count))", file: file, line: line)
            shot(app, test, "\(label)-\(mode.lowercased())")
        }
    }

    private static func shot(_ app: XCUIApplication, _ test: XCTestCase, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; test.add(s)
    }
}
