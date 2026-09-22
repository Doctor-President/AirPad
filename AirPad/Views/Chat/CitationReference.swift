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
            guard let match = citationTokenRegex.firstMatch(in: plain, range: full) else { break }
            let token = ns.substring(with: match.range)          // "[2]" or "[1, 2, 7]"
            guard let range = attr.range(of: token) else { break }
            // AC1 — one superscript per index in the bracket (deepseek writes
            // `[1, 2, 7]`), each linked to its own citation. AE3 — a thin space
            // separates adjacent numerals so consecutive markers never fuse: between
            // indices of one bracket, AND before a token that abuts a prior citation
            // numeral (`[25][26]` → "2526" → "²⁵ ²⁶"). The replacement carries no `[`,
            // so the next `firstMatch` advances.
            func separator() -> AttributedString {
                var sep = AttributedString("\u{2009}")   // thin space
                sep.font = ChatTypography.inlineCitationSuperscript
                sep.baselineOffset = ChatTypography.inlineCitationBaselineOffset
                return sep
            }
            var replacement = AttributedString("")
            if match.range.location > 0,
               ns.substring(with: NSRange(location: match.range.location - 1, length: 1)).first?.isNumber == true {
                replacement.append(separator())   // AE3 — abuts the previous marker
            }
            for (i, n) in indices(inToken: token).enumerated() {
                if i > 0 { replacement.append(separator()) }
                var sup = AttributedString("\(n)")
                sup.font = ChatTypography.inlineCitationSuperscript
                sup.baselineOffset = ChatTypography.inlineCitationBaselineOffset
                sup.foregroundColor = ChatTypography.bodyText   // monochrome, over link tint
                if let link = url(forIndex: n) { sup.link = link }
                replacement.append(sup)
            }
            attr.replaceSubrange(range, with: replacement)
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
        let matches = citationTokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = Set<Int>()
        for m in matches { out.formUnion(indices(inToken: ns.substring(with: m.range))) }
        return out
    }

    /// Brief AB3 — remove every `[n]` whose index is NOT in `valid` (a hallucinated
    /// marker with no candidate behind it), so it never renders as a superscript or
    /// a chip. Valid markers are left for `styleInlineMarkers`. Absorbs one space
    /// before a removed token so "foo [9] bar" reads "foo bar". Applied at commit
    /// time in `ChatSession.send`, so it covers every turn (the empty-library branch
    /// passes an empty `valid` set → all markers stripped).
    static func stripInvalidMarkers(in text: String, valid: Set<Int>) -> String {
        let ns = text as NSString
        let matches = citationTokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ns
        for m in matches.reversed() {
            let all = indices(inToken: ns.substring(with: m.range))
            let kept = all.filter { valid.contains($0) }
            if kept.count == all.count { continue }   // all valid — leave untouched
            var r = m.range
            if kept.isEmpty {
                // Whole token invalid → drop it, absorbing one preceding space.
                if r.location > 0, out.substring(with: NSRange(location: r.location - 1, length: 1)) == " " {
                    r = NSRange(location: r.location - 1, length: r.length + 1)
                }
                out = out.replacingCharacters(in: r, with: "") as NSString
            } else {
                // Some valid → rebuild the bracket with only the valid indices.
                out = out.replacingCharacters(in: r, with: "[" + kept.map(String.init).joined(separator: ", ") + "]") as NSString
            }
        }
        return out as String
    }

    /// AC1 — ONE citation token: a bracket holding one or more comma-separated
    /// 1-2 digit indices. Matches `[7]`, `[1, 2, 7]`, `[1,2]`; adjacency (`[n][m]`)
    /// and `[n], [m]` are two tokens. Shared by the renderer, `citedIndices`, and
    /// `stripInvalidMarkers` so parser/renderer/stripper can't disagree — and
    /// model-agnostic (Qwen writes `[7]`, deepseek writes `[1, 2, 7]`).
    static let citationTokenRegex = try! NSRegularExpression(pattern: #"\[\s*\d{1,2}(?:\s*,\s*\d{1,2})*\s*\]"#)
    private static let indexRegex = try! NSRegularExpression(pattern: #"\d{1,2}"#)

    /// All indices inside a citation token, in order (`"[1, 2, 7]"` → `[1, 2, 7]`).
    static func indices(inToken token: String) -> [Int] {
        let ns = token as NSString
        return indexRegex.matches(in: token, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range)) }
    }
}
