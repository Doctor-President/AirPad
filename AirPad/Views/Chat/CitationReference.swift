import SwiftUI

/// ws-citation-deeplink Piece 1.5 — ONE "citation reference" concept, TWO
/// renderings that share the same number and rhyme visually:
///   - inline: a light SUPERSCRIPT numeral in the model's serif voice — points
///     *down* to the source.
///   - footer: a solid ENCIRCLED numeral (the destination).
/// Both live here so Piece 2 (tap → node) wires BOTH navigations from one place,
/// not from two scattered style tweaks. Monochrome — no color-coding (the app's
/// tag/blob/Map-neighborhood color languages are siloed and don't agree yet;
/// chips inherit a unified color only after that arc).
enum CitationReference {

    /// Rewrites the model's `[n]` tokens in already-rendered assistant prose into
    /// superscript numerals (brackets dropped, ~0.7× body, baseline-raised, same
    /// Source Serif). Done at render time — the model is never asked to emit
    /// superscript. Mutates in place; safe to call on any inline AttributedString
    /// (a no-op when there are no `[n]` tokens, so OPEN answers are untouched).
    static func styleInlineMarkers(in attr: inout AttributedString) {
        while true {
            let plain = String(attr.characters)
            let ns = plain as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let match = markerRegex.firstMatch(in: plain, range: full) else { break }
            let token = ns.substring(with: match.range)          // "[2]"
            let number = ns.substring(with: match.range(at: 1))  // "2"
            guard let range = attr.range(of: token) else { break }
            var superscript = AttributedString(number)
            superscript.font = ChatTypography.inlineCitationSuperscript
            superscript.baselineOffset = ChatTypography.inlineCitationBaselineOffset
            attr.replaceSubrange(range, with: superscript)
        }
    }

    /// SF Symbol for the footer's solid encircled number (`1.circle.fill` …).
    /// Falls back past the filled-number-circle range (1…50) — unlikely at topK 8.
    static func footerSymbolName(_ index: Int) -> String {
        (1...50).contains(index) ? "\(index).circle.fill" : "circle.fill"
    }

    private static let markerRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
}
