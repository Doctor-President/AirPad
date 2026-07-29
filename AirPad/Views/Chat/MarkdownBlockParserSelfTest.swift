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
