import Foundation
import CoreGraphics

/// SB139 Stage 4c1 — per-node color derivation from substrate placements.
///
/// Pure compute, no UIKit. Stores results as HSB doubles; the scene converts
/// to `UIColor` at render time. Sibling to `SubstrateCanvasLayoutAdapter`.
///
/// **Algorithm:**
/// 1. Group placements by cluster. Compute centroid per cluster; centrality
///    per node = `1 - distance_to_centroid / max_distance_in_cluster`.
/// 2. Hash each node ID to a deterministic raw hue offset in `[-1, +1]`.
/// 3. Build a 2D k-NN graph (`k=8`) over non-noise placements. Smooth raw
///    offsets by replacing each with the mean of itself + its neighbors,
///    repeated `smoothingIterations` times. Continuity emerges because
///    neighbors share most of their k-NN sets.
/// 4. Final HSB per node:
///    - hue = clusterBaseHue + smoothedOffset × `maxHueJitter`
///    - saturation = lerp(min, max) over centrality
///    - brightness = `brightnessFixed`
/// 5. Noise (cluster `-1`) gets a desaturated gray placeholder. 4c1.2 will
///    replace this with the proper nearest-non-noise-cluster treatment.
///
/// **Determinism:** node ordering inside loops is sorted by node ID, not
/// dictionary order, so the same input produces the same output across
/// launches.
@available(iOS 17.0, *)
enum SubstrateColoringPass {

    // MARK: - Tunables

    /// Hue separation seed for cluster bases. Two-color cycle because no
    /// third hue can satisfy ≥120° separation from both Klein Blue and
    /// Mango simultaneously (the brief's hard constraint for the two
    /// distinguishable cluster colors). 3+ clusters cycle — T re-picks
    /// from the inspect view if a third cluster becomes visually load-
    /// bearing. Hue values are SwiftUI-fraction (0…1), matching
    /// `UIColor(hue:saturation:brightness:alpha:)`.
    static let clusterPalette: [Double] = [
        215.0 / 360.0,  // Klein Blue #1B59C2 — c0 base
        32.0 / 360.0,   // Mango #E8820A — c1 base
    ]

    /// Hue jitter applied as ± fraction of full hue wheel. ±15° → 15/360.
    static let maxHueJitter: Double = 15.0 / 360.0

    /// Centrality lerp range for saturation. Edge nodes desaturated;
    /// centroid nodes saturated. Empirical seed; tunable from inspect view
    /// if T wants finer control.
    static let saturationMin: Double = 0.45
    static let saturationMax: Double = 0.90

    /// Fixed brightness. Slightly under Klein Blue's natural B (0.76) so
    /// adjacent hues read as comparably-luminous.
    static let brightnessFixed: Double = 0.72

    /// Number of smoothing passes over the k-NN graph. Each pass replaces
    /// every node's offset with the mean of itself + its k-NN. 2 passes
    /// produces a coherent gradient on T's 163-node continent without
    /// homogenizing variation.
    static let smoothingIterations: Int = 2

    /// k for the 2D k-NN graph used for color smoothing. 8 neighbors
    /// produces visible local coherence on T's corpus without dragging
    /// distant points into each other's color zone.
    static let smoothingK: Int = 8

    /// Noise (HDBSCAN `-1`) placeholder color until 4c1.2 ships the
    /// nearest-cluster-desaturated treatment. Slate gray, distinct from
    /// any cluster color.
    static let noiseColor = HSB(hue: 0.0, saturation: 0.0, brightness: 0.35)

    // MARK: - Output type

    struct HSB {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    // MARK: - Compute

    static func map(_ placements: [SubstrateLayoutService.CanvasPlacement]) -> [String: HSB] {
        guard !placements.isEmpty else { return [:] }

        // Stable iteration order across launches.
        let sorted = placements.sorted { $0.nodeID < $1.nodeID }
        let n = sorted.count
        let indexByNodeID: [String: Int] = Dictionary(
            uniqueKeysWithValues: sorted.enumerated().map { ($1.nodeID, $0) }
        )

        // Group by cluster (non-noise only).
        var clusterMembers: [Int: [Int]] = [:]
        for (i, p) in sorted.enumerated() where p.clusterID >= 0 {
            clusterMembers[p.clusterID, default: []].append(i)
        }

        // Per-cluster centroid + per-node centrality.
        var centrality = [Double](repeating: 0, count: n)
        for (_, members) in clusterMembers {
            guard !members.isEmpty else { continue }
            var cx = 0.0, cy = 0.0
            for i in members {
                cx += Double(sorted[i].coord.x)
                cy += Double(sorted[i].coord.y)
            }
            cx /= Double(members.count)
            cy /= Double(members.count)
            var maxDist = 0.0
            var dists = [Double](repeating: 0, count: members.count)
            for (j, i) in members.enumerated() {
                let dx = Double(sorted[i].coord.x) - cx
                let dy = Double(sorted[i].coord.y) - cy
                let d = (dx * dx + dy * dy).squareRoot()
                dists[j] = d
                if d > maxDist { maxDist = d }
            }
            if maxDist > 0 {
                for (j, i) in members.enumerated() {
                    centrality[i] = 1.0 - (dists[j] / maxDist)
                }
            } else {
                // Single-point cluster or degenerate spread; treat as central.
                for i in members { centrality[i] = 1.0 }
            }
        }

        // Deterministic raw hue offsets in [-1, +1].
        var offsets = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let h = fnv1aHash(sorted[i].nodeID)
            // Map full UInt64 → [-1, +1].
            offsets[i] = (Double(h) / Double(UInt64.max)) * 2.0 - 1.0
        }

        // 2D k-NN over non-noise placements.
        let nonNoiseIndices = (0..<n).filter { sorted[$0].clusterID >= 0 }
        let knn = compute2DKnnIndices(
            placements: sorted,
            subset: nonNoiseIndices,
            k: smoothingK
        )

        // Smooth offsets. Each pass: offset[i] = mean(offset[i] + offsets of its k-NN).
        for _ in 0..<smoothingIterations {
            var next = offsets
            for i in nonNoiseIndices {
                guard let neighbors = knn[i], !neighbors.isEmpty else { continue }
                var sum = offsets[i]
                for j in neighbors { sum += offsets[j] }
                next[i] = sum / Double(neighbors.count + 1)
            }
            offsets = next
        }

        // Assemble HSB per node.
        var out: [String: HSB] = [:]
        out.reserveCapacity(n)
        for i in 0..<n {
            let p = sorted[i]
            if p.clusterID < 0 {
                out[p.nodeID] = noiseColor
                continue
            }
            // SB139 Stage 4c2 commit 1 — palette slot is stable across
            // refits via `SubstrateClusterRegistry` and is preferred over
            // the session-local HDBSCAN label. Falls back to `clusterID`
            // only when the registry hasn't populated yet (transitional;
            // matches prior session-local behavior).
            let slot = p.paletteSlot ?? p.clusterID
            let baseHue = clusterPalette[slot % clusterPalette.count]
            var hue = baseHue + offsets[i] * maxHueJitter
            // Wrap into [0, 1).
            hue = hue - floor(hue)
            let sat = saturationMin + centrality[i] * (saturationMax - saturationMin)
            out[p.nodeID] = HSB(hue: hue, saturation: sat, brightness: brightnessFixed)
        }
        _ = indexByNodeID  // reserved for future debug paths
        return out
    }

    // MARK: - 2D k-NN

    /// Compute k nearest neighbors in 2D for each index in `subset`.
    /// Returns a sparse `[i: [neighborIndices]]` keyed by index in `placements`.
    /// O(|subset|²) — fine at corpus scale (~163 nodes × k=8).
    private static func compute2DKnnIndices(
        placements: [SubstrateLayoutService.CanvasPlacement],
        subset: [Int],
        k: Int
    ) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        result.reserveCapacity(subset.count)
        guard subset.count > 1 else { return result }
        let effectiveK = Swift.min(k, subset.count - 1)
        for i in subset {
            let ix = Double(placements[i].coord.x)
            let iy = Double(placements[i].coord.y)
            var pairs: [(idx: Int, dist: Double)] = []
            pairs.reserveCapacity(subset.count - 1)
            for j in subset where j != i {
                let dx = ix - Double(placements[j].coord.x)
                let dy = iy - Double(placements[j].coord.y)
                pairs.append((j, dx * dx + dy * dy))
            }
            pairs.sort {
                if $0.dist != $1.dist { return $0.dist < $1.dist }
                return $0.idx < $1.idx
            }
            result[i] = pairs.prefix(effectiveK).map(\.idx)
        }
        return result
    }

    // MARK: - Hash

    /// FNV-1a 64-bit. Deterministic across launches; cheap; well-distributed.
    private static func fnv1aHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001B3
        }
        return h
    }
}
