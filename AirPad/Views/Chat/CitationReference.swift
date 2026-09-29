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
    static func styleInlineMarkers(in attr: inout AttributedString, face: EntryBodyFont) {
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
                sep.font = ChatTypography.inlineCitationSuperscript(face)
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
                sup.font = ChatTypography.inlineCitationSuperscript(face)
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

    /// Brief BH — renumber cited `[n]` to **one number per SOURCE**, assigned 1…k by
    /// FIRST appearance in the prose, and rebuild ONE citation per source with the same
    /// number. Result: the inline superscripts and the node-deduped footer chips always
    /// show the same numbers (a reader's ¹ points at chip ①).
    ///
    /// The bug it fixes: two passages of one entry (`[3]` and `[12]`) kept two prose
    /// numbers but the footer dedupes by source and drew the FIRST kept citation's RAW
    /// candidate index — a number (e.g. ①) with no relation to the prose or to a source
    /// ordinal. This applies at commit time in EVERY citation path (corpus send, the web
    /// tool loop, the debug hook) — one numbering scheme, no second.
    ///
    /// Rewrites each `[n]` token to the source display number, collapses within-bracket
    /// duplicates (`[3, 12]` on one entry → `[1]`) and drops an immediately-repeated
    /// identical marker (`[1][1]` → `[1]`). Tap routing stays index-based (the link URL
    /// and the citation both carry the display number), so it still resolves to the node.
    /// `alwaysInclude` (Brief BU1) — RAW candidate indices that MUST survive as chips even when the
    /// prose never cited them: the entries READ IN FULL (BS2 — "provenance is the product").
    ///
    /// ★ Without this, BS2's guarantee was silently defeated HERE, at the last step.
    /// `alwaysCiteIndices` correctly kept the read entry past `ChatSession.send`'s cited-only filter,
    /// but this function then rebuilt its output **purely from prose mentions** — so an entry the
    /// model happened not to write `[n]` for was dropped anyway. It looked correct for as long as the
    /// model cited the entry of its own accord. Measured in the gauntlet on the offer/forced-read
    /// path (cases 4/5), where the model cited a skimmed passage instead: the footer read
    /// "Read *…* in full" while the entry had NO chip.
    static func renumberBySource(
        text: String,
        citations: [ChatSession.Message.Citation],
        alwaysInclude: Set<Int> = []
    ) -> (text: String, citations: [ChatSession.Message.Citation]) {
        guard !citations.isEmpty else { return (text, citations) }
        func sourceKey(_ c: ChatSession.Message.Citation) -> String { c.nodeID ?? c.url ?? "idx:\(c.index)" }
        // raw candidate index → its citation (first wins; per-block citations share a source).
        var byIndex: [Int: ChatSession.Message.Citation] = [:]
        for c in citations where byIndex[c.index] == nil { byIndex[c.index] = c }

        let ns = text as NSString
        let tokens = citationTokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Assign display numbers 1…k to SOURCES in order of first prose mention.
        var displayForSource: [String: Int] = [:]
        var displayForRaw: [Int: Int] = [:]
        for m in tokens {
            for raw in indices(inToken: ns.substring(with: m.range)) {
                guard let c = byIndex[raw] else { continue }
                let key = sourceKey(c)
                let d: Int
                if let existing = displayForSource[key] { d = existing }
                else { d = displayForSource.count + 1; displayForSource[key] = d }
                displayForRaw[raw] = d
            }
        }
        // BU1 — a REQUIRED source with no prose mention still gets a display number, appended after
        // the mentioned ones (first-mention order is preserved for everything the model did cite).
        for raw in alwaysInclude.sorted() {
            guard let c = byIndex[raw] else { continue }
            let key = sourceKey(c)
            if displayForSource[key] == nil { displayForSource[key] = displayForSource.count + 1 }
            if displayForRaw[raw] == nil { displayForRaw[raw] = displayForSource[key] }
        }
        guard !displayForRaw.isEmpty else { return (text, citations) }

        // Rewrite each token → the source display numbers, de-duped within the bracket.
        var out = ns
        for m in tokens.reversed() {
            var seen = Set<Int>(); var disp: [Int] = []
            for raw in indices(inToken: ns.substring(with: m.range)) {
                guard let d = displayForRaw[raw] else { continue }
                if seen.insert(d).inserted { disp.append(d) }
            }
            let rep = disp.isEmpty ? "" : "[" + disp.map(String.init).joined(separator: ", ") + "]"
            out = out.replacingCharacters(in: m.range, with: rep) as NSString
        }
        // Drop an immediately-repeated identical marker (`[1][1]` / `[1] [1]` → `[1]`).
        let rewritten = out as String
        let collapsed = repeatedMarkerRegex.stringByReplacingMatches(
            in: rewritten, range: NSRange(location: 0, length: (rewritten as NSString).length), withTemplate: "$1")

        // ONE citation per source, in display order (1…k).
        let renumbered: [ChatSession.Message.Citation] = displayForSource
            .sorted { $0.value < $1.value }
            .compactMap { (key, display) in
                guard let c = citations.first(where: { sourceKey($0) == key }) else { return nil }
                if let node = c.nodeID { return .init(index: display, nodeID: node, title: c.title, snippet: c.snippet) }
                if let u = c.url { return .init(index: display, url: u, title: c.title, snippet: c.snippet) }
                return nil
            }
        return (collapsed, renumbered)
    }

    /// A run of the SAME citation token repeated with only whitespace between
    /// (`[1][1]` / `[1] [1]`) — collapsed to one by `renumberBySource`.
    private static let repeatedMarkerRegex = try! NSRegularExpression(
        pattern: #"(\[\s*\d{1,2}(?:\s*,\s*\d{1,2})*\s*\])(?:\s*\1)+"#)

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
