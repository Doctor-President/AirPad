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

    // Serif reads optically SMALLER than sans at equal point size.
    // 17 -> 18 is a correction, not an increase.
    static let body     = Font.custom(serif, size: 18, relativeTo: .body)
    static let bodyLine : CGFloat = 7    // was 6; serif wants more air

    static let h1 = Font.custom(serifBold, size: 24, relativeTo: .title2)
    static let h2 = Font.custom(serifBold, size: 21, relativeTo: .title3)
    static let h3 = Font.custom(serifBold, size: 18, relativeTo: .headline)

    // Code stays MONOSPACED SYSTEM. A serif code block is illegible.
    static let code = Font.system(size: 15, design: .monospaced)

    static let thinking = Font.custom(serif, size: 15, relativeTo: .footnote)

    // Footer icons are SF Symbols. System font. Unchanged.
    static let footerIcon = Font.system(size: 16)

    // Spacing
    static let blockSpacing : CGFloat = 16   // was 14; serif wants more
    static let bulletIndent : CGFloat = 20
    static let bulletGap    : CGFloat = 8

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
