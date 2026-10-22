import Foundation

/// In-process assertions for `MarkdownBlockParser`. Mirrors the
/// `EntryMigrationSelfTest` / `UMAPSelfTest` pattern — no XCTest target,
/// returns a one-or-multi-line summary surfaced by `SubstrateInspectView`.
///
/// These encode the CLASSIFICATION-ORDER hazard so a later refactor cannot
/// silently reintroduce it: a bullet whose content is entirely bold must
/// stay a bullet, and a lone `**…**` line must become a heading.
///
/// Coverage:
///   T1 — ordering hazard (Qwen dialect, 3-space bullets)
///   T2 — FM itinerary dialect (`- `, blank line after header)
///   T3 — FM flat list, no header (`* `)
///   T4 — flat prose (the most common real shape) → one paragraph
///   T5 — unclosed fence → one codeBlock, nothing dropped
enum MarkdownBlockParserSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // T1 — ordering hazard. Bold-line header, then two Qwen 3-space
        // bullets, the second entirely bold. The header must NOT be claimed
        // as a bullet (the `\s+` guard); the all-bold bullet must NOT become
        // a heading (classification order). Bullet content must have no
        // leading spaces (`\s+` strip, not `\s`).
        do {
            ran += 1
            let input = [
                "**Northern California (SF Bay Area & Beyond)**",
                "*   **San Francisco:** Walk the Golden Gate Bridge...",
                "*   **Napa/Sonoma Valley**",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .heading(level: 2, text: "Northern California (SF Bay Area & Beyond)"),
                .bullet("**San Francisco:** Walk the Golden Gate Bridge..."),
                .bullet("**Napa/Sonoma Valley**"),
            ]
            if blocks != expected {
                failures.append("T1: \(describe(blocks)) != \(describe(expected))")
            }
            // Specific assertions called out by the brief.
            if case .heading = blocks.first {} else {
                failures.append("T1: element[0] must be .heading, got \(describe1(blocks.first))")
            }
            if blocks.count > 2, case .bullet = blocks[2] {} else {
                failures.append("T1: element[2] must be .bullet, got \(describe1(blocks.count > 2 ? blocks[2] : nil))")
            }
            if blocks.count > 1, case let .bullet(text) = blocks[1],
               text.first == " " {
                failures.append("T1: element[1] has leading spaces: '\(text)'")
            }
        }

        // T2 — FM itinerary dialect: bold-line header, a BLANK line, then two
        // hyphen bullets. Exactly three blocks, NO empty paragraph for the
        // blank, colon survives inside the heading.
        do {
            ran += 1
            let input = [
                "**Day 1: Arrival in Los Angeles**",
                "",
                "- Upon arrival at LAX, check into your hotel.",
                "- Spend the afternoon exploring the Walk of Fame.",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .heading(level: 2, text: "Day 1: Arrival in Los Angeles"),
                .bullet("Upon arrival at LAX, check into your hotel."),
                .bullet("Spend the afternoon exploring the Walk of Fame."),
            ]
            if blocks != expected {
                failures.append("T2: \(describe(blocks)) != \(describe(expected))")
            }
            if blocks.count != 3 {
                failures.append("T2: expected 3 blocks (no empty paragraph), got \(blocks.count)")
            }
            if case let .heading(_, text) = blocks.first, !text.contains(":") {
                failures.append("T2: colon did not survive in heading: '\(text)'")
            }
        }

        // T3 — FM flat list, no header. Two `* ` bullets. The renderer must
        // not assume a heading precedes a list.
        do {
            ran += 1
            let input = [
                "* Oklahoma Route 66 Museum",
                "* Lake Okmulgee",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .bullet("Oklahoma Route 66 Museum"),
                .bullet("Lake Okmulgee"),
            ]
            if blocks != expected {
                failures.append("T3: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T4 — flat prose (the most common real shape). Three sentences
        // wrapped across lines collapse to ONE paragraph, lines joined by a
        // single space.
        do {
            ran += 1
            let input = [
                "California offers a wide range of activities.",
                "You can visit beaches, mountains, and cities.",
                "There is something for everyone.",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .paragraph("California offers a wide range of activities. You can visit beaches, mountains, and cities. There is something for everyone."),
            ]
            if blocks != expected {
                failures.append("T4: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T5 — unclosed fence. Opener, two lines, EOF, no closing fence. One
        // codeBlock containing both lines; nothing dropped.
        do {
            ran += 1
            let input = [
                "```",
                "let x = 1",
                "let y = 2",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .codeBlock("let x = 1\nlet y = 2"),
            ]
            if blocks != expected {
                failures.append("T5: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T6 — duplicate bullets are the SAME value. The parser must still
        // emit two blocks; identity/dedup is not its job (and the ForEach
        // keys on offset so both render). Guards against a future
        // Identifiable/hashValue regression dropping one.
        do {
            ran += 1
            let input = [
                "- Yes",
                "- Yes",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [.bullet("Yes"), .bullet("Yes")]
            if blocks != expected {
                failures.append("T6: \(describe(blocks)) != \(describe(expected))")
            }
            if blocks.count != 2 {
                failures.append("T6: expected 2 blocks for duplicate bullets, got \(blocks.count)")
            }
        }

        // T7 — well-formed pipe table → one .table with split/trimmed cells.
        do {
            ran += 1
            let input = [
                "| Model | Score |",
                "|-------|-------|",
                "| Fable | 0.9 |",
                "| Opus | 0.95 |",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .table(headers: ["Model", "Score"],
                       rows: [["Fable", "0.9"], ["Opus", "0.95"]]),
            ]
            if blocks != expected {
                failures.append("T7: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T8 — ragged row (fewer cells than the header). The parser KEEPS it in
        // the table (rows carry it verbatim); the renderer is what falls back to
        // a plain line. Guards the escape hatch's parser-side input.
        do {
            ran += 1
            let input = [
                "| A | B |",
                "|---|---|",
                "| 1 | 2 |",
                "| 3 |",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .table(headers: ["A", "B"], rows: [["1", "2"], ["3"]]),
            ]
            if blocks != expected {
                failures.append("T8: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T9 — table mid-STREAM must NEVER flash raw pipes. A header row with no
        // separator yet is HELD (no block); a header+separator with no data rows
        // yet is also held (no phantom block). Both resolve on the next pass.
        do {
            ran += 1
            let headerOnly = MarkdownBlockParser.parse("| Model | Score |")
            if !headerOnly.isEmpty {
                failures.append("T9a: header-only must be held, got \(describe(headerOnly))")
            }
            let noRows = MarkdownBlockParser.parse("| Model | Score |\n|---|---|")
            if !noRows.isEmpty {
                failures.append("T9b: header+separator with no rows must be held, got \(describe(noRows))")
            }
        }

        // T10 — a lone pipe INSIDE prose (no leading pipe) must stay a
        // paragraph, never trip the table path.
        do {
            ran += 1
            let input = "Use the A | B operator when either matches."
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .paragraph("Use the A | B operator when either matches."),
            ]
            if blocks != expected {
                failures.append("T10: \(describe(blocks)) != \(describe(expected))")
            }
        }

        // T11 — table directly under a heading (no blank between): heading then
        // table, in order.
        do {
            ran += 1
            let input = [
                "## Results",
                "| A | B |",
                "|---|---|",
                "| 1 | 2 |",
            ].joined(separator: "\n")
            let blocks = MarkdownBlockParser.parse(input)
            let expected: [MarkdownBlock] = [
                .heading(level: 2, text: "Results"),
                .table(headers: ["A", "B"], rows: [["1", "2"]]),
            ]
            if blocks != expected {
                failures.append("T11: \(describe(blocks)) != \(describe(expected))")
            }
        }

        if failures.isEmpty {
            return "MarkdownBlockParser: \(ran)/\(ran) passed"
        } else {
            return "MarkdownBlockParser FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Describe helpers (readable failure messages)

    private static func describe(_ blocks: [MarkdownBlock]) -> String {
        "[" + blocks.map(describe1).joined(separator: ", ") + "]"
    }

    private static func describe1(_ block: MarkdownBlock?) -> String {
        guard let block else { return "nil" }
        switch block {
        case let .heading(level, text): return "heading(\(level), \"\(text)\")"
        case let .paragraph(text):      return "paragraph(\"\(text)\")"
        case let .bullet(text):         return "bullet(\"\(text)\")"
        case let .numbered(index, text): return "numbered(\(index), \"\(text)\")"
        case let .codeBlock(code):      return "codeBlock(\"\(code.replacingOccurrences(of: "\n", with: "\\n"))\")"
        case let .table(headers, rows): return "table(h:\(headers), r:\(rows))"
        }
    }
}

/// live-35 (2) — inline math renders as plain text, dollar amounts never do. Launch arg `-MathTextSelfTest`;
/// RED `-Live34Web YES` (raw `$…$`, as live-34 showed it).
enum MathTextSelfTest {
    static func run() -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ name: String, _ ok: Bool, _ detail: String) { rows.append((name, ok, detail)) }
        func text(_ blocks: [MarkdownBlock]) -> [String] {
            blocks.map {
                switch $0 {
                case let .heading(_, t), let .paragraph(t), let .bullet(t), let .numbered(_, t): return t
                case let .codeBlock(c): return "CODE[" + c + "]"
                case let .table(h, r): return (h + r.flatMap { $0 }).joined(separator: " | ")
                }
            }
        }
        func p(_ s: String, settled: Bool = true) -> [String] { text(MarkdownBlockParser.parse(s, settled: settled)) }

        // T's three lines (TF 202610220047, the server's working for "how many days")
        let t = p("- October: $31 - 6 = 25$ days\n- Months since: $25 + 30 + 31 + 31 + 30 + 22 = 169$\n- Total: $365 + 169 =$ **534 days**")
        row("T's-working-without-dollar-signs", t == ["October: 31 - 6 = 25 days", "Months since: 25 + 30 + 31 + 31 + 30 + 22 = 169",
                                                      "Total: 365 + 169 = **534 days**"], t.joined(separator: " ¶ "))
        // Dollar amounts are never math.
        let money = ["$5 and $10", "it costs $1,200.", "between $5-$10 a month, or $50/$100 a year", "US$5 or US$10"]
        let m = money.flatMap { p($0) }
        row("dollar-amounts-unchanged", m == money, m.joined(separator: " ¶ "))
        // A Library answer with a price (the corpus path renders through the same parser).
        let lib = "The lamp in **Living room ideas** costs $45 [1], and the shade is $12.50 — $57.50 in all [2]."
        row("library-answer-with-a-price-unchanged", p(lib) == [lib], p(lib).joined())
        // Display blocks: simple → a paragraph of plain text; complex → a monospaced block.
        let d = p("The total:\n\n$$\n365 + 169 = 534\n$$\n\nand\n\n\\[ \\frac{a}{b} \\times 2 \\]\n\n$$\\int_0^1 x\\,dx$$")
        row("display-blocks", d == ["The total:", "365 + 169 = 534", "and", "a/b × 2", "CODE[\\int_0^1 x\\,dx]"], d.joined(separator: " ¶ "))
        // Common commands → their symbols; \( … \) too.
        let c = p("$2 \\times 3 \\div 4 \\cdot 5$, $a \\le b \\ge c \\neq d \\approx e \\pm f$, $x^2 + y^3$, $\\sqrt{16} = 4$, "
                  + "$\\frac{1}{2}$, $\\text{days} = 534$ and \\(3 \\times 4 = 12\\)")
        row("commands-mapped", c == ["2 × 3 ÷ 4 · 5, a ≤ b ≥ c ≠ d ≈ e ± f, x² + y³, √16 = 4, 1/2, days = 534 and 3 × 4 = 12"], c.joined())
        // Anything more complex → a code span (monospaced), never raw `$`; a code span stays as written.
        let x = p("Area: $\\int_0^1 f(x)\\,dx$; shell: `echo $HOME$`")
        row("complex-→-monospaced-code-stays", x == ["Area: `\\int_0^1 f(x)\\,dx`; shell: `echo $HOME$`"], x.joined())
        // A table cell.
        let tb = p("| Step | Working |\n|---|---|\n| 1 | $31 - 6 = 25$ |")
        row("table-cell", tb == ["Step | Working | 1 | 31 - 6 = 25"], tb.joined())
        // Streaming: every prefix of the answer, as the tail parses it — math appears once its closing `$` is confirmed
        // and never flips back; "$5 and $1…" never becomes math.
        func stream(_ full: String, final: String, inlineCloser: Bool) -> (ok: Bool, detail: String) {
            var converted = false, flips = 0, early = 0
            let ch = Array(full)
            for k in 1...ch.count {
                let s = String(ch[0..<k]), out = p(s, settled: false).joined(separator: " ¶ ")
                let isMath = !out.contains("$") && s.contains("$")
                if converted && !isMath { flips += 1 }
                if inlineCloser && isMath && s.hasSuffix("$") { early += 1 }   // a closing `$` that is the last character must wait
                converted = converted || isMath
            }
            let last = p(full).joined()
            return (flips == 0 && early == 0 && last == final, "flips=\(flips) early=\(early) final=\(last)")
        }
        let s1 = stream("So $31 - 6 = 25$ days.", final: "So 31 - 6 = 25 days.", inlineCloser: true)
        var s2ok = true
        for k in 1...10 { if p(String(Array("$5 and $10.")[0..<k]), settled: false).joined().contains("5 and") && !p(String(Array("$5 and $10.")[0..<k]), settled: false).joined().contains("$") { s2ok = false } }
        let s3 = stream("Intro.\n\n$$\n365 + 169 = 534\n$$\n\nDone.", final: "Intro.365 + 169 = 534Done.", inlineCloser: false)
        let held = p("Intro.\n\n$$\n365 + 169", settled: false)
        row("streaming-no-flicker", s1.ok && s2ok && s3.ok && held == ["Intro."],
            "\(s1.detail) · money=\(s2ok) · display \(s3.detail) · held=\(held)")

        let passed = rows.filter(\.1).count
        let lines = rows.map { "\($0.1 ? "✓" : "✗") \($0.0) — \($0.2)" }.joined(separator: "\n")
        return "\(passed == rows.count ? "PASS" : "FAIL") — \(passed)/\(rows.count)\(Live35.red ? " (RED: -Live34Web)" : "")\n\(lines)"
    }
}
