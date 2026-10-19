// CardSurface.swift
// LIGHT-MODE card-surface tuner — scaffolding for a TASTE pass. T is the arbiter;
// nothing here picks a value.
//
// ★ THREE INVARIANTS, each load-bearing:
//
// 1. DARK MODE IS BYTE-IDENTICAL. Every knob is LIGHT-ONLY. Each resolver's dark
//    branch returns the shipped literal verbatim — `black@0.32` (card shadow),
//    `#111115` (ground), `white@0.24 → white@0` (rim) — and no dial can reach it.
//    Emboss is light-only by construction (the builder returns `EmptyView` in dark).
//
// 2. ONE SOURCE FOR BOTH CARD SURFACES. The card face renders in FOUR places:
//    `NodeCardView` (CoverFlow carousel + VerticalScroll) and `NodeGridTile` (the
//    2/3-column grid), which are separate implementations that each carried their
//    own private rim constants (`NodeCardView.rimOpacity` / `NodeGridTile
//    .tileRimOpacity`, both 0.24). `AppearancePalette.cardShadow` was already
//    shared ("ONE token so the two surfaces can't drift"); the rim was NOT. Both
//    now resolve through THIS file, so a dial cannot move one and leave the other.
//
// 3. THE PANEL CANNOT DRIFT FROM RELEASE. `Defaults` below holds the compiled-in
//    shipped values, and it is the ONLY place they are written. The live surfaces
//    read through `Store`, which falls back to `Defaults`; per-knob reset and
//    "reset all" just delete keys. So a reset provably renders what ships.
//
// ★ NO TUNER IN THIS BUILD. There is no write path and no UserDefaults read: the
// compiled-in `CardSurfaceDefaults` ARE the shipped values in every configuration.
// `showsDevTuners` is untouched and stays `false` in Release.

import SwiftUI
import UIKit

// MARK: - Numeric dials

enum CardSurfaceDial: String, CaseIterable, Identifiable {
    // 1 — card background
    case baseLightness
    // 2 — card shadow
    case shadowAlpha, shadowRadius, shadowY
    // 4 — rim light
    case rimOpacity, rimWidth
    // 5 — emboss
    case embossLightAlpha, embossDarkAlpha, embossInset, embossBlur

    var id: String { rawValue }

    var label: String {
        switch self {
        case .baseLightness:    return "1 · Card bg lightness"
        case .shadowAlpha:      return "2 · Shadow alpha"
        case .shadowRadius:     return "2 · Shadow radius"
        case .shadowY:          return "2 · Shadow y-offset"
        case .rimOpacity:       return "4 · Rim alpha"
        case .rimWidth:         return "4 · Rim width"
        case .embossLightAlpha: return "5 · Emboss light alpha"
        case .embossDarkAlpha:  return "5 · Emboss dark alpha"
        case .embossInset:      return "5 · Emboss inset"
        case .embossBlur:       return "5 · Emboss blur"
        }
    }

    /// Range. `baseLightness` spans BOTH directions per the brief: below 1.0
    /// darkens toward the dark-mode logic, above 1.0 lifts toward white.
    /// `shadowAlpha` reaches 0.95 because `listRowLift` solved this same
    /// separation problem on this same parchment at 0.75, and its comment records
    /// that 0.22 read as NO separation on device.
    var range: ClosedRange<Double> {
        switch self {
        case .baseLightness:    return 0.85...1.10
        case .shadowAlpha:      return 0.0...0.95
        case .shadowRadius:     return 0.0...40.0
        case .shadowY:          return -20.0...40.0
        case .rimOpacity:       return 0.0...1.0
        case .rimWidth:         return 0.0...6.0
        case .embossLightAlpha: return 0.0...1.0
        case .embossDarkAlpha:  return 0.0...1.0
        case .embossInset:      return 0.0...12.0
        case .embossBlur:       return 0.0...8.0
        }
    }

    var step: Double {
        switch self {
        case .baseLightness:                     return 0.005
        case .shadowRadius, .shadowY:            return 0.5
        case .rimWidth, .embossInset, .embossBlur: return 0.25
        default:                                 return 0.01
        }
    }

    var format: String {
        switch self {
        case .shadowRadius, .shadowY, .rimWidth, .embossInset, .embossBlur: return "%.2f"
        case .baseLightness: return "%.3f"
        default: return "%.2f"
        }
    }

    var key: String { "cardsurf.\(rawValue)" }
}

// MARK: - Hex dials

enum CardSurfaceHex: String, CaseIterable, Identifiable {
    case shadowHex        // 2
    case groundHex        // 3
    case rimHex           // 4
    case embossLightHex   // 5
    case embossDarkHex    // 5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shadowHex:      return "2 · Shadow hex"
        case .groundHex:      return "3 · Ground hex"
        case .rimHex:         return "4 · Rim hex"
        case .embossLightHex: return "5 · Emboss light hex"
        case .embossDarkHex:  return "5 · Emboss dark hex"
        }
    }

    var key: String { "cardsurf.\(rawValue)" }
}

// MARK: - Bool dials

enum CardSurfaceFlag: String, CaseIterable, Identifiable {
    case rimTopOnly       // 4 — true = current top→bottom fade; false = all edges
    case embossEnabled    // 5 — DEFAULT OFF so T sees it appear
    case embossRaised     // 5 — true = light top / dark bottom; false = inverse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rimTopOnly:    return "4 · Rim: top-only (off = all edges)"
        case .embossEnabled: return "5 · Emboss ENABLED"
        case .embossRaised:  return "5 · Emboss raised (off = pressed)"
        }
    }

    var key: String { "cardsurf.\(rawValue)" }
}

// MARK: - Compiled-in shipped defaults (the ONLY place these are written)

/// ★ T'S DEVICE PICK, COMPILED IN (device, TestFlight `202608091420`, 2026-08-09).
/// These are the light-mode card surface's SHIPPED values: a user with EMPTY tuning
/// storage gets exactly this FROM CODE — not from a stored or panel-supplied value.
/// Same idiom as `LeverShimmerTuning.defaultVariant`.
///
/// ★ THE DIRECTION T CHOSE WAS **LIGHTER, NOT DARKER** — do not relitigate it.
/// The card face resolves to **`#FFFFFA`** (baseLightness `1.10`, i.e. ABOVE 1.0 —
/// lifted toward white) on the UNCHANGED `#F4EFE3` parchment ground, so the card
/// separates by being brighter than its ground rather than by casting a heavier
/// shadow. Everything else follows from that: shadow alpha drops `0.22 → 0.07`
/// (near-zero occlusion) while falling further and softer (`y 4 → 11`, radius
/// `12 → 12.5`); the rim goes faint → **strong** (`0.24 → 0.95`) and finer
/// (`1.5 → 1.25`); and the **emboss is ON**, raised, inset 0, blur 0.5.
/// Separation is carried by LUMINANCE and EDGE, not occlusion — which is also the
/// colorblind-safe register.
///
/// ★ live-22 (1) — T's picks from the live-21 renders (2026-10-16): palette L2 (cards #FBF9F5), field F2
/// (#F4F2ED), the card edge a 0.5 pt black hairline @0.16 on all edges in place of the white top rim, and the drop
/// shadow at 25% of today's strength (0.262 → 0.0655; radius 12.5 and y 11 unchanged — at a quarter strength the
/// same radius still reads as a soft lift, so it stays). The emboss is unchanged.
///
/// ★ live-23 (1) — T tuned it on the phone with the live-22 tuner (2026-10-16, Ops
/// `reference/appearance-tuning-2026-10-16.md`): the shadow back up to 50% (0.131) with a much wider radius (24 —
/// a wide, soft lift rather than a tight one), the hairline at 0.25. The dark field is half a step lighter (#1A1A1A,
/// `CardSurfaceResolved.ground`); the rest of dark is unchanged.
///
/// ⚠️ LIGHT-MODE ONLY. Every dark resolver returns a shipped literal and cannot
/// read these values (see `CardSurfaceResolved`), so dark is untouched by this bake.
enum CardSurfaceDefaults {
    /// live-22 — the shadow alpha T's "25% of today" is measured against (live-21's S1; the appearance tuner's 100%).
    static let referenceShadowAlpha = 0.262
    /// live-22 — the card edge before the hairline (the white top rim); the appearance tuner's "hairline off".
    static let priorRimHex = "FFFFFF"
    static let priorRimOpacity = 0.95
    static let priorRimWidth = 1.25
    /// live-22 — the hairline's colour (live-21's S4: black, all edges).
    static let hairlineHex = "000000"

    static func value(_ d: CardSurfaceDial) -> Double {
        switch d {
        case .baseLightness:    return 1.000   // live-22 (1) T: L2 — the paper #FBF9F5 IS the card face (was 1.100 → #FFFFFA on L1)
        case .shadowAlpha:      return referenceShadowAlpha * 0.5    // live-23 (1) T tuned on device: 50% of 0.262 = 0.131 (live-22: 25%)
        case .shadowRadius:     return 24.00   // live-23 (1) T tuned on device: a wide, soft lift (was 12.5)
        case .shadowY:          return 11.00   // T (was 4.0) — falls further/softer
        case .rimOpacity:       return 0.25    // live-23 (1) T tuned on device (live-22: 0.16; before that the white rim @0.95 — priorRimOpacity)
        case .rimWidth:         return 0.50    // live-22 (1) T: hairline 0.5 pt (was 1.25 — priorRimWidth)
        case .embossLightAlpha: return 0.47    // T (was 0.35)
        case .embossDarkAlpha:  return 0.13    // T (was 0.25)
        case .embossInset:      return 0.00    // T (was 2.0)
        case .embossBlur:       return 0.50    // T (was 0.0)
        }
    }

    static func hex(_ h: CardSurfaceHex) -> String {
        switch h {
        case .shadowHex:      return "3F3A33"  // live-22 (1) T: L2's warm shadow (was 434343)
        case .groundHex:      return "F4F2ED"  // live-22 (1) T: L2 · F2, one step lighter than L2's #EFECE6 (was DDDDDD) — map + card ground
        case .rimHex:         return hairlineHex   // live-22 (1) T: the hairline is black (was FFFFFF — priorRimHex)
        case .embossLightHex: return "FFFFFF"  // T kept white
        case .embossDarkHex:  return "43372A"  // T kept the warm brown-gray
        }
    }

    static func flag(_ f: CardSurfaceFlag) -> Bool {
        switch f {
        case .rimTopOnly:    return false      // live-22 (1) T: the hairline runs all edges (was the top→bottom fade)
        case .embossEnabled: return true       // ★ T turned the emboss ON
        case .embossRaised:  return true       // light top / dark bottom
        }
    }
}

// MARK: - Store

/// An App Store build has no tuner, so there is no write path and no UserDefaults read: the compiled-in
/// `CardSurfaceDefaults` ARE the shipped values. live-22 (2): in DEBUG / TestFlight the on-device appearance tuner
/// (`AppearanceTuning`) can vary the LIGHT values live; at its defaults it returns exactly `CardSurfaceDefaults`
/// (`-AppearanceTuningSelfTest`), and in DEBUG it is only live with `-AppearanceTuner YES`, so a Simulator carrying
/// keys from an earlier dialing session still cannot contaminate a verification run.
enum CardSurfaceStore {
    #if DEBUG || TESTFLIGHT
    static func read(_ d: CardSurfaceDial) -> Double { AppearanceTuning.light(d, baked: CardSurfaceDefaults.value(d)) }
    static func read(_ h: CardSurfaceHex) -> String { AppearanceTuning.light(h, baked: CardSurfaceDefaults.hex(h)) }
    static func read(_ f: CardSurfaceFlag) -> Bool { AppearanceTuning.light(f, baked: CardSurfaceDefaults.flag(f)) }
    #else
    static func read(_ d: CardSurfaceDial) -> Double { CardSurfaceDefaults.value(d) }
    static func read(_ h: CardSurfaceHex) -> String { CardSurfaceDefaults.hex(h) }
    static func read(_ f: CardSurfaceFlag) -> Bool { CardSurfaceDefaults.flag(f) }
    #endif
}

// MARK: - Resolvers (the ONLY readers the live surfaces use)

enum CardSurfaceResolved {

    private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return (CGFloat((v >> 16) & 0xFF) / 255.0,
                CGFloat((v >> 8) & 0xFF) / 255.0,
                CGFloat(v & 0xFF) / 255.0)
    }

    /// Touch the observable so the calling body re-renders on a knob change.

    // 1 — CARD BACKGROUND -----------------------------------------------------

    /// Light-only. Dark never reads this (the dark gradient path never calls
    /// `pigmentOnParchment`).
    static var baseLightness: CGFloat {
        return CGFloat(CardSurfaceStore.read(.baseLightness))
    }

    /// The resolved card-background hex, for the panel's live readout — T is
    /// colorblind, so the hex is the verifiable control, not the swatch.
    static var resolvedCardBackgroundHex: String {
        let (r, g, b) = rgb(AppearancePalette.cwParchmentHex)
        let l = baseLightness
        let rr = Int((min(1, r * l) * 255).rounded())
        let gg = Int((min(1, g * l) * 255).rounded())
        let bb = Int((min(1, b * l) * 255).rounded())
        return String(format: "#%02X%02X%02X", rr, gg, bb)
    }

    // 2 — CARD SHADOW ---------------------------------------------------------

    /// Dark branch is the shipped literal `black @ 0.32`, byte-identical.
    ///
    /// ⚠️ Kept for any consumer that needs the appearance-adaptive token without a
    /// `dark:` in hand. It does NOT carry the transition presence factor, because a
    /// `Color(UIColor { trait in … })` dynamic provider is opaque to SwiftUI's
    /// interpolation and will not animate. The two card surfaces use
    /// ONE resolver, so the carousel and the grid cannot drift from each other.
    static var cardShadow: Color {
        let bakedHex = CardSurfaceStore.read(.shadowHex)
        let bakedAlpha = CardSurfaceStore.read(.shadowAlpha)
        var darkAlpha: CGFloat = 0.742   // T device-final 2026-09-14, see Ops/reference/tuner-state-accepted.md
        #if DEBUG || TESTFLIGHT
        darkAlpha = CGFloat(AppearanceTuning.darkShadowAlpha(baked: Double(darkAlpha)))   // live-22 (2) — read here, in body
        #endif
        return Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0, green: 0, blue: 0, alpha: darkAlpha)
            }
            let (r, g, b) = rgb(bakedHex)
            return UIColor(red: r, green: g, blue: b, alpha: CGFloat(bakedAlpha))
        })
    }

    /// The shadow colour the card surfaces actually render, as a PLAIN `Color` so
    /// SwiftUI can interpolate its alpha (a dynamic `UIColor` provider cannot be
    ///
    /// ⚠️ DARK: `black @ 0.32 × presence`. At rest presence is 1, so dark's resting
    /// appearance is exactly the shipped `black @ 0.32` — unchanged.
    /// Light-only geometry. DARK keeps the shipped `12` / `4` exactly.
    static func shadowRadius(dark: Bool) -> CGFloat {
        #if DEBUG || TESTFLIGHT
        if dark { return AppearanceTuning.darkShadowRadius(baked: 12) }   // live-22 (2)
        #endif
        return dark ? 12 : CGFloat(CardSurfaceStore.read(.shadowRadius))
    }
    static func shadowY(dark: Bool) -> CGFloat {
        dark ? 4 : CGFloat(CardSurfaceStore.read(.shadowY))
    }

    // 3 — GROUND --------------------------------------------------------------

    /// Dark branch is the shipped literal `#111115`, byte-identical.
    static func ground(dark: Bool) -> Color {
        // dark: live-23 (1) T tuned on device — half a step lighter, #1A1A1A (was #161616, T device-final 2026-09-14)
        let baked = dark ? "1A1A1A" : CardSurfaceStore.read(.groundHex)
        var hex = baked
        #if DEBUG || TESTFLIGHT
        if dark { hex = AppearanceTuning.darkGroundHex(baked: baked) }   // live-22 (2)
        #endif
        let (r, g, b) = rgb(hex)
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }

    // 4 — RIM -----------------------------------------------------------------

    /// An App Store build's dark card edge (live-26 (1), T 2026-10-18): a white hairline on every edge, 1 pt at 12%.
    /// nil would be the top-only white fade (0.24, 1.5 pt) dark had before.
    static let bakedDarkHairline: (opacity: Double, width: Double)? = (0.12, 1)

    /// The rim gradient's two stops. ★ DARK IS EXACTLY THE SHIPPED PAIR —
    /// `Color.white.opacity(0.24)` → `Color.white.opacity(0)` — so splitting the
    /// rim per-mode leaves dark byte-identical.
    static func rimStops(dark: Bool) -> [Color] {
        #if DEBUG || TESTFLIGHT
        if AppearanceTuning.isLive {
            if dark, let h = AppearanceTuning.darkHairline { return [Color.white.opacity(h.opacity), Color.white.opacity(0)] }   // live-22 (2)
            if dark { return [Color.white.opacity(0.24), Color.white.opacity(0)] }
        }
        #endif
        if dark, let h = bakedDarkHairline { return [Color.white.opacity(h.opacity), Color.white.opacity(0)] }
        if dark { return [Color.white.opacity(0.24), Color.white.opacity(0)] }
        let (r, g, b) = rgb(CardSurfaceStore.read(.rimHex))
        let base = Color(red: Double(r), green: Double(g), blue: Double(b))
        return [base.opacity(CardSurfaceStore.read(.rimOpacity)), base.opacity(0)]
    }

    static func rimWidth(dark: Bool) -> CGFloat {
        #if DEBUG || TESTFLIGHT
        if dark, AppearanceTuning.isLive { return AppearanceTuning.darkHairline.map { CGFloat($0.width) } ?? 1.5 }   // live-22 (2)
        #endif
        if dark, let h = bakedDarkHairline { return CGFloat(h.width) }
        return dark ? 1.5 : CGFloat(CardSurfaceStore.read(.rimWidth))
    }

    /// Top-only (the shipped fade) vs all-edges. Dark is always the shipped
    /// top-only gradient.
    static func rimIsTopOnly(dark: Bool) -> Bool {
        #if DEBUG || TESTFLIGHT
        if dark, AppearanceTuning.isLive { return AppearanceTuning.darkHairline == nil }   // live-22 (2): a dark hairline runs all edges
        #endif
        if dark { return bakedDarkHairline == nil }
        return CardSurfaceStore.read(.rimTopOnly)
    }

    static func rimGradient(dark: Bool) -> LinearGradient {
        let stops = rimStops(dark: dark)
        if rimIsTopOnly(dark: dark) {
            return LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
        }
        // All-edges: a flat stroke at the rim colour (no fade).
        return LinearGradient(colors: [stops[0], stops[0]], startPoint: .top, endPoint: .bottom)
    }

    // 5 — EMBOSS (new; light-only, default OFF) --------------------------------

    static func embossEnabled(dark: Bool) -> Bool {
        if dark { return false }          // light-only by construction
        return CardSurfaceStore.read(.embossEnabled)
    }

    /// Paired inner hairlines inset from the card edge — one light, one dark.
    /// Raised = light on top / dark on bottom; pressed = the inverse.
    static func embossStops(dark: Bool) -> (top: Color, bottom: Color) {
        let (lr, lg, lb) = rgb(CardSurfaceStore.read(.embossLightHex))
        let (dr, dg, db) = rgb(CardSurfaceStore.read(.embossDarkHex))
        let light = Color(red: Double(lr), green: Double(lg), blue: Double(lb))
            .opacity(CardSurfaceStore.read(.embossLightAlpha))
        let shade = Color(red: Double(dr), green: Double(dg), blue: Double(db))
            .opacity(CardSurfaceStore.read(.embossDarkAlpha))
        let raised = CardSurfaceStore.read(.embossRaised)
        return raised ? (light, shade) : (shade, light)
    }

    static var embossInset: CGFloat { CGFloat(CardSurfaceStore.read(.embossInset)) }
    static var embossBlur: CGFloat { CGFloat(CardSurfaceStore.read(.embossBlur)) }
}

// MARK: - Emboss overlay (shared by BOTH card surfaces)

/// Paired inner hairlines inset from the card edge. Applied by `NodeCardView`
/// (radius 30) and `NodeGridTile` (radius 14) through the same builder, so the
/// two surfaces cannot diverge. Renders nothing in dark, and nothing when the
/// flag is off — which is the shipped state.
struct CardEmbossOverlay: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        if CardSurfaceResolved.embossEnabled(dark: dark) {
            let stops = CardSurfaceResolved.embossStops(dark: dark)
            let inset = CardSurfaceResolved.embossInset
            let blur = CardSurfaceResolved.embossBlur
            ZStack {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [stops.top, .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.clear, stops.bottom],
                                       startPoint: .center, endPoint: .bottom),
                        lineWidth: 1
                    )
            }
            .padding(inset)
            .blur(radius: blur)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Hero photo fade (live-23 (3))

/// The fade of a card's hero photo into the card body (carousel + grid). T (2026-10-17): live-22's fade was "too
/// severe" — a linear ramp over the last 22% of the hero zone. The fluted cards, which blend seamlessly, ease their
/// colour out over the lower half of the zone with a short tail past its edge (measured on the live-22 carousel: 76%
/// of peak at the zone's middle, 43% at 0.8, 10% at its edge, 6% just past it). So the photo now runs 10% past the
/// zone and fades over the last 60% of the zone on a smoothstep. The TestFlight appearance tuner varies length and
/// curve live (per appearance); an App Store build renders `baked`.
/// live-28 (A1) — light's hero fade: Today (live-27's full-width veil), A (a band behind the dateline only), B (A plus a
/// perceptual fade). The App Store build keeps Today until T picks (`CardHeroFade.bakedLightMode`).
/// Compiled into every build (the App Store build reads `bakedLightMode`); the tuner sets it in DEBUG / TestFlight.
enum LightFadeMode: String, Codable, CaseIterable, Identifiable {
    case today, band, perceptual
    var id: String { rawValue }
    var label: String { self == .today ? "Today" : self == .band ? "A" : "B" }
}

enum CardHeroFade {
    /// `length`: the fraction of the hero zone the photo fades over. `curve`: 0 linear · 1 smoothstep ·
    /// 2 smootherstep (between: a blend). `overshoot`: how far past the zone the photo runs, as a fraction of it.
    struct Shape: Equatable, CustomStringConvertible {
        var length: Double; var curve: Double; var overshoot: Double
        /// live-26 (3c) — "Fade into body": how far the photo carries down into the card body, 0 (today) … 1 (to the
        /// bottom of the title block, `titleDepth` of the zone further down). The fade keeps its length and curve and
        /// moves down with it.
        var intoBody: Double = 0
        /// live-26 (3c) — the veil behind the card text where the photo now runs: from 0.95 zones down the photo's opacity
        /// is × (1 − scrim). Set by `current(dark:)` (`textScrim` × `intoBody`), so today's fade (into 0) has none.
        var scrim: Double = 0
        /// live-28 (A1) B — light's perceptual fade: the opacity re-shaped by `perceptualGamma` (the photo holds longer,
        /// then falls faster to the same end).
        var perceptual = false
        var description: String {
            String(format: "length %.2f curve %.2f overshoot %.2f into %.2f scrim %.2f", length, curve, overshoot, intoBody, scrim)
        }
    }
    /// How far past the photo's overshoot the title block ends, as a fraction of the zone: measured title-block bottoms
    /// at 1.36 (carousel, one-line title) · 1.44 (grid 3) · 1.60 (grid 2) · 1.66 (Map) zones from the card top, so
    /// "Fade into body" at 100% ends the photo at 1.6 zones (live-26 (3c)).
    static let titleDepth: Double = 0.5
    /// The photo's run past the zone, as a fraction of it: the overshoot plus the "Fade into body" extension.
    static func run(_ s: Shape) -> Double { max(s.overshoot, 0) + min(max(s.intoBody, 0), 1) * titleDepth }
    /// live-27 (0) — T's light fade (2026-10-18 (b)): over 39% of the zone, curve 0.5, carried 14% into the body.
    static let bakedLight = Shape(length: 0.25, curve: 2, overshoot: 0.10, intoBody: 0.15)   // live-29 (B1): T's 10-19
    /// live-26 (1) — T's dark fade (2026-10-18): over 35% of the zone, nearly linear (curve 0.15); live-27 (0): carried
    /// 18% into the body.
    static let bakedDark = Shape(length: 0.35, curve: 0.15, overshoot: 0.10, intoBody: 0)   // live-29 (B1): T's 10-19
    /// What an App Store build renders for an appearance.
    static func baked(dark: Bool) -> Shape { dark ? bakedDark : bakedLight }
    /// live-26 (3c) — "Match fluted": the photo fade fitted (least squares over 0.5–2.2 zones) to the fluted cards'
    /// measured fade on the carousel, grid 2 / 3 and Map faces (Ops design-refs/live26-*/fade-profiles.md). Dark: 50% at
    /// 0.96 zones, 5% at 1.21 (T's dark fade: 0.98 / 1.08). Light: 50% at 1.21, 5% at 1.52 (today: 0.85 / 1.03).
    static func matchFluted(dark: Bool) -> Shape {
        dark ? Shape(length: 0.80, curve: 1.9, overshoot: 0.10, intoBody: 0.50)
             : Shape(length: 0.80, curve: 0.8, overshoot: 0.10, intoBody: 1.00)
    }
    /// live-22's mask (for the "before" stills and the self-test).
    static let live22 = Shape(length: 0.22, curve: 0, overshoot: 0)

    static func current(dark: Bool) -> Shape {
        var s = baked(dark: dark)
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { s = v.heroFade }
        #endif
        s.scrim = veil(intoBody: s.intoBody, dark: dark)
        // live-28 (A1) — A / B in light: no full-width veil (it washed the photo out above the dateline, inside the hero
        // zone); the dateline gets its own band (`datelineBand`). B also re-shapes the fade.
        if !dark && lightMode != .today { s.scrim = 0; s.perceptual = lightMode == .perceptual }
        return s
    }

    /// live-28 (A1) — light's fade in an App Store build until T picks on device.
    static let bakedLightMode: LightFadeMode = .band   // live-29 (B1): T picked A (10-19)
    static var lightMode: LightFadeMode {
        #if DEBUG
        if let f = UserDefaults.standard.string(forKey: "LightFade"), let m = LightFadeMode(rawValue: f) { return m }
        #endif
        #if DEBUG || TESTFLIGHT
        if AppearanceTuning.isLive { return AppearanceTuner.shared.state.lightFade }
        #endif
        return bakedLightMode
    }
    /// B's re-shaping power on the photo's opacity (< 1 keeps the photo longer). DEBUG `-PerceptualGamma`.
    static var perceptualGamma: Double {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "PerceptualGamma") != nil { return UserDefaults.standard.double(forKey: "PerceptualGamma") }
        #endif
        return 0.45
    }
    /// The band's feather above and below the dateline row: it never reaches further than this above the row's top.
    static let bandFeather: CGFloat = 8
    /// live-28 (A1) — A / B in light: the band behind the dateline row (its strength over the card body colour) and the
    /// dateline row's own ink (the other meta text keeps 76%). Nil = no band (Today, and dark).
    /// DEBUG `-DatelineBand` / `-DatelineInk` (the sweeps).
    static func datelineBand(dark: Bool) -> (strength: Double, ink: Double)? {
        guard !dark, lightMode != .today else { return nil }
        var band = lightMode == .band ? bandStrengthA : bandStrengthB, ink = lightMode == .band ? datelineInkA : datelineInkB
        #if DEBUG
        if UserDefaults.standard.object(forKey: "DatelineBand") != nil { band = UserDefaults.standard.double(forKey: "DatelineBand") }
        if UserDefaults.standard.object(forKey: "DatelineInk") != nil { ink = UserDefaults.standard.double(forKey: "DatelineInk") }
        #endif
        return (band, ink)
    }
    /// Measured (live-28 (A1), the hero-fade fixtures on the carousel, grid 2 / 3 and Map, light, every dateline ≥ 4.5): the
    /// least band at each dateline ink — A: 76% → 0.9, 85% → 0, 100% → 0; B: 76% → over 0.9, 85% → 0.6, 100% → 0. A darker
    /// dateline cuts the band to nothing, so neither needs one: A's dateline is 85% ink (worst 5.30), B's 100% (worst 4.92).
    static let bandStrengthA = 0.0, bandStrengthB = 0.0, datelineInkA = 0.85, datelineInkB = 1.0

    /// The veil behind the card text for a "Fade into body" setting (0 = today's fade: none). live-27 (1): dark scales
    /// with the extension (0.45 at 100%; T's 0.18 → 0.08 passes); light comes in fully by 10% of it — at T's 0.14 the least
    /// that keeps the dateline AA is 0.9, at Match fluted / 100% 1.0 (stills, Ops design-refs/live27-*/fade-veil.md).
    static func veil(intoBody: Double, dark: Bool) -> Double {
        textScrim(dark: dark) * min(max(intoBody, 0) / veilRamp(dark: dark), 1)
    }
    static func veilRamp(dark: Bool) -> Double { dark ? 1 : 0.10 }

    /// live-26 (3c) — the least veil that keeps every card text line AA (4.5:1, or no worse than on today's fade where
    /// that's already under) at "Match fluted" and at "Fade into body" 100%, measured on busy synthetic photos, light +
    /// dark (Ops design-refs/live26-*/fade-contrast.md). DEBUG `-FadeScrimLight` / `-FadeScrimDark` override it (sweeps).
    static func textScrim(dark: Bool) -> Double {
        #if DEBUG
        let k = dark ? "FadeScrimDark" : "FadeScrimLight"
        if UserDefaults.standard.object(forKey: k) != nil { return UserDefaults.standard.double(forKey: k) }
        #endif
        // Measured (live-26 (3c)): dark 0.45 (0.30 left the gradient-art source row at 3.9); light 1.0 — the light
        // source/time row was 3.74:1 on the plain body. live-27 (1): with the meta ink at AA (4.55) light still needs 1.0
        // at Match fluted / 100% (0.9 → 4.38 / 4.29): the ink clears AA by a hair, so any photo behind it is under.
        return dark ? 0.45 : 1.0
    }

    /// The photo frame's height for a hero zone.
    static func frameHeight(zone: CGFloat, _ s: Shape) -> CGFloat { zone * CGFloat(1 + run(s)) }

    /// Where the fade starts, as a fraction of the photo frame.
    static func fadeTop(_ s: Shape) -> Double {
        min(max(1 - min(max(s.length, 0.02), 1 + run(s)) / (1 + run(s)), 0), 0.98)
    }

    static func ease(_ p: Double, curve: Double) -> Double {
        let p = min(max(p, 0), 1)
        let smooth = p * p * (3 - 2 * p), smoother = p * p * p * (p * (6 * p - 15) + 10)
        let c = min(max(curve, 0), 2)
        return c <= 1 ? p + (smooth - p) * c : smooth + (smoother - smooth) * (c - 1)
    }

    /// Opacity of the photo at `y` (0 = top of the photo frame … 1 = its bottom).
    static func alpha(_ s: Shape, at y: Double) -> Double {
        let top = fadeTop(s)
        var a = y <= top ? 1 : 1 - ease((y - top) / (1 - top), curve: s.curve)
        if s.perceptual { a = pow(a, perceptualGamma) }
        guard s.scrim > 0 else { return a }
        return a * (1 - min(max(s.scrim, 0), 1) * ease((y * (1 + run(s)) - 0.95) / 0.10, curve: 1))
    }

    /// The mask's stops, top → bottom. Linear needs only its two ends (live-22's three-stop mask); an eased fade is
    /// sampled at 16 points.
    static func stops(_ s: Shape) -> [Gradient.Stop] {
        let top = fadeTop(s)
        if s.curve <= 0 && s.scrim <= 0 && !s.perceptual {
            return [.init(color: .black, location: 0), .init(color: .black, location: top), .init(color: .clear, location: 1)]
        }
        var ys = (0...15).map { top + (1 - top) * Double($0) / 15 }
        if s.scrim > 0 {   // the veil's ramp (0.95 → 1.05 zones), sampled too
            ys += (0...4).map { (0.95 + 0.025 * Double($0)) / (1 + run(s)) }.filter { $0 > 0 && $0 < 1 }
        }
        var out: [Gradient.Stop] = [.init(color: .black, location: 0)]
        for y in Set(ys).sorted() { out.append(.init(color: .black.opacity(alpha(s, at: y)), location: CGFloat(y))) }
        return out
    }
}


/// live-28 (A1) — the dateline row's frame, for the band behind it.
struct DatelineRowKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// live-28 (A1) — A / B in light: a soft band of the card body colour (#FBF9F5) behind the dateline row only, the row's
/// height plus `bandFeather` above and below, across the card. Drawn under the card text (and outside `-CardHideText`,
/// so the backdrop stills keep it). Nothing above the row's top minus the feather: the hero zone keeps T's fade.
struct DatelineBand: View {
    let anchor: Anchor<CGRect>?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { g in
            if let anchor, let band = CardHeroFade.datelineBand(dark: scheme == .dark), band.strength > 0 {
                let r = g[anchor], f = CardHeroFade.bandFeather, h = r.height + 2 * f
                let c = Color(hexString: "FBF9F5")
                LinearGradient(stops: [.init(color: c.opacity(0), location: 0), .init(color: c.opacity(band.strength), location: f / h),
                                       .init(color: c.opacity(band.strength), location: 1 - f / h), .init(color: c.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: g.size.width + 80, height: h)
                    .position(x: g.size.width / 2, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
