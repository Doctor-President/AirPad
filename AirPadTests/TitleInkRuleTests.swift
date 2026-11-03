import XCTest
import simd
@testable import AirPad

/// 1.1-A (4) / 1.1-B — the pure title-ink rule: the ink with the higher AREA contrast (80th percentile of the title's
/// samples) wins; there is no halo. Positive controls (must pick dark / must pick light) plus the area (not worst-case,
/// not mean) property.
final class TitleInkRuleTests: XCTestCase {
    private let inks = TitleInkRule.legibleInks
    private func grey(_ v: Int) -> SIMD3<Float> { SIMD3(repeating: Float(v) / 255) }

    func testWhiteGroundPicksDarkInk() {
        let p = TitleInkRule.pick(samples: [grey(255), grey(240)], inks: inks)
        XCTAssertFalse(p.lightInk)
        XCTAssertEqual(p.ink, inks.dark)
        XCTAssertGreaterThanOrEqual(p.area, 4.5)
        XCTAssertGreaterThanOrEqual(p.worst, 4.5)
    }

    func testBlackGroundPicksLightInk() {
        let p = TitleInkRule.pick(samples: [grey(0), grey(20)], inks: inks)
        XCTAssertTrue(p.lightInk)
        XCTAssertEqual(p.ink, inks.light)
    }

    /// The halo is gone structurally: a Pick has no halo (or any stroke / outline) field, even where neither ink reads.
    func testNoPickCarriesAHalo() {
        let p = TitleInkRule.pick(samples: [grey(0x77)], inks: inks)   // < 4.5 against both inks
        XCTAssertLessThan(p.area, 4.5)
        let fields = Mirror(reflecting: p).children.compactMap { $0.label?.lowercased() }
        XCTAssertEqual(Set(fields), ["ink", "area", "worst", "lightink"])
        XCTAssertFalse(fields.contains { $0.contains("halo") || $0.contains("stroke") || $0.contains("outline") })
    }

    /// The area measure, precisely: sorted ascending, c[n − ⌈0.8·n⌉] — 35 samples → the 8th lowest (28 of 35 reach it).
    func testAreaContrastIsThe80thPercentile() {
        let samples = (0..<35).map { grey($0 * 7) }   // 0 … 238, distinct
        let c = samples.map { TitleInkRule.contrast(inks.dark, $0) }.sorted()
        XCTAssertEqual(TitleInkRule.areaContrast(inks.dark, over: samples), c[7])
        XCTAssertEqual(c.filter { $0 >= c[7] }.count, 28)
        XCTAssertEqual(TitleInkRule.areaContrast(inks.dark, over: [grey(255)]), TitleInkRule.contrast(inks.dark, grey(255)))
        XCTAssertEqual(TitleInkRule.areaContrast(inks.dark, over: []), 21)
    }

    /// A few bright points under a mostly dark title no longer flip the ink (1.1-A's worst case did).
    func testAFewBadSamplesNoLongerFlipThePick() {
        let samples = Array(repeating: grey(30), count: 31) + Array(repeating: grey(250), count: 4)
        let wl = TitleInkRule.worstContrast(inks.light, over: samples), wd = TitleInkRule.worstContrast(inks.dark, over: samples)
        XCTAssertLessThan(wl, wd)   // the worst case would have picked the dark ink
        let p = TitleInkRule.pick(samples: samples, inks: inks)
        XCTAssertTrue(p.lightInk)
        XCTAssertGreaterThanOrEqual(p.area, 4.5)
        XCTAssertEqual(p.worst, wl)
        // …but a real majority still decides: 8 bright points of 35 (> 20%) flip it to the dark ink's side of the sort
        let more = Array(repeating: grey(30), count: 27) + Array(repeating: grey(250), count: 8)
        XCTAssertEqual(TitleInkRule.areaContrast(inks.light, over: more), TitleInkRule.contrast(inks.light, grey(250)))
    }

    /// Ties go to the light ink.
    func testTieGoesToLightInk() {
        let p = TitleInkRule.pick(samples: [grey(100)], inks: .init(light: grey(200), dark: grey(200)))
        XCTAssertTrue(p.lightInk)
    }

    func testContrastMatchesWCAG() {
        XCTAssertEqual(TitleInkRule.contrast(grey(255), grey(0)), 21, accuracy: 0.01)
        XCTAssertEqual(TitleInkRule.contrast(grey(0x76), grey(255)), 4.54, accuracy: 0.02)   // the classic AA grey
    }

    /// Twins: the ground shows through Outline's faint fill and the light Flat; Riso on the light Map multiplies into it.
    func testGroundIsAnInput() {
        let fill = SIMD3<Float>(0.2, 0.5, 0.9)
        let a = TitleInkTwin.outline(fill: fill, fillOpacity: 0.115, ground: grey(17))
        let b = TitleInkTwin.outline(fill: fill, fillOpacity: 0.115, ground: grey(240))
        XCTAssertTrue(TitleInkRule.pick(samples: a, inks: inks).lightInk)
        XCTAssertFalse(TitleInkRule.pick(samples: b, inks: inks).lightInk)
        XCTAssertEqual(TitleInkRule.titleBox.count, 35)
        let f = OrbStudyPalettes.families[3]
        let st = TitleInkTwin.Stops(a: f.a, b: f.b, c: f.c, r: f.r, seed: 0.42)
        let lightRiso = TitleInkTwin.riso(st, RisoLook(), dark: false, ground: grey(255))
        let darkerGround = TitleInkTwin.riso(st, RisoLook(), dark: false, ground: grey(128))
        XCTAssertEqual(lightRiso.count, 35)
        XCTAssertTrue(zip(lightRiso, darkerGround).allSatisfy { simd_reduce_add($0.0) >= simd_reduce_add($0.1) })
    }
}
