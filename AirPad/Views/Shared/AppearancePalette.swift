import SwiftUI
import UIKit

/// ws-dark-light-mode — the app-level appearance token layer. The two
/// "rooms" (SB17) resolve through one trait-keyed layer; each theme's hex is
/// authored from its own physics ("light is sourced, not applied" — SB15),
/// never a luminance flip:
///
/// - **Solar Flare (dark):** the values already shipped, EXTRACTED verbatim.
///   Every dark value equals what surfaces used before this token layer
///   (`#FFFFFF` chrome on the `#1A1A1A` ground), so they read BYTE-IDENTICAL
///   in dark — that is the correctness check for every conversion to this layer.
/// - **Cucumber Water (light):** a first-pass inverted-thermal palette — warm
///   parchment base, cool blue-black ink, a brighter-warmer elevated panel.
///   T judges and art-directs these hex values on device; they are a starting
///   point, not final.
///
/// PROMOTED from `DetailPalette` (2026-07-16): the detail view was the pattern
/// test (surface 1, shipped `367126a`); it passed, so the same tokens now serve
/// the rest of the app (Map chrome, node cards, Dashboard, Librarian, capture
/// "+"). The token ROLES are unchanged — only the scope grew. `NoteTypography`
/// is still deliberately NOT touched (a preserved, already-adaptive type-role
/// construct; the note *text* resolves through it). Typography/metrics
/// (`EntryVisualSettings` type roles) are untouched too — this layer is color
/// only.
///
/// The `UIColor { trait }` pattern mirrors the one `NoteTypography` already
/// proved: hex is authored per-theme in code (T reads hex, not swatches; he is
/// colorblind), and the value flips on `userInterfaceStyle`.
///
/// Token → 07-01 `--bg-*` mapping:
///   `bgBase`     → `--bg-base`     (the base ground of a surface)
///   `bgElevated` → `--bg-elevated` (a raised panel/card)
///   `--bg-surface` is expressed as `ink`-tint translucent fills (chips /
///     controls / hairlines) rather than a distinct opaque token — fills are
///     translucent tints over the ground, and baking them opaque would perturb
///     the dark look this layer must preserve.
enum AppearancePalette {

    // MARK: - Hex helpers

    /// Parse a 6-digit sRGB hex (no `#`) into 0…1 components.
    private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return (
            CGFloat((v >> 16) & 0xFF) / 255.0,
            CGFloat((v >> 8) & 0xFF) / 255.0,
            CGFloat(v & 0xFF) / 255.0
        )
    }

    /// An opaque color that flips on the interface style.
    private static func dynamic(dark: String, light: String) -> Color {
        Color(UIColor { trait in
            let (r, g, b) = rgb(trait.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }

    /// A color carrying a per-theme alpha (for shadows / lifts).
    private static func dynamic(dark: String, darkAlpha: CGFloat,
                                light: String, lightAlpha: CGFloat) -> Color {
        Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let (r, g, b) = rgb(isDark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    // MARK: - Tokens

    /// `--bg-base` — the detail ground.
    /// Dark: `#1A1A1A` neutral near-black (the landed `NoteTypography.background`
    /// dark value — a NEUTRAL gray, R=G=B, not "warm"). Light: warm parchment,
    /// Tomoe River register — NOT stark white (`.systemBackground` would glare).
    static let bgBase = dynamic(dark: "1A1A1A", light: "F4EFE3")

    /// `--bg-elevated` — the raised note panel.
    /// Dark: `#1A1A1A` (matched to the ground — the panel floats by light, not
    /// color). Light: a hair brighter/warmer than the ground so it lifts by
    /// luminance (transmissive — light falls ONTO the paper).
    static let bgElevated = dynamic(dark: "1A1A1A", light: "FAF6EC")

    /// Primary foreground — text and icons. Used directly and at the same
    /// opacities the chrome used with `.white`. Dark `#FFFFFF` makes every
    /// `.white → ink` substitution identical in dark; light is a cool
    /// fountain-pen blue-black (the Tomoe-River pairing, and the "cool presence"
    /// the theme calls for) — dark enough to read on parchment.
    static let ink = dynamic(dark: "FFFFFF", light: "232A2E")

    /// Ink for text placed on a card FACE (over the warm-cream card art), at a
    /// given opacity. Dark reproduces the shipped warm-cream (`#FFF9F0`)
    /// BYTE-IDENTICAL; light flips to the appearance `ink` (`#232A2E`) so the
    /// text reads on Cucumber-Water parchment. Same opacity either way — the ink
    /// flip is coupled plumbing, not a judged knob. Mirrors NodeCardView's local
    /// `ink()`; shared here so the body chips can't drift from it.
    static func cardCreamInk(_ opacity: CGFloat) -> Color {
        let dark = UIColor(Color(red: 1.0, green: 0.976, blue: 0.941)).withAlphaComponent(opacity)
        let light = UIColor(ink)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .withAlphaComponent(opacity)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The note panel's lift shadow. Dark: `black@0.35` (the landed value —
    /// identical). Light: soft, low, diffused — no hard shadow ("cloud cover is
    /// a reprieve").
    static let panelShadow = dynamic(dark: "000000", darkAlpha: 0.35,
                                     light: "000000", lightAlpha: 0.10)

    /// The card lift shadow that separates a card FACE (carousel + grid tiles)
    /// from the ground. ONE token so the two surfaces can't drift.
    /// Dark: `black@0.32` — the shipped `NodeCardView` value, BYTE-IDENTICAL, so
    /// the dark card lift is unchanged. Light: a WARM low-saturation brown-gray
    /// (`#43372A`) pulled toward the Cucumber-Water cream — an occluded warm
    /// light reads warm on parchment, where a neutral gray reads "digital." Kept
    /// SUBTLE (physical, not tinted): `0.22` alpha vs the dark `0.32`, matching
    /// the parchment's soft-shadow register (T-dialed up from 0.18 for a touch
    /// more lift). Dial: T nudges the warmth via the light hex and the heft via
    /// `lightAlpha` here (hex is the colorblind-safe control; the grid scales
    /// this same color down by tile width).
    static let cardShadow = dynamic(dark: "000000", darkAlpha: 0.32,
                                    light: "43372A", lightAlpha: 0.22)

    /// Foreground for a glyph placed ON an `ink`-filled SOLID (the capture "+":
    /// an `ink` circle with this glyph cut out of it). Dark: pure `#000000` —
    /// byte-identical to the shipped `.black` plus on the `.white` circle
    /// (`ink` dark is `#FFFFFF`). Light: parchment `#F4EFE3` so the glyph reads
    /// as cut out of the dark `ink` circle on cream. Surface 6's "+" has no
    /// designed treatment yet (Solar Flare's white-on-dark was a default, not a
    /// decision) — this is a plausible, high-contrast first pass; T art-directs.
    static let onInk = dynamic(dark: "000000", light: "F4EFE3")

    /// Map dot-matrix dot color for the `BackgroundGridNode` shader
    /// (`u_dot_color`), which needs raw sRGB floats, not a SwiftUI `Color`.
    /// Dark `#FFFFFF` == the shipped white dots — byte-identical, since the
    /// shader outputs `u_dot_color * alpha` premultiplied and `(1,1,1)`
    /// reproduces the old `vec4(alpha,alpha,alpha,alpha)`. Light: a cool
    /// graphite so the dots read as SB03's "barely-there dot impressions …
    /// visible but not assertive" on parchment. This is only the hue/luma floor
    /// — the exact PRESENCE is T's to dial via the tuner's dot-opacity slider.
    static func mapGridDotRGB(dark: Bool) -> (r: Float, g: Float, b: Float) {
        let (r, g, b) = rgb(dark ? "FFFFFF" : "2E3A40")
        return (Float(r), Float(g), Float(b))
    }

    /// Map dot-matrix dot OPACITY for the `BackgroundGridNode` shader
    /// (`u_dot_opacity` — the peak dot alpha at xScale=1). Was a single shipped
    /// constant (0.25); now per-mode, T-dialed: dark `0.18` (a quieter dot on
    /// the near-black ground) / light `0.47` (dots need more presence to read
    /// on cream). Pushed live from the Map's per-frame trait resolution
    /// alongside `mapGridDotRGB`.
    static func mapGridDotOpacity(dark: Bool) -> Float {
        dark ? 0.18 : 0.47
    }

    /// The Map canvas background. Dark: `#111115` (T's dialed near-black — a
    /// hair warmer/lighter than the old `#07070A` Void). Light: `#F4EFE3`, the
    /// same parchment ground as the detail view (`bgBase`). Resolved by the
    /// caller's `colorScheme`, so the SwiftUI fill recomputes on appearance flip.
    static func mapBackground(dark: Bool) -> Color {
        let (r, g, b) = rgb(dark ? "111115" : "F4EFE3")
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
}
