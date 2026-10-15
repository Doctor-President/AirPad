import XCTest

/// live-18 (0b) — live-17's report: a photo shared from the gallery viewer still went out under its STORED file name
/// (`<UUID>.jpg`), as documents did before live-17. Companion: the viewer's Share hands over a named copy — the photo's own
/// file name when known, else "Photo · <date>".
///
/// On the real screens: a seeded two-photo gallery stored under UUID names (`-UITestSeedPhotoEntries`); each photo opened
/// from its tile into the fullscreen viewer, then the viewer's Share. Asserts the share sheet is handed
/// `<name>.jpg` ("IMG_4012.jpg" for the photo picked from Photos, "Photo · <date>.jpg" for the one with no name), shows
/// no UUID, and that the named copy is removed when the sheet closes. `DocumentHandoffProbe` logs what the share sheet
/// was handed (read from the app's stdout file). Synthetic content only; scratch library. Simulator.
final class PhotoHandoffName: XCTestCase {

    static let base = ["-UITestLibrary", "-UITestSeedPhotoEntries", "-StdoutToFile", "-DocumentHandoffProbe",
                       "-EmbedCPUOnly", "-StubAuthorModel"]
    static let added = Date(timeIntervalSince1970: 1_760_300_000).formatted(date: .abbreviated, time: .omitted)
    static let photos: [(id: String, display: String)] = [
        ("5E7A1C93-2B4D-4F18-9A6E-0C3D8B1F0004", "IMG_4012"),
        ("A08F2D5B-7C61-4E39-B2D4-6F1E9C3A0005", "Photo · \(added)"),
    ]

    override func setUp() { continueAfterFailure = true }   // every photo reports

    // MARK: - Harness (same stdout-file pattern as DocumentHandoffName)

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

    private static func probe(_ kind: String, _ id: String) -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
            .filter { $0.contains("[DocHandoff] \(kind) ") && $0.contains("doc=\(id) ") }
    }

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

    func testShareHandsThePhotosName() {
        let seeding = launch(fresh: true)
        XCTAssertTrue(seeding.buttons["entryRow-uitest-photo-gallery"].waitForExistence(timeout: 60), "seeded")
        seeding.terminate()
        for photo in Self.photos {
            let app = launch()
            let row = app.buttons["entryRow-uitest-photo-gallery"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the gallery entry is on Recents")
            row.tap()
            let tile = app.descendants(matching: .any).matching(identifier: "galleryTile-\(photo.id)").firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 15), "\(photo.display): its tile")
            Thread.sleep(forTimeInterval: 1)
            tile.tap()
            let share = app.descendants(matching: .any).matching(identifier: "galleryShare-\(photo.id)").firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 15), "\(photo.display): the viewer's Share")
            Self.clearLog()
            share.tap()
            Thread.sleep(forTimeInterval: 3)   // the share sheet loads its header + targets
            let a = XCTAttachment(screenshot: app.screenshot()); a.name = "share-\(photo.display)"; a.lifetime = .keepAlways; add(a)
            let sheetTexts = Self.labels(app)
            let handed = Self.probe("share", photo.id).last ?? ""
            print("[PhotoHandoffName] share \(photo.display) handed: \(handed) · sheet texts=\(sheetTexts.prefix(12))")
            let files = handed.range(of: " files=").map { String(handed[$0.upperBound...]) } ?? ""
            XCTAssertEqual(files, "\(photo.display).jpg", "\(photo.display): the share sheet is handed <name>.jpg (\(handed))")
            XCTAssertFalse(sheetTexts.contains { $0.contains(String(photo.id.prefix(8))) },
                           "\(photo.display): no UUID on the share sheet (saw \(sheetTexts.prefix(12)))")
            XCTAssertTrue(sheetTexts.contains(photo.display),
                          "\(photo.display): the share sheet's header shows the name (saw \(sheetTexts.prefix(6)))")
            // The share sheet's own Close, by its identifier (over the full-screen viewer, its type flips between Button
            // and PopUpButton, so a `buttons` query misses it).
            let close = app.descendants(matching: .any).matching(identifier: "header.closeButton").firstMatch
            if close.waitForExistence(timeout: 5) { close.tap() } else { app.swipeDown(velocity: .fast) }
            var released: [String] = []
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                released = Self.probe("released", photo.id)
                if !released.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            XCTAssertTrue(released.last?.hasSuffix(" left=0") == true, "\(photo.display): the named copy is removed when the sheet closes (\(released))")
            app.terminate()
        }
    }
}
