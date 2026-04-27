import Foundation

/// Generates Über-node clusters from the corpus.
/// Tier 1: tag-only clustering (no embeddings).
@MainActor
final class UberNodeService {

    /// Generate Über-node clusters by grouping nodes by primary tag.
    /// Uses weighted eligibility: primary members + 0.5 × secondary members >= 2.0
    /// Returns nil if no clusters are viable.
    func generateClusters(from nodes: [Node]) -> UberNodeCache? {
        // Group nodes by their primary tag
        let primaryGroups = Dictionary(grouping: nodes) { node -> String? in
            node.tags.first
        }

        // Build all unique tags present in corpus
        let allTags = Set(nodes.flatMap { $0.tags })

        // For each tag, compute weighted eligibility
        var viableGroups: [(tagName: String, primaryNodes: [Node], effectiveCount: Double)] = []

        for tagName in allTags {
            let primaryNodes = primaryGroups[tagName] ?? []
            let primaryCount = primaryNodes.count

            // Count secondary members: nodes where tagName appears but is NOT primary
            let secondaryCount = nodes.filter { node in
                node.tags.contains(tagName) && node.tags.first != tagName
            }.count

            let effectiveCount = Double(primaryCount) + (Double(secondaryCount) * 0.5)

            // Require both weighted eligibility AND at least 1 primary member to surface
            if effectiveCount >= 2.0 && primaryCount >= 1 {
                viableGroups.append((tagName, primaryNodes, effectiveCount))
            }
        }

        guard !viableGroups.isEmpty else { return nil }

        // Generate clusters (each node appears in exactly one cluster - its primary)
        let clusters: [UberNodeCluster] = viableGroups.map { tagName, primaryNodes, _ in
            // Title shows primary count only (the visible bubble membership)
            let clusterTitle = generateClusterTitle(from: tagName, nodeCount: primaryNodes.count)
            return UberNodeCluster(
                id: UUID().uuidString,
                title: clusterTitle,
                tagName: tagName,
                childNodeIDs: primaryNodes.map { $0.id },
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
    /// Hashes (node.id, node.tags) tuples — changes on add/remove/tag mutations.
    func corpusHash(from nodes: [Node]) -> String {
        let sortedFingerprints = nodes.map { node in
            "\(node.id):\(node.tags.joined(separator: ","))"
        }.sorted().joined(separator: "|")
        return String(sortedFingerprints.hashValue)
    }
}
