import Foundation
import CoreGraphics

/// Algorithmic layout engine for resting-state node positioning.
/// Pure math — deterministic, fast, no continuous physics simulation.
@MainActor
final class LayoutService {

    // MARK: - Layout parameters (tunable)

    private let neighborhoodCentroidRadius: CGFloat = 600
    private let ringSpacing: CGFloat = 40
    private let inertiaWeight: CGFloat = 0.2  // 80% algorithmic / 20% prior position
    private let floaterRadius: CGFloat = 900

    // MARK: - Public API

    /// Compute algorithmic layout positions for all nodes.
    /// Returns a dictionary of nodeID → CGPoint (SpriteKit convention: y-up from center).
    /// - Parameters:
    ///   - nodes: All corpus nodes
    ///   - neighborhoodCache: Neighborhood assignments (nil = all floaters)
    ///   - existingPositions: Prior positions for inertia blending
    func computeAlgorithmicLayout(
        nodes: [Node],
        neighborhoodCache: NeighborhoodCache?,
        existingPositions: [String: CGPoint]
    ) -> [String: CGPoint] {
        let startTime = Date()

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
            // Centroid position
            let centroidX = cos(wedgeMidpoint) * neighborhoodCentroidRadius
            let centroidY = sin(wedgeMidpoint) * neighborhoodCentroidRadius

            // Place members in concentric rings
            let positions = placeNodesInRings(
                nodes: members,
                centroid: CGPoint(x: centroidX, y: centroidY),
                ringSpacing: ringSpacing
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
        var finalPositions: [String: CGPoint] = [:]
        for (nodeID, algorithmicPos) in computedPositions {
            if let priorPos = existingPositions[nodeID] {
                // 80% algorithmic / 20% prior
                let blendedX = algorithmicPos.x * (1 - inertiaWeight) + priorPos.x * inertiaWeight
                let blendedY = algorithmicPos.y * (1 - inertiaWeight) + priorPos.y * inertiaWeight
                finalPositions[nodeID] = CGPoint(x: blendedX, y: blendedY)
            } else {
                // New node — use algorithmic position directly
                finalPositions[nodeID] = algorithmicPos
            }
        }

        let elapsed = Date().timeIntervalSince(startTime) * 1000  // ms
        print("[Layout] Layout computed in \(Int(elapsed))ms")

        return finalPositions
    }

    // MARK: - Concentric ring placement

    /// Place nodes in concentric rings around a centroid.
    /// Ring capacities: 6, 12, 18, 24, ... (6n per ring)
    private func placeNodesInRings(
        nodes: [Node],
        centroid: CGPoint,
        ringSpacing: CGFloat
    ) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var remainingNodes = nodes
        var ringIndex = 0

        while !remainingNodes.isEmpty {
            let capacity = (ringIndex + 1) * 6
            let nodesForRing = Array(remainingNodes.prefix(capacity))
            remainingNodes.removeFirst(nodesForRing.count)

            let radius = CGFloat(ringIndex) * ringSpacing
            let angleStep = (2 * CGFloat.pi) / CGFloat(nodesForRing.count)

            for (i, node) in nodesForRing.enumerated() {
                let angle = CGFloat(i) * angleStep
                let x = centroid.x + cos(angle) * radius
                let y = centroid.y + sin(angle) * radius
                positions[node.id] = CGPoint(x: x, y: y)
            }

            ringIndex += 1
        }

        return positions
    }
}
