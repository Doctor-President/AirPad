import SwiftUI

/// Central type + color tokens for the chat lane. After this file lands,
/// nothing in `ChatTranscript` or `LibrarianSurface` may hardcode a chat
/// font size — every chat text site reads from here. Color tokens are hex
/// literals only (T is colorblind; hex is the verifiable source of truth).
enum ChatTypography {
    // Body. Bumped 15 -> 17 to match iOS system chat density.
    static let body        = Font.system(size: 17)
    static let bodyLine    : CGFloat = 6      // lineSpacing

    // Block markdown scale (used by COMMIT 2).
    static let h1          = Font.system(size: 22, weight: .semibold)
    static let h2          = Font.system(size: 19, weight: .semibold)
    static let h3          = Font.system(size: 17, weight: .semibold)
    static let code        = Font.system(size: 15, design: .monospaced)

    // Ancillary
    static let thinking    = Font.system(size: 14)
    static let footerIcon  = Font.system(size: 16)

    // Spacing
    static let blockSpacing    : CGFloat = 14   // between markdown blocks
    static let bulletIndent    : CGFloat = 20   // hanging indent
    static let bulletGap       : CGFloat = 8

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
