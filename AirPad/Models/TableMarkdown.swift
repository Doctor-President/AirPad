import Foundation

/// 1.1-C (C6) — a table in a note: a GFM pipe table in the stored Markdown (any Markdown app opens it), a block in the
/// editor, plain rows in every preview. `TableConverter` is the ONE converter: the note editor's paste, the share sheet
/// (C1, shared HTML / text with a table) and the Markdown export (C5) all go through it.
struct MarkdownTable: Equatable {
    var headers: [String]
    var rows: [[String]]

    init(headers: [String], rows: [[String]]) {
        let n = max(headers.count, rows.map(\.count).max() ?? 0, 1)
        func pad(_ r: [String]) -> [String] { r.count >= n ? Array(r.prefix(n)) : r + Array(repeating: "", count: n - r.count) }
        self.headers = pad(headers)
        self.rows = rows.map(pad)
    }

    /// "Insert table": 3 columns × 3 rows (a header + 2), empty.
    static let blank = MarkdownTable(headers: ["", "", ""], rows: [["", "", ""], ["", "", ""]])

    var columnCount: Int { headers.count }
    var isEmpty: Bool { (headers + rows.flatMap { $0 }).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

enum TableSegment: Equatable {
    case text(String)
    case table(MarkdownTable)
}

enum TableConverter {

    // MARK: - GFM (storage)

    /// The table as GFM pipe lines. A `|` in a cell is escaped, a line break becomes `<br>`.
    static func gfm(_ t: MarkdownTable) -> String {
        func cell(_ s: String) -> String {
            let one = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
            let esc = one.replacingOccurrences(of: "\\|", with: "\u{E0F0}").replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\u{E0F0}", with: "\\|")
            let trimmed = esc.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? " " : trimmed
        }
        func line(_ cells: [String]) -> String { "| " + cells.map(cell).joined(separator: " | ") + " |" }
        let sep = "|" + t.headers.map { _ in " --- " }.joined(separator: "|") + "|"
        return ([line(t.headers), sep] + t.rows.map(line)).joined(separator: "\n")
    }

    /// The cells of one pipe row (`| a | b |` or `a | b`), unescaped. nil when the line has no unescaped pipe.
    static func cells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        var out: [String] = [], cur = "", esc = false, sawPipe = false
        for ch in t {
            if esc { cur.append(ch == "|" ? "|" : "\\\(ch)"); esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "|" { out.append(cur); cur = ""; sawPipe = true; continue }
            cur.append(ch)
        }
        if esc { cur.append("\\") }
        out.append(cur)
        guard sawPipe else { return nil }
        t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { out.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") && !out.isEmpty { out.removeLast() }
        return out.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n") }
    }

    /// A GFM delimiter row (`| --- | :-: |`) with `n` cells (any n ≥ 1 when nil).
    static func isSeparator(_ line: String, columns n: Int? = nil) -> Bool {
        guard let c = cells(line), !c.isEmpty else { return false }
        guard c.allSatisfy({ $0.range(of: #"^:?-{1,}:?$"#, options: .regularExpression) != nil }) else { return false }
        return n == nil || c.count == n
    }

    /// Stored Markdown → prose and tables, in order. A table is a header row with ≥ 2 cells, a matching delimiter row,
    /// then every following line with a pipe. Text between keeps its exact characters (the newline before a table
    /// stays at the end of the text before it; the newline after it starts the text after it).
    static func splitGFM(_ markdown: String) -> [TableSegment] {
        guard markdown.contains("|"), markdown.contains("-") else { return [.text(markdown)] }
        let lines = markdown.components(separatedBy: "\n")
        enum Block { case prose([String]), table(MarkdownTable) }
        var blocks: [Block] = []
        var prose: [String] = []
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count, !isSeparator(lines[i]), let head = cells(lines[i]), head.count >= 2,
               isSeparator(lines[i + 1], columns: head.count) {
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty, let r = cells(lines[j]) {
                    rows.append(r); j += 1
                }
                if !prose.isEmpty { blocks.append(.prose(prose)); prose = [] }
                blocks.append(.table(MarkdownTable(headers: head, rows: rows)))
                i = j
                continue
            }
            prose.append(lines[i]); i += 1
        }
        if !prose.isEmpty { blocks.append(.prose(prose)) }
        guard blocks.contains(where: { if case .table = $0 { return true }; return false }) else { return [.text(markdown)] }
        // The "\n" between two blocks goes to the prose beside it (a table is always whole lines).
        var segs: [TableSegment] = []
        for (k, b) in blocks.enumerated() {
            switch b {
            case .table(let t): segs.append(.table(t))
            case .prose(let ls):
                let before = k > 0 ? "\n" : "", after = k < blocks.count - 1 ? "\n" : ""
                segs.append(.text(before + ls.joined(separator: "\n") + after))
            }
        }
        return segs
    }

    /// Segments → stored Markdown (the inverse of `splitGFM`; a table always sits on its own lines).
    static func join(_ segs: [TableSegment]) -> String {
        var out = ""
        for s in segs {
            switch s {
            case .text(let t): out += t
            case .table(let t):
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                out += gfm(t)
            }
        }
        return out
    }

    // MARK: - Previews (cards and previews never show pipes)

    /// One table row as a preview line: its cells joined by " · " (empty cells skipped).
    static func plainRow(_ cells: [String]) -> String {
        cells.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Stored Markdown with every table as plain rows (header, then each row; the delimiter row gone).
    static func flattenForPreview(_ markdown: String) -> String {
        let segs = splitGFM(markdown)
        guard segs.contains(where: { if case .table = $0 { return true }; return false }) else { return markdown }
        return join(segs.map { s in
            if case .table(let t) = s { return .text(([t.headers] + t.rows).map(plainRow).filter { !$0.isEmpty }.joined(separator: "\n")) }
            return s
        })
    }

    // MARK: - Paste / share (HTML · TSV · pipe · CSV)

    /// What a paste (or a share) holds, as prose and tables, or nil when it holds no table (the caller pastes as
    /// before). HTML `<table>` first (web pages, Docs, Sheets), then the plain text: pipe tables (chat), tab-separated
    /// runs (Numbers, Excel, Sheets), and CSV when the WHOLE text is CSV.
    static func segments(html: String?, text: String?) -> [TableSegment]? {
        if let html, html.range(of: "<table", options: .caseInsensitive) != nil {
            let s = fromHTML(html)
            if s.contains(where: { if case .table = $0 { return true }; return false }) { return s }
        }
        guard let text, !text.isEmpty else { return nil }
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let gfmSegs = splitGFM(norm)
        if gfmSegs.contains(where: { if case .table = $0 { return true }; return false }) { return gfmSegs }
        let tsv = fromTSV(norm)
        if tsv.contains(where: { if case .table = $0 { return true }; return false }) { return tsv }
        if let csv = fromCSV(norm) { return [.table(csv)] }
        return nil
    }

    /// Runs of ≥ 2 consecutive lines with tabs and the same cell count (≥ 2) are tables (first line = header).
    static func fromTSV(_ text: String) -> [TableSegment] {
        let lines = text.components(separatedBy: "\n")
        var segs: [TableSegment] = []
        var prose: [String] = []
        var i = 0
        var afterTable = false
        while i < lines.count {
            let n = lines[i].contains("\t") ? lines[i].components(separatedBy: "\t").count : 0
            var j = i
            if n >= 2 { while j < lines.count, lines[j].contains("\t"), lines[j].components(separatedBy: "\t").count == n { j += 1 } }
            if n >= 2, j - i >= 2 {
                let rows = lines[i..<j].map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
                if !prose.isEmpty || afterTable { segs.append(.text((afterTable ? "\n" : "") + prose.joined(separator: "\n") + (prose.isEmpty ? "" : "\n"))) }
                prose = []
                segs.append(.table(MarkdownTable(headers: rows[0], rows: Array(rows.dropFirst()))))
                afterTable = true
                i = j
                continue
            }
            prose.append(lines[i]); i += 1
        }
        if !prose.isEmpty { segs.append(.text((afterTable ? "\n" : "") + prose.joined(separator: "\n"))) }
        return segs.isEmpty ? [.text(text)] : segs
    }

    /// The whole text as CSV (RFC 4180 quoting): ≥ 2 lines, every line the same field count (≥ 2), short fields, and
    /// no field empty at a line's end (so a letter's "Hi Sam," lines never read as a table).
    static func fromCSV(_ text: String) -> MarkdownTable? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(","), !trimmed.contains("\t") else { return nil }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(trimmed), k = 0
        while k < it.count {
            let ch = it[k]
            if quoted {
                if ch == "\"" { if k + 1 < it.count, it[k + 1] == "\"" { field.append("\""); k += 1 } else { quoted = false } }
                else { field.append(ch) }
            } else if ch == "\"" && field.isEmpty { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(ch) }
            k += 1
        }
        row.append(field); rows.append(row)
        it = []
        rows = rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
        guard rows.count >= 2, let n = rows.first?.count, n >= 2, rows.allSatisfy({ $0.count == n }) else { return nil }
        let fields = rows.flatMap { $0 }.map { $0.trimmingCharacters(in: .whitespaces) }
        guard rows.allSatisfy({ !($0.last ?? "").trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let mean = Double(fields.map(\.count).reduce(0, +)) / Double(max(fields.count, 1))
        guard mean <= 24 else { return nil }
        // A field that reads as a clause (8+ words) is prose with commas, not data.
        guard !fields.contains(where: { $0.split(separator: " ").count >= 8 }) else { return nil }
        let clean = rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        return MarkdownTable(headers: clean[0], rows: Array(clean.dropFirst()))
    }

    /// HTML → prose and tables. Each `<table>` without a table inside it becomes a table (the first row, or the
    /// `<thead>` row, is the header; `colspan` cells repeat as empty cells); everything else becomes plain text.
    static func fromHTML(_ html: String) -> [TableSegment] {
        var segs: [TableSegment] = []
        var rest = Substring(html)
        func appendProse(_ h: Substring) {
            let t = htmlToText(String(h))
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if case .text(let prev)? = segs.last { segs[segs.count - 1] = .text(prev + "\n" + t) } else { segs.append(.text(t)) }
        }
        while let open = rest.range(of: "<table", options: .caseInsensitive) {
            guard let close = matchingTableEnd(rest, from: open.lowerBound) else { break }
            appendProse(rest[rest.startIndex..<open.lowerBound])
            let inner = rest[open.lowerBound..<close]
            if let t = parseHTMLTable(String(inner)) {
                if case .text(let prev)? = segs.last, !prev.hasSuffix("\n") { segs[segs.count - 1] = .text(prev + "\n") }
                segs.append(.table(t))
            } else {
                appendProse(inner)
            }
            rest = rest[close...]
        }
        if !rest.isEmpty {
            let t = htmlToText(String(rest))
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if case .table? = segs.last { segs.append(.text("\n" + t)) } else { appendProse(rest) }
            }
        }
        return segs
    }

    /// The index just past the `</table>` that closes the `<table` at `from` (nested tables counted).
    private static func matchingTableEnd(_ s: Substring, from: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = from
        while i < s.endIndex {
            let tail = s[i...]
            if tail.hasPrefixCI("<table") { depth += 1; i = s.index(i, offsetBy: 6) ; continue }
            if tail.hasPrefixCI("</table") {
                depth -= 1
                guard let gt = tail.firstIndex(of: ">") else { return nil }
                if depth == 0 { return s.index(after: gt) }
                i = s.index(after: gt); continue
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func parseHTMLTable(_ h: String) -> MarkdownTable? {
        // A table with a table inside is layout, not data.
        let opens = h.components(separatedBy: "<table").count - 1 + h.components(separatedBy: "<TABLE").count - 1
        guard opens == 1 else { return nil }
        var rows: [[String]] = []
        var headerRow: Int?
        for m in matches(h, #"<tr\b[^>]*>([\s\S]*?)</tr\s*>"#) {
            var cells: [String] = []
            var sawTH = false
            for c in matchesFull(m, #"<t([hd])\b([^>]*)>([\s\S]*?)</t[hd]\s*>"#) {
                if c.0 == "h" || c.0 == "H" { sawTH = true }
                let span = Int(firstMatch(c.1, #"colspan\s*=\s*["']?(\d+)"#) ?? "") ?? 1
                cells.append(cellText(c.2))
                if span > 1 { cells += Array(repeating: "", count: min(span, 20) - 1) }
            }
            guard !cells.isEmpty else { continue }
            if sawTH && headerRow == nil && rows.isEmpty { headerRow = 0 }
            rows.append(cells)
        }
        guard rows.count >= 1, (rows.map(\.count).max() ?? 0) >= 2 || rows.count >= 2 else { return nil }
        let head = rows[0]
        return MarkdownTable(headers: head, rows: Array(rows.dropFirst()))
    }

    private static func cellText(_ h: String) -> String {
        var t = h.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"</(p|div|li)\s*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        t = stripTags(t)
        t = decodeEntities(t)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Prose HTML → plain text: block ends and `<br>` are line breaks, tags dropped, entities decoded, blank runs folded.
    static func htmlToText(_ h: String) -> String {
        var t = h.replacingOccurrences(of: #"<(script|style|head)\b[\s\S]*?</\1\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"<li\b[^>]*>"#, with: "\n- ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"</(p|div|h[1-6]|li|ul|ol|blockquote|pre|tr|section|article)\s*>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        t = stripTags(t)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
        t = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var t = s
        for (e, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                       ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                       ("&rdquo;", "”"), ("&ldquo;", "“")] {
            t = t.replacingOccurrences(of: e, with: v)
        }
        // numeric entities
        while let r = t.range(of: #"&#(x[0-9A-Fa-f]+|\d+);"#, options: .regularExpression) {
            let body = t[r].dropFirst(2).dropLast()
            let v = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            t.replaceSubrange(r, with: v.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? "")
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    // Small regex helpers.
    private static func matches(_ s: String, _ p: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    private static func matchesFull(_ s: String, _ p: String) -> [(String, String, String)] {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)), ns.substring(with: $0.range(at: 3)))
        }
    }
    private static func firstMatch(_ s: String, _ p: String) -> String? {
        matches(s, p).first
    }
}

private extension Substring {
    func hasPrefixCI(_ p: String) -> Bool {
        guard count >= p.count else { return false }
        return self.prefix(p.count).lowercased() == p
    }
}
