import SwiftUI
import UIKit

#if DEBUG
/// live-26 (3f) — synthetic answer tables (never T's chats): 2 × 3, a presidents-shaped 5 × 46 (fictional names; irregular
/// pipes — no spaces, trailing spaces, one row missing its closing pipe —, a "22/24" cell, empty cells, an escaped pipe),
/// 8 × 10, and a 1-column table. Shared by `-ChatTableSelfTest` and the `-RenderTableAnswer` stills.
enum ChatTableFixtures {
    static let twoByThree = """
    | Tide | Height |
    |---|---|
    | Low | 0.4 m |
    | High | 4.1 m |
    | Spring low | 0.1 m |
    """

    static var presidents: String {
        let first = ["Ada", "Bram", "Cora", "Dell", "Edda", "Finn", "Greta", "Hal", "Ines", "Jory", "Kit", "Lena", "Moss", "Nell",
                     "Otto", "Pia", "Quin", "Rhea", "Sol", "Tamsin", "Ulf", "Vera", "Wynn"]
        let last = ["Marlow", "Penrose", "Quayle", "Ashby", "Thorne", "Vale", "Crane", "Holloway", "Fenwick", "Larch"]
        let parties = ["Harbour", "Ridge", "Tide", "Lantern"]
        let causes = ["Congestive heart failure", "Pneumonia", "Stroke", "Old age", "Tuberculosis", "Heart attack"]
        var lines = ["| # | President | Party | Term | Cause of death |", "|---|---|:---|---|---|"]
        var n = 1, i = 0
        while lines.count < 48 {
            if n == 24 { n += 1; continue }
            let name = "\(first[i % first.count]) \(last[(i * 3) % last.count])"
            let start = 1789 + i * 5
            let term = "\(start)–\(start + 4)"
            let num = n == 22 ? "22/24" : "\(n)"
            let cause = i >= 40 ? "" : causes[i % causes.count]
            switch i {
            case 6:  lines.append("|\(num)|\(name)|\(parties[i % 4])|\(term)|\(cause)|")                 // no spaces
            case 11: lines.append("| \(num) | \(name) | \(parties[i % 4]) | \(term) | \(cause) |   ")     // trailing spaces
            case 29: lines.append("| \(num) | \(name) | \(parties[i % 4]) | \(term) | \(cause)")         // no closing pipe
            case 33: lines.append("| \(num) | \(name) \\| acting | \(parties[i % 4]) | \(term) | \(cause) |") // escaped pipe
            default: lines.append("| \(num) | \(name) | \(parties[i % 4]) | \(term) | \(cause) |")
            }
            n += 1; i += 1
        }
        return lines.joined(separator: "\n")
    }

    static var eightByTen: String {
        let h = ["Day", "Low", "High", "Wind", "Swell", "Water °C", "Air °C", "Notes"]
        var lines = ["| " + h.joined(separator: " | ") + " |", "|" + h.map { _ in "---" }.joined(separator: "|") + "|"]
        for d in 1...10 {
            lines.append("| Oct \(d) | 0\(d % 9).\(d)0 | 1\(d % 9):\(d % 6)5 | \(8 + d % 7) kn SW | \(1 + d % 3).\(d % 9) m | \(14 - d % 3) | \(17 - d % 4) | \(d % 3 == 0 ? "Fog early, clear by noon" : "Fair") |")
        }
        return lines.joined(separator: "\n")
    }

    /// live-27 (4c) — a table whose last column wraps (long notes) while the first ones are short: the rows grow, the
    /// visible cells sit at the top of theirs (the stills check it reads as intended). Stills only (`-RenderTableAnswer wrap`).
    static let wrapping = """
    | Pool | Depth | Found | Notes |
    |---|---|---|---|
    | North 1 | 0.4 m | Anemones | Two beadlet anemones on the west wall, one closed; a shore crab under the ledge that ran when the light reached it |
    | North 2 | 0.7 m | Blenny | Fast |
    | North 3 | 0.2 m | Limpets | A dozen on the rim, none in the water; the pool was warm by noon and smelled of weed, and a gull had been at the edge |
    | Slipway | 1.1 m | Wrack | Bladder wrack only |
    """

    static let oneColumn = """
    | Packing |
    |---|
    | Waders |
    | Head torch |
    | Tide table |
    """

    static let all: [(name: String, md: String)] = [("2x3", twoByThree), ("5x46", presidents), ("8x10", eightByTen), ("1col", oneColumn)]
}

/// `-ChatTableSelfTest`.
enum ChatTableSelfTest {
    @MainActor static func run() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func table(_ md: String) -> (headers: [String], rows: [[String]])? {
            let blocks = MarkdownBlockParser.parse("An answer.\n\n" + md + "\n\nAfter.")
            for b in blocks { if case let .table(h, r) = b { return (h, r) } }
            return nil
        }
        row("tables-render-as-a-grid-not-stacked-records", MarkdownBlockView.tablePresentation == .grid)
        let shapes = ChatTableFixtures.all.map { f in (f.name, table(f.md)) }
        let dims = shapes.map { "\($0.0)=\($0.1.map { "\($0.headers.count)x\($0.rows.count)" } ?? "none")" }
        row("every-fixture-parses-whole (2x3 · 5x46 · 8x10 · 1x3)", dims == ["2x3=2x3", "5x46=5x46", "8x10=8x10", "1col=1x3"],
            dims.joined(separator: " "))
        if let p = table(ChatTableFixtures.presidents), p.rows.count == 46 {
            let t = ChatTable(headers: p.headers, rows: p.rows)
            row("irregular-pipes-still-five-cells", t.rows.allSatisfy { $0.count == 5 } && p.rows[6].count == 5 && p.rows[29].count == 5,
                "row7=\(p.rows[6]) row30=\(p.rows[29])")
            row("22/24-cell-and-empty-cells-kept", p.rows[21][0] == "22/24" && p.rows.suffix(5).allSatisfy { $0[4].isEmpty },
                "\(p.rows[21])")
            row("escaped-pipe-stays-in-its-cell", p.rows[33][1].hasSuffix("| acting") && p.rows[33].count == 5, "\(p.rows[33])")
            row("voiceover-reads-a-row-as-a-record", t.spokenRow(0).hasPrefix("#: 1, President: ") && !t.spokenRow(45).contains("Cause of death"),
                t.spokenRow(45))
            row("copy-as-csv-quotes-what-needs-it", t.csv.hasPrefix("#,President,Party,Term,Cause of death\r\n1,")
                && t.csv.components(separatedBy: "\r\n").count == 47, String(t.csv.prefix(120)))
            let back = MarkdownBlockParser.parse(t.markdown)
            if case let .table(h2, r2)? = back.first { row("copy-as-markdown-round-trips", h2 == t.headers && r2 == t.rows) }
            else { row("copy-as-markdown-round-trips", false, "didn't parse back") }
            let w = t.columnWidths(font: .systemFont(ofSize: 17))
            row("column-widths-fit-then-wrap (44…220 pt)", w.count == 5 && w.allSatisfy { $0 >= 44 && $0 <= 220 } && w[0] < w[1], "\(w)")
        } else {
            row("irregular-pipes-still-five-cells", false, "the 5 × 46 table didn't parse whole: \(table(ChatTableFixtures.presidents).map { "\($0.rows.count) rows" } ?? "none")")
        }
        // live-27 (4c) — a table narrower than the answer fills its width (the extra shared by the columns); a wider one
        // fades the side(s) it can scroll to (the leading fade starts after the pinned first column).
        let filled = ChatTable.fill([60, 100, 40], to: 400)
        row("a-narrow-table-fills-the-answer-width", abs(filled.reduce(0, +) - 400) < 0.5 && filled[1] > filled[0] && filled[0] > 60,
            "\(filled)")
        row("a-wide-table-keeps-its-widths", ChatTable.fill([300, 300], to: 400) == [300, 300])
        let E = ChatTableView.fadeEdges
        row("fade-on-the-side(s)-that-can-scroll", E(0, 400, 900) == (false, true) && E(200, 400, 900) == (true, true)
            && E(500, 400, 900) == (true, false) && E(0, 400, 400) == (false, false))
        let half = MarkdownBlockParser.parse("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4")
        if case let .table(_, r)? = half.first { row("a-half-arrived-last-row-is-held-mid-stream", r.count == 1, "\(r)") }
        else { row("a-half-arrived-last-row-is-held-mid-stream", false, "\(half)") }
        return "[ChatTableSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
