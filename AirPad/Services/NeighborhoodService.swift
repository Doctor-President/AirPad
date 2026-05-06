import Foundation

/// Generates neighborhoods from tag co-occurrence graph using Louvain community detection.
/// Phase A: math-only clustering before semantic placement. No model invocation.
@MainActor
final class NeighborhoodService {

    /// Generate neighborhoods from corpus using Louvain method.
    /// Returns nil if corpus is too small or has no tagged nodes.
    /// `previousMembers` maps persisted neighborhood IDs to their member node IDs;
    /// used to keep cluster identity stable across runs via Jaccard matching.
    func generateNeighborhoods(
        from nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        previousMembers: [String: Set<String>] = [:]
    ) -> NeighborhoodCache? {
        // Edge case: empty or trivial corpus
        guard nodes.count >= 2 else { return nil }

        // Skip compute if too few nodes have tags (avoids singleton explosion at startup)
        let taggedNodeCount = nodes.filter { !$0.tags.isEmpty }.count
        guard taggedNodeCount >= 5 else {
            print("[Neighborhood] Skipping compute — only \(taggedNodeCount) tagged nodes")
            return nil
        }

        // Build tag frequency map for TF-IDF weighting
        let tagFrequency = computeTagFrequency(nodes: nodes)

        // Build weighted co-occurrence graph
        let graph = buildCoOccurrenceGraph(nodes: nodes, tagFrequency: tagFrequency)

        // Run Louvain community detection
        let communities = louvainClustering(graph: graph)

        // Stabilize cluster identity across runs (AT21 Cat A): rewrite the
        // arbitrary first-node-UUID community IDs to either reuse a persisted
        // ID (when the fresh cluster's member set has Jaccard ≥ 0.5 with a
        // persisted cluster) or mint a fresh UUID.
        let stabilizedCommunities = stabilizeCommunityIDs(
            communities: communities,
            previousMembers: previousMembers
        )

        // Build neighborhoods from communities
        let neighborhoods = buildNeighborhoods(
            communities: stabilizedCommunities,
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
            corpusFingerprint: corpusFingerprint(from: nodes),
            generatedAt: Date()
        )
    }

    // MARK: - Tag frequency

    /// Compute corpus-wide tag frequency for TF-IDF weighting.
    private func computeTagFrequency(nodes: [Node]) -> [String: Int] {
        var frequency: [String: Int] = [:]
        for node in nodes {
            for tag in node.tags {
                frequency[tag, default: 0] += 1
            }
        }
        return frequency
    }

    // MARK: - Co-occurrence graph

    /// Build weighted undirected graph from tag co-occurrence.
    /// Edge weight = sum of TF-IDF rarity scores for shared tags.
    private func buildCoOccurrenceGraph(nodes: [Node], tagFrequency: [String: Int]) -> [String: [String: Double]] {
        var graph: [String: [String: Double]] = [:]
        let epsilon = 0.05  // Minimum edge weight threshold

        // Initialize adjacency lists
        for node in nodes {
            graph[node.id] = [:]
        }

        // Pairwise co-occurrence
        for i in 0..<nodes.count {
            let node1 = nodes[i]
            guard !node1.tags.isEmpty else { continue }

            for j in (i + 1)..<nodes.count {
                let node2 = nodes[j]
                guard !node2.tags.isEmpty else { continue }

                // Find shared tags
                let sharedTags = Set(node1.tags).intersection(Set(node2.tags))
                guard !sharedTags.isEmpty else { continue }

                // Compute edge weight using TF-IDF rarity
                var weight: Double = 0
                for tag in sharedTags {
                    let freq = tagFrequency[tag] ?? 1
                    // Rarity weight: 1 / log(1 + frequency)
                    let rarityWeight = 1.0 / log(1.0 + Double(freq))
                    weight += rarityWeight
                }

                // Only add edge if weight exceeds threshold
                if weight >= epsilon {
                    graph[node1.id]![node2.id] = weight
                    graph[node2.id]![node1.id] = weight
                }
            }
        }

        return graph
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
