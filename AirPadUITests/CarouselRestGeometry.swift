import XCTest

/// live-18 (1) — T (iPhone on iOS 27; finding `2026-10-15-card-carousel-skew.md`): Card view's coverflow is right on
/// entry, but after scrolling ~5 cards each card comes to REST skewed (3D-tilted + shifted off-centre), in both
/// directions, until T scrolls back to the first card. Not motion.
///
/// On the real Card view with the Sample Library (210 cards; `-UITestSampleLibrary` seeds it into a scratch library):
/// slow one-card drags forward past card 20 and back, then fast flicks forward and back. At EVERY rest the card the deck
/// draws at centre must be flat and centred: visual offset < 0.5 pt, rotation 0 (`-CoverFlowProbe` logs the deck's own
/// numbers each rest, plus the scroll track's real slot geometry). Screenshots at a few rests. Synthetic content only.
final class CarouselRestGeometry: XCTestCase {

    static let args = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-OpenCardView",
                       "-gridColumnCount", "1", "-StdoutToFile", "-CoverFlowProbe", "-EmbedCPUOnly", "-StubAuthorModel"]

    struct Rest { let line: String; let idx: Int; let offsetPt: Double; let deg: Double; let slot: Double; let label: String }
    /// "Rotation 0": scroll offsets land on the 1/3-pt pixel grid, so a card's rest can sit up to ~0.3 pt from the ideal —
    /// 0.04° of rake. 0.1° is the rake of 0.5 pt (the offset bound): flat to the pixel.
    static let maxOffsetPt = 0.5, maxDegrees = 0.1

    private static func appCaches() -> URL? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let caches = c.appendingPathComponent("Library/Caches")
            if fm.fileExists(atPath: caches.appendingPathComponent("AirPadUITestScratch").path) { return caches }
        }
        return nil
    }

    private static func restLines() -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.contains("[CoverFlow] rest ") }
    }

    private static func value(_ line: String, _ key: String) -> String {
        guard let r = line.range(of: " \(key)=") else { return "" }
        return String(line[r.upperBound...].prefix { $0 != " " })
    }

    /// Performs `gesture`, then waits for the carousel's next rest line.
    private func rest(after gesture: () -> Void, _ label: String) -> Rest? {
        let before = Self.restLines().count
        gesture()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let lines = Self.restLines()
            if lines.count > before {
                Thread.sleep(forTimeInterval: 0.6)   // a flick can rest, nudge, rest again — take the last
                guard let line = Self.restLines().last else { return nil }
                return Rest(line: line, idx: Int(Self.value(line, "idx")) ?? -1,
                            offsetPt: Double(Self.value(line, "offsetPt")) ?? .nan,
                            deg: Double(Self.value(line, "deg")) ?? .nan,
                            slot: Double(Self.value(line, "slotFromCentre")) ?? .nan, label: label)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("\(label): no rest within 8 s")
        return nil
    }

    func testEveryRestIsFlatAndCentred() {
        let app = XCUIApplication()
        app.launchArguments = Self.args
        app.launch()
        Thread.sleep(forTimeInterval: 20)   // sample seed + corpus load + carousel settle

        let y = 0.45
        func drag(from a: Double, to b: Double, _ v: XCUIGestureVelocity) -> () -> Void {
            { app.coordinate(withNormalizedOffset: CGVector(dx: a, dy: y))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: b, dy: y)),
                       withVelocity: v, thenHoldForDuration: v == .slow ? 0.15 : 0) }
        }
        var rests: [Rest] = []
        func record(_ r: Rest?) {
            guard let r else { return }
            rests.append(r)
            if [1, 5, 10, 20].contains(r.idx) || rests.count % 12 == 0 {
                let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(r.label) idx \(r.idx)"; a.lifetime = .keepAlways; add(a)
            }
        }
        // Slow, one card at a time: forward past card 20, then back to the start.
        for i in 0..<22 { record(rest(after: drag(from: 0.80, to: 0.20, .slow), "slow-fwd-\(i)")) }
        for i in 0..<22 { record(rest(after: drag(from: 0.20, to: 0.80, .slow), "slow-back-\(i)")) }
        // Fast drags (no hold), then real flicks that coast several cards: forward, then back.
        for i in 0..<6 { record(rest(after: drag(from: 0.90, to: 0.10, .fast), "fast-fwd-\(i)")) }
        for i in 0..<6 { record(rest(after: drag(from: 0.10, to: 0.90, .fast), "fast-back-\(i)")) }
        for i in 0..<5 { record(rest(after: { app.swipeLeft(velocity: XCUIGestureVelocity(4000)) }, "flick-fwd-\(i)")) }
        for i in 0..<7 { record(rest(after: { app.swipeRight(velocity: XCUIGestureVelocity(4000)) }, "flick-back-\(i)")) }

        // Skewed = the card drawn at centre is off-centre or tilted, OR the track's own snapped slot isn't centred.
        let bad = rests.filter { !(abs($0.offsetPt) < Self.maxOffsetPt) || !(abs($0.deg) < Self.maxDegrees) || !(abs($0.slot) < Self.maxOffsetPt) }
        let maxOff = rests.map { abs($0.offsetPt) }.max() ?? .nan
        let maxIdx = rests.map(\.idx).max() ?? -1
        print("[CarouselRestGeometry] \(rests.count) rests, max card \(maxIdx), max |offset| \(String(format: "%.2f", maxOff)) pt, \(bad.count) skewed")
        for r in rests { print("[CarouselRestGeometry] \(r.label): \(r.line.components(separatedBy: "[CoverFlow] ").last ?? "")") }
        XCTAssertGreaterThanOrEqual(maxIdx, 20, "paged past card 20")
        XCTAssertGreaterThanOrEqual(rests.count, 62, "a rest after every gesture")
        XCTAssertTrue(bad.isEmpty, "\(bad.count)/\(rests.count) rests skewed, first: \(bad.prefix(3).map { "\($0.label) idx \($0.idx) offset \($0.offsetPt) pt deg \($0.deg) slot \($0.slot)" })")
    }
}
