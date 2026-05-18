import Foundation
import CoreGraphics

/// Result container for algorithmic layout computation.
struct LayoutResult {
    let positions: [String: CGPoint]
    let radii: [String: CGFloat]
}

/// Algorithmic layout engine for resting-state node positioning.
/// Pure math — deterministic, fast, no continuous physics simulation.
@MainActor
final class LayoutService {

    // MARK: - Layout parameters (tunable)

    private let neighborhoodCentroidRadius: CGFloat = 600
    private let inertiaWeight: CGFloat = 0.1  // Lowered from 0.2 to reduce pull toward old positions (hyper-cluster fix)
    private let floaterRadius: CGFloat = 900

    // Node sizing
    private let minRadius: CGFloat = 12.0
    private let maxRadius: CGFloat = 48.0
    private let mediaWordEquivalent: Double = 20.0
    private let centralityCoefficient: Double = 0.25
    private let minSeparationGap: CGFloat = 4.0

    // MARK: - Public API

    /// Compute algorithmic layout positions and radii for all nodes.
    /// Returns positions (SpriteKit convention: y-up from center) and radii (pt).
    /// - Parameters:
    ///   - nodes: All corpus nodes
    ///   - neighborhoodCache: Neighborhood assignments (nil = all floaters)
    ///   - existingPositions: Prior positions for inertia blending
    func computeAlgorithmicLayout(
        nodes: [Node],
        neighborhoodCache: NeighborhoodCache?,
        existingPositions: [String: CGPoint]
    ) -> LayoutResult {
        let startTime = Date()

        // Compute significance scores for all nodes
        var significanceScores: [String: Double] = [:]
        for node in nodes {
            significanceScores[node.id] = significance(for: node, allNodes: nodes, neighborhoodCache: neighborhoodCache)
        }
        let maxSignificance = significanceScores.values.max() ?? 1.0

        // Compute radii based on significance
        var radii: [String: CGFloat] = [:]
        for (nodeID, sig) in significanceScores {
            radii[nodeID] = radius(forSignificance: sig, corpusMaxSignificance: maxSignificance)
        }

        // Group nodes by neighborhood
        var neighborhoodGroups: [String: [Node]] = [:]
        var floaters: [Node] = []

        for node in nodes {
            if let neighborhoodID = neighborhoodCache?.neighborhoodID(forNodeID: node.id) {
                neighborhoodGroups[neighborhoodID, default: []].append(node)
            } else {
                floaters.append(node)
            }
        }

        // Sort neighborhoods by member count (largest first for stability)
        let sortedNeighborhoods = neighborhoodGroups.sorted { $0.value.count > $1.value.count }

        // Allocate wedges proportionally
        let totalMembers = sortedNeighborhoods.reduce(0) { $0 + $1.value.count }
        let minWedgeAngle = CGFloat.pi / 6  // 30 degrees minimum

        var wedgeAllocations: [(neighborhoodID: String, members: [Node], wedgeAngle: CGFloat, wedgeMidpoint: CGFloat)] = []
        var currentAngle: CGFloat = 0

        for (neighborhoodID, members) in sortedNeighborhoods {
            let proportion = CGFloat(members.count) / CGFloat(totalMembers)
            let wedgeAngle = max(minWedgeAngle, proportion * 2 * .pi)
            let wedgeMidpoint = currentAngle + wedgeAngle / 2
            wedgeAllocations.append((neighborhoodID, members, wedgeAngle, wedgeMidpoint))
            currentAngle += wedgeAngle
        }

        // Compute positions
        var computedPositions: [String: CGPoint] = [:]

        // Place neighborhoods
        for (_, members, _, wedgeMidpoint) in wedgeAllocations {
            // Find max radius in this neighborhood for ring spacing
            let maxMemberRadius = members.compactMap { radii[$0.id] }.max() ?? minRadius

            // Centroid position
            let centroidX = cos(wedgeMidpoint) * neighborhoodCentroidRadius
            let centroidY = sin(wedgeMidpoint) * neighborhoodCentroidRadius

            // Place members in concentric rings with dynamic spacing
            let positions = placeNodesInRings(
                nodes: members,
                centroid: CGPoint(x: centroidX, y: centroidY),
                maxNodeRadius: maxMemberRadius,
                radii: radii
            )

            for (nodeID, pos) in positions {
                computedPositions[nodeID] = pos
            }
        }

        // Place floaters in outer band
        for floater in floaters {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let x = cos(angle) * floaterRadius
            let y = sin(angle) * floaterRadius
            computedPositions[floater.id] = CGPoint(x: x, y: y)
        }

        // Blend with existing positions (inertia)
        var blendedPositions: [String: CGPoint] = [:]
        for (nodeID, algorithmicPos) in computedPositions {
            if let priorPos = existingPositions[nodeID] {
                let blendedX = algorithmicPos.x * (1 - inertiaWeight) + priorPos.x * inertiaWeight
                let blendedY = algorithmicPos.y * (1 - inertiaWeight) + priorPos.y * inertiaWeight
                blendedPositions[nodeID] = CGPoint(x: blendedX, y: blendedY)
            } else {
                // New node — use algorithmic position directly
                blendedPositions[nodeID] = algorithmicPos
            }
        }

        // Min-separation post-pass
        let finalPositions = enforceMinimumSeparation(positions: blendedPositions, radii: radii)

        let elapsed = Date().timeIntervalSince(startTime) * 1000  // ms

        // Compute stats
        let radiiValues = radii.values.map { $0 }
        let minR = radiiValues.min() ?? 0
        let maxR = radiiValues.max() ?? 0
        let meanR = radiiValues.isEmpty ? 0 : radiiValues.reduce(0, +) / CGFloat(radiiValues.count)
        print("[Layout] Layout computed in \(Int(elapsed))ms")
        print("[Layout] Computed radii: min=\(Int(minR))pt, max=\(Int(maxR))pt, mean=\(Int(meanR))pt")

        return LayoutResult(positions: finalPositions, radii: radii)
    }

    // MARK: - Concentric ring placement

    /// Place nodes in concentric rings around a centroid.
    /// Ring spacing and capacity driven by actual node radii to prevent overlap.
    private func placeNodesInRings(
        nodes: [Node],
        centroid: CGPoint,
        maxNodeRadius: CGFloat,
        radii: [String: CGFloat]
    ) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var remainingNodes = nodes
        var ringIndex = 0

        // Ring spacing based on actual max node size
        let ringSpacing = 2 * maxNodeRadius + 8

        while !remainingNodes.isEmpty {
            let ringRadius = CGFloat(ringIndex) * ringSpacing

            // Dynamic capacity: how many nodes fit on this ring circumference
            let capacity: Int
            if ringIndex == 0 {
                // Center ring: single node
                capacity = 1
            } else {
                // Circumference / (node diameter + gap)
                let circumference = 2 * CGFloat.pi * ringRadius
                let slotWidth = 2 * maxNodeRadius + 8
                capacity = max(1, Int(floor(circumference / slotWidth)))
            }

            let nodesForRing = Array(remainingNodes.prefix(capacity))
            remainingNodes.removeFirst(nodesForRing.count)

            let angleStep = (2 * CGFloat.pi) / CGFloat(nodesForRing.count)

            for (i, node) in nodesForRing.enumerated() {
                let angle = CGFloat(i) * angleStep
                let x = centroid.x + cos(angle) * ringRadius
                let y = centroid.y + sin(angle) * ringRadius
                positions[node.id] = CGPoint(x: x, y: y)
            }

            ringIndex += 1
        }

        return positions
    }

    // MARK: - Node significance and sizing

    /// Compute hybrid significance score for a node.
    /// Combines content weight (words + media) with centrality (tag bridges).
    func significance(for node: Node, allNodes: [Node], neighborhoodCache: NeighborhoodCache?) -> Double {
        // Count words across all items
        var wordCount = 0
        for item in node.items {
            let text: String?
            switch item.type {
            case .text:
                text = item.content
            case .audio, .video:
                text = item.transcript
            case .image, .document:
                text = item.description
            case .link:
                // Combine title and preview for links
                let title = item.title ?? ""
                let preview = item.preview ?? ""
                text = title + " " + preview
            case .imageVideo:
                // No aggregate text — gallery entries contribute via item
                // count (below), not text length.
                text = nil
            }
            if let t = text {
                wordCount += t.split(separator: " ").count
            }
        }

        // Count media items
        let mediaCount = node.items.filter {
            $0.type == .image || $0.type == .video || $0.type == .audio || $0.type == .document || $0.type == .imageVideo
        }.count

        // Content weight
        let contentWeight = Double(wordCount) + Double(mediaCount) * mediaWordEquivalent

        // Centrality factor: count neighborhood bridges
        var neighborhoodBridges = 0
        if let cache = neighborhoodCache,
           let ownNeighborhoodID = cache.neighborhoodID(forNodeID: node.id) {
            // Build a map of nodeID -> Node for fast lookup
            let nodeMap = Dictionary(uniqueKeysWithValues: allNodes.map { ($0.id, $0) })

            // For each tag in this node, count how many OTHER neighborhoods contain it
            for tag in node.tags {
                var bridgedNeighborhoods = Set<String>()
                for neighborhood in cache.neighborhoods where neighborhood.id != ownNeighborhoodID {
                    // Check if any member of this neighborhood has this tag
                    for memberID in neighborhood.memberNodeIDs {
                        if let member = nodeMap[memberID], member.tags.contains(tag) {
                            bridgedNeighborhoods.insert(neighborhood.id)
                            break  // Found one, no need to check other members
                        }
                    }
                }
                neighborhoodBridges += bridgedNeighborhoods.count
            }
        }

        let centralityMultiplier = 1.0 + Double(neighborhoodBridges) * centralityCoefficient
        return contentWeight * centralityMultiplier
    }

    /// Map significance to radius using logarithmic scaling.
    func radius(forSignificance significance: Double, corpusMaxSignificance: Double) -> CGFloat {
        guard corpusMaxSignificance > 0 && significance > 0 else { return minRadius }

        let normalized = pow(log(1 + significance) / log(1 + corpusMaxSignificance), 0.7)
        return minRadius + (maxRadius - minRadius) * CGFloat(normalized)
    }

    // MARK: - Collision avoidance

    /// Enforce minimum separation between all nodes.
    /// Iterates up to 10 times, nudging overlapping nodes apart.
    private func enforceMinimumSeparation(
        positions: [String: CGPoint],
        radii: [String: CGFloat]
    ) -> [String: CGPoint] {
        var adjustedPositions = positions
        let maxIterations = 10

        for _ in 0..<maxIterations {
            var moved = false
            let nodeIDs = Array(adjustedPositions.keys).sorted()

            for i in 0..<nodeIDs.count {
                for j in (i+1)..<nodeIDs.count {
                    let idA = nodeIDs[i]
                    let idB = nodeIDs[j]

                    guard let posA = adjustedPositions[idA],
                          let posB = adjustedPositions[idB] else { continue }

                    let radiusA = radii[idA] ?? minRadius
                    let radiusB = radii[idB] ?? minRadius
                    let minSep = radiusA + radiusB + minSeparationGap

                    let dx = posB.x - posA.x
                    let dy = posB.y - posA.y
                    let dist = sqrt(dx * dx + dy * dy)

                    if dist < minSep && dist > 0.1 {
                        // Nudge apart along connecting vector
                        let overlap = minSep - dist
                        let nudge = overlap / 2
                        let nx = dx / dist
                        let ny = dy / dist

                        adjustedPositions[idA] = CGPoint(
                            x: posA.x - nx * nudge,
                            y: posA.y - ny * nudge
                        )
                        adjustedPositions[idB] = CGPoint(
                            x: posB.x + nx * nudge,
                            y: posB.y + ny * nudge
                        )
                        moved = true
                    }
                }
            }

            if !moved { break }
        }

        return adjustedPositions
    }
}
