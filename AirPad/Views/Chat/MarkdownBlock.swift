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
}

/// Line-oriented block splitter. The classification ORDER is load-bearing
/// (see COMMIT 2 brief): two shipping providers emit three bullet dialects
/// (`* `, `- `, `*   `) and BOLD-LINE headers rather than ATX. Both are
/// handled; ATX is supported too for a future provider.
enum MarkdownBlockParser {

    static func parse(_ raw: String) -> [MarkdownBlock] {
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

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = trimTrailing(rawLine)                       // trailing WS only
            let s = String(line.drop(while: { $0.isWhitespace }))  // + leading, for rules

            // 1 — FENCE. While open, nothing else applies; lines accumulate
            //     verbatim (leading whitespace preserved). Info string on the
            //     opener (```swift) is consumed, not content.
            if s.hasPrefix("```") {
                if inFence { flushFence() }                        // closing fence
                else { flushParagraph(); inFence = true }          // opener
                continue
            }
            if inFence { fence.append(line); continue }

            // 2 — ATX HEADING
            if let h = atxHeading(s) { flushParagraph(); blocks.append(h); continue }

            // 3 — BULLET (before bold-heading: a bullet whose content is
            //     entirely bold, `*   **Napa**`, must stay a bullet)
            if let b = bullet(s) { flushParagraph(); blocks.append(b); continue }

            // 4 — NUMBERED
            if let n = numbered(s) { flushParagraph(); blocks.append(n); continue }

            // 5 — BOLD-LINE HEADING (only raw lines that reached here)
            if let bh = boldHeading(s) { flushParagraph(); blocks.append(bh); continue }

            // 6 — BLANK: boundary only, never an empty paragraph (FM puts a
            //     blank line between a header and its first bullet).
            if s.isEmpty { flushParagraph(); continue }

            // 7 — PARAGRAPH
            paragraph.append(s)
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

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(headingFont(level))
                .foregroundStyle(ChatTypography.headingText)
                .textSelection(.enabled)

        case let .paragraph(text):
            Text(Self.inline(text))
                .font(ChatTypography.body)
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
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return ChatTypography.h1
        case 2:  return ChatTypography.h2
        default: return ChatTypography.h3
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
                .font(ChatTypography.body)
                .foregroundStyle(ChatTypography.secondaryText)
                .frame(width: ChatTypography.bulletIndent, alignment: .leading)
            Text(Self.inline(text))
                .font(ChatTypography.body)
                .foregroundStyle(ChatTypography.bodyText)
                .lineSpacing(ChatTypography.bodyLine)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    // Inline parse cache — mirrors the old AssistantMarkdownText.cache.
    private static var cache: [String: AttributedString] = [:]
    private static func inline(_ raw: String) -> AttributedString {
        if let cached = cache[raw] { return cached }
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
        CitationReference.styleInlineMarkers(in: &result)
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[raw] = result
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
