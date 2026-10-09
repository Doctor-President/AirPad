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
            // `[1, 2, 7]`), each linked to its own citation. AE3 — a separator keeps
            // consecutive markers from fusing: between indices of one bracket, AND before
            // a token that abuts a prior citation numeral (`[25][26]`). CH (T device
            // 2026-10-09): the thin space was too narrow at superscript size — "¹²³" read
            // as 123 — so the separator is a superscript COMMA ("¹,²,³"). Only a prior
            // CITATION numeral triggers it (a year like "1990[3]" stays "1990³"). The
            // replacement carries no `[`, so the next `firstMatch` advances.
            func separator() -> AttributedString {
                var sep = AttributedString(",")
                sep.font = ChatTypography.inlineCitationSuperscript(face)
                sep.baselineOffset = ChatTypography.inlineCitationBaselineOffset
                sep.foregroundColor = ChatTypography.bodyText
                return sep
            }
            var replacement = AttributedString("")
            if range.lowerBound > attr.startIndex {
                let prev = attr.characters.index(before: range.lowerBound)
                if attr.characters[prev].isNumber, attr[prev..<range.lowerBound].runs.first?.baselineOffset != nil {
                    replacement.append(separator())   // AE3 — abuts the previous marker
                }
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

    /// AC1 + Brief BU4 — ONE citation token: a bracket holding one or more comma-separated 1-2 digit
    /// indices, each with an OPTIONAL `E` prefix. Matches `[7]`, `[1, 2, 7]`, `[1,2]` AND the BU4
    /// entry-label form `[E7]`, `[E1, E2]` (the packet now labels items `[E<n>]`); adjacency
    /// (`[n][m]`) and `[n], [m]` are two tokens. Shared by the renderer, `citedIndices`,
    /// `stripInvalidMarkers`, and `renumberBySource` so parser/renderer/stripper can't disagree.
    /// `indexRegex` extracts only the DIGITS, so `[E7]` → index 7; `renumberBySource` rewrites every
    /// surviving token to a plain `[n]`, so the committed prose (and its superscripts/tap targets)
    /// stay numeric — the `E` lives only in the model-facing packet + the model's raw reply.
    static let citationTokenRegex = try! NSRegularExpression(pattern: #"\[\s*[Ee]?\s*\d{1,2}(?:\s*,\s*[Ee]?\s*\d{1,2})*\s*\]"#)
    private static let indexRegex = try! NSRegularExpression(pattern: #"\d{1,2}"#)

    /// All indices inside a citation token, in order (`"[1, 2, 7]"` → `[1, 2, 7]`).
    static func indices(inToken token: String) -> [Int] {
        let ns = token as NSString
        return indexRegex.matches(in: token, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range)) }
    }
}

/// Brief CH ruling 8 (T 2026-10-07; design: Ops `findings/citation-numbering-design.md`) — ONE numberer per
/// assistant message, fed WHILE the answer streams, so the reader never sees ⁵ ⁸ ⁹ turn into ¹ ² ³ at the end.
///
/// - Numbers are assigned per SOURCE, 1…k in order of first appearance, and never change: the stream is
///   append-only, so first appearance is final. The text shown at any moment is a PREFIX of the committed text.
/// - An invalid marker (no candidate behind its packet index) is dropped at first sight, never shown then removed.
/// - Same-source merging (`[3, 12]` on one entry → `[1]`) and `[1][1]` collapsing happen at first sight too.
/// - Prose references by packet number ("entries 5, 8, 9", "(entry 6)") are rewritten through the same map into
///   bracket form with the noun kept ("entries [1], [2], [3]") — only when EVERY number is a valid packet index.
/// - A trailing fragment that could still become a token is HELD BACK until it resolves: an open `[` that is a
///   prefix of a citation token, a prose-reference noun with its number list so far, a partial noun ("entr"), and
///   trailing whitespace (so an invalid marker can absorb the space before it). The hold is bounded (40 chars).
/// - `renumberBySource` stays the scheme's commit-time core for the paths that don't stream (the debug hook).
struct CitationNumberer {
    typealias Citation = ChatSession.Message.Citation

    private let byIndex: [Int: Citation]
    private var raw: NSString = ""
    private var settled = 0                      // UTF-16 offset into `raw`: everything before it is displayed
    /// What the reader sees: the settled prefix, rewritten. Append-only.
    private(set) var displayText = ""
    private var displayForSource: [String: Int] = [:]
    private var sourceOrder: [String] = []
    /// The last emitted marker, while only whitespace has followed it (for `[1] [1]` → `[1]`).
    private var lastMarker: String?

    init(candidates: [Citation]?) {
        var m: [Int: Citation] = [:]
        for c in candidates ?? [] where m[c.index] == nil { m[c.index] = c }
        byIndex = m
    }

    static func sourceKey(_ c: Citation) -> String { c.nodeID ?? c.url ?? "idx:\(c.index)" }

    mutating func feed(_ delta: String) {
        raw = (raw as String + delta) as NSString
        advance(final: false)
    }

    /// Release everything held back (stream end).
    mutating func settleAll() { advance(final: true) }

    /// The committed message: `displayText` (trailing whitespace trimmed) + one citation per source in display
    /// order. `alwaysInclude` (BU1/BS2 always-cite, and the title-rescue fallback) are RAW packet indices appended
    /// as k+1… when their source wasn't mentioned — nothing already shown changes number.
    func result(alwaysInclude: Set<Int> = []) -> (text: String, citations: [Citation]) {
        var order = sourceOrder
        var firstCitation: [String: Citation] = [:]
        for c in byIndex.keys.sorted().compactMap({ byIndex[$0] }) where firstCitation[Self.sourceKey(c)] == nil {
            firstCitation[Self.sourceKey(c)] = c
        }
        for raw in alwaysInclude.sorted() {
            guard let c = byIndex[raw] else { continue }
            let key = Self.sourceKey(c)
            if !order.contains(key) { order.append(key) }
        }
        let cites: [Citation] = order.enumerated().compactMap { i, key in
            guard let c = firstCitation[key] else { return nil }
            if let node = c.nodeID { return Citation(index: i + 1, nodeID: node, title: c.title, snippet: c.snippet) }
            if let u = c.url { return Citation(index: i + 1, url: u, title: c.title, snippet: c.snippet) }
            return nil
        }
        let text = displayText.replacingOccurrences(of: #"\s+\z"#, with: "", options: .regularExpression)
        return (text, cites)
    }

    // MARK: - Settling

    private mutating func advance(final: Bool) {
        let pending = raw.substring(from: settled) as NSString
        var cut = pending.length
        if !final, let h = Self.holdStart(pending) { cut = h }
        guard cut > 0 else { return }
        let chunk = pending.substring(to: cut)
        settled += cut
        var out = rewrite(chunk)
        if displayText.isEmpty { out = out.replacingOccurrences(of: #"\A\s+"#, with: "", options: .regularExpression) }
        displayText += out
    }

    /// Where the held-back tail of `pending` starts (UTF-16), or nil when everything can settle. A held fragment
    /// also takes the whitespace before it, so a later-dropped marker can absorb its space.
    static func holdStart(_ pending: NSString) -> Int? {
        let full = NSRange(location: 0, length: pending.length)
        var start: Int?
        for re in [bracketPrefixRegex, proseFragmentRegex, partialNounRegex, trailingSpaceRegex] {
            if let m = re.firstMatch(in: pending as String, range: full), m.range.length <= 40 {
                start = min(start ?? m.range.location, m.range.location)
            }
        }
        guard var s = start else { return nil }
        while s > 0, let u = UnicodeScalar(pending.character(at: s - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { s -= 1 }
        return s
    }

    private mutating func display(forRaw raw: Int) -> Int? {
        guard let c = byIndex[raw] else { return nil }
        let key = Self.sourceKey(c)
        if let d = displayForSource[key] { return d }
        sourceOrder.append(key)
        displayForSource[key] = sourceOrder.count
        return sourceOrder.count
    }

    /// Rewrites one settled chunk, left to right (first appearance assigns the number).
    private mutating func rewrite(_ chunk: String) -> String {
        let ns = chunk as NSString
        let full = NSRange(location: 0, length: ns.length)
        enum Kind { case bracket, prose }
        var hits: [(NSRange, Kind)] = CitationReference.citationTokenRegex.matches(in: chunk, range: full).map { ($0.range, .bracket) }
        hits += Self.proseRefRegex.matches(in: chunk, range: full).map { ($0.range, .prose) }
        hits.sort { $0.0.location < $1.0.location }

        var out = ""
        var pos = 0
        for (r, kind) in hits where r.location >= pos {
            let gap = ns.substring(with: NSRange(location: pos, length: r.location - pos))
            pos = r.location + r.length
            let token = ns.substring(with: r)
            switch kind {
            case .bracket:
                var seen = Set<Int>(), disp: [Int] = []
                for raw in CitationReference.indices(inToken: token) {
                    if let d = display(forRaw: raw), seen.insert(d).inserted { disp.append(d) }
                }
                if disp.isEmpty {
                    // Invalid marker → dropped at first sight, absorbing one space before it.
                    out += gap.hasSuffix(" ") ? String(gap.dropLast()) : gap
                    if gap.contains(where: { !$0.isWhitespace }) { lastMarker = nil }
                    continue
                }
                let marker = "[" + disp.map(String.init).joined(separator: ", ") + "]"
                if marker == lastMarker, gap.allSatisfy(\.isWhitespace) { continue }   // `[1] [1]` → `[1]`
                out += gap + marker
                lastMarker = marker
            case .prose:
                let nums = Self.numberRegex.matches(in: token, range: NSRange(location: 0, length: (token as NSString).length))
                let raws = nums.compactMap { Int((token as NSString).substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
                guard !raws.isEmpty, raws.allSatisfy({ byIndex[$0] != nil }) else {
                    out += gap + token
                    lastMarker = nil
                    continue
                }
                // Assign in READING order (first appearance), then substitute right-to-left (stable ranges).
                let disp = raws.map { display(forRaw: $0)! }
                var rewritten = token as NSString
                for (m, d) in zip(nums, disp).reversed() {
                    rewritten = rewritten.replacingCharacters(in: m.range, with: "[\(d)]") as NSString
                }
                out += gap + (rewritten as String)
                lastMarker = nil
            }
        }
        let tail = ns.substring(from: pos)
        if tail.contains(where: { !$0.isWhitespace }) { lastMarker = nil }
        return out + tail
    }

    // MARK: - Grammar

    /// A prose reference by packet number: "entries 5, 8 and 9", "(entry 6)". Session 3 audit fix (T 2026-10-09):
    /// ENTRY/ENTRIES only — "your notes 3 times mention Mara" / "item 2 on your packing list" became chips to
    /// unrelated packet entries [3]/[2].
    static let proseRefRegex = try! NSRegularExpression(
        pattern: #"\b(?:entry|entries)\s+#?\d{1,2}(?:\s*(?:,|and|&)\s*#?\d{1,2})*\b"#, options: [.caseInsensitive])
    private static let numberRegex = try! NSRegularExpression(pattern: #"#?\d{1,2}"#)   // "#2" → "[n]"
    /// A PREFIX of a citation token at the end of the stream: `[`, `[E`, `[5, `, `[5, 1`.
    private static let bracketPrefixRegex = try! NSRegularExpression(
        pattern: #"\[\s*[Ee]?\s*(?:\d{1,2}\s*,\s*[Ee]?\s*)*\d{0,2}\s*\z"#)
    /// A prose-reference noun with its number list so far: "entries", "entries 5,", "entries 5, 8 an".
    private static let proseFragmentRegex = try! NSRegularExpression(
        pattern: #"\b(?:entry|entries)(?:\s+#?\d{1,2}(?:\s*(?:,|&|and)\s*#?\d{1,2})*)?(?:\s*(?:,|&|and|an|a)?\s*#?)?\z"#,
        options: [.caseInsensitive])
    /// The start of a noun that could become a prose reference: "e", "en", … "entrie".
    private static let partialNounRegex = try! NSRegularExpression(
        pattern: #"\b(?:e|en|ent|entr|entri|entrie)\z"#, options: [.caseInsensitive])
    private static let trailingSpaceRegex = try! NSRegularExpression(pattern: #"\s+\z"#)
}

#if DEBUG
/// Brief CH ruling 8 — pure self-test for `CitationNumberer` (`-CitationNumberSelfTest`, Simulator; PASS/FAIL per
/// case). The load-bearing check is the PREFIX INVARIANT: at every chunk boundary of every chunking (whole,
/// word-by-word, char-by-char) the displayed text is a prefix of the committed text, so no number ever changes.
enum CitationNumberSelfTest {
    typealias C = ChatSession.Message.Citation

    static func run() -> String {
        var fails: [String] = [], ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            ran += 1
            if !ok { fails.append("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        // Packet: 3 and 12 are two passages of one entry; 4 and 7 have no candidate.
        let packet: [C] = [(2, "E"), (3, "N3"), (5, "A"), (6, "D"), (8, "B"), (9, "C"), (12, "N3")].map {
            C(index: $0.0, nodeID: $0.1, title: "T\($0.1)", snippet: "")
        }
        /// Feeds `chunks`, checking the prefix invariant + that `forbidden` never shows; returns the committed result.
        func stream(_ name: String, _ chunks: [String], candidates: [C]? = packet, alwaysInclude: Set<Int> = [],
                    forbidden: [String] = []) -> (text: String, citations: [C]) {
            var n = CitationNumberer(candidates: candidates)
            var shown: [String] = []
            for c in chunks { n.feed(c); shown.append(n.displayText) }
            n.settleAll()
            let r = n.result(alwaysInclude: alwaysInclude)
            let bad = shown.first { !r.text.hasPrefix($0.replacingOccurrences(of: #"\s+\z"#, with: "", options: .regularExpression)) }
            check("\(name) prefix-invariant", bad == nil, "shown \(bad ?? "") ⊄ final \(r.text)")
            for f in forbidden { check("\(name) never shows \(f)", !shown.contains { $0.contains(f) } && !r.text.contains(f)) }
            return r
        }
        func chunkings(_ s: String) -> [[String]] {
            [[s], s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element },
             s.map { String($0) }]
        }

        // 1. markers split across chunks
        let r1 = stream("split", ["Plastic Beach ", "[", "5", ", 8]", " and Roger Rabbit [", "9]."])
        check("split text", r1.text == "Plastic Beach [1, 2] and Roger Rabbit [3].", r1.text)
        check("split chips", r1.citations.map(\.nodeID) == ["A", "B", "C"] && r1.citations.map(\.index) == [1, 2, 3])

        // CONTROL — the old pipeline (show raw packet numbers, renumber at commit) must FAIL the same invariant,
        // or the check has no teeth: it showed "[5, 8]" and committed "[1, 2]".
        let oldShown = "Plastic Beach [5, 8]"
        let oldFinal = CitationReference.renumberBySource(text: "Plastic Beach [5, 8] and Roger Rabbit [9].",
                                                          citations: packet.filter { [5, 8, 9].contains($0.index) }).text
        check("control: old pipeline breaks the prefix invariant", !oldFinal.hasPrefix(oldShown), oldFinal)

        // 2. an invalid marker is never displayed, and absorbs its space
        for (i, ch) in chunkings("Jane Austen [1] wrote it [4].").enumerated() {
            let r = stream("orphan#\(i)", ch, candidates: [], forbidden: ["[1", "[4", "¹"])
            check("orphan#\(i) text", r.text == "Jane Austen wrote it.", r.text)
        }

        // 3. same-source merge + repeat collapse
        for (i, ch) in chunkings("A [3, 12] then [12] [3] end [E5].").enumerated() {
            let r = stream("merge#\(i)", ch)
            check("merge#\(i) text", r.text == "A [1] then [1] end [2].", r.text)
        }

        // 4. always-cite appended after the mentioned ones (nothing shown changes)
        let r4 = stream("always", chunkings("Only [8] here.")[1], alwaysInclude: [5, 8])
        check("always chips", r4.citations.map(\.nodeID) == ["B", "A"] && r4.text == "Only [1] here.", "\(r4.citations.map(\.nodeID)) \(r4.text)")

        // 5. prose references rewritten through the same map, at first appearance
        for (i, ch) in chunkings("As entries 5, 8 and 9 show [6], and (entry 6) too; see note #2.").enumerated() {
            let r = stream("prose#\(i)", ch, forbidden: ["entries 5", "entry 6)"])
            check("prose#\(i) text", r.text == "As entries [1], [2] and [3] show [4], and (entry [4]) too; see note #2.", r.text)
        }
        // 6. a number with no candidate is not a citation
        for (i, ch) in chunkings("Step item 2 of 3 and entries 5 and 7.").enumerated() {
            let r = stream("noref#\(i)", ch)
            check("noref#\(i) text", r.text == "Step item 2 of 3 and entries 5 and 7.", r.text)
        }
        // Session 3 audit fix — "notes N" / "item N" are prose, never a citation
        for (i, ch) in chunkings("Your notes 5 times mention Mara; item 8 on the list is the passport.").enumerated() {
            let r = stream("notes-n#\(i)", ch)
            check("notes-n#\(i) text", r.text == "Your notes 5 times mention Mara; item 8 on the list is the passport.", r.text)
        }
        let rNone = stream("noref-empty", ["Step item 2 of 3."], candidates: [C(index: 5, nodeID: "A", title: "", snippet: "")])
        check("item 2 of 3 left alone", rNone.text == "Step item 2 of 3.", rNone.text)

        // 7. determinism across chunkings + equivalence with the commit-time pipeline on bracket-only text
        for s in ["Plastic Beach [5, 8] and [9][9]. Also [4] and [12] [3].", "[2] opens; [E6], [5]!", "No markers at all."] {
            let outs = chunkings(s).enumerated().map { stream("det", $0.element).text }
            check("deterministic \(s)", Set(outs).count == 1, "\(outs)")
            let old = CitationReference.renumberBySource(
                text: CitationReference.stripInvalidMarkers(in: s, valid: Set(packet.map(\.index))),
                citations: packet.filter { CitationReference.citedIndices(in: s).contains($0.index) })
            check("matches renumberBySource \(s)", outs[0] == old.text, "\(outs[0]) vs \(old.text)")
        }

        // 8. a literal `[` (markdown link) is released, never mangled or held forever
        let link = "See [Lakeview](https://example.com/x) for more [5]."
        let r8 = stream("markdown", link.map { String($0) })
        check("markdown text", r8.text == "See [Lakeview](https://example.com/x) for more [1].", r8.text)

        // 9. hold-back is bounded: nothing but a short tail is ever withheld
        var n9 = CitationNumberer(candidates: packet)
        n9.feed("The entries")
        check("holds a prose noun", n9.displayText == "The", n9.displayText)
        n9.feed(" were long.")
        check("releases when it can't be a reference", n9.displayText == "The entries were long.", n9.displayText)

        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(ran - fails.count)/\(ran)\n  " + fails.joined(separator: "\n  ")
    }
}
#endif
