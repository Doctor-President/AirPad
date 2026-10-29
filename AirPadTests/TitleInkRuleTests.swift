import XCTest
import simd
@testable import AirPad

/// 1.1-A (4) — the pure title-ink rule: worst-case WCAG contrast over the samples picks the ink; under 4.5:1 a halo in
/// the other ink. Positive controls (must pick dark / must pick light / must halo) plus the worst-case (not mean) property.
final class TitleInkRuleTests: XCTestCase {
    private let inks = TitleInkRule.legibleInks
    private func grey(_ v: Int) -> SIMD3<Float> { SIMD3(repeating: Float(v) / 255) }

    func testWhiteGroundPicksDarkInk() {
        let p = TitleInkRule.pick(samples: [grey(255), grey(240)], inks: inks)
        XCTAssertFalse(p.lightInk)
        XCTAssertEqual(p.ink, inks.dark)
        XCTAssertNil(p.halo)
        XCTAssertGreaterThanOrEqual(p.worst, 4.5)
    }

    func testBlackGroundPicksLightInk() {
        let p = TitleInkRule.pick(samples: [grey(0), grey(20)], inks: inks)
        XCTAssertTrue(p.lightInk)
        XCTAssertEqual(p.ink, inks.light)
        XCTAssertNil(p.halo)
    }

    func testMidGreyHalosInTheOtherInk() {
        let p = TitleInkRule.pick(samples: [grey(0x77)], inks: inks)   // < 4.5 against both inks
        XCTAssertLessThan(p.worst, 4.5)
        XCTAssertNotNil(p.halo)
        XCTAssertEqual(p.halo, p.lightInk ? inks.dark : inks.light)
    }

    /// One bright patch under the title must flip the choice away from the ink a MEAN would pick.
    func testWorstCaseNotMean() {
        let samples = Array(repeating: grey(30), count: 34) + [grey(250)]   // mostly dark, one near-white sample
        let p = TitleInkRule.pick(samples: samples, inks: inks)
        let wl = TitleInkRule.worstContrast(inks.light, over: samples), wd = TitleInkRule.worstContrast(inks.dark, over: samples)
        XCTAssertEqual(p.worst, max(wl, wd))
        XCTAssertEqual(p.lightInk, wl >= wd)
        XCTAssertNotNil(p.halo)   // neither ink survives both a #1E1E1E and a #FAFAFA sample
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
