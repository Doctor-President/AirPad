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
