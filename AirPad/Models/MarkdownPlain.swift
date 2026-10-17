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

    /// One line's leading block syntax: `# ` headings, `> ` quotes, `- ` / `* ` / `+ ` / `• ` / `1. ` markers,
    /// `[ ]` / `[x]` checkboxes, and a horizontal rule.
    static func block(_ line: String) -> String {
        var l = line
        if l.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil { return "" }
        l = replace(l, #"^\s{0,3}#{1,6}\s+"#, "")
        while let r = l.range(of: #"^\s*>\s?"#, options: .regularExpression) { l.removeSubrange(r) }
        l = replace(l, #"^\s*(?:[-*+•]|\d{1,3}[.)])\s+"#, "")
        l = replace(l, #"^\[[ xX]\]\s+"#, "")
        return l
    }

    /// Inline syntax: emphasis, code, links (the text stays), images (the alt text stays), autolinks; a backslash
    /// escape is the literal character. Unpaired `**` / `__` (a fragment cut mid-span) go too.
    static func inline(_ s: String) -> String {
        guard s.contains(where: { "*_`[]<\\!".contains($0) }) else { return s }
        // Escapes first, parked on private-use characters so `\*` never reads as emphasis.
        let specials = Array(#"\`*_{}[]()#+-.!>|~"#)
        var t = s
        for (i, ch) in specials.enumerated() {
            t = t.replacingOccurrences(of: "\\" + String(ch), with: String(UnicodeScalar(0xE000 + i)!))
        }
        t = replace(t, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        t = replace(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = replace(t, #"<((?:https?|mailto):[^>\s]+)>"#, "$1")
        t = replace(t, #"`([^`\n]+)`"#, "$1")
        for _ in 0..<3 {   // nested / adjacent spans (`***x***`, `**a** and **b**`)
            t = replace(t, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2")
            t = replace(t, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1")
            t = replace(t, #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1")
        }
        t = replace(t, #"\*\*|__"#, "")
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
