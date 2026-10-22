import SwiftUI

/// One block of laid-out assistant markdown.
///
/// `AttributedString(markdown:)` carries `presentationIntent` for headings
/// and lists, but SwiftUI's `Text` IGNORES that metadata for LAYOUT — no
/// heading sizing, no hanging indents. So we hand-roll ONLY the block split.
/// Inline styling (bold / italic / code spans) INSIDE each block still goes
/// through AttributedString, which the platform renders for free.
/// A block is a VALUE — two identical `- Yes` bullets ARE the same value, so
/// position is the only identity a block has. Deliberately NOT `Identifiable`:
/// every ForEach over blocks keys on OFFSET, and an `id: hashValue` would
/// collide on duplicates and silently drop a view.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: Int, text: String)
    case codeBlock(String)
    /// A GitHub-style pipe table, rendered as a grid (`ChatTableView`, live-26 (3f); it was reflowed into key:value
    /// groups until then). Cells are already split + trimmed; a ragged row is padded / joined to the header's count by
    /// `ChatTable`.
    case table(headers: [String], rows: [[String]])
}

/// Line-oriented block splitter. The classification ORDER is load-bearing
/// (see COMMIT 2 brief): two shipping providers emit three bullet dialects
/// (`* `, `- `, `*   `) and BOLD-LINE headers rather than ATX. Both are
/// handled; ATX is supported too for a future provider.
enum MarkdownBlockParser {

    /// `settled: false` — the streaming tail's partial text (live-35 (2): math waits for its closing delimiter).
    static func parse(_ raw: String, settled: Bool = true) -> [MarkdownBlock] {
        let blocks = parseBlocks(raw, settled: settled)
        guard MathText.enabled else { return blocks }
        // live-35 (2) — inline math in every block's text (the last block's end is the stream's end while streaming).
        return blocks.enumerated().map { k, b in
            let end = !settled && k == blocks.count - 1
            let m = { (t: String) in MathText.inline(t, atStreamEnd: end) }
            switch b {
            case let .heading(level, text): return .heading(level: level, text: m(text))
            case let .paragraph(text): return .paragraph(m(text))
            case let .bullet(text): return .bullet(m(text))
            case let .numbered(index, text): return .numbered(index: index, text: m(text))
            case .codeBlock: return b
            case let .table(headers, rows): return .table(headers: headers.map(m), rows: rows.map { $0.map(m) })
            }
        }
    }

    private static func parseBlocks(_ raw: String, settled: Bool) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        // Open-paragraph accumulator: consecutive non-blank prose lines join
        // with a single space, flushed on any block boundary.
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        // Open fenced-code accumulator.
        var inFence = false
        var fence: [String] = []
        func flushFence() {
            // Unclosed fence at EOF still emits — never drop content.
            blocks.append(.codeBlock(fence.joined(separator: "\n")))
            fence.removeAll(keepingCapacity: true)
            inFence = false
        }

        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Indexed (not for-in) so the table branch can look ahead for the
        // `|---|` separator and consume the row run.
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func stripped(_ raw: String) -> String {
            let t = trimTrailing(Substring(raw))
            return String(t.drop(while: { $0.isWhitespace }))
        }
        // Index of the next NON-BLANK line after `idx`, or nil at EOF.
        func nextNonBlank(after idx: Int) -> Int? {
            var k = idx + 1
            while k < lines.count {
                if !stripped(lines[k]).isEmpty { return k }
                k += 1
            }
            return nil
        }

        var i = 0
        while i < lines.count {
            let line = trimTrailing(Substring(lines[i]))           // trailing WS only
            let s = String(line.drop(while: { $0.isWhitespace }))  // + leading, for rules

            // 1 — FENCE. While open, nothing else applies; lines accumulate
            //     verbatim (leading whitespace preserved). Info string on the
            //     opener (```swift) is consumed, not content.
            if s.hasPrefix("```") {
                if inFence { flushFence() }                        // closing fence
                else { flushParagraph(); inFence = true }          // opener
                i += 1; continue
            }
            if inFence { fence.append(line); i += 1; continue }

            // 2 — TABLE (leading pipe). Checked before the other classifiers so
            //     a `| … |` row never reads as prose. Three outcomes:
            //     (a) header + a `|---|` separator on the next non-blank line →
            //         a reflowed `.table` (rows accumulated until a blank or a
            //         non-pipe line);
            //     (b) a leading-pipe line with NO non-blank line after it → a
            //         half-arrived table mid-STREAM: HOLD it (emit nothing) so
            //         raw pipes never flash; the next parse pass resolves it;
            //     (c) otherwise (next non-blank isn't a separator) → confirmed
            //         not-a-table → normal prose.
            if s.hasPrefix("|") {
                if isTableRowCandidate(s),
                   let sepIdx = nextNonBlank(after: i),
                   isSeparatorLine(stripped(lines[sepIdx])) {
                    let headers = splitCells(s)
                    var rows: [[String]] = []
                    var j = sepIdx + 1
                    while j < lines.count {
                        let rs = stripped(lines[j])
                        if rs.isEmpty { break }                    // blank ends the table
                        // live-26 (3f): a row a model left without its closing pipe still belongs — unless it's the
                        // LAST line (then it may be a row still streaming, held as before).
                        let unclosed = rs.hasPrefix("|") && rs.filter({ $0 == "|" }).count >= 2 && j + 1 < lines.count
                        guard isTableRowCandidate(rs) || unclosed else { break } // non-pipe ends it
                        rows.append(splitCells(rs))
                        j += 1
                    }
                    // Only emit once there's ≥1 data row: header+separator with
                    // no rows yet is a mid-stream table — consume + hold (no
                    // phantom empty block), the next row-bearing pass emits it.
                    if !rows.isEmpty {
                        flushParagraph()
                        blocks.append(.table(headers: headers, rows: rows))
                    }
                    i = j
                    continue
                }
                if nextNonBlank(after: i) == nil {
                    // (b) dangling at EOF → mid-stream, hold. Leave any open
                    //     paragraph intact; just don't emit this line yet.
                    i += 1; continue
                }
                // (c) confirmed not-a-table → prose (raw pipes are correct here).
                paragraph.append(s); i += 1; continue
            }

            // 2b — live-35 (2): DISPLAY MATH on its own lines, `$$ … $$` / `\[ … \]` → its own paragraph of plain text,
            //      or a monospaced block when plain text can't say it. Unclosed while streaming → held (no raw `$$`
            //      flash); unclosed in settled text → prose, as written.
            if MathText.enabled, s.hasPrefix("$$") || s.hasPrefix("\\[") {
                let closer = s.hasPrefix("$$") ? "$$" : "\\]"
                var body = String(s.dropFirst(2)), j = i, closed = false
                while true {
                    if let r = body.range(of: closer) {
                        closed = body[r.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                        body = String(body[..<r.lowerBound]); break
                    }
                    j += 1
                    guard j < lines.count else { break }
                    body += "\n" + lines[j]
                }
                if closed, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    flushParagraph()
                    if let plain = MathText.display(body) { blocks.append(.paragraph(plain)) }
                    else { blocks.append(.codeBlock(body.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    i = j + 1; continue
                }
                if !closed, !settled { flushParagraph(); i = lines.count; continue }
            }

            // 3 — ATX HEADING
            if let h = atxHeading(s) { flushParagraph(); blocks.append(h); i += 1; continue }

            // 4 — BULLET (before bold-heading: a bullet whose content is
            //     entirely bold, `*   **Napa**`, must stay a bullet)
            if let b = bullet(s) { flushParagraph(); blocks.append(b); i += 1; continue }

            // 5 — NUMBERED
            if let n = numbered(s) { flushParagraph(); blocks.append(n); i += 1; continue }

            // 6 — BOLD-LINE HEADING (only raw lines that reached here)
            if let bh = boldHeading(s) { flushParagraph(); blocks.append(bh); i += 1; continue }

            // 7 — BLANK: boundary only, never an empty paragraph (FM puts a
            //     blank line between a header and its first bullet).
            if s.isEmpty { flushParagraph(); i += 1; continue }

            // 8 — PARAGRAPH
            paragraph.append(s)
            i += 1
        }

        // EOF — flush whatever is open.
        if inFence { flushFence() } else { flushParagraph() }
        return blocks
    }

    // MARK: - Line classifiers ( `s` is already leading-stripped )

    private static func trimTrailing(_ s: Substring) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    /// `^\s*(#{1,3})\s+(.*)$`
    private static func atxHeading(_ s: String) -> MarkdownBlock? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 3 else { return nil }
        let after = s.dropFirst(hashes)
        guard let f = after.first, f.isWhitespace else { return nil }
        return .heading(level: hashes, text: String(after.drop(while: { $0.isWhitespace })))
    }

    /// `^\s*[-*]\s+(.*)$` — the `\s+` is load-bearing: it stops `**Bold**`
    /// being read as a bullet (2nd char is `*`, not whitespace), and strips
    /// Qwen's three-space run fully so no leading spaces leak into content.
    private static func bullet(_ s: String) -> MarkdownBlock? {
        guard let first = s.first, first == "-" || first == "*" else { return nil }
        let after = s.dropFirst()
        guard let f = after.first, f.isWhitespace else { return nil }
        return .bullet(String(after.drop(while: { $0.isWhitespace })))
    }

    /// `^\s*(\d+)\.\s+(.*)$`
    private static func numbered(_ s: String) -> MarkdownBlock? {
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let afterDigits = s.dropFirst(digits.count)
        guard afterDigits.first == "." else { return nil }
        let afterDot = afterDigits.dropFirst()
        guard let f = afterDot.first, f.isWhitespace else { return nil }
        return .numbered(index: Int(digits) ?? 0,
                         text: String(afterDot.drop(while: { $0.isWhitespace })))
    }

    /// `^\*\*(.+)\*\*$` where the capture is a SINGLE span (no inner `**`).
    /// Strips the `**` so the inline parse won't double-bold the heading.
    /// A trailing colon inside the span is expected and fine.
    private static func boldHeading(_ s: String) -> MarkdownBlock? {
        guard s.hasPrefix("**"), s.hasSuffix("**"), s.count >= 5 else { return nil }
        let inner = s.dropFirst(2).dropLast(2)
        guard !inner.isEmpty, !inner.contains("**") else { return nil }
        return .heading(level: 2, text: String(inner))
    }

    // MARK: - Table classifiers

    /// A BORDERED pipe row: starts AND ends with `|` and holds ≥1 cell. Bordered
    /// is the shape the shipping models emit (T's screenshot), and it keeps a
    /// lone pipe *inside* prose (`A | B`, no leading pipe) from ever triggering.
    /// A row still streaming (no trailing `|` yet) is deliberately NOT a
    /// candidate — it's held rather than reflowed half-formed.
    private static func isTableRowCandidate(_ s: String) -> Bool {
        guard s.hasPrefix("|"), s.hasSuffix("|") else { return false }
        return s.filter { $0 == "|" }.count >= 2
    }

    /// A separator row: bordered, every cell matching `:?-{1,}:?` (dashes with
    /// optional alignment colons). This is the unambiguous "this IS a table"
    /// signal — prose essentially never contains a `|---|` line.
    private static func isSeparatorLine(_ s: String) -> Bool {
        guard s.hasPrefix("|"), s.hasSuffix("|") else { return false }
        let cells = splitCells(s)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            var body = Substring(cell)
            if body.first == ":" { body = body.dropFirst() }
            if body.last == ":" { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    /// Split a bordered pipe row into trimmed cells (edge pipes dropped). Empty
    /// cells are PRESERVED so the cell count matches the header for raggedness
    /// checks; the renderer skips empties.
    private static func splitCells(_ s: String) -> [String] {
        // live-26 (3f): an escaped `\|` is a pipe inside a cell, not a border.
        let held = "\u{E0F0}"
        var t = Substring(s.replacingOccurrences(of: "\\|", with: held))
        if t.first == "|" { t = t.dropFirst() }
        if t.last == "|" { t = t.dropLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: held, with: "|") }
    }
}

// MARK: - Contextual spacing

/// Space ABOVE each block. `VStack(spacing:)` applies one value to every gap
/// and can't see neighbouring KINDS, so containers use `spacing: 0` and pad
/// each block's top with this. ONE implementation, called from BOTH the
/// settled bubble (`MarkdownBlockText`) and the stream tail (`StreamingTail`)
/// — if the two diverge, spacing shifts at the instant the stream commits,
/// the exact reflow class COMMIT 3 removed. Do not copy-paste it.
enum BlockSpacing {
    /// Zero for the first block — a `.padding(.top,)` does NOT collapse like
    /// a CSS margin, so a non-zero first pad would add a phantom leading gap.
    static func topPad(index: Int, blocks: [MarkdownBlock],
                       listSpacing: CGFloat, blockSpacing: CGFloat,
                       headingSpaceBefore: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        let prev = blocks[index - 1]
        let curr = blocks[index]

        // Adjacent list items of the SAME kind hug.
        if isListItem(prev), isListItem(curr), sameListKind(prev, curr) {
            return listSpacing
        }
        // Headings get extra air above them (on top of blockSpacing).
        if case .heading = curr {
            return blockSpacing + headingSpaceBefore
        }
        return blockSpacing
    }

    private static func isListItem(_ b: MarkdownBlock) -> Bool {
        if case .bullet = b { return true }
        if case .numbered = b { return true }
        return false
    }

    /// bullet↔bullet and numbered↔numbered hug. bullet↔numbered does NOT —
    /// switching marker style is a semantic break.
    private static func sameListKind(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
        switch (a, b) {
        case (.bullet, .bullet):     return true
        case (.numbered, .numbered): return true
        default:                     return false
        }
    }
}

// MARK: - Rendering

/// Renders ONE block. Inline markdown inside the block goes through
/// AttributedString(`.inlineOnlyPreservingWhitespace`) — exactly as the old
/// `AssistantMarkdownText` did — so bold lead-ins inside bullets keep working
/// for free. Parse is cached, keyed by the block's text.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// live-26 (3f) — tables render as a grid (`ChatTableView`); stacked records are only VoiceOver's reading order.
    static let tablePresentation: ChatTablePresentation = .grid

    /// Brief BF — the app-wide content face; the Librarian answer/headings follow it.
    @Environment(\.appBodyFont) private var appFont
    private var bodyFont: Font { ChatTypography.body(appFont) }

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text, face: appFont))
                .font(headingFont(level))
                .foregroundStyle(ChatTypography.headingText)
                .textSelection(.enabled)

        case let .paragraph(text):
            Text(Self.inline(text, face: appFont))
                .font(bodyFont)
                .foregroundStyle(ChatTypography.bodyText)
                .lineSpacing(ChatTypography.bodyLine)
                .textSelection(.enabled)

        case let .bullet(text):
            listRow(marker: "•", text: text)

        case let .numbered(index, text):
            listRow(marker: "\(index).", text: text)

        case let .codeBlock(code):
            Text(code)
                .font(ChatTypography.code)                 // MONOSPACED SYSTEM
                .foregroundStyle(ChatTypography.bodyText)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hexString: "1C1C1E"))
                )

        case let .table(headers, rows):
            // live-26 (3f) — a real grid (header row, hairlines, tabular numerals, sideways scroll with the header and
            // first column staying put, tap → full screen). The 2026-07-29 reflow is gone from the visual; VoiceOver
            // still reads each row as a record ("column: value").
            ChatTableView(table: ChatTable(headers: headers, rows: rows))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return ChatTypography.h1(appFont)
        case 2:  return ChatTypography.h2(appFont)
        default: return ChatTypography.h3(appFont)
        }
    }

    /// Bullet + numbered share a hanging-indent row. The marker sits in a
    /// fixed-width column so wrapped lines align under the TEXT (not the
    /// glyph) and numbered markers of differing widths still line up. The
    /// marker uses the SERIF body font so it sits at the text's baseline
    /// and stroke weight — a system glyph beside serif text reads wrong.
    /// KEEP the fixed-width frame — it is the only thing aligning `1.` vs
    /// `10.`; only the width is tuned.
    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChatTypography.bulletGap) {
            Text(marker)
                .font(bodyFont)
                .foregroundStyle(ChatTypography.secondaryText)
                .frame(width: ChatTypography.bulletIndent, alignment: .leading)
            Text(Self.inline(text, face: appFont))
                .font(bodyFont)
                .foregroundStyle(ChatTypography.bodyText)
                .lineSpacing(ChatTypography.bodyLine)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    // Inline parse cache — mirrors the old AssistantMarkdownText.cache.
    private static var cache: [String: AttributedString] = [:]
    private static func inline(_ raw: String, face: EntryBodyFont) -> AttributedString {
        // Brief BG — the `[n]` citation superscript follows the app Font, so the parse
        // cache is keyed by face too (a Font switch populates fresh entries, never stale).
        let cacheKey = "\(face.rawValue)\u{1}\(raw)"
        if let cached = cache[cacheKey] { return cached }
        var result: AttributedString
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = attr
        } else {
            result = AttributedString(raw)
        }
        // ★ Trust boundary — DE-LINK model-authored web URLs. A small local model
        // can't reproduce a long URL (playlist ids, query strings) so it fabricates
        // them; those inline links are dead and must NOT look tappable. Strip the
        // `.link` attribute from every http/https run so the model's URLs render as
        // plain text. The REAL links live in the structured tool-result surface (the
        // "Searched the web" activity list / citation chips), which is generated by
        // AirPad from scraped results, not typed by the model. Internal
        // `airpad-citation://` links (the [n] superscripts, app-generated) are a
        // DIFFERENT scheme and are preserved.
        deLinkModelAuthoredURLs(in: &result)
        // Piece 1.5 — render the model's [n] citation tokens as serif superscript
        // numerals (a no-op when there are none, so non-citation text is untouched).
        CitationReference.styleInlineMarkers(in: &result, face: face)
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = result
        return result
    }

    /// Remove `.link` from http/https runs (model-typed → unreliable), leaving the
    /// text visible but not tappable. Non-http schemes (e.g. `airpad-citation://`)
    /// are left intact. Ranges are collected first, then cleared, so we never mutate
    /// the AttributedString while iterating its runs.
    private static func deLinkModelAuthoredURLs(in attr: inout AttributedString) {
        var ranges: [Range<AttributedString.Index>] = []
        for run in attr.runs {
            if let url = run.link,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                ranges.append(run.range)
            }
        }
        for r in ranges { attr[r].link = nil }
    }
}

/// Settled assistant bubble body — block-laid-out markdown. Parses once,
/// cached by raw string (committed text is immutable, so a given raw string
/// always parses to the same blocks), then renders the block stack.
struct MarkdownBlockText: View {
    let raw: String

    var body: some View {
        // Settled bubble: raw is immutable committed text, so parsing here
        // (cached) is cheap and body rarely re-evals. Bind once — topPad and
        // the ForEach both need the array.
        let blocks = Self.parse(raw)
        #if DEBUG
        let _ = FreezeProbe.hit("mdtext.body.\(raw.count)")
        #endif
        // Contextual spacing: VStack(spacing:) can't vary per-gap, so the
        // container is spacing 0 and each block carries its own top pad via
        // the shared BlockSpacing resolver — identical logic in the stream
        // tail (StreamingTail) so spacing doesn't shift at commit.
        VStack(alignment: .leading, spacing: 0) {
            // Key on OFFSET: a block is a value with no identity beyond
            // position, so duplicate bullets must not collide. Index is
            // stable for immutable committed text.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block)
                    .padding(.top, BlockSpacing.topPad(
                        index: index, blocks: blocks,
                        listSpacing: ChatTypography.listSpacing,
                        blockSpacing: ChatTypography.blockSpacing,
                        headingSpaceBefore: ChatTypography.headingSpaceBefore))
            }
        }
    }

    private static var cache: [String: [MarkdownBlock]] = [:]
    private static func parse(_ raw: String) -> [MarkdownBlock] {
        if let cached = cache[raw] { return cached }
        let blocks = MarkdownBlockParser.parse(raw)
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[raw] = blocks
        return blocks
    }
}

// MARK: - live-35 (2) — inline math as plain text

/// Models write working in TeX ("$31 - 6 = 25$ days"); the app doesn't typeset math (a 1.1 item), so the delimiters
/// showed as raw dollar signs. Every model, every path: the block parser runs each block's text through `inline`.
/// - Inline math by the pandoc rule: an opening `$` with a non-space right after it, a closing `$` with a non-space
///   right before it and NO digit right after it — so dollar amounts ("$5 and $10", "costs $1,200.") never pair up.
///   Also `\( … \)`, and `$$ … $$` / `\[ … \]` inside a line. Code spans are left alone.
/// - Simple math becomes clean plain text (delimiters gone, `\times` → ×, `\frac{a}{b}` → a/b, `^2` → ², `\sqrt{x}` → √x,
///   `\text{…}` → its text …); anything else becomes a monospaced code span, never raw `$`.
/// - Streaming (`atStreamEnd`): a closing `$` that is the text's last character waits for the next one (a digit would
///   make it a dollar amount), so math appears once, when its closing delimiter is confirmed, and never flips back.
enum MathText {
    static var enabled: Bool { !Live35.red }

    /// One block's text with its math rendered (markdown-escaped plain text or a code span).
    static func inline(_ s: String, atStreamEnd: Bool = false) -> String {
        guard enabled, s.contains("$") || s.contains("\\(") || s.contains("\\[") else { return s }
        let c = Array(s)
        var out = "", i = 0
        func isSpace(_ ch: Character) -> Bool { ch.isWhitespace }
        func escaped(_ k: Int) -> Bool {   // an odd run of backslashes before k
            var n = 0, j = k - 1
            while j >= 0, c[j] == "\\" { n += 1; j -= 1 }
            return n % 2 == 1
        }
        while i < c.count {
            let ch = c[i]
            // A code span stays as written.
            if ch == "`" {
                var run = 0; while i + run < c.count, c[i + run] == "`" { run += 1 }
                let fence = String(repeating: "`", count: run)
                if let close = find(fence, in: c, from: i + run) {
                    out += String(c[i..<(close + run)]); i = close + run; continue
                }
                out += fence; i += run; continue
            }
            // \( … \) and \[ … \]
            if ch == "\\", i + 1 < c.count, c[i + 1] == "(" || c[i + 1] == "[", !escaped(i) {
                let closer = c[i + 1] == "(" ? "\\)" : "\\]"
                if let close = find(closer, in: c, from: i + 2) {
                    let tex = String(c[(i + 2)..<close])
                    if !tex.trimmingCharacters(in: .whitespaces).isEmpty, !isCheckbox(tex) {
                        out += render(tex); i = close + 2; continue
                    }
                }
            }
            if ch == "$", !escaped(i) {
                // $$ … $$ inside a line
                if i + 1 < c.count, c[i + 1] == "$" {
                    if let close = find("$$", in: c, from: i + 2), close > i + 2 {
                        out += render(String(c[(i + 2)..<close])); i = close + 2; continue
                    }
                    out += "$$"; i += 2; continue
                }
                // $ … $ — the pandoc rule
                if i + 1 < c.count, !isSpace(c[i + 1]) {
                    var j = i + 1, found: Int? = nil
                    while j < c.count {
                        if c[j] == "$", !escaped(j), !isSpace(c[j - 1]), j > i + 1 {
                            if j + 1 < c.count {
                                if !c[j + 1].isNumber { found = j; break }
                            } else if !atStreamEnd { found = j; break }
                        }
                        j += 1
                    }
                    if let close = found {
                        out += render(String(c[(i + 1)..<close])); i = close + 1; continue
                    }
                }
            }
            out.append(ch); i += 1
        }
        return out
    }

    /// A display block's TeX, whole: plain text, or nil when it needs the monospaced block.
    static func display(_ tex: String) -> String? { plain(tex).map(escapeMarkdown) }

    /// Simple math → plain text (unescaped); nil when something is left that plain text can't say.
    static func plain(_ tex: String) -> String? {
        var t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        func sub(_ p: String, _ r: String) { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        for cmd in ["text", "textrm", "textit", "textbf", "mathrm", "mathbf", "mathit", "operatorname", "mbox", "boldsymbol"] {
            sub(#"\\\#(cmd)\s*\{([^{}]*)\}"#, "$1")
        }
        sub(#"\\(left|right|big|Big|bigg|Bigg|displaystyle|textstyle)(?![A-Za-z])\s*"#, "")
        sub(#"\\[,;:! ]|~"#, " ")
        sub(#"\\q?quad(?![A-Za-z])"#, " ")
        sub(#"\^\s*\{?\\circ\}?"#, "°")
        for (k, v) in symbols { sub(#"\\\#(k)(?![A-Za-z])"#, v) }
        // Escaped characters are literal (parked, so the brace / subscript passes below leave them alone).
        for (k, v) in [("%", "%"), ("$", "$"), ("&", "&"), ("#", "#"), ("{", "\u{E001}"), ("}", "\u{E002}"), ("_", "\u{E003}")] {
            t = t.replacingOccurrences(of: "\\" + k, with: v)
        }
        // Innermost structures first, until nothing changes.
        for _ in 0..<8 {
            let before = t
            t = replaceEach(t, #"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#) { "\(group($0[1]))/\(group($0[2]))" }
            t = replaceEach(t, #"\\[dt]?frac\s*(\d)\s*(\d)"#) { "\($0[1])/\($0[2])" }
            t = replaceEach(t, #"\\sqrt\s*\{([^{}]*)\}"#) { "√" + group($0[1]) }
            t = replaceEach(t, #"\^\s*\{([^{}]*)\}"#) { script($0[1], superscripts) ?? "^{\($0[1])}" }
            t = replaceEach(t, #"_\s*\{([^{}]*)\}"#) { script($0[1], subscripts) ?? "_{\($0[1])}" }
            if t == before { break }
        }
        t = replaceEach(t, #"\^([0-9A-Za-z+\-])"#) { script($0[1], superscripts) ?? "^\($0[1])" }
        t = replaceEach(t, #"_([0-9A-Za-z])"#) { script($0[1], subscripts) ?? "_\($0[1])" }
        // Plain grouping braces go; anything still needing TeX keeps the monospaced form.
        if t.contains("\\") || t.contains("^") || t.contains("_") { return nil }
        t = t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "{").replacingOccurrences(of: "\u{E002}", with: "}")
            .replacingOccurrences(of: "\u{E003}", with: "_")
        t = t.replacingOccurrences(of: #"[ \t\n]{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// The span as the block's markdown: escaped plain text, else a code span (monospaced), never raw `$`.
    private static func render(_ tex: String) -> String {
        if let p = plain(tex) { return escapeMarkdown(p) }
        let flat = tex.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.contains("`") ? escapeMarkdown(flat) : "`" + flat + "`"
    }

    static func escapeMarkdown(_ s: String) -> String {
        var o = ""
        for ch in s { if "\\*_`[]<>".contains(ch) { o.append("\\") }; o.append(ch) }
        return o
    }

    private static func isCheckbox(_ tex: String) -> Bool {   // a notes checkbox "\[x\]", "\[ \]" is not math
        tex.trimmingCharacters(in: .whitespaces).count <= 1
    }

    private static func find(_ needle: String, in c: [Character], from: Int) -> Int? {
        let n = Array(needle)
        guard from <= c.count - n.count else { return nil }
        var k = from
        while k <= c.count - n.count {
            if Array(c[k..<(k + n.count)]) == n, !(n.first == "$" && k > 0 && c[k - 1] == "\\") { return k }
            k += 1
        }
        return nil
    }

    private static func group(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= 1 || t.range(of: #"^[\p{L}\p{N}.,√⁰-⁹²³¹]+$"#, options: .regularExpression) != nil ? t : "(\(t))"
    }

    private static func script(_ s: String, _ map: [Character: Character]) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        var o = ""
        for ch in t { guard let m = map[ch] else { return nil }; o.append(m) }
        return o
    }

    private static func replaceEach(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ"]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "i": "ᵢ", "n": "ₙ", "x": "ₓ"]
    private static let symbols: [(String, String)] = [
        ("times", "×"), ("div", "÷"), ("cdot", "·"), ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"),
        ("neq", "≠"), ("ne", "≠"), ("approx", "≈"), ("pm", "±"), ("mp", "∓"), ("infty", "∞"), ("degree", "°"),
        ("to", "→"), ("rightarrow", "→"), ("Rightarrow", "⇒"), ("leftarrow", "←"), ("ldots", "…"), ("dots", "…"),
        ("cdots", "⋯"), ("sim", "∼"), ("propto", "∝"), ("sum", "∑"), ("prod", "∏"), ("partial", "∂"), ("in", "∈"),
        ("percent", "%"), ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("Delta", "Δ"),
        ("epsilon", "ε"), ("theta", "θ"), ("lambda", "λ"), ("mu", "μ"), ("pi", "π"), ("rho", "ρ"), ("sigma", "σ"),
        ("Sigma", "Σ"), ("tau", "τ"), ("phi", "φ"), ("omega", "ω"), ("Omega", "Ω")]
}
