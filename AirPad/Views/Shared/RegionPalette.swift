//  RegionPalette.swift
//  Map territory-tint FAMILIES (ws-ios-polish, COMMIT 2).
//
//  T's complaint: the shipping region set (Paul Tol "vibrant", `CorpusPhysicsScene.
//  territoryPaletteHex`) is SATURATED AT MID-LIGHTNESS — the muddiest zone on a dark ground.
//  These families regenerate the 12 region colours from per-appearance HSL parameters so the
//  whole set can move OUT of the mud, and they are TUNER-DIALABLE (the instrument hands T the
//  parameters; CC does not pick final values — that has misfired twice this arc).
//
//  ★ CURRENT = the shipping hex, verbatim, as the A/B baseline. When the active family is
//    `.current` (the default, and the ONLY reachable family outside DEBUG), resolution is
//    byte-identical to today, so Release is unaffected.
//  ★ PER APPEARANCE: light and dark carry independent params. PASTEL / NEON are dark-FAVOURED
//    (high-lightness colour needs a dark ground to read; on cream it washes out — the same
//    headroom logic that killed the glow on cream). On light they are pushed darker/more
//    saturated = "the best they can do", never silently washed out (see `defaults`).

import UIKit

enum RegionPaletteFamily: Int, CaseIterable {
    case current = 0, subdued, jewel, pastel, neon
    var displayName: String {
        switch self {
        case .current: return "Current"
        case .subdued: return "Subdued"
        case .jewel:   return "Jewel"
        case .pastel:  return "Pastel"
        case .neon:    return "Neon"
        }
    }
    /// Families that are dark-favoured — reported to T; on light they resolve to a darker/more
    /// saturated variant ("best it can do") rather than a washed-out one.
    var darkFavoured: Bool { self == .pastel || self == .neon }
}

enum RegionPalette {
    static let slotCount = 12

    /// The shipping baseline — CURRENT family returns these verbatim (single source: the scene's
    /// existing `territoryPaletteHex`, so there's no second copy to drift).
    static var currentHex: [String] { CorpusPhysicsScene.territoryPaletteHex }

    /// Family character as HSL params. `hueStart`/`hueSpread` are fractions of the colour wheel
    /// (the 12 slots span `hueSpread` of the wheel, rotated by `hueStart`); `sat`/`light` are HSL
    /// 0…1. Chosen to characterise each family; T overrides them live via the tuner.
    struct Params { var hueStart: Double; var hueSpread: Double; var sat: Double; var light: Double }

    static func defaults(_ f: RegionPaletteFamily, isLight: Bool) -> Params {
        switch f {
        case .current:
            return Params(hueStart: 0, hueSpread: 1, sat: 0, light: 0)  // unused — hex path
        case .subdued:   // low saturation, mid lightness — desaturation is the direct opposite of mud
            return isLight ? Params(hueStart: 0, hueSpread: 1, sat: 0.30, light: 0.44)
                           : Params(hueStart: 0, hueSpread: 1, sat: 0.32, light: 0.60)
        case .jewel:     // high saturation, LOW lightness — rich, the darkness is intentional
            return isLight ? Params(hueStart: 0, hueSpread: 1, sat: 0.82, light: 0.36)
                           : Params(hueStart: 0, hueSpread: 1, sat: 0.80, light: 0.44)
        case .pastel:    // high lightness, low saturation — dark-favoured; on light pushed down
            return isLight ? Params(hueStart: 0, hueSpread: 1, sat: 0.34, light: 0.60)
                           : Params(hueStart: 0, hueSpread: 1, sat: 0.38, light: 0.80)
        case .neon:      // high sat + high lightness, NARROW hue range — dark-favoured
            return isLight ? Params(hueStart: 0.55, hueSpread: 0.42, sat: 0.88, light: 0.52)
                           : Params(hueStart: 0.55, hueSpread: 0.42, sat: 0.95, light: 0.60)
        }
    }

    // MARK: - Active family + dialled params (DEBUG tuner) — .current everywhere in Release.

    static var activeFamily: RegionPaletteFamily {
        #if DEBUG
        return RegionPaletteFamily(rawValue: BlobFieldTuning.shared.regionFamily) ?? .current
        #else
        return .current
        #endif
    }

    /// Family params, defaults overlaid by the live tuner dials (DEBUG only).
    static func params(_ f: RegionPaletteFamily, isLight: Bool) -> Params {
        var p = defaults(f, isLight: isLight)
        #if DEBUG
        let t = BlobFieldTuning.shared
        p.hueStart  = t.regionParam(f.rawValue, isLight, "hueStart",  default: p.hueStart)
        p.hueSpread = t.regionParam(f.rawValue, isLight, "hueSpread", default: p.hueSpread)
        p.sat       = t.regionParam(f.rawValue, isLight, "sat",       default: p.sat)
        p.light     = t.regionParam(f.rawValue, isLight, "light",     default: p.light)
        #endif
        return p
    }

    /// The resolved colour for a territory SLOT (index) in the active family + appearance.
    static func color(isLight: Bool, slot: Int) -> UIColor {
        let fam = activeFamily
        if fam == .current {
            let hex = currentHex
            return UIColor(hex: hex[slot % max(hex.count, 1)]) ?? .gray
        }
        let p = params(fam, isLight: isLight)
        let n = max(slotCount, 1)
        var hue = p.hueStart + p.hueSpread * (Double(slot % n) / Double(n))
        #if DEBUG
        hue += BlobFieldTuning.shared.regionSlotHueOffset(fam.rawValue, isLight, slot % n)
        #endif
        hue -= floor(hue)
        let (r, g, b) = hslToRGB(hue, clamp01(p.sat), clamp01(p.light))
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// The active family + appearance as 12 hex strings — for the tuner's Copy export.
    static func resolvedHex(isLight: Bool) -> [String] {
        (0..<slotCount).map { hexString(color(isLight: isLight, slot: $0)) }
    }

    // MARK: - Distinguishability

    /// How many of the 12 slots stay mutually DISTINCT (min pairwise CIE76 ΔE ≥ `threshold`) in a
    /// family + appearance. A family with narrow hue span / very low sat / extreme lightness
    /// collapses hues → fewer distinct slots. Reported to T (hard constraint: a dozen+ regions
    /// must be told apart). ΔE ~12 ≈ "clearly different"; caveat: this is normal-vision ΔE, not CVD.
    static func distinctSlotCount(_ f: RegionPaletteFamily, isLight: Bool, threshold: Double = 12) -> Int {
        var cols: [(Double, Double, Double)] = []
        for s in 0..<slotCount {
            let c = color(isLight: isLight, slot: s)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            cols.append(rgbToLab(Double(r), Double(g), Double(b)))
        }
        // Greedily keep slots whose ΔE to every already-kept slot is ≥ threshold.
        var kept: [(Double, Double, Double)] = []
        for c in cols {
            if kept.allSatisfy({ deltaE($0, c) >= threshold }) { kept.append(c) }
        }
        return kept.count
    }

    // MARK: - Colour maths (HSL→RGB, RGB→Lab, ΔE) — no UIKit HSB (that's brightness, not lightness).

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h - floor(h)) * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hp) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return (r + m, g + m, b + m)
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func hexString(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    private static func rgbToLab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92 }
        let R = lin(r), G = lin(g), B = lin(b)
        let x = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047
        let y = (R * 0.2126 + G * 0.7152 + B * 0.0722)
        let z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func deltaE(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dl = a.0 - b.0, da = a.1 - b.1, db = a.2 - b.2
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
