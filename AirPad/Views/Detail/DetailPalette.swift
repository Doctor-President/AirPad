import SwiftUI
import UIKit

/// ws-dark-light-mode — detail-view-scoped semantic color tokens (STEP 1/2 of
/// the appearance arc). Two themes resolve through one trait-keyed layer:
///
/// - **Solar Flare (dark):** the values already shipped, EXTRACTED verbatim.
///   Every dark value equals what the detail view used before this token layer
///   (`#FFFFFF` chrome on the `#1A1A1A` ground), so the view reads BYTE-IDENTICAL
///   in dark — that is the correctness check for this refactor.
/// - **Cucumber Water (light):** a first-pass inverted-thermal palette — warm
///   parchment base, cool blue-black ink, a brighter-warmer elevated panel.
///   T judges and art-directs these hex values on device; they are a starting
///   point, not final.
///
/// Scoped to the detail view + its entry cards ONLY (the pattern test, not an
/// app-wide unification). `NoteTypography` is deliberately NOT touched — it is a
/// preserved type-role construct and already adaptive; the note *text* still
/// resolves through it. Typography/metrics (`EntryVisualSettings` type roles)
/// are untouched here too — this layer is color only.
///
/// The `UIColor { trait }` pattern mirrors the one `NoteTypography` already
/// proved: hex is authored per-theme in code (T reads hex, not swatches; he is
/// colorblind), and the value flips on `userInterfaceStyle`. Never a luminance
/// flip — each theme's hex is chosen from its own physics.
///
/// Token → 07-01 `--bg-*` mapping:
///   `bgBase`     → `--bg-base`     (the detail ground)
///   `bgElevated` → `--bg-elevated` (the raised note panel)
///   `--bg-surface` is expressed as `ink`-tint translucent fills (chips /
///     controls / hairlines) rather than a distinct opaque token — the detail
///     view's fills are translucent tints over the ground, and baking them
///     opaque would perturb the dark look this refactor must preserve.
enum DetailPalette {

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

    /// The note panel's lift shadow. Dark: `black@0.35` (the landed value —
    /// identical). Light: soft, low, diffused — no hard shadow ("cloud cover is
    /// a reprieve").
    static let panelShadow = dynamic(dark: "000000", darkAlpha: 0.35,
                                     light: "000000", lightAlpha: 0.10)
}
