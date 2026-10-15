import XCTest

/// live-19 (3a) — iOS 27: Apple's forums report `ScrollViewProxy.scrollTo` failing to reach UNREALISED rows of a lazy
/// stack (thread 848608 / FB24968838). Our `scrollTo` surfaces, driven on the real screens with the Sample Library
/// (210 entries; `-UITestSampleLibrary`):
///   - Card view's vertical stack (`LazyVStack`), the grid (`LazyVGrid`) and the List: `-DebugFocusSweep` fires the
///     REAL focus request (what a Librarian search row fires) at five nodes spread across the library, 5 s apart —
///     rows the surface has never realised. Each must end ON SCREEN.
///   - The chat transcript: a long synthetic chat (`-UITestSeedLongChat`, 80 messages) opens on its LAST answer.
/// Synthetic content only; scratch library.
final class ScrollToLanding: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private static func appCaches() -> URL? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let caches = c.appendingPathComponent("Library/Caches")
            if fm.fileExists(atPath: caches.appendingPathComponent("AirPadUITestScratch").path) { return caches }
        }
        return nil
    }

    private static func sweepRequests() -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("[FocusSweep] request"), let r = line.range(of: " id=") else { return nil }
            return String(line[r.upperBound...])
        }
    }

    private func onScreen(_ e: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard e.exists else { return false }
        let f = e.frame, w = app.frame
        return !f.isEmpty && w.contains(CGPoint(x: f.midX, y: f.midY))
    }

    /// One surface: launch it, let the sweep fire, and check every requested node's element (`prefix + id`) lands.
    private func sweep(_ surfaceArgs: [String], prefix: String, _ name: String) {
        // The app's stdout file outlives a launch: clear it, or the PREVIOUS row's requests are read as this row's.
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? Data().write(to: log) }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-StdoutToFile",
                               "-DebugFocusSweep", "-EmbedCPUOnly", "-StubAuthorModel"] + surfaceArgs
        app.launch()
        var checked = Set<String>(), landed: [String] = [], missed: [String] = []
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && checked.count < 5 {
            for id in Self.sweepRequests() where !checked.contains(id) {
                checked.insert(id)
                Thread.sleep(forTimeInterval: 2.5)   // the deferred scroll + its animation
                let target = app.descendants(matching: .any).matching(identifier: prefix + id).firstMatch
                if onScreen(target, app) { landed.append(id) } else {
                    missed.append(id)
                    let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(name) missed \(id)"; a.lifetime = .keepAlways; add(a)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("[ScrollToLanding] \(name): \(landed.count)/\(checked.count) landed; missed \(missed)")
        XCTAssertEqual(checked.count, 5, "\(name): the sweep fired five requests")
        XCTAssertTrue(missed.isEmpty, "\(name): \(missed.count) focus scroll(s) did not land: \(missed)")
        app.terminate()
    }

    func testVerticalCardsLand() { sweep(["-OpenCardView", "-gridColumnCount", "4"], prefix: "verticalCard-", "vertical cards") }
    func testGridLands() { sweep(["-OpenCardView", "-gridColumnCount", "2"], prefix: "cardTile-", "grid") }
    func testListLands() { sweep(["-OpenListView"], prefix: "listRow-", "list") }

    func testLongChatOpensOnItsLastAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-OpenChatsList", "-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedLongChat"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20), "Chats list never opened")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long synthetic chat'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no long chat row")
        row.tap()
        Thread.sleep(forTimeInterval: 3)
        let last = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'the end of the long chat'")).firstMatch
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "long chat opened"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(onScreen(last, app), "the long chat opens on its last answer (exists=\(last.exists) frame=\(last.frame))")
        app.terminate()
    }
}
