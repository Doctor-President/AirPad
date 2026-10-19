import Foundation

/// live-25 (2) — Markdown syntax never shows in a DERIVED title or summary. A note's text is stored as Markdown
/// (`MarkdownCodec`), so anything that lifts that text into a label — an untitled entry's card / grid / canvas title,
/// Done's first-words title (B1), the card-content proposal's preview — strips it first: `**` `__` `*` `_` `` ` ``,
/// heading `#`, quote `>`, list markers and checkboxes, link syntax (the link text stays), escapes (`\*` → `*`).
/// Display and derivation only: the stored note text never changes.
enum MarkdownPlain {
    /// Block + inline: each line loses its heading / quote / list / checkbox marker, then its inline syntax.
    static func text(_ s: String) -> String {
        s.components(separatedBy: "\n").map { inline(block($0)) }.joined(separator: "\n")
    }

    /// One line's leading block syntax: `# ` headings, `> ` quotes, `- ` / `* ` / `+ ` / `• ` / `1. ` markers, and a
    /// horizontal rule. A checkbox (live-26 (3b), every spelling — `checkbox(_:)`) becomes the checkbox glyph.
    static func block(_ line: String) -> String {
        var l = line
        if l.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil { return "" }
        if let cb = checkbox(l) { return (cb.done ? checkedGlyph : uncheckedGlyph) + " " + cb.text }
        l = replace(l, #"^\s{0,3}#{1,6}\s+"#, "")
        while let r = l.range(of: #"^\s*>\s?"#, options: .regularExpression) { l.removeSubrange(r) }
        l = replace(l, #"^\s*(?:[-*+•]|\d{1,3}[.)])\s+"#, "")
        return l
    }

    /// The checkbox glyphs a plain-text label shows (a styled label strikes a done row through).
    static let uncheckedGlyph = "☐", checkedGlyph = "☑"

    /// live-26 (3b) — a checkbox at a line's start, in every spelling the writers store: the editor's escaped
    /// `- \[ ] ` / `- \[x] ` (its encoder escapes the bracket), raw `- [ ] ` / `* [ ] ` / `+ [ ] ` / `• [ ] ` / `1. [ ] `
    /// (share extension, paste), and a bare `[ ]` / `[x]` / `[X]`. Indentation allowed. The rest of the line is returned
    /// as stored (its inline markup still in it).
    static func checkbox(_ line: String) -> (done: Bool, text: String)? {
        guard let m = line.range(of: #"^\s*(?:(?:[-*+•]|\d{1,3}[.)])\s+)?\\?\[([ xX])\\?\](?:\s+|$)"#, options: .regularExpression)
        else { return nil }
        let head = line[m]
        return (head.contains("x") || head.contains("X"), String(line[m.upperBound...]))
    }

    /// Inline syntax: emphasis, strike, code, links (the text stays), images (the alt text stays); inline HTML tags
    /// (`<u>` — the editor's underline — `<b>`, `<span …>`, any tag) go, `<br>` is a space, entities are decoded; a
    /// backslash escape is the literal character. Text a person typed stays: `a < b`, `<3`, `x > y`, `<sam@example.com>`
    /// (the editor stores a typed `<` escaped). Unpaired `**` / `__` (a fragment cut mid-span) go too.
    static func inline(_ s: String) -> String {
        guard s.contains(where: { "*_`[]<\\!&~".contains($0) }) else { return s }
        var t = park(s)
        t = replace(t, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        t = replace(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = replace(t, #"`([^`\n]+)`"#, "$1")
        t = replace(t, #"<br\s*/?>"#, " ")
        t = replace(t, htmlTag, "")
        for _ in 0..<3 {   // nested / adjacent spans (`***x***`, `**a** and **b**`)
            t = replace(t, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2")
            t = replace(t, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1")
            t = replace(t, #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1")
            t = replace(t, #"~~(?=\S)(.+?)(?<=\S)~~"#, "$1")
        }
        t = replace(t, #"\*\*|__"#, "")
        return unpark(t)
    }

    /// live-26 (3b) — a label line WITH its styling where the label can show it: underline (`<u>`), bold (`**`, `__`,
    /// `<b>`, `<strong>`), italic (`*`, `_`, `<i>`, `<em>`), strike (`~~`, `<s>`, `<del>`, `<strike>`); other tags go,
    /// entities are decoded, links keep their text (not tappable), typed `<` stays. Block markers are the caller's.
    static func styled(_ s: String) -> AttributedString {
        guard s.contains(where: { "*_`[]<\\!&~".contains($0) }) else { return AttributedString(s) }
        var t = park(s)
        t = replace(t, #"<br\s*/?>"#, " ")
        for (pattern, md) in [(#"</?(?:b|strong)\b[^<>]*>"#, "**"), (#"</?(?:i|em)\b[^<>]*>"#, "*"),
                              (#"</?(?:s|del|strike)\b[^<>]*>"#, "~~")] {
            t = replace(t, pattern, md)
        }
        t = replace(t, #"<u\b[^<>]*>"#, underlineOpen)
        t = replace(t, #"</u\s*>"#, underlineClose)
        t = replace(t, htmlTag, "")
        t = replace(t, #"<"#, #"\\<"#)   // what's left is typed text, never an autolink or HTML to the parser
        var out = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(inline(s))
        for run in out.runs where run.link != nil { out[run.range].link = nil }
        while let open = out.range(of: underlineOpen) {
            out.removeSubrange(open)
            let close = out[open.lowerBound...].range(of: underlineClose)
            let end = close?.lowerBound ?? out.endIndex
            out[open.lowerBound..<end].underlineStyle = .single
            if let close { out.removeSubrange(close) }
        }
        while let stray = out.range(of: underlineClose) { out.removeSubrange(stray) }
        for (i, ch) in specials.enumerated() {
            let p = String(UnicodeScalar(0xE000 + i)!)
            while let r = out.range(of: p) { out.replaceSubrange(r, with: AttributedString(String(ch), attributes: out[r].runs.first?.attributes ?? .init())) }
        }
        return out
    }

    /// live-26 (3b) — note text for the editor's own decoder (`MarkdownCodec.decode`, which reads `<u>` and Markdown
    /// only): `<b>` / `<strong>` → `**`, `<i>` / `<em>` → `*`, `<s>` / `<del>` / `<strike>` → `~~`, `<br>` → a space,
    /// any other tag dropped, entities decoded (to the decoder's escapes where it has one). `<u>` and typed `<` stay.
    static func forDecoder(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return s }
        var t = park(s)
        t = replace(t, #"<br\s*/?>"#, " ")
        for (pattern, md) in [(#"</?(?:b|strong)\b[^<>]*>"#, "**"), (#"</?(?:i|em)\b[^<>]*>"#, "*"),
                              (#"</?(?:s|del|strike)\b[^<>]*>"#, "~~")] {
            t = replace(t, pattern, md)
        }
        t = replace(t, #"</?(?!u\b)[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?/?>"#, "")
        let decoderEscapes: Set<Character> = ["*", "`", "~", "[", "<", "\\"]
        for (i, ch) in specials.enumerated() {
            t = t.replacingOccurrences(of: String(UnicodeScalar(0xE000 + i)!),
                                       with: decoderEscapes.contains(ch) ? "\\" + String(ch) : String(ch))
        }
        return t
    }

    /// Any HTML tag (a name right after `<`, so `a < b`, `<3` and `<sam@example.com>` never match).
    private static let htmlTag = #"</?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?/?>"#
    private static let underlineOpen = "\u{E100}", underlineClose = "\u{E101}"
    /// Characters an escape (or an entity) can stand for, parked on private-use characters while the syntax is read.
    private static let specials = Array(#"\`*_{}[]()#+-.!<>|~&"#)

    /// Escapes and entities → parked literals (so `\*` / `&lt;` never read as syntax).
    private static func park(_ s: String) -> String {
        var t = s
        for (i, ch) in specials.enumerated() {
            t = t.replacingOccurrences(of: "\\" + String(ch), with: String(UnicodeScalar(0xE000 + i)!))
        }
        guard t.contains("&") else { return t }
        func parked(_ c: Character) -> String {
            specials.firstIndex(of: c).map { String(UnicodeScalar(0xE000 + $0)!) } ?? String(c)
        }
        let named: [String: Character] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]
        var out = "", rest = Substring(t)
        while let r = rest.range(of: #"&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z]{2,8});"#, options: .regularExpression) {
            out += rest[..<r.lowerBound]
            let body = String(rest[r].dropFirst().dropLast())
            var ch: Character?
            if let c = named[body.lowercased()] { ch = c }
            else if body.hasPrefix("#x") || body.hasPrefix("#X") { ch = UInt32(body.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(Character.init) }
            else if body.hasPrefix("#") { ch = UInt32(body.dropFirst()).flatMap(UnicodeScalar.init).map(Character.init) }
            out += ch.map(parked) ?? String(rest[r])
            rest = rest[r.upperBound...]
        }
        return out + rest
    }
    private static func unpark(_ s: String) -> String {
        var t = s
        for (i, ch) in specials.enumerated() {
            t = t.replacingOccurrences(of: String(UnicodeScalar(0xE000 + i)!), with: String(ch))
        }
        return t
    }

    /// Done's first-words title (B1): the plain text of the note, trimmed, its first 40 characters.
    static func fragmentTitle(_ content: String) -> String {
        String(text(content).trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

extension Node {
    /// What an untitled entry shows as its title on the card / grid / canvas: its first item's text, plain. Nil when
    /// there's none (the surface then says "Untitled").
    var untitledDisplayText: String? {
        guard let raw = items.first?.content, !raw.isEmpty else { return nil }
        let plain = MarkdownPlain.text(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }
}
