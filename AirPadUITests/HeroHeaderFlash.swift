import XCTest

/// live-14/16 — T: opening an entry with a hero photo flashed something before the photo — first the fluted glass
/// (TF 202610141313), then the plain band (TF 202610142006) — and the gallery below showed grey photo-icon tiles while
/// its thumbnails loaded. Any flash reads as broken; the Card T tapped was ALREADY showing that photo.
///
/// On the real screens: seeded synthetic entries — a LARGE (6000×4500) hero, a small hero, and a 31-photo gallery whose
/// first photo is its hero — each opened from Card view (which shows the photo before the tap), List view and Recents
/// (which don't). `HeroHeaderProbe` logs what each frame RENDERED (read from the app's stdout file); the FIRST header
/// state must be the image (not the band, not the glass), and the gallery's first tiles must be images at their first
/// frame. Synthetic images only; scratch library. Simulator.
final class HeroHeaderFlash: XCTestCase {

    static let base = ["-UITestLibrary", "-UITestSeedHeroEntries", "-StdoutToFile", "-HeroHeaderProbe",
                       "-EmbedCPUOnly", "-StubAuthorModel"]
    static let entries = ["uitest-hero-large", "uitest-hero-small", "uitest-gallery-31"]
    /// The gallery's first row (what is on screen when the entry opens).
    static let firstRow = ["uitest-gallery-31-g00", "uitest-gallery-31-g01", "uitest-gallery-31-g02"]

    enum Surface: String { case card = "Card", list = "List", recents = "Recents" }

    override func setUp() { continueAfterFailure = true }   // every entry × surface reports

    // MARK: - Harness

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

    private static func logLines() -> [Substring] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    private static func heroStates(_ id: String) -> [String] {
        logLines().compactMap { line in
            guard line.contains("[HeroHeader] node=\(id) ") else { return nil }
            return line.components(separatedBy: "state=").last
        }
    }

    private static func tileStates(_ item: String) -> [String] {
        logLines().compactMap { line in
            guard line.contains("[GalleryTile] ") && line.contains(" item=\(item) ") else { return nil }
            return line.components(separatedBy: "state=").last
        }
    }

    /// One launch with a clean log; returns the app on its first screen (the Dashboard: Recents + the Library row).
    private func launch(fresh: Bool = false) -> XCUIApplication {
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? FileManager.default.removeItem(at: log) }
        let app = XCUIApplication()
        app.launchArguments = Self.base + (fresh ? ["-UITestLibraryFresh"] : [])
        app.launch()
        return app
    }

    /// Open `id` from `surface` and return what its detail screen rendered.
    private func open(_ id: String, from surface: Surface) {
        let app = launch()
        let target: XCUIElement
        switch surface {
        case .recents:
            target = app.buttons["entryRow-\(id)"].firstMatch
        case .card, .list:
            // The app opens on Recents; its Back leads to the Dashboard and the Library row.
            let back = app.buttons["Back"].exists ? app.buttons["Back"] : app.buttons["chevron.backward"]
            if back.waitForExistence(timeout: 20) { back.tap() }
            let library = app.buttons.matching(identifier: "collectionRow-_corpus").firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 20), "the Dashboard's Library row")
            library.tap()
            let switcher = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View: '")).firstMatch
            XCTAssertTrue(switcher.waitForExistence(timeout: 10), "the view switcher")
            if switcher.label != "View: \(surface.rawValue)" {
                switcher.tap()
                let item = app.buttons[surface.rawValue].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 5), "the switcher offers \(surface.rawValue)")
                item.tap()
            }
            let prefix = surface == .card ? "cardTile-" : "listRow-"
            target = app.descendants(matching: .any).matching(identifier: "\(prefix)\(id)").firstMatch
        }
        XCTAssertTrue(target.waitForExistence(timeout: 20), "\(id) is on \(surface.rawValue)")
        // Card view shows the photo before the tap (T's case): let its tiles decode, as a person looking at them would.
        if surface == .card { Thread.sleep(forTimeInterval: 3) }
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") {   // keep only what the OPEN renders
            try? Data().write(to: log)
        }
        target.tap()
        Thread.sleep(forTimeInterval: 4)   // the header + gallery settle
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "\(id)-from-\(surface.rawValue)"
        shot.lifetime = .keepAlways; add(shot)
        app.terminate()
    }

    private func check(from surface: Surface) {
        // Seed the scratch library once (31 large synthetic photos take a while: wait until every entry is listed), then
        // every open is a warm relaunch.
        let seeding = launch(fresh: true)
        for id in Self.entries {
            XCTAssertTrue(seeding.buttons["entryRow-\(id)"].waitForExistence(timeout: 90), "\(id) seeded")
        }
        seeding.terminate()
        for id in Self.entries {
            open(id, from: surface)
            let hero = Self.heroStates(id)
            print("[HeroHeaderFlash] \(surface.rawValue) \(id) header=\(hero)")
            for line in Self.logLines() where line.contains("[DisplayImage] open") || line.contains("hero fallback") {
                print("[HeroHeaderFlash] \(surface.rawValue) \(id) \(line)")
            }
            XCTAssertEqual(hero.first, "image", "\(id) from \(surface.rawValue): the FIRST header frame is the photo (states \(hero))")
            XCTAssertFalse(hero.contains("glass"), "\(id) from \(surface.rawValue): never the glass (states \(hero))")
            if id == "uitest-gallery-31" {
                let rows = Self.firstRow.map { ($0, Self.tileStates($0)) }
                print("[HeroHeaderFlash] \(surface.rawValue) gallery first row=\(rows.map { "\($0.0.suffix(3))=\($0.1)" })")
                XCTAssertTrue(rows.contains { !$0.1.isEmpty }, "\(surface.rawValue): the gallery's first row rendered")
                for (item, states) in rows where !states.isEmpty {
                    XCTAssertEqual(states.first, "image", "\(item) from \(surface.rawValue): populated at its first frame (states \(states))")
                }
            }
        }
    }

    func testOpenFromCardView_firstFrameIsThePhoto() { check(from: .card) }
    func testOpenFromListView_firstFrameIsThePhoto() { check(from: .list) }
    func testOpenFromRecents_firstFrameIsThePhoto() { check(from: .recents) }
}
