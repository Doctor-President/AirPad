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
    /// SB137 Stage A — node IDs that landed in sub-threshold Louvain clusters
    /// and failed isolate routing (no substantive neighborhood passed the 0.20
    /// cosine threshold, or the node has no `contentEmbedding`).
    let unattachedNodeIDs: [String]
    /// SB137 Stage A — diagnostic snapshot of the routing pass: per-isolate
    /// best cosine, in-cluster sanity sample, and counts. Used to pick an
    /// empirical cosine threshold and to dump a sidecar JSON after a
    /// re-cluster. Nil when routing was skipped (no isolates).
    let routingDiagnostics: RoutingDiagnostics?
    let corpusFingerprint: String
    let generatedAt: Date

    /// Lookup neighborhood ID for a given node. Returns nil if node is unattached.
    func neighborhoodID(forNodeID nodeID: String) -> String? {
        nodeToNeighborhoodID[nodeID]
    }

    /// Check if cache should be invalidated based on corpus changes.
    func shouldInvalidate(currentFingerprint: String) -> Bool {
        corpusFingerprint != currentFingerprint
    }
}

/// SB137 Stage A — captured during isolate routing so the cosine distribution
/// can be inspected post-hoc and the threshold tuned empirically. Persisted
/// alongside `corpus_index.json` as `corpus_routing_diagnostics.json` and
/// echoed to console on every refresh.
struct RoutingDiagnostics: Codable {
    let generatedAt: Date
    let thresholdUsed: Double
    let totalIsolates: Int
    let isolatesWithEmbedding: Int
    let isolatesNoEmbedding: Int
    let routableTargetCount: Int
    /// Per-isolate best-match cosine (only nodes that had an embedding and at
    /// least one routable target). Sorted descending by cosine.
    let isolateBestCosines: [IsolateCosineSample]
    /// Per substantive cluster, sample of member-node cosines against that
    /// cluster's own description embedding. Sanity benchmark — distribution
    /// should sit above the routing threshold.
    let inClusterCosines: [InClusterCosineSample]

    struct IsolateCosineSample: Codable {
        let nodeID: String
        let bestCommunityID: String
        let bestCosine: Double

        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id"
            case bestCommunityID = "best_community_id"
            case bestCosine = "best_cosine"
        }
    }

    struct InClusterCosineSample: Codable {
        let communityID: String
        let nodeID: String
        let cosine: Double

        enum CodingKeys: String, CodingKey {
            case communityID = "community_id"
            case nodeID = "node_id"
            case cosine
        }
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case thresholdUsed = "threshold_used"
        case totalIsolates = "total_isolates"
        case isolatesWithEmbedding = "isolates_with_embedding"
        case isolatesNoEmbedding = "isolates_no_embedding"
        case routableTargetCount = "routable_target_count"
        case isolateBestCosines = "isolate_best_cosines"
        case inClusterCosines = "in_cluster_cosines"
    }
}
