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
    /// Initial 1200 pt seed (sized to `LayoutService.floaterRadius: 900`'s
    /// visual regime) produced a density floor at T's 171-node corpus:
    /// ~50% disk-area packing in the densest cluster, so 4c1.3 relaxation
    /// hit `maxStretch` cap at 41–51% of nodes with no visible
    /// improvement. Raised to 2000 pt: gives nodes ~67% more breathing
    /// room at the substrate level so relaxation has somewhere to put
    /// them. Tunable downward (1600–1800) if 2000 feels too spread.
    static let targetSpan: CGFloat = 2000

    struct Mapped {
        /// SwiftUI-convention positions (y-down from center), keyed by node ID.
        var positions: [String: CanvasPosition]
        /// The UMAP→canvas scale that produced these positions. Surfaced
        /// for diagnostics and for 4c3 to consume when retargeting camera
        /// dolly-zoom against the substrate bounding box.
        var unitsToPoints: CGFloat
    }

    static func map(_ placements: [SubstrateLayoutService.CanvasPlacement]) -> Mapped {
        guard !placements.isEmpty else {
            return Mapped(positions: [:], unitsToPoints: 1.0)
        }

        var minX: Float = .infinity, maxX: Float = -.infinity
        var minY: Float = .infinity, maxY: Float = -.infinity
        for p in placements {
            minX = min(minX, p.coord.x); maxX = max(maxX, p.coord.x)
            minY = min(minY, p.coord.y); maxY = max(maxY, p.coord.y)
        }

        let spanX = CGFloat(maxX - minX)
        let spanY = CGFloat(maxY - minY)
        let longerSpan = max(spanX, spanY)
        let scale: CGFloat = longerSpan > 0 ? (targetSpan / longerSpan) : 1.0

        let cx = CGFloat(minX + maxX) * 0.5
        let cy = CGFloat(minY + maxY) * 0.5

        var positions: [String: CanvasPosition] = [:]
        positions.reserveCapacity(placements.count)
        for p in placements {
            let x = (CGFloat(p.coord.x) - cx) * scale
            // UMAP y → SwiftUI y-down convention (matches CanvasLayout.positions).
            let y = (CGFloat(p.coord.y) - cy) * scale
            positions[p.nodeID] = CanvasPosition(x: Double(x), y: Double(y))
        }

        return Mapped(positions: positions, unitsToPoints: scale)
    }
}
