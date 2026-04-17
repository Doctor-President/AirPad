import Foundation

/// Shared batch-text parser. Used by the main app (ImportIdeasSheet) and the share extension.
///
/// Format-aware: detects bullet lists, numbered lists, bare-line brainstorm dumps, dated entries,
/// and prose paragraphs. Segments mixed documents into format regions and applies the appropriate
/// split rule per region before the character-threshold and heuristic-fragment gates.
enum BatchParser {

    static let maxNodes = 200
    static let minChars = 50

    // MARK: - Public API

    /// Returns cleaned candidate blocks, heuristic fragments, and their total detected count.
    /// Main-app entry point — heuristic failures routed to review queue by CorpusStore.
    static func partitionBlocks(text: String) -> (candidates: [String], fragments: [String]) {
        let blocks = extractBlocks(from: text)
        var candidates: [String] = []
        var fragments: [String] = []
        for block in blocks {
            if isFragment(block) { fragments.append(block) }
            else { candidates.append(block) }
        }
        return (Array(candidates.prefix(maxNodes)), fragments)
    }

    /// Returns Node objects from pre-filtered text blocks.
    static func makeNodes(texts: [String], importTimestamp: String) -> [Node] {
        let source = "import-\(importTimestamp)"
        let now = Date()
        return texts.map { blockText in
            let nodeID = UUID().uuidString
            let item = NodeItem(
                id: UUID().uuidString,
                type: .text,
                createdAt: now,
                content: blockText
            )
            return Node(
                id: nodeID,
                createdAt: now,
                updatedAt: now,
                title: "",
                summary: "",
                tags: [],
                items: [item],
                needsAIProcessing: true,
                source: source
            )
        }
    }

    /// Convenience wrapper for the share extension (no review-queue routing needed there).
    static func parse(text: String, importTimestamp: String) -> [Node] {
        let (candidates, _) = partitionBlocks(text: text)
        return makeNodes(texts: candidates, importTimestamp: importTimestamp)
    }

    /// Live preview count for ImportIdeasSheet — uses the same extraction logic.
    static func detectedCount(text: String) -> Int {
        extractBlocks(from: text).count
    }

    // MARK: - Format-aware block extraction

    private enum Format {
        case bulletList     // lines starting with - • * –
        case numberedList   // lines starting with 1. 2) etc.
        case bareLineList   // short lines (≤ 80 chars), no blank separators, non-sentence
        case prose          // everything else — double-break paragraph
    }

    /// Core extraction: split text into format regions and expand each region into blocks.
    static func extractBlocks(from text: String) -> [String] {
        // Paragraph regions are separated by one or more blank lines.
        let paragraphs = text.components(separatedBy: "\n\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        var blocks: [String] = []
        for paragraph in paragraphs {
            let lines = paragraph
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            switch detectFormat(lines: lines) {
            case .bulletList:
                for line in lines {
                    let clean = stripBulletPrefix(line)
                    let block = stripDatePrefix(from: clean)
                    if block.count >= minChars { blocks.append(block) }
                }
            case .numberedList:
                for line in lines {
                    let clean = stripNumberedPrefix(line)
                    let block = stripDatePrefix(from: clean)
                    if block.count >= minChars { blocks.append(block) }
                }
            case .bareLineList:
                for line in lines {
                    let block = stripDatePrefix(from: line)
                    if block.count >= minChars { blocks.append(block) }
                }
            case .prose:
                // Rejoin wrapped lines and treat the paragraph as one block.
                let joined = lines.joined(separator: " ")
                let block = stripDatePrefix(from: joined)
                if block.count >= minChars { blocks.append(block) }
            }
        }
        return blocks
    }

    // MARK: - Format detection

    private static func detectFormat(lines: [String]) -> Format {
        // Bullet: every line starts with a bullet marker
        if lines.allSatisfy({ isBulletLine($0) }) { return .bulletList }

        // Numbered: every line starts with a number+separator
        if lines.allSatisfy({ isNumberedLine($0) }) { return .numberedList }

        // Bare line brainstorm: ≥ 2 lines, all ≤ 80 chars, and NOT all sentence-ending.
        // "All sentence-ending" signals wrapped prose rather than a rapid-fire idea dump.
        if lines.count >= 2 && lines.allSatisfy({ $0.count <= 80 }) {
            let sentenceEnders: Set<Character> = [".", "?", "!"]
            let allSentenceEnding = lines.allSatisfy { !$0.isEmpty && sentenceEnders.contains($0.last!) }
            if !allSentenceEnding { return .bareLineList }
        }

        return .prose
    }

    private static func isBulletLine(_ line: String) -> Bool {
        line.range(of: "^[-•*–]\\s", options: .regularExpression) != nil
    }

    private static func isNumberedLine(_ line: String) -> Bool {
        line.range(of: "^\\d+[.)\\s]\\s*\\S", options: .regularExpression) != nil
    }

    // MARK: - Prefix stripping

    private static func stripBulletPrefix(_ text: String) -> String {
        text.replacingOccurrences(of: "^[-•*–]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripNumberedPrefix(_ text: String) -> String {
        text.replacingOccurrences(of: "^\\d+[.)\\s]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Strips leading date prefixes before processing a block.
    /// Matches: 11/03, 11-03, 2024-11-03, Nov 3, November 3, Nov 3 2024 — followed by — – - or :
    static func stripDatePrefix(from text: String) -> String {
        let pattern = "^(\\d{4}[/\\-]\\d{2}[/\\-]\\d{2}|\\d{1,2}[/\\-]\\d{1,2}([/\\-]\\d{2,4})?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{1,2}(?:,?\\s+\\d{4})?)\\s*[—\\-–:]\\s*"
        let result = text.replacingOccurrences(of: pattern, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        return result == text ? text : result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Heuristic fragment detection

    static func isFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) { return true }
        }

        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) { return true }
        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) { return true }

        if words.count <= 5 && (text.hasSuffix("!") || text.hasSuffix("!!")) { return true }

        return false
    }

    // MARK: - Fragment signal sets

    private static let reactionWords: Set<String> = [
        "lol", "haha", "hahaha", "omg", "wtf", "wow", "damn", "lmao",
        "smh", "ffs", "bruh", "yikes", "oof", "ngl", "omfg", "rofl"
    ]

    private static let apologyPhrases = [
        "sorry", "my bad", "apologies", "forgive me", "excuse me",
        "i apologize", "i'm sorry", "so sorry"
    ]

    private static let reactionPhrases = [
        "wait what", "no way", "oh no", "oh wow", "oh man", "oh my",
        "that's crazy", "that is crazy", "can't believe", "cannot believe",
        "holy shit", "holy crap", "what the hell", "what the heck"
    ]
}
