import SwiftUI
import UIKit

// live-23 (4) — ★ the card-content PROPOSAL (T judges; built behind the TestFlight tuner's "Card content: Today /
// Proposal" switch, Today by default). One system for every face:
//   • a CONTENT STRIP — one quiet row of type symbols with counts, fixed order, only for types present (the honest
//     "how much is in here"); it replaces "+N more";
//   • a PREVIEW HIERARCHY — title → summary (clamped) → ONE representative preview from the richest item: a list shows
//     its first rows with real bullets / numbers / checkboxes (hanging indent) and "+N more items"; a voice item shows
//     the waveform glyph, its duration and the first transcript line; attributes keep today's row;
//   • carousel = vertical (same components, same order, only the space differs); grid 2-col = title (2) + summary (2)
//     + strip; grid 3-col = an adaptive title (3 lines without a hero, 2 with, scaling to 0.85 before truncating), the
//     strip as icons only for the 2–3 most-present types, no summary, every tile the same height.
// Typography is the app's one family (`appBodyFont`); markers and symbols are the card's secondary ink.

/// Which card content renders. An App Store build always renders Today; DEBUG / TestFlight read the appearance tuner
/// (and DEBUG `-CardContent proposal`, for the stills).
enum CardContentPresentation {
    static var isProposal: Bool {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "CardContent") { return forced == "proposal" }   // stills: proposal | today
        #endif
        #if DEBUG || TESTFLIGHT
        if AppearanceTuning.isLive { return AppearanceTuner.shared.state.cardContent == .proposal }
        #endif
        return bakedProposal
    }
    /// What an App Store build renders.
    static let bakedProposal = true   // live-26 (1): T chose the proposal (2026-10-18)
}

// MARK: - The summary (pure)

struct CardContentSummary: Equatable {
    /// Fixed strip order.
    enum Kind: Int, CaseIterable, Comparable {
        case text, photo, video, voice, document, link, chat
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        var symbol: String {
            switch self {
            case .text: return "note.text"
            case .photo: return "photo"
            case .video: return "video"
            case .voice: return "waveform"
            case .document: return "doc"
            case .link: return "link"
            case .chat: return "bubble.left.and.bubble.right"
            }
        }
        var noun: String {
            switch self {
            case .text: return "paragraph"
            case .photo: return "photo"
            case .video: return "video"
            case .voice: return "voice note"
            case .document: return "document"
            case .link: return "link"
            case .chat: return "chat"
            }
        }
    }

    struct Count: Equatable {
        let kind: Kind
        let n: Int           // how many (ranks "most present")
        let label: String    // what the strip prints: "3", "31", "0:28", "11 pp"
    }

    struct ListRow: Equatable {
        enum Marker: Equatable { case bullet, number(Int), check(Bool) }
        let marker: Marker
        /// The row as plain text (accessibility, comparisons).
        let text: String
        /// live-26 (3b) — the row as stored (its inline markup), so the face can render underline / bold / italic / strike.
        var source: String? = nil
        static func == (a: ListRow, b: ListRow) -> Bool { a.marker == b.marker && a.text == b.text }
        /// live-29 (B4) — what the card's face renders for this row (the one path the view uses, so the self-test
        /// checks what shows, not just `text`).
        var rendered: AttributedString { source.map(MarkdownPlain.styledLines) ?? AttributedString(text) }
    }

    /// live-26 (3b) — prose for the preview: plain (compared, read aloud) + the paragraph as stored (rendered styled).
    struct PreviewText: Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
        let plain: String
        var source: String? = nil
        init(plain: String, source: String? = nil) { self.plain = plain; self.source = source }
        init(stringLiteral value: String) { plain = value }
        static func == (a: PreviewText, b: PreviewText) -> Bool { a.plain == b.plain }
        var description: String { plain }
        /// live-29 (B4) — what the card's face renders (the one path the view uses). T's device showed a preview line
        /// beginning "### " although `plain` was clean: the face rendered `source` through the inline-only styler.
        var rendered: AttributedString { source.map(MarkdownPlain.styledLines) ?? AttributedString(plain) }
    }

    enum Preview: Equatable {
        case list(rows: [ListRow], more: Int)
        case voice(duration: String?, firstLine: String?)
        case text(PreviewText)
        case photos(itemID: String)
        case document(itemID: String)
        case link(itemID: String)
    }

    let strip: [Count]
    let preview: Preview?

    /// The 2–3 most-present types (by count), shown in the fixed order — the 3-col tile's icon strip.
    func mostPresent(_ k: Int = 3) -> [Count] {
        Array(strip.sorted { $0.n != $1.n ? $0.n > $1.n : $0.kind < $1.kind }.prefix(k)).sorted { $0.kind < $1.kind }
    }

    /// Spoken summary of the strip ("3 paragraphs, 31 photos, …").
    var accessibilityText: String {
        strip.map { c in
            switch c.kind {
            case .voice where c.n == 1: return "voice note, \(c.label)"
            case .document where c.label.hasSuffix("pp"): return "document, \(c.label.dropLast(3)) pages"
            default: return "\(c.n) \(c.kind.noun)\(c.n == 1 ? "" : "s")"
            }
        }.joined(separator: ", ")
    }

    // MARK: Build

    static func make(_ node: Node, hasHero: Bool) -> CardContentSummary {
        var paragraphs = 0, photos = 0, videos = 0, voices = 0, voiceSeconds = 0.0, docs = 0, pages = 0, links = 0, chats = 0
        var docPagesKnown = true
        for item in node.items {
            switch item.type {
            case .text:
                paragraphs += Self.paragraphs(item.content ?? "").count
            case .imageVideo:
                for m in item.mediaItems ?? [] { if m.mediaType == .video { videos += 1 } else { photos += 1 } }
            case .image: photos += 1
            case .video: videos += 1
            case .audio:
                voices += 1; voiceSeconds += max(item.durationSeconds ?? 0, 0)
            case .document:
                for d in item.documentItems ?? [] {
                    docs += 1
                    if let p = d.pageCount, p > 0 { pages += p } else { docPagesKnown = false }
                }
            case .link: links += max(item.linkItems?.count ?? 0, item.url == nil ? 0 : 1)
            case .chats: chats += item.chatSessionIDs?.count ?? 0
            case .rating, .field: break
            }
        }
        var strip: [Count] = []
        if paragraphs > 0 { strip.append(Count(kind: .text, n: paragraphs, label: "\(paragraphs)")) }
        if photos > 0 { strip.append(Count(kind: .photo, n: photos, label: "\(photos)")) }
        if videos > 0 { strip.append(Count(kind: .video, n: videos, label: "\(videos)")) }
        if voices > 0 {
            let d = Self.duration(voiceSeconds)
            strip.append(Count(kind: .voice, n: voices, label: voices == 1 ? (d ?? "1") : "\(voices) · \(d ?? "")"))
        }
        if docs > 0 {
            strip.append(Count(kind: .document, n: docs,
                               label: docs == 1 && docPagesKnown && pages > 0 ? "\(pages) pp" : "\(docs)"))
        }
        if links > 0 { strip.append(Count(kind: .link, n: links, label: "\(links)")) }
        if chats > 0 { strip.append(Count(kind: .chat, n: chats, label: "\(chats)")) }
        return CardContentSummary(strip: strip, preview: richestPreview(node, hasHero: hasHero))
    }

    /// The ONE preview: the richest item, scored — a list beats a voice note beats photos (when there's no hero to
    /// show them already) beats prose, then a document, then a link. Prose scores by length, so a long note wins
    /// over a one-line caption.
    static func richestPreview(_ node: Node, hasHero: Bool) -> Preview? {
        var best: (score: Int, preview: Preview)?
        func offer(_ score: Int, _ p: Preview) { if score > (best?.score ?? Int.min) { best = (score, p) } }
        for item in node.items {
            switch item.type {
            case .text:
                let content = item.content ?? ""
                let rows = listRows(content)
                if rows.count >= 2 {
                    offer(100 + rows.count, .list(rows: Array(rows.prefix(3)), more: max(rows.count - 3, 0)))
                } else if let first = paragraphs(content).first {
                    offer(min(content.count / 8, 70), .text(PreviewText(plain: MarkdownPlain.text(first), source: first)))   // live-25 (2) / live-26 (3b)
                }
            case .audio:
                let line = item.transcript.flatMap { t in
                    t.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
                }
                offer(line == nil ? 55 : 80, .voice(duration: duration(item.durationSeconds ?? 0), firstLine: line))
            case .imageVideo:
                let n = item.mediaItems?.count ?? 0
                if n > 0 && !hasHero { offer(60 + min(n, 30), .photos(itemID: item.id)) }
            case .document:
                if !(item.documentItems ?? []).isEmpty { offer(50, .document(itemID: item.id)) }
            case .link:
                if !(item.linkItems ?? []).isEmpty { offer(40, .link(itemID: item.id)) }
            default: break
            }
        }
        return best?.preview
    }

    /// Non-empty prose paragraphs (blank-line separated); a list counts as one paragraph.
    static func paragraphs(_ s: String) -> [String] {
        s.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every list row in a note body: `- ` / `* ` / `+ ` / `• ` bullets, `1. ` numbers, and checklist items in every
    /// spelling the writers store (live-26 (3b): the editor's escaped `- \[ ] `, raw `- [ ] ` / `* [x] `, a bare `[ ]`,
    /// `1. [ ] ` — `MarkdownPlain.checkbox`).
    static func listRows(_ s: String) -> [ListRow] {
        s.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            func row(_ m: ListRow.Marker, _ rest: String) -> ListRow { ListRow(marker: m, text: MarkdownPlain.inline(rest), source: rest) }
            if let cb = MarkdownPlain.checkbox(line) { return row(.check(cb.done), cb.text) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("• ") {
                return row(.bullet, String(line.dropFirst(2)))
            }
            if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                return row(.number(n), String(line[line.index(dot, offsetBy: 2)...]))
            }
            return nil
        }
    }

    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - The content strip

/// One quiet row: type symbol + count, fixed order, only types present. `iconsOnly` = the 3-col tile's form.
struct CardContentStrip: View {
    let counts: [CardContentSummary.Count]
    var iconsOnly = false
    var size: CGFloat = 11
    let ink: Color
    var halo: Color = .clear
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        HStack(spacing: iconsOnly ? size * 0.8 : size * 0.95) {
            ForEach(counts, id: \.kind) { c in
                HStack(spacing: size * 0.3) {
                    Image(systemName: c.kind.symbol)
                        .font(.system(size: size * 0.95, weight: .regular))
                    if !iconsOnly {
                        Text(c.label)
                            .font(appFont.font(size: size, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(ink)
        .shadow(color: halo.opacity(0.4), radius: 2, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CardContentSummary(strip: counts, preview: nil).accessibilityText)
        .accessibilityIdentifier("cardContentStrip")
    }
}

// MARK: - The list preview

/// The first rows of a list with real markers and a hanging indent, then "+N more items".
struct CardListPreview: View {
    let rows: [CardContentSummary.ListRow]
    let more: Int
    var size: CGFloat = 13
    let ink: Color
    let markerInk: Color
    var halo: Color = .clear
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.35) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: size * 0.45) {
                    marker(row.marker)
                        .frame(width: size * 1.1, alignment: .leading)
                    Text(row.rendered)   // live-26 (3b) / live-29 (B4)
                        .font(appFont.font(size: size))
                        .foregroundColor(ink)
                        .strikethrough(row.marker == .check(true), color: markerInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if more > 0 {
                Text("+\(more) more item\(more == 1 ? "" : "s")")
                    .font(appFont.font(size: size * 0.85))
                    .italic()
                    .foregroundColor(markerInk)
                    .padding(.leading, size * 1.55)
            }
        }
        .shadow(color: halo.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func marker(_ m: CardContentSummary.ListRow.Marker) -> some View {
        switch m {
        case .bullet:
            Text("•").font(appFont.font(size: size, weight: .bold)).foregroundColor(markerInk)
        case .number(let n):
            Text("\(n).").font(appFont.font(size: size * 0.92, weight: .medium)).monospacedDigit().foregroundColor(markerInk)
        case .check(let done):
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size * 0.95))
                .foregroundColor(markerInk)
        }
    }

}

/// A voice item: the waveform glyph, its duration, the first transcript line.
struct CardVoicePreview: View {
    let duration: String?
    let firstLine: String?
    var size: CGFloat = 13
    var lines = 2
    let ink: Color
    let markerInk: Color
    var halo: Color = .clear
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        HStack(alignment: .top, spacing: size * 0.6) {
            Image(systemName: "waveform")
                .font(.system(size: size * 1.25))
                .foregroundColor(markerInk)
            VStack(alignment: .leading, spacing: 2) {
                if let duration {
                    Text(duration).font(appFont.font(size: size, weight: .semibold)).monospacedDigit().foregroundColor(ink)
                }
                if let firstLine {
                    Text(firstLine)
                        .font(appFont.font(size: size * 0.92))
                        .italic()
                        .foregroundColor(ink)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                }
            }
        }
        .shadow(color: halo.opacity(0.35), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Self-test

#if DEBUG
extension CardContentSummary {
    /// `-CardContentSelfTest` — the proposal's content strip and preview choice, on synthetic entries shaped like the
    /// showcase's. Pure.
    static func selfTest() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        let t = Date(timeIntervalSince1970: 1_760_500_000)
        func text(_ s: String) -> NodeItem { NodeItem(id: UUID().uuidString, type: .text, createdAt: t, content: s) }
        func node(_ items: [NodeItem]) -> Node {
            Node(id: UUID().uuidString, createdAt: t, updatedAt: t, title: "x", summary: "", tags: [], items: items,
                 entrySchemaVersion: 4)
        }
        func strip(_ s: CardContentSummary) -> String { s.strip.map { "\($0.kind)=\($0.label)" }.joined(separator: " ") }

        var gallery = NodeItem(id: "g", type: .imageVideo, createdAt: t)
        gallery.mediaItems = (0..<31).map { GalleryItem(id: "p\($0)", mediaType: .image, file: "f", aspectRatio: 1, capturedAt: t) }
        let g = make(node([text("Low water at 06:12."), gallery]), hasHero: true)
        row("gallery-strip-text-1-photo-31", strip(g) == "text=1 photo=31", strip(g))
        row("gallery-with-hero-previews-prose-not-photos", g.preview == .text("Low water at 06:12."), "\(String(describing: g.preview))")
        let gNoHero = make(node([text("Hi."), gallery]), hasHero: false)
        row("gallery-without-hero-previews-photos", gNoHero.preview == .photos(itemID: "g"))

        let voice = NodeItem.audio(itemID: "v", file: "f", transcript: "First line here.\nSecond.", duration: 28)
        let v = make(node([voice]), hasHero: false)
        row("voice-strip-duration-0:28", strip(v) == "voice=0:28", strip(v))
        row("voice-preview-duration-and-first-line", v.preview == .voice(duration: "0:28", firstLine: "First line here."))

        let doc = DocumentItem(id: "d", filePath: "f", fileName: "a.pdf", fileType: "pdf", documentTitle: nil, extractedText: nil,
                               thumbnailFile: nil, pageCount: 11, wordCount: nil, capturedAt: t)
        let dItem = NodeItem(id: "di", type: .document, createdAt: t, file: "f", displayName: nil, isExpanded: true,
                             updatedAt: t, documentItems: [doc])
        row("document-strip-11-pp", strip(make(node([dItem]), hasHero: false)) == "document=11 pp")

        let listBody = "- [x] Book\n- [ ] Print\n\n- Waders\n- Torch\n\n1. Leave\n2. Park"
        let parsed = listRows(listBody)
        row("list-rows-parse-checks-bullets-numbers", parsed.map(\.marker) == [.check(true), .check(false), .bullet, .bullet, .number(1), .number(2)]
            && parsed[0].text == "Book" && parsed[4].text == "Leave", "\(parsed)")
        let l = make(node([text("A plain paragraph that is longer than the list note, by quite a long way indeed, yes."), text(listBody)]), hasHero: false)
        row("list-beats-prose-for-the-preview", l.preview == .list(rows: Array(parsed.prefix(3)), more: 3), "\(String(describing: l.preview))")
        row("list-note-counts-as-paragraphs", strip(l) == "text=4", strip(l))

        var link = NodeItem(id: "l", type: .link, createdAt: t)
        link.linkItems = [LinkItem(id: "l1", url: "https://example.com", title: "A", siteName: "example.com", capturedAt: t),
                          LinkItem(id: "l2", url: "https://example.org", title: "B", siteName: "example.org", capturedAt: t)]
        let mixed = make(node([text("One."), gallery, voice, link]), hasHero: true)
        row("strip-is-fixed-order-only-types-present", mixed.strip.map(\.kind) == [.text, .photo, .voice, .link], strip(mixed))
        row("three-col-icons-are-the-most-present-in-order", mixed.mostPresent(3).map(\.kind) == [.text, .photo, .link],
            mixed.mostPresent(3).map { "\($0.kind)" }.joined(separator: ","))
        row("attributes-are-not-in-the-strip", make(node([NodeItem(id: "r", type: .rating, createdAt: t, rating: Rating(value: 3))]),
                                                     hasHero: false).strip.isEmpty)
        row("empty-entry-has-no-strip-no-preview", make(node([]), hasHero: false) == CardContentSummary(strip: [], preview: nil))
        // live-25 (2) — Markdown syntax never shows in a derived title / preview (the "+" Capture stores its typed first
        // line as `**…**`; the card showed the stars). Display and derivation only: the stored text is untouched.
        var untitled = node([text("**Ask the harbour office about the mooring.**")]); untitled.title = ""
        row("untitled-card-title-drops-bold", untitled.untitledDisplayText == "Ask the harbour office about the mooring.",
            untitled.untitledDisplayText ?? "nil")
        row("stored-text-is-unchanged", untitled.items.first?.content == "**Ask the harbour office about the mooring.**")
        let md: [(String, String)] = [
            ("**Feb 2** — cut the water", "Feb 2 — cut the water"), ("__bold__ and *it* and _it_", "bold and it and it"),
            ("***both***", "both"), ("`code` here", "code here"), ("# Heading", "Heading"), ("> quoted", "quoted"),
            ("- [ ] Body — **$400–700** used", "☐ Body — $400–700 used"), ("- item", "item"), ("1. first", "first"),
            ("see [the tide table](https://example.com/t) now", "see the tide table now"), ("![a heron](f.jpg)", "a heron"),
            (#"\*not emphasis\*"#, "*not emphasis*"), ("snake_case_name stays", "snake_case_name stays"),
            ("5 * 3 * 2", "5 * 3 * 2"), ("**cut mid-span", "cut mid-span"), ("a plain sentence.", "a plain sentence."),
        ]
        let mdFails = md.filter { MarkdownPlain.text($0.0) != $0.1 }.map { "\($0.0) → \(MarkdownPlain.text($0.0))" }
        row("markdown-syntax-drops-link-text-stays (\(md.count) cases)", mdFails.isEmpty, mdFails.joined(separator: " | "))
        row("done-fragment-title-is-plain (B1)", MarkdownPlain.fragmentTitle("**Ask the harbour office about the mooring.**")
            == "Ask the harbour office about the mooring", MarkdownPlain.fragmentTitle("**Ask the harbour office about the mooring.**"))
        let prose = make(node([text("**Feb 2** — cut the water by half a cup and put the lemon in at the end")]), hasHero: true)
        row("proposal-prose-preview-is-plain", prose.preview == .text("Feb 2 — cut the water by half a cup and put the lemon in at the end"),
            "\(String(describing: prose.preview))")
        let rowsMd = listRows("- [ ] Body — **$400–700** used\n- [ ] Lens — **$150+**")
        row("proposal-list-rows-are-plain", rowsMd.map(\.text) == ["Body — $400–700 used", "Lens — $150+"], "\(rowsMd.map(\.text))")
        // live-26 (3b) — markup never leaks into a derived label. Fixtures = what the writers really store (Ops report:
        // the editor escapes a checklist's bracket (`- \[ ] `) and writes underline as `<u>…</u>`; the share extension and
        // paste store raw text, any spelling).
        let checks = listRows([#"- \[ ] a"#, #"- \[x] b"#, "- [ ] c", "- [X] d", "* [ ] e", "+ [x] f", "• [ ] g", "[ ] h", "[x] i",
                               "1. [ ] j", #"  - \[ ] k"#].joined(separator: "\n"))
        row("checklist-every-spelling-is-a-checkbox (11)", checks.map(\.marker) == [.check(false), .check(true), .check(false),
            .check(true), .check(false), .check(true), .check(false), .check(false), .check(true), .check(false), .check(false)]
            && checks.map(\.text) == ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"],
            checks.map { "\($0.marker):\($0.text)" }.joined(separator: " "))
        let glyphs: [(String, String)] = [(#"- \[ ] Buy milk"#, "☐ Buy milk"), ("- [x] Done it", "☑ Done it"), ("[ ] bare", "☐ bare"),
                                          ("1. [X] numbered", "☑ numbered"), ("• [ ] dot", "☐ dot")]
        let glyphFails = glyphs.filter { MarkdownPlain.text($0.0) != $0.1 }.map { "\($0.0) → \(MarkdownPlain.text($0.0))" }
        row("checklist-in-a-plain-label-is-the-glyph (\(glyphs.count))", glyphFails.isEmpty, glyphFails.joined(separator: " | "))
        let html: [(String, String)] = [
            ("<u>word</u> more", "word more"),
            ("<b>b</b> <strong>s</strong> <i>i</i> <em>e</em> <s>x</s> <del>d</del> <mark>m</mark>", "b s i e x d m"),
            ("line<br>next<br/>last<br />end", "line next last end"), (#"<span style="color:#1B59C2">blue</span> word"#, "blue word"),
            ("<font face=x>f</font>", "f"), ("[<u>site</u>](https://example.com)", "site"), ("**<u>both</u>**", "both"),
            ("~~gone~~ stays", "gone stays"), ("a &amp; b &lt;c&gt; &quot;q&quot; it&#39;s&nbsp;here &#8212; &#x2014;", "a & b <c> \"q\" it's here — —"),
            ("&amp;lt; once", "&lt; once"),
        ]
        let htmlFails = html.filter { MarkdownPlain.text($0.0) != $0.1 }.map { "\($0.0) → \(MarkdownPlain.text($0.0))" }
        row("inline-html-and-entities-never-show (\(html.count))", htmlFails.isEmpty, htmlFails.joined(separator: " | "))
        let literal: [(String, String)] = [("a < b", "a < b"), ("<3 this", "<3 this"), ("x > y", "x > y"),
                                           ("mail <sam@example.com>", "mail <sam@example.com>"), ("see <https://example.com>", "see <https://example.com>"),
                                           (#"typed \<u> by hand"#, "typed <u> by hand"), (#"a \< b"#, "a < b"), ("5 < 6 > 4", "5 < 6 > 4")]
        let litFails = literal.filter { MarkdownPlain.text($0.0) != $0.1 }.map { "\($0.0) → \(MarkdownPlain.text($0.0))" }
        row("typed-angle-brackets-stay (\(literal.count))", litFails.isEmpty, litFails.joined(separator: " | "))
        // live-29 (B4) — what the card RENDERS never starts with a heading / quote / list marker, in every spelling a
        // note can hold: T's device (Proposal card, light) showed a preview line "### " + all-caps text. Synthetic fixtures.
        let headings: [(String, String)] = [
            ("### PROPOSAL OUTLINE\nThe plan is to cut the water by half", "PROPOSAL OUTLINE\nThe plan is to cut the water by half"),
            ("## Weekly menu", "Weekly menu"), ("# One", "One"), ("###### Six", "Six"),
            ("    ### INDENTED FOUR", "INDENTED FOUR"), ("\u{00A0}### NBSP LEAD", "NBSP LEAD"), ("### NBSP\u{00A0}AFTER", "NBSP\u{00A0}AFTER"),
            ("\u{FEFF}### BOM LEAD", "BOM LEAD"), ("\u{200B}## ZERO WIDTH", "ZERO WIDTH"), ("### CR LINE\r", "CR LINE"),
            ("###NO SPACE", "NO SPACE"), ("##Tight", "Tight"), ("> ### Quoted heading", "Quoted heading"),
            ("### **Bold heading**", "Bold heading"), ("#hashtag stays", "#hashtag stays"), ("#1 priority stays", "#1 priority stays"),
        ]
        func shownText(_ src: String) -> String {
            guard case .text(let t)? = make(node([text(src)]), hasHero: true).preview else { return "(no text preview)" }
            return String(t.rendered.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headFails = headings.filter { shownText($0.0) != $0.1 }.map { "\($0.0.debugDescription) → \(shownText($0.0).debugDescription)" }
        row("card-preview-renders-no-heading-marker (\(headings.count))", headFails.isEmpty, headFails.joined(separator: " | "))
        let listHead = listRows("- ### HEADED ROW\n- plain row")
        row("card-list-row-renders-no-heading-marker", listHead.map { String($0.rendered.characters) } == ["HEADED ROW", "plain row"],
            listHead.map { String($0.rendered.characters) }.joined(separator: " | "))
        let st = MarkdownPlain.styled("<u>under</u> **bold** *it* ~~gone~~ <b>tag</b> &amp;")
        func styleAt(_ word: String) -> String {
            guard let r = st.range(of: word) else { return "missing" }
            let run = st[r].runs.first!
            var f: [String] = []
            if run.underlineStyle != nil { f.append("u") }
            if run.strikethroughStyle != nil || run.inlinePresentationIntent?.contains(.strikethrough) == true { f.append("s") }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { f.append("b") }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { f.append("i") }
            return f.joined()
        }
        let stOK = String(st.characters) == "under bold it gone tag &" && styleAt("under") == "u" && styleAt("bold") == "b"
            && styleAt("it") == "i" && styleAt("gone") == "s" && styleAt("tag") == "b"
        row("styled-labels-render-underline-bold-italic-strike", stOK,
            "\(String(st.characters)) u=\(styleAt("under")) b=\(styleAt("bold")) i=\(styleAt("it")) s=\(styleAt("gone")) tag=\(styleAt("tag"))")
        let ul = node([text("<u>Ask</u> the harbour &amp; the yard")])
        row("untitled-title-drops-html", ul.untitledDisplayText == "Ask the harbour & the yard", ul.untitledDisplayText ?? "nil")
        let edPreview = make(node([text(#"- \[ ] Print the reef map"# + "\n" + #"- \[x] Book the cottage"# + "\n" + "- <u>Waders</u>")]), hasHero: true)
        row("editor-checklist-previews-as-checkboxes", edPreview.preview == .list(rows: [
            ListRow(marker: .check(false), text: "Print the reef map"), ListRow(marker: .check(true), text: "Book the cottage"),
            ListRow(marker: .bullet, text: "Waders")], more: 0), "\(String(describing: edPreview.preview))")

        // live-26 (1): T chose the proposal (2026-10-18) — an App Store build and plain DEBUG render it.
        row("app-store-and-plain-debug-render-the-proposal",
            UserDefaults.standard.string(forKey: "CardContent") != nil || UserDefaults.standard.bool(forKey: "AppearanceTuner")
            || CardContentPresentation.isProposal)
        return "[CardContentSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
