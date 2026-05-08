import Foundation

/// Generates neighborhoods from tag co-occurrence graph using Louvain community detection.
/// Phase A: math-only clustering before semantic placement. No model invocation.
@MainActor
final class NeighborhoodService {

    /// SB137 Stage A — minimum cluster size threshold for isolate routing.
    /// Sub-threshold cluster members get routed by content-embedding cosine.
    static func minClusterSize(forNodeCount n: Int) -> Int {
        max(4, Int((Double(n) / 40.0).rounded(.up)))
    }

    /// SB137 Stage A — cosine threshold for isolate-to-neighborhood routing.
    /// Externalized as a constant for easy tuning post-shipping.
    /// Empirical basis (post-backfill pass 2): isolate p25=0.072 (noise floor),
    /// isolate p50=0.242, in-cluster p75=0.260. 0.20 sits above noise, below
    /// in-cluster p75, and routes meaningfully more than half of the isolate
    /// pool without demanding genuine-cluster-strength similarity.
    static let cosineRouteThreshold: Double = 0.20

    /// Generate neighborhoods from corpus using Louvain method.
    /// Returns nil if corpus is too small or has no tagged nodes.
    /// `previousMembers` maps persisted neighborhood IDs to their member node IDs;
    /// used to keep cluster identity stable across runs via Jaccard matching.
    /// `persistedDescriptionEmbeddings` (SB137 Stage A) supplies per-neighborhood
    /// description vectors for the isolate routing step.
    func generateNeighborhoods(
        from nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        previousMembers: [String: Set<String>] = [:],
        persistedDescriptionEmbeddings: [String: [Float]] = [:]
    ) -> NeighborhoodCache? {
        // Edge case: empty or trivial corpus
        guard nodes.count >= 2 else { return nil }

        // Skip compute if too few nodes have tags (avoids singleton explosion at startup)
        let taggedNodeCount = nodes.filter { !$0.tags.isEmpty }.count
        guard taggedNodeCount >= 5 else {
            print("[Neighborhood] Skipping compute — only \(taggedNodeCount) tagged nodes")
            return nil
        }

        // SB137 Stage A — lift-weighted edges (identity-marker tags dominate;
        // gravity-well tag pairs collapse to weak weight).
        let graph = buildLiftWeightedGraph(nodes: nodes)

        // Run Louvain community detection on the lift-weighted graph.
        let louvainCommunities = louvainClustering(graph: graph)

        // Stabilize cluster identity across runs (AT21 Cat A): rewrite the
        // arbitrary first-node-UUID community IDs to either reuse a persisted
        // ID (when the fresh cluster's member set has Jaccard ≥ 0.5 with a
        // persisted cluster) or mint a fresh UUID.
        //
        // Mutation order (SB137 #7): stabilize → route → persist members. Routing
        // requires stable IDs to look up persisted description embeddings;
        // running it post-stabilization avoids redoing Jaccard inside routing.
        // Persistence still happens after routing so the next refresh's Jaccard
        // input includes routing results (the actual concern in #7).
        let stabilizedCommunities = stabilizeCommunityIDs(
            communities: louvainCommunities,
            previousMembers: previousMembers
        )

        // SB137 Stage A — isolate routing via content embedding.
        let routingResult = routeIsolatesViaContentEmbedding(
            communities: stabilizedCommunities,
            nodes: nodes,
            persistedDescriptionEmbeddings: persistedDescriptionEmbeddings,
            totalNodeCount: nodes.count
        )

        // Build neighborhoods from post-routing communities.
        let neighborhoods = buildNeighborhoods(
            communities: routingResult.communities,
            nodes: nodes,
            layoutPositions: layoutPositions
        )

        // Build reverse mapping (node → neighborhood)
        var nodeToNeighborhoodID: [String: String] = [:]
        for neighborhood in neighborhoods {
            for nodeID in neighborhood.memberNodeIDs {
                nodeToNeighborhoodID[nodeID] = neighborhood.id
            }
        }

        return NeighborhoodCache(
            neighborhoods: neighborhoods,
            nodeToNeighborhoodID: nodeToNeighborhoodID,
            unattachedNodeIDs: routingResult.unattachedNodeIDs,
            routingDiagnostics: routingResult.diagnostics,
            corpusFingerprint: corpusFingerprint(from: nodes),
            generatedAt: Date()
        )
    }

    // MARK: - Lift-weighted graph (SB137 Stage A)

    /// Build a weighted undirected graph whose edge weights reflect identity-marker
    /// tag pairs (high lift) over gravity-well tag pairs (lift near 1.0). Replaces the
    /// SB126-era TF-IDF rarity weighting that didn't separate Health-Fitness (lift 8.19)
    /// from Tech-Work (lift 1.31). Stage B will plug content-embedding edges into this
    /// builder; the Louvain step downstream is unchanged.
    private func buildLiftWeightedGraph(nodes: [Node]) -> [String: [String: Double]] {
        let builder = LiftWeightedGraphBuilder(nodes: nodes)
        return builder.build()
    }

    // MARK: - Louvain clustering

    /// Run one pass of Louvain method. Returns community assignment for each node.
    private func louvainClustering(graph: [String: [String: Double]]) -> [String: String] {
        let nodeIDs = Array(graph.keys)
        guard !nodeIDs.isEmpty else { return [:] }

        // Initialize: each node in its own community
        var nodeToCommunity: [String: String] = [:]
        for nodeID in nodeIDs {
            nodeToCommunity[nodeID] = nodeID  // Use node ID as initial community ID
        }

        // Precompute total edge weights per node
        var nodeDegree: [String: Double] = [:]
        for (nodeID, neighbors) in graph {
            nodeDegree[nodeID] = neighbors.values.reduce(0, +)
        }

        // Total graph weight (sum of all edge weights)
        let totalWeight = nodeDegree.values.reduce(0, +) / 2.0  // Divided by 2 because undirected

        var improved = true
        var iteration = 0
        let maxIterations = 50  // Safety limit

        while improved && iteration < maxIterations {
            improved = false
            iteration += 1

            // Shuffle node order for better convergence
            let shuffledNodes = nodeIDs.shuffled()

            for nodeID in shuffledNodes {
                let currentCommunity = nodeToCommunity[nodeID]!

                // Find neighboring communities
                var neighborCommunities = Set<String>()
                for (neighbor, _) in graph[nodeID] ?? [:] {
                    neighborCommunities.insert(nodeToCommunity[neighbor]!)
                }

                // Find best community (including staying in current one)
                var bestCommunity = currentCommunity
                var bestGain: Double = 0

                for candidateCommunity in neighborCommunities {
                    let gain = modularityGain(
                        nodeID: nodeID,
                        fromCommunity: currentCommunity,
                        toCommunity: candidateCommunity,
                        nodeToCommunity: nodeToCommunity,
                        graph: graph,
                        nodeDegree: nodeDegree,
                        totalWeight: totalWeight
                    )

                    if gain > bestGain {
                        bestGain = gain
                        bestCommunity = candidateCommunity
                    }
                }

                // Move to best community if it improves modularity
                if bestCommunity != currentCommunity && bestGain > 0 {
                    nodeToCommunity[nodeID] = bestCommunity
                    improved = true
                }
            }
        }

        return nodeToCommunity
    }

    /// Calculate modularity gain from moving a node between communities.
    private func modularityGain(
        nodeID: String,
        fromCommunity: String,
        toCommunity: String,
        nodeToCommunity: [String: String],
        graph: [String: [String: Double]],
        nodeDegree: [String: Double],
        totalWeight: Double
    ) -> Double {
        guard fromCommunity != toCommunity else { return 0 }

        let nodeDeg = nodeDegree[nodeID] ?? 0
        let neighbors = graph[nodeID] ?? [:]

        // Sum of edge weights to nodes in target community
        var edgesToCommunity: Double = 0
        for (neighbor, weight) in neighbors {
            if nodeToCommunity[neighbor] == toCommunity {
                edgesToCommunity += weight
            }
        }

        // Sum of edge weights to nodes in current community (excluding self-loops)
        var edgesFromCommunity: Double = 0
        for (neighbor, weight) in neighbors {
            if nodeToCommunity[neighbor] == fromCommunity && neighbor != nodeID {
                edgesFromCommunity += weight
            }
        }

        // Total degree of target community (excluding this node)
        var toCommunityDegree: Double = 0
        for (otherNodeID, community) in nodeToCommunity {
            if community == toCommunity && otherNodeID != nodeID {
                toCommunityDegree += nodeDegree[otherNodeID] ?? 0
            }
        }

        // Total degree of source community (excluding this node)
        var fromCommunityDegree: Double = 0
        for (otherNodeID, community) in nodeToCommunity {
            if community == fromCommunity && otherNodeID != nodeID {
                fromCommunityDegree += nodeDegree[otherNodeID] ?? 0
            }
        }

        // Modularity gain formula
        let gain = (edgesToCommunity - edgesFromCommunity) / totalWeight
                 - nodeDeg * (toCommunityDegree - fromCommunityDegree) / (2 * totalWeight * totalWeight)

        return gain
    }

    // MARK: - Build neighborhoods

    /// Convert community assignments to Neighborhood objects.
    private func buildNeighborhoods(
        communities: [String: String],
        nodes: [Node],
        layoutPositions: [String: CanvasPosition]
    ) -> [Neighborhood] {
        // Group nodes by community
        var communityGroups: [String: [String]] = [:]
        for (nodeID, communityID) in communities {
            communityGroups[communityID, default: []].append(nodeID)
        }

        // Build neighborhood objects
        var neighborhoods: [Neighborhood] = []
        for (communityID, memberNodeIDs) in communityGroups {
            // Calculate centroid from layout positions
            let positions = memberNodeIDs.compactMap { layoutPositions[$0] }
            let centroid: CGPoint
            if positions.isEmpty {
                centroid = .zero
            } else {
                let cx = positions.map { $0.x }.reduce(0, +) / Double(positions.count)
                let cy = positions.map { $0.y }.reduce(0, +) / Double(positions.count)
                centroid = CGPoint(x: cx, y: cy)
            }

            let neighborhood = Neighborhood(
                id: communityID,
                memberNodeIDs: memberNodeIDs,
                centroid: centroid,
                memberCount: memberNodeIDs.count
            )
            neighborhoods.append(neighborhood)
        }

        // Sort by member count descending
        return neighborhoods.sorted { $0.memberCount > $1.memberCount }
    }

    // MARK: - Isolate routing (SB137 Stage A)

    /// Routes members of sub-threshold clusters into substantive neighborhoods
    /// using cosine similarity between the node's content embedding and the
    /// persisted description embedding of each candidate neighborhood.
    ///
    /// - Sub-threshold cluster: member_count < `minClusterSize(forNodeCount:)`.
    /// - Substantive neighborhood candidates: post-stabilization clusters whose
    ///   stable ID maps to a persisted entry with a non-empty description
    ///   embedding (clusters formed this refresh with no Jaccard match have no
    ///   description yet — SB126 Stage 1 generates one on the next refresh).
    /// - Argmax cosine ≥ `cosineRouteThreshold` → reassign in-place.
    /// - Else (or when node has no `contentEmbedding`) → unattached.
    private func routeIsolatesViaContentEmbedding(
        communities: [String: String],
        nodes: [Node],
        persistedDescriptionEmbeddings: [String: [Float]],
        totalNodeCount: Int
    ) -> (communities: [String: String], unattachedNodeIDs: [String], diagnostics: RoutingDiagnostics?) {
        let threshold = Self.minClusterSize(forNodeCount: totalNodeCount)

        // Group node IDs by community for sizing.
        var membersByCommunity: [String: [String]] = [:]
        for (nodeID, communityID) in communities {
            membersByCommunity[communityID, default: []].append(nodeID)
        }

        // Substantive clusters with a usable description embedding form the
        // routing target pool. Clusters that hit threshold but lack a persisted
        // description (newly formed) are skipped per brief edge case.
        var routableTargets: [(communityID: String, embedding: [Float])] = []
        for (communityID, members) in membersByCommunity where members.count >= threshold {
            if let embedding = persistedDescriptionEmbeddings[communityID], !embedding.isEmpty {
                routableTargets.append((communityID, embedding))
            }
        }

        // Identify isolate node IDs.
        let isolateNodeIDs: [String] = membersByCommunity
            .filter { $0.value.count < threshold }
            .flatMap { $0.value }

        if isolateNodeIDs.isEmpty {
            return (communities, [], nil)
        }

        let nodesByID: [String: Node] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var updatedCommunities = communities
        var unattached: [String] = []
        var isolateBestSamples: [RoutingDiagnostics.IsolateCosineSample] = []
        var noEmbeddingCount = 0

        for nodeID in isolateNodeIDs {
            guard let node = nodesByID[nodeID] else {
                unattached.append(nodeID)
                continue
            }
            guard let nodeEmbedding = node.contentEmbedding, !nodeEmbedding.isEmpty else {
                // Brief edge case: nodes with no content embedding (FM safety
                // refusals, pre-Stage-2 captures) cannot be routed by cosine.
                noEmbeddingCount += 1
                unattached.append(nodeID)
                continue
            }
            guard !routableTargets.isEmpty else {
                unattached.append(nodeID)
                continue
            }

            var bestMatch: (communityID: String, score: Double)?
            for target in routableTargets {
                let score = cosineSimilarity(nodeEmbedding, target.embedding)
                if score > (bestMatch?.score ?? -.infinity) {
                    bestMatch = (target.communityID, score)
                }
            }

            if let match = bestMatch {
                isolateBestSamples.append(
                    RoutingDiagnostics.IsolateCosineSample(
                        nodeID: nodeID,
                        bestCommunityID: match.communityID,
                        bestCosine: match.score
                    )
                )
                if match.score >= Self.cosineRouteThreshold {
                    updatedCommunities[nodeID] = match.communityID
                } else {
                    unattached.append(nodeID)
                }
            } else {
                unattached.append(nodeID)
            }
        }

        // In-cluster sanity sample: for each routable target, pick up to 5
        // member nodes with content embeddings and record their cosine against
        // their own cluster description. Distribution shows whether the chosen
        // threshold sits above where same-cluster nodes actually fall.
        var inClusterSamples: [RoutingDiagnostics.InClusterCosineSample] = []
        let inClusterSamplesPerCluster = 5
        for target in routableTargets {
            let memberIDs = membersByCommunity[target.communityID] ?? []
            let memberNodesWithEmbedding: [Node] = memberIDs.compactMap { id in
                guard let n = nodesByID[id], let v = n.contentEmbedding, !v.isEmpty else { return nil }
                return n
            }
            for sampleNode in memberNodesWithEmbedding.prefix(inClusterSamplesPerCluster) {
                let v = sampleNode.contentEmbedding ?? []
                let score = cosineSimilarity(v, target.embedding)
                inClusterSamples.append(
                    RoutingDiagnostics.InClusterCosineSample(
                        communityID: target.communityID,
                        nodeID: sampleNode.id,
                        cosine: score
                    )
                )
            }
        }

        let diagnostics = RoutingDiagnostics(
            generatedAt: Date(),
            thresholdUsed: Self.cosineRouteThreshold,
            totalIsolates: isolateNodeIDs.count,
            isolatesWithEmbedding: isolateNodeIDs.count - noEmbeddingCount,
            isolatesNoEmbedding: noEmbeddingCount,
            routableTargetCount: routableTargets.count,
            isolateBestCosines: isolateBestSamples.sorted { $0.bestCosine > $1.bestCosine },
            inClusterCosines: inClusterSamples
        )

        return (updatedCommunities, unattached, diagnostics)
    }

    /// Cosine similarity between two equal-length float vectors. Returns 0 if
    /// dimensions disagree or either vector has zero magnitude.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var magA: Double = 0
        var magB: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            magA += x * x
            magB += y * y
        }
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA.squareRoot() * magB.squareRoot())
    }

    // MARK: - Cluster identity stability (AT21 Cat A)

    /// Rewrites the community IDs in `communities` so that fresh clusters
    /// sharing ≥ 0.5 Jaccard overlap with a persisted cluster reuse the
    /// persisted ID. Other clusters get a fresh UUID. Greedy: each persisted
    /// ID is claimed at most once. The 0.5 threshold is a starting heuristic;
    /// can be tuned if observed behavior suggests another value.
    private func stabilizeCommunityIDs(
        communities: [String: String],
        previousMembers: [String: Set<String>]
    ) -> [String: String] {
        // Group nodes by their provisional community ID
        var freshClusters: [String: Set<String>] = [:]
        for (nodeID, communityID) in communities {
            freshClusters[communityID, default: []].insert(nodeID)
        }

        let jaccardThreshold = 0.5
        var freshToStableID: [String: String] = [:]
        var claimedPersistedIDs = Set<String>()

        for (freshID, freshSet) in freshClusters {
            var bestMatch: (id: String, score: Double)?
            for (persistedID, persistedSet) in previousMembers where !claimedPersistedIDs.contains(persistedID) {
                guard !persistedSet.isEmpty else { continue }
                let intersection = freshSet.intersection(persistedSet).count
                let unionCount = freshSet.union(persistedSet).count
                guard unionCount > 0 else { continue }
                let score = Double(intersection) / Double(unionCount)
                if score >= jaccardThreshold, score > (bestMatch?.score ?? -1) {
                    bestMatch = (persistedID, score)
                }
            }
            if let match = bestMatch {
                freshToStableID[freshID] = match.id
                claimedPersistedIDs.insert(match.id)
            } else {
                freshToStableID[freshID] = UUID().uuidString
            }
        }

        var rewritten: [String: String] = [:]
        for (nodeID, communityID) in communities {
            rewritten[nodeID] = freshToStableID[communityID]!
        }
        return rewritten
    }

    // MARK: - Fingerprint

    /// Compute corpus fingerprint for cache invalidation.
    /// Hash of (node.id, node.tags) tuples — same format as UberNodeService.
    func corpusFingerprint(from nodes: [Node]) -> String {
        let sortedFingerprints = nodes.map { node in
            "\(node.id):\(node.tags.joined(separator: ","))"
        }.sorted().joined(separator: "|")
        return String(sortedFingerprints.hashValue)
    }
}

// MARK: - LiftWeightedGraphBuilder (SB137 Stage A)

/// Builds a node-pair graph whose edge weights reflect identity-marker tag
/// pairs (high lift) over gravity-well tag pairs (lift near 1.0). Lift is
/// computed on-the-fly from raw co-occurrence + usage counts rather than read
/// from `TagIndexEntry.topSimilarTags` because the persisted records are
/// filtered at lift > 1.5 and capped per-tag for a different consumer (the SB126
/// Stage 3 similar-tag UI surface). This builder needs the dense pair-lift
/// matrix and a 1.0 floor, so it derives them locally and caches per-pair
/// results for the duration of one graph build.
///
/// Stage B will inject content-embedding edges into this builder (or wrap it
/// in a graph-union step) so the downstream Louvain step is unchanged.
fileprivate struct LiftWeightedGraphBuilder {
    let nodes: [Node]

    /// Brief §Algorithmic spec: tag pairs with lift ≤ 1.0 contribute 0 to edge
    /// weight. Strictly greater than for "more than random co-occurrence".
    private let liftFloor: Double = 1.0

    func build() -> [String: [String: Double]] {
        var graph: [String: [String: Double]] = [:]
        for node in nodes { graph[node.id] = [:] }

        // Precompute usage counts and pairwise co-occurrence over tagged nodes.
        var tagFrequency: [String: Int] = [:]
        var pairCoOccurrence: [String: [String: Int]] = [:]
        var totalTaggedNodes = 0

        for node in nodes {
            let uniqueTags = Array(Set(node.tags))
            guard !uniqueTags.isEmpty else { continue }
            totalTaggedNodes += 1
            for tag in uniqueTags {
                tagFrequency[tag, default: 0] += 1
            }
            for i in 0..<uniqueTags.count {
                for j in (i + 1)..<uniqueTags.count {
                    let a = uniqueTags[i], b = uniqueTags[j]
                    pairCoOccurrence[a, default: [:]][b, default: 0] += 1
                    pairCoOccurrence[b, default: [:]][a, default: 0] += 1
                }
            }
        }

        guard totalTaggedNodes > 0 else { return graph }

        // Per-build cache of computed lifts; keyed (a,b) with a<b for symmetry.
        var liftCache: [String: Double] = [:]

        func liftBetween(_ a: String, _ b: String) -> Double {
            let key = a < b ? "\(a)\u{1}\(b)" : "\(b)\u{1}\(a)"
            if let cached = liftCache[key] { return cached }
            let nA = tagFrequency[a] ?? 0
            let nB = tagFrequency[b] ?? 0
            let nAB = pairCoOccurrence[a]?[b] ?? 0
            let lift: Double
            if nA == 0 || nB == 0 || nAB == 0 {
                lift = 0
            } else {
                lift = (Double(nAB) * Double(totalTaggedNodes)) / (Double(nA) * Double(nB))
            }
            liftCache[key] = lift
            return lift
        }

        // Edge construction. Per brief: T = tags(i) ∩ tags(j); if |T| < 2, no edge.
        // For each t ∈ T, contribute its strongest lift partner among T\{t},
        // counted only if that lift > 1.0.
        for i in 0..<nodes.count {
            let node1 = nodes[i]
            let tags1 = Set(node1.tags)
            guard tags1.count >= 2 else {
                // |tags1| < 2 → can't possibly satisfy |T| ≥ 2 with any partner.
                // (Skip outer iteration, but also skip inner — no edge possible.)
                if tags1.isEmpty { continue }
                // tags1.count == 1: still iterate inner pairs in case partner has |T|≥2 with other nodes;
                // actually no — |T| = |tags1 ∩ tags2| ≤ |tags1| = 1, so guaranteed no edge.
                continue
            }
            for j in (i + 1)..<nodes.count {
                let node2 = nodes[j]
                let shared = tags1.intersection(node2.tags)
                guard shared.count >= 2 else { continue }

                let sharedArray = Array(shared)
                var weight: Double = 0
                for tag in sharedArray {
                    var bestLift: Double = 0
                    for other in sharedArray where other != tag {
                        let l = liftBetween(tag, other)
                        if l > bestLift { bestLift = l }
                    }
                    if bestLift > liftFloor {
                        weight += bestLift
                    }
                }
                if weight > 0 {
                    graph[node1.id]![node2.id] = weight
                    graph[node2.id]![node1.id] = weight
                }
            }
        }

        return graph
    }
}
