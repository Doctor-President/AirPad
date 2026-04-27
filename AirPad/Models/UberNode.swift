import Foundation

/// Ephemeral clustering result — Tier 1 Über-nodes generated from tag affinity.
/// Not a permanent corpus object; regenerated on invalidation.
struct UberNodeCluster: Codable, Identifiable, Hashable {
    let id: String
    let title: String           // Generated from tag name
    let tagName: String         // Primary tag that defines this cluster
    let childNodeIDs: [String]  // Member node IDs
    let generatedAt: Date       // Cache timestamp
    let corpusHash: String      // Invalidation fingerprint

    static func == (lhs: UberNodeCluster, rhs: UberNodeCluster) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Cache container for Über-node clustering results.
struct UberNodeCache: Codable {
    var clusters: [UberNodeCluster]
    var nodeCountAtGeneration: Int  // Diagnostic only
    var generatedAt: Date

    /// Check if cache should be invalidated.
    /// Returns true if current corpus fingerprint differs from any cluster's stored hash.
    func shouldInvalidate(currentFingerprint: String) -> Bool {
        guard let firstCluster = clusters.first else { return true }
        return firstCluster.corpusHash != currentFingerprint
    }
}
