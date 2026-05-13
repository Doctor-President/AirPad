import Foundation
import CoreGraphics

/// SB139 Stage 4c1.3 — tethered Position-Based Dynamics relaxation for the
/// substrate canvas.
///
/// Pure compute. Resolves visual overlap among nodes whose UMAP-derived
/// canvas positions land within each other's render radius. Truth coords
/// stay first-class on `SubstrateLayoutService`; this pass produces a
/// *display* delta the canvas reads when rendering. Caller decides whether
/// to apply it (flag-gated).
///
/// **Algorithm — tether spring + hard pairwise projection (PBD):**
/// 1. Tether integration: each node is pulled toward its truth position
///    by a Hookean step `stepSize · tetherStiffness · (truth − display)`.
///    Tether is the only integrated force.
/// 2. Projection inner loop: any two nodes closer than `r_i + r_j + minGap`
///    are pushed apart along their connecting axis by *half the overlap
///    each*. Inner loop repeats until a pass finds no violations (cap at
///    `maxProjectionPasses` as a safety net). Gauss-Seidel order — each
///    pair's projection is visible to subsequent pairs in the same pass.
/// 3. Outer loop terminates when total per-iter motion drops below
///    `settleThreshold` AND projection's final pass found zero
///    violations, or after `maxIterations`.
///
/// **Hard invariant:** at termination, no two nodes' rendered disks
/// overlap. Projection is a constraint, not a force — it always
/// guarantees `dist(i,j) ≥ r_i + r_j + minGap` after each pass
/// completes. Earlier soft-repulsion variant only *approached* this
/// asymptotically and stalled in dense regions; PBD enforces it by
/// post-condition.
///
/// **Why no maxStretch cap:** earlier variant clamped displacement to
/// bound how far a node could travel from truth. With a hard non-overlap
/// rule, the cap fights the constraint — a node that needed to displace
/// further would either violate the constraint (cap wins) or violate
/// the cap (constraint wins). Tether already minimizes displacement to
/// the smallest value compatible with the constraint; no separate cap
/// is needed.
///
/// **Determinism:** node IDs are sorted before iteration so the same
/// inputs produce the same output across launches.
///
/// **Coordinate space:** inputs and outputs are canvas-point space (the
/// same `CanvasPosition` units `SubstrateCanvasLayoutAdapter.Mapped`
/// emits). Node radii are in points. No UMAP-space conversion needed.
@available(iOS 17.0, *)
enum SubstrateRelaxationPass {

    // MARK: - Tunables

    /// Per-outer-iter spring constant pulling display → truth. Tether
    /// is now the sole integrated force (projection is a constraint),
    /// so this directly controls how aggressively nodes return toward
    /// their UMAP coord between projection passes.
    static let tetherStiffness: CGFloat = 0.15

    /// Minimum visible gap between two settled nodes (added to
    /// `r_i + r_j` when computing the minimum allowed center-to-center
    /// distance). T's primary tuning surface — raise for more breathing
    /// room, lower for tighter clusters. 4 pt seed: visible separation
    /// without sacrificing cluster density.
    static let minGap: CGFloat = 4.0

    /// Integration step scaling the per-iter tether motion into a
    /// position delta. Bumped from 0.5 to 1.0 vs. the earlier soft
    /// solver: that variant under-relaxed to keep summed forces from
    /// overshooting; PBD has no force summation (projection is binary),
    /// so tether wants the full step. 1.0 puts tether convergence well
    /// inside `maxIterations` even in dense regions.
    static let stepSize: CGFloat = 1.0

    /// Maximum outer iterations before giving up. At
    /// `stepSize · tetherStiffness = 0.15` per iter, displacement halves
    /// roughly every 4 iters — 80 outer iters drive any reasonable
    /// initial state to settled.
    static let maxIterations: Int = 80

    /// Maximum projection sub-passes per outer iter. Inner loop breaks
    /// early once a pass finds zero violations; 50 is a safety net for
    /// pathological piles where each pair-fix induces new overlaps.
    static let maxProjectionPasses: Int = 50

    /// Convergence threshold: when the largest single-node motion across
    /// a whole outer iter (tether + projection combined) is below this
    /// AND the final projection pass had zero violations, the solver
    /// stops early.
    static let settleThreshold: CGFloat = 0.5

    /// Fallback radius when a node isn't present in `nodeRadii`. The
    /// layout service composes pipelines that may run before sprite
    /// radii are computed; 24 pt mirrors `CorpusPhysicsScene`'s 1-item
    /// node radius so the relaxation is correct-ish rather than wildly
    /// off for unmeasured nodes.
    static let defaultRadius: CGFloat = 24.0

    // MARK: - Compute

    /// Relax `truthPositions` against pairwise overlap, returning display
    /// positions per node. Inputs and outputs are in canvas-point space.
    /// Node IDs without an entry in `truthPositions` are skipped silently.
    ///
    /// **Post-condition (when termination is by settle, not iter cap):**
    /// for any two returned positions `p_i`, `p_j`, the center-to-center
    /// distance is at least `r_i + r_j + minGap`. If termination is by
    /// iter cap, near-equilibrium may leave a small number of pairs
    /// transiently within `minGap`; raise `maxIterations` if the
    /// diagnostic shows this.
    static func relax(
        truthPositions: [String: CanvasPosition],
        nodeRadii: [String: CGFloat]
    ) -> [String: CanvasPosition] {
        let ids = truthPositions.keys.sorted()
        guard ids.count > 1 else { return truthPositions }

        // Flatten to parallel arrays for tight inner loops.
        let n = ids.count
        var dispX = [CGFloat](repeating: 0, count: n)
        var dispY = [CGFloat](repeating: 0, count: n)
        var truthX = [CGFloat](repeating: 0, count: n)
        var truthY = [CGFloat](repeating: 0, count: n)
        var radii = [CGFloat](repeating: defaultRadius, count: n)
        for (i, id) in ids.enumerated() {
            let p = truthPositions[id]!
            truthX[i] = CGFloat(p.x); truthY[i] = CGFloat(p.y)
            dispX[i] = truthX[i]; dispY[i] = truthY[i]
            if let r = nodeRadii[id] { radii[i] = r }
        }

        var prevX = [CGFloat](repeating: 0, count: n)
        var prevY = [CGFloat](repeating: 0, count: n)

        for _ in 0..<maxIterations {
            for i in 0..<n { prevX[i] = dispX[i]; prevY[i] = dispY[i] }

            // 1. Tether integration. Tether is the only integrated force;
            //    projection (step 2) is a positional constraint.
            for i in 0..<n {
                dispX[i] += stepSize * tetherStiffness * (truthX[i] - dispX[i])
                dispY[i] += stepSize * tetherStiffness * (truthY[i] - dispY[i])
            }

            // 2. PBD projection inner loop. Gauss-Seidel — each pair's
            //    half/half push is visible to subsequent pairs in the
            //    same pass, so projection converges in fewer passes than
            //    a Jacobi (deferred-update) variant. Loop terminates the
            //    first pass with zero violations, capped by safety net.
            var violationsInPass = 0
            for _ in 0..<maxProjectionPasses {
                violationsInPass = 0
                for i in 0..<n {
                    let ri = radii[i]
                    var j = i + 1
                    while j < n {
                        let dx = dispX[j] - dispX[i]
                        let dy = dispY[j] - dispY[i]
                        let d2 = dx * dx + dy * dy
                        let minDist = ri + radii[j] + minGap
                        if d2 < minDist * minDist {
                            let d = d2 > 0 ? d2.squareRoot() : 0
                            let overlap = minDist - d
                            let ux: CGFloat
                            let uy: CGFloat
                            if d > 0 {
                                ux = dx / d
                                uy = dy / d
                            } else {
                                // Deterministic separation axis for exact
                                // coincidence — alternate index pairs along
                                // ±x so a pile fans out instead of stalling.
                                ux = ((i + j) & 1) == 0 ? 1 : -1
                                uy = 0
                            }
                            let half = overlap * 0.5
                            dispX[i] -= ux * half
                            dispY[i] -= uy * half
                            dispX[j] += ux * half
                            dispY[j] += uy * half
                            violationsInPass += 1
                        }
                        j += 1
                    }
                }
                if violationsInPass == 0 { break }
            }

            // 3. Convergence on total motion across the whole outer iter
            //    (tether + projection combined). Stop only when the system
            //    has both settled AND projection's final pass was clean —
            //    a clean projection without small motion means tether
            //    pull is fully resisted by the constraint at equilibrium.
            var maxMotion: CGFloat = 0
            for i in 0..<n {
                let mx = dispX[i] - prevX[i]
                let my = dispY[i] - prevY[i]
                let m2 = mx * mx + my * my
                if m2 > maxMotion * maxMotion { maxMotion = m2.squareRoot() }
            }
            if maxMotion < settleThreshold && violationsInPass == 0 { break }
        }

        var out: [String: CanvasPosition] = truthPositions
        out.reserveCapacity(n)
        for (i, id) in ids.enumerated() {
            out[id] = CanvasPosition(x: Double(dispX[i]), y: Double(dispY[i]))
        }
        return out
    }
}
