import Foundation

/// A community detected via Louvain clustering over tag co-occurrence.
/// Ephemeral — recomputed on corpus changes, not persisted.
struct Neighborhood: Identifiable, Hashable {
    let id: String
    let memberNodeIDs: [String]
    let centroid: CGPoint
    let memberCount: Int

    static func == (lhs: Neighborhood, rhs: Neighborhood) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Cache container for neighborhood detection results.
struct NeighborhoodCache {
    let neighborhoods: [Neighborhood]
    let nodeToNeighborhoodID: [String: String]
    let corpusFingerprint: String
    let generatedAt: Date

    /// Lookup neighborhood ID for a given node. Returns nil if node is a floater.
    func neighborhoodID(forNodeID nodeID: String) -> String? {
        nodeToNeighborhoodID[nodeID]
    }

    /// Check if cache should be invalidated based on corpus changes.
    func shouldInvalidate(currentFingerprint: String) -> Bool {
        corpusFingerprint != currentFingerprint
    }
}
