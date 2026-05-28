import Foundation
import CoreGraphics

/// SB139 Stage 4c1 — UMAP coords → canvas positions.
///
/// The substrate emits unbounded 2D floats; the canvas operates in a
/// point-space comparable to `LayoutService` output (~±1000 pt). This
/// adapter normalizes a placement set to fit a target span around the
/// canvas origin and returns `CanvasPosition` values in the same
/// SwiftUI convention (y-down from center) that `CorpusStore.canvasLayout`
/// already uses — `CorpusPhysicsScene.storedPosition(for:)` flips Y at
/// the SpriteKit boundary unchanged.
///
/// **Base scale, not interactive scale:** the adapter computes a single
/// fit-time scale that maps UMAP units to canvas points. Pinch zoom and
/// pan continue to operate via `cameraNode.xScale` / `cameraNode.position`
/// on top of this mapping — Consultation 1's "base vs. interactive scale"
/// distinction lives here as a primitive 4c3 can extend.
///
/// **Stateless:** holds no model. Caller re-derives placements when
/// `SubstrateLayoutService.generation` bumps.
@available(iOS 17.0, *)
enum SubstrateCanvasLayoutAdapter {

    /// Target span of the longer axis after mapping (canvas points).
    /// History: 1200 → 2000 because min/max scaling let outliers compress
    /// the dense mass, forcing extra span just to give it room. The P5/P95
    /// span fix eliminated that compression — the dense mass now actually
    /// fills `targetSpan` — so 2000 left it overspread relative to the
    /// viewport. Dropped to 1600: dense cluster occupies the screen area
    /// more tightly while outliers still sit ~88% past the dense edge
    /// (clamped at ±1400 from the ±800 dense half-extent).
    static let targetSpan: CGFloat = 1600

    struct Mapped {
        /// SwiftUI-convention positions (y-down from center), keyed by node ID.
        var positions: [String: CanvasPosition]
        /// The UMAP→canvas scale that produced these positions. Surfaced
        /// for diagnostics and for 4c3 to consume when retargeting camera
        /// dolly-zoom against the substrate bounding box.
        var unitsToPoints: CGFloat
    }

    /// Outer half-extent (canvas points) past which outliers are clamped.
    /// Sits 100 pt clear of the physics edge loop at ±1500 so outliers
    /// rest at the boundary without the engine continuously pushing them
    /// inward. ~40% past the dense-mass edge (targetSpan/2 = 1000) gives
    /// outliers a visibly separate band from the central cluster.
    static let outlierClamp: CGFloat = 1400

    static func map(_ placements: [SubstrateLayoutService.CanvasPlacement]) -> Mapped {
        guard !placements.isEmpty else {
            return Mapped(positions: [:], unitsToPoints: 1.0)
        }

        // Percentile-based span instead of min/max. UMAP routinely leaves a
        // handful of points far from the dense mass; min/max scaling lets
        // those outliers dominate the bounding box, compressing the dense
        // cluster into a small region. Asymmetric outliers also shift the
        // (min+max)/2 centroid off the dense mass, producing the "stuck in
        // a corner with empty space" symptom. P5–P95 anchors centering and
        // scale to the body of the distribution; outliers are clamped to
        // `outlierClamp` so they sit at the edge rather than escaping
        // past the physics boundary.
        let xs = placements.map { CGFloat($0.coord.x) }.sorted()
        let ys = placements.map { CGFloat($0.coord.y) }.sorted()
        let p5x = percentile(xs, 0.05)
        let p95x = percentile(xs, 0.95)
        let p5y = percentile(ys, 0.05)
        let p95y = percentile(ys, 0.95)

        let spanX = p95x - p5x
        let spanY = p95y - p5y
        let longerSpan = max(spanX, spanY)
        let scale: CGFloat = longerSpan > 0 ? (targetSpan / longerSpan) : 1.0

        let cx = (p5x + p95x) * 0.5
        let cy = (p5y + p95y) * 0.5

        var positions: [String: CanvasPosition] = [:]
        positions.reserveCapacity(placements.count)
        for p in placements {
            let rx = (CGFloat(p.coord.x) - cx) * scale
            // UMAP y → SwiftUI y-down convention (matches CanvasLayout.positions).
            let ry = (CGFloat(p.coord.y) - cy) * scale
            let x = max(-outlierClamp, min(outlierClamp, rx))
            let y = max(-outlierClamp, min(outlierClamp, ry))
            positions[p.nodeID] = CanvasPosition(x: Double(x), y: Double(y))
        }

        return Mapped(positions: positions, unitsToPoints: scale)
    }

    /// Linear-interpolated percentile from a sorted array. Robust to
    /// short arrays — single-element falls through to that element.
    private static func percentile(_ sorted: [CGFloat], _ p: Double) -> CGFloat {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = Double(sorted.count - 1) * p
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = CGFloat(rank - Double(lo))
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}
