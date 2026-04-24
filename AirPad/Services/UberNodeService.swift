import Foundation

/// Generates Über-node clusters from the corpus.
/// Tier 1: tag-only clustering (no embeddings).
@MainActor
final class UberNodeService {

    /// Generate Über-node clusters by grouping nodes by primary tag.
    /// Returns nil if no clusters are viable (fewer than 2 nodes share any tag).
    func generateClusters(from nodes: [Node]) -> UberNodeCache? {
        // Group nodes by their primary tag
        let tagGroups = Dictionary(grouping: nodes) { node -> String? in
            node.tags.first
        }

        // Filter out untagged nodes and groups with only 1 member
        let viableGroups = tagGroups
            .filter { key, nodes in key != nil && nodes.count >= 2 }
            .map { (key: $0.key!, value: $0.value) }

        guard !viableGroups.isEmpty else { return nil }

        // Generate clusters
        let clusters: [UberNodeCluster] = viableGroups.map { tagName, groupNodes in
            let clusterTitle = generateClusterTitle(from: tagName, nodeCount: groupNodes.count)
            return UberNodeCluster(
                id: UUID().uuidString,
                title: clusterTitle,
                tagName: tagName,
                childNodeIDs: groupNodes.map { $0.id },
                generatedAt: Date(),
                corpusHash: corpusHash(from: nodes)
            )
        }

        return UberNodeCache(
            clusters: clusters,
            nodeCountAtGeneration: nodes.count,
            generatedAt: Date()
        )
    }

    // MARK: - Helpers

    /// Generate a human-readable cluster title from a tag name.
    /// Examples: "work" → "Work Ideas", "travel" → "Travel Notes"
    private func generateClusterTitle(from tagName: String, nodeCount: Int) -> String {
        let capitalized = tagName.prefix(1).uppercased() + tagName.dropFirst()
        return "\(capitalized) (\(nodeCount))"
    }

    /// Compute a fingerprint of the corpus for cache invalidation.
    /// Simple hash of node IDs — changes when nodes are added/removed.
    private func corpusHash(from nodes: [Node]) -> String {
        let sortedIDs = nodes.map { $0.id }.sorted().joined()
        return String(sortedIDs.hashValue)
    }
}
