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

    /// URL scheme carried by the inline superscript's `.link`. Piece 2 routes
    /// taps: `ChatTranscript` intercepts these via `openURL` and resolves the
    /// index against the turn's citations → `openNode`.
    static let scheme = "airpad-citation"
    static func url(forIndex index: Int) -> URL? { URL(string: "\(scheme)://\(index)") }
    /// Parses the `[n]` index back out of a citation link URL. Nil for any other URL.
    static func index(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.host ?? "")
    }

    /// Rewrites the model's `[n]` tokens in already-rendered assistant prose into
    /// superscript numerals (brackets dropped, ~0.7× body, baseline-raised, same
    /// Source Serif). Each becomes a `.link` to `airpad-citation://n` so the tap
    /// routes through `openURL` (Piece 2) — but stays MONOCHROME via an explicit
    /// foreground that overrides the default link tint. Done at render time — the
    /// model never emits superscript. No-op when there are no `[n]` tokens.
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
            superscript.foregroundColor = ChatTypography.bodyText   // monochrome, over link tint
            if let n = Int(number), let link = url(forIndex: n) {
                superscript.link = link
            }
            attr.replaceSubrange(range, with: superscript)
        }
    }

    /// SF Symbol for the footer's solid encircled number (`1.circle.fill` …).
    /// Falls back past the filled-number-circle range (1…50) — unlikely at topK 8.
    static func footerSymbolName(_ index: Int) -> String {
        (1...50).contains(index) ? "\(index).circle.fill" : "circle.fill"
    }

    /// The set of `[n]` indices the model actually cited in `text`. Ask uses this
    /// to keep only cited sources: retrieval provides candidate passages, but a
    /// passage becomes a citation only when the prose references it. Empty when the
    /// answer cites nothing (→ no footer). Same regex as the inline styler, so what
    /// renders as a superscript and what survives as a source can't disagree.
    static func citedIndices(in text: String) -> Set<Int> {
        let ns = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = Set<Int>()
        for m in matches where m.numberOfRanges > 1 {
            if let n = Int(ns.substring(with: m.range(at: 1))) { out.insert(n) }
        }
        return out
    }

    private static let markerRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
}
