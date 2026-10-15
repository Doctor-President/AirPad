import XCTest

/// live-14 — T (TF 202610141313): opening some entries that have a hero image briefly showed the fluted glass (the
/// no-hero header) before the image. On the real screen: seeded entries with a LARGE (6000×4500) and a small hero,
/// opened from Recents; the header's states (`HeroHeaderProbe`, read from the app's stdout file) must never include
/// the glass before — or instead of — the image. Synthetic images only; scratch library. Simulator.
final class HeroHeaderFlash: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// The AirPad app container's Caches (the one holding the UI-test scratch library).
    private static func appCaches() -> URL? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let caches = c.appendingPathComponent("Library/Caches")
            if fm.fileExists(atPath: caches.appendingPathComponent("AirPadUITestScratch").path) { return caches }
        }
        return nil
    }

    private func states(for id: String) -> [String] {
        guard let log = Self.appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("[HeroHeader] node=\(id) ") else { return nil }
            return line.components(separatedBy: "state=").last
        }
    }

    private func open(_ id: String, fresh: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestSeedHeroEntries", "-StdoutToFile", "-EmbedCPUOnly", "-StubAuthorModel"]
            + (fresh ? ["-UITestLibraryFresh"] : [])
        app.launch()
        let row = app.buttons["entryRow-\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded hero entry \(id) is in Recents")
        row.tap()
        Thread.sleep(forTimeInterval: 4)   // the header loads + decodes
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "\(id)-open"; shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }

    func testHeroEntries_neverShowTheGlassBeforeTheImage() {
        // A clean log for this run (the scratch library and its Caches exist after one launch).
        let first = XCUIApplication()
        first.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedHeroEntries"]
        first.launch(); first.terminate()
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? FileManager.default.removeItem(at: log) }

        for id in ["uitest-hero-large", "uitest-hero-small"] {
            open(id, fresh: false)
            let seen = states(for: id)
            print("[HeroHeaderFlash] \(id) states=\(seen)")
            XCTAssertTrue(seen.contains("image"), "\(id): the hero image showed (states \(seen))")
            let beforeImage = seen.prefix(while: { $0 != "image" })
            XCTAssertFalse(beforeImage.contains("glass") || beforeImage.contains("failed"),
                           "\(id): the glass showed before the hero image (states \(seen))")
        }
    }
}
