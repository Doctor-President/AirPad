import SwiftUI

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

    // COLOR TOKENS — hex literals only. Do not substitute named colors.
    // Body text moves OFF pure white. This is deliberate; #FFFFFF at
    // 17pt on near-black reads harsh.
    static let bodyText        = Color(hexString: "E8E6E3")  // warm off-white
    static let headingText     = Color(hexString: "F5F3F0")  // slightly lifted
    static let secondaryText   = Color(hexString: "9A9793")  // thinking/footer
    static let userBubbleFill  = Color(hexString: "00BFFF")  // Electric Cyan
    static let userBubbleAlpha : Double = 0.18               // unchanged
    static let userBubbleText  = Color(hexString: "F5F3F0")
}
