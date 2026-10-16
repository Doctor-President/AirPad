import XCTest

/// live-19 (3d) — iOS 27 rest geometry on the other paged surfaces (live-18 found iOS 27's lazy stack dropping a
/// spacing under the coverflow): the photo viewer's `.paging` pager (a 31-photo synthetic gallery) and a document
/// entry's `.viewAligned` carousel (14 synthetic PDFs). Pages forward past the lazy window and back, slow drags and
/// fast flicks; at EVERY rest the item nearest the leading edge sits on it (< 0.5 pt, unless the scroll is clamped at
/// its start/end) and the measured pitch equals the layout's (`-PagedRestProbe`). Synthetic content; scratch library.
final class PagedRestGeometry: XCTestCase {

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
    private static func rests(_ surface: String) -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.contains("[PagedRest] \(surface) rest") }
    }
    private static func value(_ line: String, _ key: String) -> Double {
        guard let r = line.range(of: " \(key)=") else { return .nan }
        return Double(line[r.upperBound...].prefix { $0 != " " }) ?? .nan
    }

    private func page(_ surface: String, _ gestures: [(String, () -> Void)], _ app: XCUIApplication) -> [String] {
        var bad: [String] = [], n = 0, maxIdx = 0.0
        for (label, g) in gestures {
            let before = Self.rests(surface).count
            g()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline && Self.rests(surface).count == before { Thread.sleep(forTimeInterval: 0.2) }
            Thread.sleep(forTimeInterval: 0.5)
            guard let line = Self.rests(surface).last, Self.rests(surface).count > before else { continue }
            n += 1
            let off = Self.value(line, "offsetPt"), pitch = Self.value(line, "pitch"), want = Self.value(line, "expectedPitch")
            let clamped = Self.value(line, "clamped") == 1
            maxIdx = max(maxIdx, Self.value(line, "idx"))
            let pitchOK = pitch.isNaN || abs(pitch - want) < 0.5
            if !(clamped || abs(off) < 0.5) || !pitchOK { bad.append("\(label): \(line.components(separatedBy: "rest ").last ?? line)") }
        }
        print("[PagedRestGeometry] \(surface): \(n) rests, max item \(Int(maxIdx)), \(bad.count) off")
        bad.forEach { print("[PagedRestGeometry]   \($0)") }
        XCTAssertGreaterThanOrEqual(n, gestures.count - 2, "\(surface): a rest after (nearly) every gesture")
        XCTAssertGreaterThanOrEqual(maxIdx, 10, "\(surface): paged past item 10")
        return bad
    }

    func testPhotoViewerPagesRestAligned() {
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? Data().write(to: log) }   // a fresh log per row
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedHeroEntries", "-StdoutToFile",
                               "-PagedRestProbe", "-EmbedCPUOnly", "-StubAuthorModel"]
        app.launch()
        let row = app.buttons["entryRow-uitest-gallery-31"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 90), "the 31-photo gallery is on Recents")
        row.tap()
        let tile = app.descendants(matching: .any).matching(identifier: "galleryTile-uitest-gallery-31-g00").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "its first tile"); Thread.sleep(forTimeInterval: 1); tile.tap()
        Thread.sleep(forTimeInterval: 2)
        let y = 0.5
        func drag(_ a: Double, _ b: Double, _ v: XCUIGestureVelocity) -> () -> Void {
            { app.coordinate(withNormalizedOffset: CGVector(dx: a, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: b, dy: y)), withVelocity: v, thenHoldForDuration: 0) }
        }
        var g: [(String, () -> Void)] = []
        for i in 0..<14 { g.append(("slow-fwd-\(i)", drag(0.85, 0.15, .slow))) }
        for i in 0..<6 { g.append(("flick-fwd-\(i)", { app.swipeLeft(velocity: XCUIGestureVelocity(3000)) })) }
        for i in 0..<14 { g.append(("slow-back-\(i)", drag(0.15, 0.85, .slow))) }
        for i in 0..<6 { g.append(("flick-back-\(i)", { app.swipeRight(velocity: XCUIGestureVelocity(3000)) })) }
        let bad = page("viewer", g, app)
        let a = XTCAttach(app); add(a)
        XCTAssertTrue(bad.isEmpty, "viewer: \(bad.count) rest(s) off: \(bad.prefix(3))")
    }

    func testDocumentCarouselRestsAligned() {
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? Data().write(to: log) }   // a fresh log per row
        let app = XCUIApplication()
        app.launchArguments = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedManyDocuments", "-StdoutToFile",
                               "-PagedRestProbe", "-EmbedCPUOnly", "-StubAuthorModel"]
        app.launch()
        let row = app.buttons["entryRow-uitest-doc-many"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the document entry is on Recents")
        row.tap()
        let first = app.descendants(matching: .any).matching(identifier: "documentOpen-D0C5A11E-0000-4000-8000-000000000001").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "its first document tile")
        Thread.sleep(forTimeInterval: 1.5)
        let f = first.frame, w = app.frame
        let y = Double(f.midY / w.height)
        func drag(_ a: Double, _ b: Double, _ v: XCUIGestureVelocity) -> () -> Void {
            { app.coordinate(withNormalizedOffset: CGVector(dx: a, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: b, dy: y)), withVelocity: v, thenHoldForDuration: 0) }
        }
        var g: [(String, () -> Void)] = []
        for i in 0..<12 { g.append(("slow-fwd-\(i)", drag(0.6, 0.15, .slow))) }
        for i in 0..<4 { g.append(("fast-fwd-\(i)", drag(0.8, 0.1, .fast))) }
        for i in 0..<12 { g.append(("slow-back-\(i)", drag(0.15, 0.6, .slow))) }
        for i in 0..<4 { g.append(("fast-back-\(i)", drag(0.1, 0.8, .fast))) }
        let bad = page("documents", g, app)
        add(XTCAttach(app))
        XCTAssertTrue(bad.isEmpty, "documents: \(bad.count) rest(s) off: \(bad.prefix(3))")
    }

    private func XTCAttach(_ app: XCUIApplication) -> XCTAttachment {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "final rest"; a.lifetime = .keepAlways; return a
    }
}
