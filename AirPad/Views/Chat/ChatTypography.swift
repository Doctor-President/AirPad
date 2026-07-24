import SwiftUI
import UIKit

/// Central type + color tokens for the chat lane. After this file lands,
/// nothing in `ChatTranscript` or `LibrarianSurface` may hardcode a chat
/// font size — every chat text site reads from here. Color tokens are hex
/// literals only (T is colorblind; hex is the verifiable source of truth).
enum ChatTypography {
    // PostScript names — verified from the TTF name tables (nameID 6),
    // not the filenames. Both faces live in family "Source Serif 4", so
    // inline `**bold**` / `*italic*` resolve to the real faces via trait.
    private static let serif     = "SourceSerif4-Regular"
    private static let serifBold = "SourceSerif4-Bold"

    // Baked from the on-device tuner pass (Source Serif reads optically small).
    static let body     = Font.custom(serif, size: 19, relativeTo: .body)
    static let bodyLine : CGFloat = 0    // explicit. Source Serif's intrinsic
                                         // leading carries it. Keep the token:
                                         // lineSpacing is additive POINTS and
                                         // does NOT scale with Dynamic Type, so
                                         // a future non-zero value must be a
                                         // deliberate choice.

    // User bubble speaks in the app's voice (SF), not the model's serif.
    static let userBody = Font.system(size: 17)
    static let userLine : CGFloat = 3.5

    // h1 = 26. NO observed model has emitted `#`. Across five sampled turns
    // (FM + Qwen), `##` is the top-level heading and `###` the subheads.
    // This value exists only so h1 cannot collide with h2. Not tuned.
    static let h1 = Font.custom(serifBold, size: 26, relativeTo: .title2)
    static let h2 = Font.custom(serifBold, size: 23, relativeTo: .title3)
    // h3 IS live (`###`). Derived from the scale, NOT device-observed: T tuned
    // h2 while h3 still rendered at 18 — below body at 19, which inverted the
    // hierarchy. 21 restores h3 above body and below h2.
    static let h3 = Font.custom(serifBold, size: 21, relativeTo: .headline)

    // Code stays MONOSPACED SYSTEM. A serif code block is illegible.
    static let code = Font.system(size: 15, design: .monospaced)

    static let thinking = Font.custom(serif, size: 15, relativeTo: .footnote)

    // Footer icons are SF Symbols. System font. Unchanged.
    static let footerIcon = Font.system(size: 16)

    // Piece 1.5 — inline citation superscript: the model's serif voice at ~0.7×
    // body (19 → 13), baseline-raised. Monochrome — inherits the answer's
    // `bodyText` color (no foreground set on the run).
    static let inlineCitationSuperscript = Font.custom(serif, size: 13, relativeTo: .footnote)
    static let inlineCitationBaselineOffset: CGFloat = 6

    // Spacing — baked from the tuner pass. `listSpacing` (adjacent list items
    // of the same kind) is deliberately tighter than `blockSpacing` so a list
    // reads as one object; `headingSpaceBefore` is EXTRA air above a heading,
    // added on top of `blockSpacing`. All consumed by `BlockSpacing.topPad`.
    static let listSpacing        : CGFloat = 10.5
    static let blockSpacing       : CGFloat = 17.5
    static let headingSpaceBefore : CGFloat = 8
    // `bulletGap` is nearly zero — the gutter is carried almost entirely by
    // `.frame(width: bulletIndent)`. That frame is load-bearing: it is the
    // only thing right-aligning numbered markers of differing widths
    // (`1.` vs `10.`). Do NOT remove it.
    static let bulletIndent       : CGFloat = 15.5
    static let bulletGap          : CGFloat = 1.5

    // COLOR TOKENS — now PER-MODE (chat was white in light: these hex tokens are
    // the chat's own two-voice palette, separate from AppearancePalette, so the
    // `.white` sweep never caught them). DARK values are the shipped hexes, so
    // dark stays BYTE-IDENTICAL; LIGHT flips to warm dark ink that reads on the
    // Cucumber-Water cream panel. Still hex-only (T is colorblind).
    //
    // Body text moves OFF pure white in dark (deliberate; #FFFFFF at 17pt on
    // near-black reads harsh) — and off pure black in light for the same reason.

    /// Dynamic dark/light color from two hex literals.
    private static func dyn(dark: String, light: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(Color(hexString: dark)) : UIColor(Color(hexString: light)) })
    }

    static let bodyText      = dyn(dark: "E8E6E3", light: "2A2520")  // warm off-white / warm near-black
    static let headingText   = dyn(dark: "F5F3F0", light: "1A1712")  // lifted / deeper (headings pop)
    static let secondaryText = dyn(dark: "9A9793", light: "6B655C")  // thinking/footer — warm mid-grey both modes

    // User bubble — Electric Cyan. DARK: translucent @0.18 (unchanged). LIGHT:
    // BOLDER cyan (@0.90) so the bubble reads on cream, with CONTRAST-DERIVED text
    // (legibleInk over the cyan fill — same luminance rule as tag pills / map orbs;
    // cyan luminance < 0.62 → warm off-white, i.e. white-on-cyan like iMessage).
    static let userBubbleFill  = Color(hexString: "00BFFF")  // hue (verifiable source)
    static let userBubbleAlpha : Double = 0.18               // dark (unchanged)

    /// Adaptive bubble FILL: dark cyan@0.18 (byte-identical) / light cyan@0.90.
    static let userBubbleFillResolved = Color(UIColor { t in
        let cyan = UIColor(Color(hexString: "00BFFF"))
        return cyan.withAlphaComponent(t.userInterfaceStyle == .dark ? 0.18 : 0.90)
    })
    /// Adaptive bubble TEXT: dark #F5F3F0 (byte-identical) / light = legibleInk
    /// over the cyan fill (contrast-derived).
    static let userBubbleText = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(Color(hexString: "F5F3F0"))
            : UIColor(AppearancePalette.legibleInk(onFillHex: "00BFFF"))
    })
}
