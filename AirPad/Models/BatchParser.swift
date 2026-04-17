import Foundation

/// Shared batch-text parser. Used by the main app (ImportIdeasSheet) and the share extension.
enum BatchParser {

    static let maxNodes = 200

    /// Splits raw text into Node objects ready for import.
    /// Returns at most `maxNodes` nodes; call `wouldTruncate(text:)` to warn beforehand.
    static func parse(text: String, importTimestamp: String) -> [Node] {
        let source = "import-\(importTimestamp)"
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { block -> String in
                // Strip leading bullet characters
                let stripped = block
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[\\-•\\*]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped
            }
            .filter { $0.count >= 20 }

        let capped = Array(blocks.prefix(maxNodes))
        let now = Date()

        return capped.map { blockText in
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

    /// Returns the number of parseable blocks without applying the cap.
    static func detectedCount(text: String) -> Int {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
            .count
    }
}
