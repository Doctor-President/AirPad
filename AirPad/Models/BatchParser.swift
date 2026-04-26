import Foundation

/// Shared batch-text parser. Used by the main app (ImportIdeasSheet) and the share extension.
enum BatchParser {

    static let maxNodes = 200
    static let minChars = 50

    // MARK: - Public API

    /// Splits raw text into Node objects ready for import.
    /// Applies character threshold and heuristic fragment filter.
    /// Used by the share extension (no model coherence check available there).
    /// Returns at most `maxNodes` nodes.
    static func parse(text: String, importTimestamp: String) -> [Node] {
        let (candidates, _) = partitionBlocks(text: text)
        return makeNodes(texts: candidates, importTimestamp: importTimestamp)
    }

    /// Partitions raw text into candidate blocks (pass heuristics) and fragment blocks (fail).
    /// The main app uses this so heuristic failures can be routed to the review queue.
    static func partitionBlocks(text: String) -> (candidates: [String], fragments: [String]) {
        let stripped = text
            .components(separatedBy: "\n\n")
            .map { block -> String in
                block
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[\\-•\\*]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { $0.count >= minChars }

        var candidates: [String] = []
        var fragments: [String] = []
        for block in stripped {
            if isFragment(block) { fragments.append(block) }
            else { candidates.append(block) }
        }
        return (Array(candidates.prefix(maxNodes)), fragments)
    }

    /// Constructs Node objects from pre-filtered text blocks.
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

    /// Returns the number of parseable blocks (≥ minChars) without applying the cap.
    static func detectedCount(text: String) -> Int {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minChars }
            .count
    }

    // MARK: - Layer 0: Structural normalization

    enum Layer0Result {
        case pass(String)           // normalized text ready for L1
        case filteredSeparator      // separator-only line (---, ===, etc.)
        case filteredEmpty          // empty after normalization
    }

    // MARK: - Layer 1: Classification labels

    enum LengthBucket: String {
        case micro = "micro"             // 1-10
        case short = "short"             // 11-50
        case medium = "medium"           // 51-200
        case long = "long"               // 201-500
        case veryLong = "very_long"      // >500
    }

    enum Format: String {
        case prose = "prose"
        case fragment = "fragment"
        case listItem = "list_item"
        case url = "url"
        case hashtag = "hashtag"
        case dateOnly = "date_only"
        case code = "code"
        case header = "header"
        case parenthetical = "parenthetical"
        case bracketedMetadata = "bracketed_metadata"
    }

    enum Completeness: String {
        case terminalPunct = "terminal_punct"
        case noTerminal = "no_terminal"
    }

    enum Capitalization: String {
        case startsCapital = "starts_capital"
        case startsLower = "starts_lower"
        case nonAlpha = "non_alpha"
    }

    struct Layer1Labels {
        let lengthBucket: LengthBucket
        let format: Format
        let completeness: Completeness
        let capitalization: Capitalization
    }

    /// Layer 1 classification: analyzes normalized text and returns structural labels.
    /// No pass/fail decision - just classification.
    static func classifyLayer1(_ text: String) -> Layer1Labels {
        let length = text.count

        // Length bucket
        let lengthBucket: LengthBucket
        switch length {
        case 1...10: lengthBucket = .micro
        case 11...50: lengthBucket = .short
        case 51...200: lengthBucket = .medium
        case 201...500: lengthBucket = .long
        default: lengthBucket = .veryLong
        }

        // Format detection (regex/structural)
        let format: Format
        if text.hasPrefix("#") && !text.contains(" ") {
            format = .hashtag
        } else if text.hasPrefix("[") && text.hasSuffix("]") {
            format = .bracketedMetadata
        } else if text.hasPrefix("(") && text.hasSuffix(")") {
            format = .parenthetical
        } else if text.hasPrefix("#") && text.contains(" ") {
            format = .header  // markdown header
        } else if text.range(of: "^(https?://|www\\.)", options: .regularExpression) != nil {
            format = .url
        } else if text.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil {
            format = .listItem
        } else if text.range(of: "^\\d{1,2}/\\d{1,2}(/\\d{2,4})?$", options: .regularExpression) != nil {
            format = .dateOnly
        } else if text.range(of: "^```|^\\s{4,}|^\\t", options: .regularExpression) != nil {
            format = .code
        } else if isFragment(text) {
            format = .fragment
        } else {
            format = .prose
        }

        // Completeness - check for terminal punctuation
        let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
        let completeness: Completeness = text.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
            ? .terminalPunct
            : .noTerminal

        // Capitalization - check first character
        let capitalization: Capitalization
        if let first = text.first {
            if first.isUppercase {
                capitalization = .startsCapital
            } else if first.isLowercase {
                capitalization = .startsLower
            } else {
                capitalization = .nonAlpha
            }
        } else {
            capitalization = .nonAlpha
        }

        return Layer1Labels(
            lengthBucket: lengthBucket,
            format: format,
            completeness: completeness,
            capitalization: capitalization
        )
    }

    /// Layer 0 normalization: filters separators and normalizes whitespace.
    /// A line is a separator if and only if, after stripping whitespace,
    /// it contains exclusively characters from {-, =, *, _} and is ≥3 chars.
    static func normalizeLayer0(_ text: String) -> Layer0Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty after trimming
        guard !trimmed.isEmpty else {
            return .filteredEmpty
        }

        // Check if separator-only (≥3 chars, exclusively from {-, =, *, _})
        if trimmed.count >= 3 {
            let separatorSet = CharacterSet(charactersIn: "-=*_")
            let allCharactersAreSeparators = trimmed.unicodeScalars.allSatisfy { separatorSet.contains($0) }
            if allCharactersAreSeparators {
                return .filteredSeparator
            }
        }

        return .pass(trimmed)
    }

    // MARK: - Heuristic fragment detection

    /// Returns true if the block looks like a fragment (pure reaction, apology, exclamation)
    /// rather than a complete standalone idea.
    static func isFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        // Short blocks (< 10 words) containing a pure reaction word
        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) {
                return true
            }
        }

        // Starts with an apology phrase
        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        // Starts with a pure reaction phrase
        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        // Short exclamation (≤ 5 words, ends with ! or !!)
        if words.count <= 5 && (text.hasSuffix("!") || text.hasSuffix("!!")) {
            return true
        }

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
