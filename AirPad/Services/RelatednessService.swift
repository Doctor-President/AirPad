import Foundation

/// Computes node relatedness based on TF-IDF-weighted tag overlap.
@MainActor
final class RelatednessService {

    /// Returns the top N related nodes for a given source node, ranked by TF-IDF tag overlap score.
    ///
    /// - Parameters:
    ///   - nodeID: The ID of the source node to find related nodes for.
    ///   - nodes: The complete corpus of nodes.
    ///   - limit: Maximum number of related nodes to return (default 5).
    /// - Returns: Array of tuples (nodeID, score) sorted by score descending.
    func topRelated(
        forNodeID nodeID: String,
        in nodes: [Node],
        limit: Int = 5
    ) -> [(nodeID: String, score: Double)] {

        // Find source node
        guard let sourceNode = nodes.first(where: { $0.id == nodeID }) else {
            return []
        }

        // If source has no tags, no relatedness can be computed
        guard !sourceNode.tags.isEmpty else {
            return []
        }

        // Compute tag frequency map across corpus
        var tagFrequency: [String: Int] = [:]
        for node in nodes {
            for tag in node.tags {
                tagFrequency[tag, default: 0] += 1
            }
        }

        // Compute relatedness scores for all other nodes
        var scores: [(nodeID: String, score: Double)] = []

        for node in nodes {
            // Skip self
            guard node.id != nodeID else { continue }

            // Find shared tags
            let sharedTags = Set(sourceNode.tags).intersection(Set(node.tags))

            // Sum rarity weights for shared tags
            var relatedScore: Double = 0.0
            for tag in sharedTags {
                if let freq = tagFrequency[tag], freq > 0 {
                    // Rarity weight = 1 / log(1 + frequency)
                    let rarityWeight = 1.0 / log(1.0 + Double(freq))
                    relatedScore += rarityWeight
                }
            }

            // Only include nodes with non-zero scores
            if relatedScore > 0 {
                scores.append((nodeID: node.id, score: relatedScore))
            }
        }

        // Sort by score descending, take top N
        scores.sort { $0.score > $1.score }
        return Array(scores.prefix(limit))
    }
}
