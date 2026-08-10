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
/// ⚠️ LIGHT-MODE ONLY. Every dark resolver returns a shipped literal and cannot
/// read these values (see `CardSurfaceResolved`), so dark is untouched by this bake.
enum CardSurfaceDefaults {
    static func value(_ d: CardSurfaceDial) -> Double {
        switch d {
        case .baseLightness:    return 1.100   // T (was 0.98) → card resolves #FFFFFA
        case .shadowAlpha:      return 0.07    // T (was 0.22) — near-zero occlusion
        case .shadowRadius:     return 12.50   // T (was 12.0)
        case .shadowY:          return 11.00   // T (was 4.0) — falls further/softer
        case .rimOpacity:       return 0.95    // T (was 0.24) — strong edge
        case .rimWidth:         return 1.25    // T (was 1.5)
        case .embossLightAlpha: return 0.47    // T (was 0.35)
        case .embossDarkAlpha:  return 0.13    // T (was 0.25)
        case .embossInset:      return 0.00    // T (was 2.0)
        case .embossBlur:       return 0.50    // T (was 0.0)
        }
    }

    static func hex(_ h: CardSurfaceHex) -> String {
        switch h {
        case .shadowHex:      return "43372A"  // T kept the warm brown-gray
        case .groundHex:      return "F4EFE3"  // T kept the parchment ground
        case .rimHex:         return "FFFFFF"  // T kept white
        case .embossLightHex: return "FFFFFF"  // T kept white
        case .embossDarkHex:  return "43372A"  // T kept the warm brown-gray
        }
    }

    static func flag(_ f: CardSurfaceFlag) -> Bool {
        switch f {
        case .rimTopOnly:    return true       // T kept the top→bottom fade
        case .embossEnabled: return true       // ★ T turned the emboss ON
        case .embossRaised:  return true       // light top / dark bottom
        }
    }
}

// MARK: - Store

/// No tuner ships in this build, so there is no write path and no reason to read
/// UserDefaults: the compiled-in `CardSurfaceDefaults` ARE the shipped values, for
/// every build and every install. (This also means a Simulator carrying keys from
/// an earlier dialing session cannot contaminate a verification run.)
enum CardSurfaceStore {
    static func read(_ d: CardSurfaceDial) -> Double { CardSurfaceDefaults.value(d) }
    static func read(_ h: CardSurfaceHex) -> String { CardSurfaceDefaults.hex(h) }
    static func read(_ f: CardSurfaceFlag) -> Bool { CardSurfaceDefaults.flag(f) }
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
        let hex = CardSurfaceStore.read(.shadowHex)
        let alpha = CardSurfaceStore.read(.shadowAlpha)
        return Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0, green: 0, blue: 0, alpha: 0.32)
            }
            let (r, g, b) = rgb(hex)
            return UIColor(red: r, green: g, blue: b, alpha: CGFloat(alpha))
        })
    }

    /// The shadow colour the card surfaces actually render, as a PLAIN `Color` so
    /// SwiftUI can interpolate its alpha (a dynamic `UIColor` provider cannot be
    ///
    /// ⚠️ DARK: `black @ 0.32 × presence`. At rest presence is 1, so dark's resting
    /// appearance is exactly the shipped `black @ 0.32` — unchanged.
    /// Light-only geometry. DARK keeps the shipped `12` / `4` exactly.
    static func shadowRadius(dark: Bool) -> CGFloat {
        dark ? 12 : CGFloat(CardSurfaceStore.read(.shadowRadius))
    }
    static func shadowY(dark: Bool) -> CGFloat {
        dark ? 4 : CGFloat(CardSurfaceStore.read(.shadowY))
    }

    // 3 — GROUND --------------------------------------------------------------

    /// Dark branch is the shipped literal `#111115`, byte-identical.
    static func ground(dark: Bool) -> Color {
        let hex = dark ? "111115" : CardSurfaceStore.read(.groundHex)
        let (r, g, b) = rgb(hex)
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }

    // 4 — RIM -----------------------------------------------------------------

    /// The rim gradient's two stops. ★ DARK IS EXACTLY THE SHIPPED PAIR —
    /// `Color.white.opacity(0.24)` → `Color.white.opacity(0)` — so splitting the
    /// rim per-mode leaves dark byte-identical.
    static func rimStops(dark: Bool) -> [Color] {
        if dark { return [Color.white.opacity(0.24), Color.white.opacity(0)] }
        let (r, g, b) = rgb(CardSurfaceStore.read(.rimHex))
        let base = Color(red: Double(r), green: Double(g), blue: Double(b))
        return [base.opacity(CardSurfaceStore.read(.rimOpacity)), base.opacity(0)]
    }

    static func rimWidth(dark: Bool) -> CGFloat {
        dark ? 1.5 : CGFloat(CardSurfaceStore.read(.rimWidth))
    }

    /// Top-only (the shipped fade) vs all-edges. Dark is always the shipped
    /// top-only gradient.
    static func rimIsTopOnly(dark: Bool) -> Bool {
        if dark { return true }
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
