import Foundation
import Accelerate

// SB139 Stage 4c2 — Bag-membrane layout (workstream ws-canvas-visual-model).
//
// Replaces the independent UMAP-to-2D display projection with a deterministic
// precompute that lays each HDBSCAN cluster as a spatial region ("bag") and
// places members at/near their bag anchor. Clusters are decided in 8D (high
// quality); this layer makes those clusters *visible as regions* in 2D
// without re-deriving a lossy flat projection inside each bag.
//
// **Stage 1 scope (this file):** centroid-per-cluster, classical MDS to 2D
// anchors, force-directed canvas-filling pass on the anchors, bag radius
// scaled by member count, golden-angle ring packing inside each bag, and
// a deterministic margin-ring placeholder for noise nodes (Stage 4 will
// replace with proper centroid-pull interstitial placement). Noise lives
// in the same MDS coord system as bags so the canvas adapter's single
// bbox rescale operates on consistent units.
//
// **Determinism contract:** same inputs → same output. No RNG. MDS sign
// canonicalized so re-fits with stable membership produce identical
// anchors (modulo membership changes themselves). Force-layout is
// deterministic by construction — fixed iteration count, fixed cooling
// schedule, no stochastic terms.

// MARK: - Persisted shape (schema-versioned forward-compat)

/// On-disk shape for the bag layout. Schema version is independent of
/// `UMAPFittedModel.schemaVersion`: the bag layout is a derived artifact
/// of a fit, but its persistence cadence and field set evolve along the
/// ws-canvas-visual-model arc (Stage 2 adds within-bag offsets; Stage 3
/// adds confidence/lean; Stage 4 adds noise placement). Stage 1 ships
/// `schemaVersion = 1`; future stages bump only if a field becomes
/// non-Optional or changes semantics.
struct BagLayout: Codable {
    var schemaVersion: Int
    var fitVersion: Int
    var bags: [BagAnchor]
    /// Per-node home positions, keyed by node ID. Includes both
    /// bag-clustered nodes and noise nodes — noise sits on a deterministic
    /// margin ring at the bag scale so the canvas adapter's bbox rescale
    /// sees one consistent coord system. Stage 4 will replace the noise
    /// ring with proper interstitial placement.
    var nodes: [String: NodeLayout]

    static let currentSchemaVersion = 1
}

/// Per-cluster anchor and region in MDS 2D units. The canvas adapter
/// rescales to canvas points downstream; MDS units are intentionally
/// dimensionless here so the bag-layout compute stays decoupled from
/// canvas geometry.
struct BagAnchor: Codable {
    /// Persistent registry UUID. Stable across re-fits when membership
    /// overlap holds — same cluster identity → same UUID → same bag
    /// recognized as "the recipes bag" across sessions.
    var persistentClusterID: UUID
    /// Session-local HDBSCAN label. Re-numbers on every fit; carried
    /// for joining with `SubstrateLayoutService.clusterLabels` without
    /// a second lookup.
    var hdbscanLabel: Int
    /// MDS 2D anchor (unitless).
    var center: SubstrateCoord2D
    /// Bag radius in the same MDS units. Scaled by `sqrt(memberCount)`
    /// so disk-area is linear in members (equal local density).
    var radius: Float
    /// Members assigned to this bag at compute time.
    var memberCount: Int
}

/// Per-node home + cluster metadata + forward-compat fields. `confidence`
/// and `leanTarget` land in later stages; Optional so Stage 1 files
/// round-trip cleanly when those stages ship.
struct NodeLayout: Codable {
    var home: SubstrateCoord2D
    /// Nil for noise (which won't appear in `BagLayout.nodes` in Stage 1
    /// anyway, but kept Optional so Stage 4's noise entries can carry
    /// `nil` here without a parallel field set).
    var persistentClusterID: UUID?
    var hdbscanLabel: Int
    /// Stage 3 — HDBSCAN membership probability for grading core/rim.
    var confidence: Float? = nil
    /// Stage 3 — 2D anchor of the most-similar other centroid, for the
    /// neighbor-lean bias.
    var leanTarget: SubstrateCoord2D? = nil
}

// MARK: - Compute

/// SB139 Stage 4c2 — bag-layout compute. Pure namespace; stateless.
/// Inputs flow in from `SubstrateLayoutService` after `runClustering`;
/// the returned `BagLayout` is cached on the service and consulted by
/// `canvasPlacements` to override the display-UMAP coord per node.
enum SubstrateBagLayout {

    /// Sentinel HDBSCAN noise label. Noise nodes are placed on a margin
    /// ring outside the bag layout (this file, post-bag loop) so they
    /// share the bag coord system; Stage 4 will replace the ring with
    /// proper interstitial placement.
    static let noiseLabel: Int = -1

    /// Build a bag layout from a fitted model + HDBSCAN labels +
    /// registry-resolved persistent IDs. Returns nil when no model is
    /// fitted, when the fit lacks 8D clustering coords (pre-c3 fallback
    /// path doesn't have them), or when no non-noise clusters exist.
    ///
    /// Determinism: no RNG; same inputs → same output. MDS sign is
    /// canonicalized so re-fits with stable membership re-emit
    /// byte-identical anchors.
    static func compute(
        trainingPoints: [UMAPFittedModel.TrainingPoint],
        clusterLabels: [Int],
        persistentClusterIDs: [UUID?],
        fitVersion: Int
    ) -> BagLayout? {
        guard !trainingPoints.isEmpty else { return nil }
        precondition(trainingPoints.count == clusterLabels.count,
                     "SubstrateBagLayout: trainingPoints/clusterLabels count mismatch")
        precondition(trainingPoints.count == persistentClusterIDs.count,
                     "SubstrateBagLayout: trainingPoints/persistentClusterIDs count mismatch")

        // Group node indices by cluster label.
        var byLabel: [Int: [Int]] = [:]
        for (idx, label) in clusterLabels.enumerated() {
            byLabel[label, default: []].append(idx)
        }
        let nonNoiseLabels = byLabel.keys.filter { $0 != noiseLabel }.sorted()
        guard !nonNoiseLabels.isEmpty else { return nil }

        // 8D centroid per cluster. Returns nil if any member lacks
        // clusteringCoord (legacy v3 fallback or pre-c3 v4 file).
        guard let centroids = computeCentroids(
            trainingPoints: trainingPoints,
            byLabel: byLabel,
            orderedLabels: nonNoiseLabels
        ) else { return nil }

        // Classical MDS on the K centroids → K anchors in 2D.
        guard var anchors = classicalMDS2D(centroids: centroids) else { return nil }
        precondition(anchors.count == nonNoiseLabels.count,
                     "SubstrateBagLayout: MDS anchor count mismatch")

        // Bag radius scaling: base picked so the largest bag's radius
        // is ~35% of the mean nearest-neighbor anchor spacing → bags
        // don't overlap initially even at the biggest cluster. 35%
        // leaves visible gaps for the eye to read regions; tunable
        // in later stages once membrane drawing lands.
        let anchorSpacing = meanNearestNeighborDistance(points: anchors)
        let maxMembers = nonNoiseLabels.map { byLabel[$0]!.count }.max() ?? 1
        let radiusBase: Float = Float(anchorSpacing * 0.35) / safeSqrt(Float(maxMembers))
        let radii: [Float] = nonNoiseLabels.map { label in
            radiusBase * safeSqrt(Float(byLabel[label]!.count))
        }

        // SB139 Stage 4c2 ws-canvas-visual-model — canvas-filling force
        // layout. Replaces the prior Jacobi pair-separation pass (commits
        // 15f86bc → 01c3c9e); separation only fixed overlap and left the
        // 14 non-recipe bags in their compressed MDS pile because MDS
        // preserves the genuine 8D similarity of those centroids. Force
        // layout adds two terms that separation lacked: long-range
        // pairwise repulsion (Coulomb) so bags spread to fill the
        // available frame, and a weak Hooke spring back to the MDS seed
        // so semantic outliers (recipes at MDS x≈2) stay outliers instead
        // of being homogenized into the spread.
        //
        // Labels render in the SwiftUI `clusterLabelOverlay` at the bag
        // centroid (bridged via `syncClusterCentroidsToCanvasState` in
        // CorpusPhysicsScene) and are decluttered there, so a bag's
        // visual footprint is only the packed-member disk + sprite
        // halo, not the ~400pt label width the prior padding budget
        // was sized for. Padding shrinks to 0.5× sprite radius
        // accordingly.
        //
        // Sprite radius is in canvas points (24pt mirrors
        // `SubstrateRelaxationPass.defaultRadius`); we work in MDS units.
        // The conversion factor is `targetSpan / finalLongerSpan` — but
        // finalLongerSpan depends on the layout we're about to run.
        // Bootstrap: estimate from pre-layout span × an expansion factor.
        // Force layout typically grows the bbox 2–4× on AirPad fits;
        // overshooting the estimate is harmless (bags spread more, easier
        // to read), undershooting starves the overlap term.
        let preLayoutLonger: Float = {
            var mnX: Float = .infinity, mxX: Float = -.infinity
            var mnY: Float = .infinity, mxY: Float = -.infinity
            for a in anchors {
                mnX = min(mnX, a.x); mxX = max(mxX, a.x)
                mnY = min(mnY, a.y); mxY = max(mxY, a.y)
            }
            return max(mxX - mnX, mxY - mnY)
        }()
        let estimatedExpansion: Float = 3.0
        let estimatedUnitsToPoints: Float =
            Float(SubstrateCanvasLayoutAdapter.targetSpan) /
            max(preLayoutLonger * estimatedExpansion, 1e-3)
        let spriteRadiusMDS: Float =
            Float(SubstrateRelaxationPass.defaultRadius) / estimatedUnitsToPoints
        let collisionRadii: [Float] = radii.map { $0 + spriteRadiusMDS }
        // Padding = half sprite-radius gap between dot footprints. Labels
        // gated → no label-margin budget needed; this is just breathing
        // room so adjacent bags read as distinct disks.
        let layoutPadding: Float = spriteRadiusMDS * 0.5
        _ = spreadAnchorsByForceLayout(
            anchors: &anchors,
            radii: collisionRadii,
            padding: layoutPadding
        )

        // Re-center anchors at centroid so the bounding box is balanced
        // around origin and the canvas adapter's bbox-midpoint
        // normalization sits on the centroid. Force layout produces a
        // roughly-centered output (Coulomb is symmetric), but a strict
        // recenter is cheap and guarantees re-fits with identical
        // membership produce identical canvas placement.
        recenterAtOrigin(&anchors)

        var bags: [BagAnchor] = []
        bags.reserveCapacity(nonNoiseLabels.count)
        var nodes: [String: NodeLayout] = [:]
        nodes.reserveCapacity(trainingPoints.count)

        for (k, label) in nonNoiseLabels.enumerated() {
            let center = anchors[k]
            let memberIndices = byLabel[label]!
            let radius = radii[k]

            // Vote for cluster UUID: take the first non-nil persistent
            // ID among members. All members of a cluster should resolve
            // to the same UUID by registry invariant; defensive first()
            // tolerates transitional nils from the registry-resolution
            // seam in `SubstrateLayoutService.runClustering`.
            guard let clusterUUID = memberIndices
                .lazy
                .compactMap({ persistentClusterIDs[$0] })
                .first
            else { continue }  // skip clusters with no registry UUID yet

            bags.append(BagAnchor(
                persistentClusterID: clusterUUID,
                hdbscanLabel: label,
                center: center,
                radius: radius,
                memberCount: memberIndices.count
            ))

            // Golden-angle ring packing inside the bag. Index 0 sits at
            // center; subsequent members spiral outward by the golden
            // angle so packing has no axis-aligned bias and is dense.
            for (memberOrder, ptIdx) in memberIndices.enumerated() {
                let home = goldenAngleOffset(
                    index: memberOrder,
                    total: memberIndices.count,
                    center: center,
                    maxRadius: radius
                )
                let tp = trainingPoints[ptIdx]
                nodes[tp.nodeID] = NodeLayout(
                    home: home,
                    persistentClusterID: clusterUUID,
                    hdbscanLabel: label
                )
            }
        }

        // SB139 Stage 4c2 ws-canvas-visual-model — noise placement (margin ring).
        //
        // The first bag-separation pass shipped 15f86bc revealed that letting
        // noise fall through to `point.coord2D` (display-UMAP coord) mixed two
        // incompatible scales at the canvas adapter: bag layout in MDS units
        // (span ~3) vs display-UMAP (span ~8) → adapter's single bbox rescale
        // crushed bags into ~23% of the canvas. Fix: place noise nodes in
        // bag-layout MDS units on a ring just outside the farthest bag edge,
        // so the adapter sees a consistent coord system and bags fill ~85% of
        // the canvas (the 15% reserve being the noise-ring margin).
        //
        // Stage 4 will replace the ring with proper centroid-pull interstitial
        // placement; this is the simplest deterministic margin-fill that keeps
        // noise visible without distorting the bag scale.
        let noiseIndices = (byLabel[noiseLabel] ?? [])
            .sorted { trainingPoints[$0].nodeID < trainingPoints[$1].nodeID }
        if !noiseIndices.isEmpty {
            // Furthest reach of any bag from origin (post-recenter anchors).
            var maxBagExtent: Float = 0
            for bag in bags {
                let centerDist = (bag.center.x * bag.center.x + bag.center.y * bag.center.y).squareRoot()
                let ext = centerDist + bag.radius
                if ext > maxBagExtent { maxBagExtent = ext }
            }
            // 1.15× = 15% gap between farthest bag edge and the noise ring.
            // Small enough that bags still fill the eye; large enough that
            // noise visibly sits "outside" the bag region.
            let noiseRingR: Float = max(maxBagExtent, 1) * 1.15
            let n = noiseIndices.count
            for (i, ptIdx) in noiseIndices.enumerated() {
                let angle = Float(i) * (2.0 * .pi) / Float(n)
                let nx = noiseRingR * Foundation.cos(angle)
                let ny = noiseRingR * Foundation.sin(angle)
                let tp = trainingPoints[ptIdx]
                nodes[tp.nodeID] = NodeLayout(
                    home: SubstrateCoord2D(x: nx, y: ny),
                    persistentClusterID: nil,
                    hdbscanLabel: noiseLabel
                )
            }
        }

        return BagLayout(
            schemaVersion: BagLayout.currentSchemaVersion,
            fitVersion: fitVersion,
            bags: bags,
            nodes: nodes
        )
    }

    // MARK: - Centroids

    private static func computeCentroids(
        trainingPoints: [UMAPFittedModel.TrainingPoint],
        byLabel: [Int: [Int]],
        orderedLabels: [Int]
    ) -> [[Double]]? {
        var centroids: [[Double]] = []
        centroids.reserveCapacity(orderedLabels.count)
        var dim = 0
        for label in orderedLabels {
            let indices = byLabel[label]!
            guard let firstCoord = trainingPoints[indices[0]].coordClustering,
                  !firstCoord.isEmpty else { return nil }
            if dim == 0 { dim = firstCoord.count }
            guard firstCoord.count == dim else { return nil }
            var sum = [Double](repeating: 0, count: dim)
            for i in indices {
                guard let c = trainingPoints[i].coordClustering, c.count == dim
                else { return nil }
                for d in 0..<dim { sum[d] += Double(c[d]) }
            }
            let n = Double(indices.count)
            for d in 0..<dim { sum[d] /= n }
            centroids.append(sum)
        }
        return centroids
    }

    // MARK: - Classical MDS

    /// Classical multidimensional scaling: K centroids in D-space →
    /// K anchors in 2-space such that pairwise distances are best-
    /// preserved (in the L2-on-Gram sense). Implemented as
    /// double-centered Gram eigendecomp via SVD on the symmetric PSD
    /// `B = -0.5 J D² J` matrix. K=1 returns origin; K<1 returns nil.
    private static func classicalMDS2D(centroids: [[Double]]) -> [SubstrateCoord2D]? {
        let k = centroids.count
        guard k >= 1 else { return nil }
        if k == 1 { return [SubstrateCoord2D(x: 0, y: 0)] }
        if k == 2 {
            // Two-cluster degenerate: place on x-axis at ±d/2.
            let d = euclidean(centroids[0], centroids[1])
            let half = Float(d / 2)
            return [
                SubstrateCoord2D(x: -half, y: 0),
                SubstrateCoord2D(x: half, y: 0)
            ]
        }

        // K×K squared distance matrix.
        var d2 = [Double](repeating: 0, count: k * k)
        for i in 0..<k {
            for j in (i + 1)..<k {
                let dij = euclidean(centroids[i], centroids[j])
                let s = dij * dij
                d2[i * k + j] = s
                d2[j * k + i] = s
            }
        }

        // Double-centering: B = -0.5 * (D² - row_means - col_means + grand_mean)
        var rowMeans = [Double](repeating: 0, count: k)
        var colMeans = [Double](repeating: 0, count: k)
        var grandMean = 0.0
        for i in 0..<k {
            for j in 0..<k {
                let v = d2[i * k + j]
                rowMeans[i] += v
                colMeans[j] += v
                grandMean += v
            }
        }
        for i in 0..<k { rowMeans[i] /= Double(k) }
        for j in 0..<k { colMeans[j] /= Double(k) }
        grandMean /= Double(k * k)

        var b = [Double](repeating: 0, count: k * k)
        for i in 0..<k {
            for j in 0..<k {
                b[i * k + j] = -0.5 * (d2[i * k + j] - rowMeans[i] - colMeans[j] + grandMean)
            }
        }

        // B is real symmetric PSD; SVD gives eigenvalues (singulars,
        // descending) and eigenvectors (columns of U). LAPACK dgesvd_
        // wants column-major — B is symmetric so row- and column-major
        // are identical; safe to pass as-is.
        guard let (uColMajor, singulars) = lapackSVDSymmetric(matrix: &b, n: k) else {
            return nil
        }
        guard singulars.count >= 2 else { return nil }

        // Top-2 eigvec columns × sqrt(singulars[0..1]). U is K×K
        // column-major; column j starts at offset j*K.
        let s0 = singulars[0] > 0 ? singulars[0].squareRoot() : 0
        let s1 = singulars[1] > 0 ? singulars[1].squareRoot() : 0

        var coords = [SubstrateCoord2D](repeating: SubstrateCoord2D(x: 0, y: 0), count: k)
        for i in 0..<k {
            let x = uColMajor[0 * k + i] * s0
            let y = uColMajor[1 * k + i] * s1
            coords[i] = SubstrateCoord2D(x: Float(x), y: Float(y))
        }

        // Canonicalize axis signs so re-fits with stable membership
        // re-emit identical anchors instead of mirror-flipping. The
        // SVD sign is arbitrary (U and -U both satisfy A = UΣVᵀ for
        // symmetric A). Convention: flip each axis so its max-absolute
        // value is positive — same convention sklearn PCA uses.
        canonicalizeAxisSigns(&coords)

        return coords
    }

    // MARK: - LAPACK adapter

    /// SVD wrapper for a real symmetric N×N matrix. Returns the U
    /// matrix (column-major, N×N) and singular values descending.
    /// For symmetric PSD inputs singular values = eigenvalues and U
    /// columns = eigenvectors. Pattern mirrors `SubstrateWhitening`.
    private static func lapackSVDSymmetric(
        matrix: inout [Double],
        n: Int
    ) -> (uColMajor: [Double], singulars: [Double])? {
        var jobu: CChar = CChar(UInt8(ascii: "A"))   // full U
        var jobvt: CChar = CChar(UInt8(ascii: "N"))  // V not needed
        var m_ = __CLPK_integer(n)
        var n_ = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var s = [Double](repeating: 0, count: n)
        var u = [Double](repeating: 0, count: n * n)
        var ldu = __CLPK_integer(n)
        var vt = [Double](repeating: 0, count: 1)
        var ldvt = __CLPK_integer(1)
        var info: __CLPK_integer = 0

        var workspaceQuery: Double = 0
        var lworkQuery = __CLPK_integer(-1)
        dgesvd_(&jobu, &jobvt, &m_, &n_, &matrix, &lda, &s,
                &u, &ldu, &vt, &ldvt, &workspaceQuery, &lworkQuery, &info)
        guard info == 0 else { return nil }

        let optimalSize = max(1, Int(workspaceQuery))
        var work = [Double](repeating: 0, count: optimalSize)
        var lwork = __CLPK_integer(optimalSize)
        dgesvd_(&jobu, &jobvt, &m_, &n_, &matrix, &lda, &s,
                &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        guard info == 0 else { return nil }

        return (u, s)
    }

    // MARK: - Packing

    /// Golden-angle ring packing. Index 0 at center; subsequent indices
    /// spiral outward at the golden angle (137.5°) with radius scaled
    /// by √(i/N) so disk-area per slot is uniform. Same packing
    /// `umap-learn` uses for `init='random'` initial placements.
    private static func goldenAngleOffset(
        index: Int,
        total: Int,
        center: SubstrateCoord2D,
        maxRadius: Float
    ) -> SubstrateCoord2D {
        guard total > 0 else { return center }
        if index == 0 || total == 1 { return center }
        let goldenAngle: Float = .pi * (3.0 - (5.0 as Float).squareRoot())
        let theta = Float(index) * goldenAngle
        // r ∝ √(i / (N-1)) so radius spans [0, maxRadius] as i goes [0, N-1].
        // Reserve i=0 for center; i=1..N-1 spiral out.
        let normalized = Float(index) / Float(max(total - 1, 1))
        let r = maxRadius * safeSqrt(normalized)
        let dx = r * Foundation.cos(theta)
        let dy = r * Foundation.sin(theta)
        return SubstrateCoord2D(x: center.x + dx, y: center.y + dy)
    }

    // MARK: - Force-directed canvas-filling layout

    /// Deterministic force-directed layout on the K bag anchors. Three
    /// force terms per iteration, computed Jacobi-style (all forces
    /// summed before any anchor moves) so the result is order-independent:
    ///
    /// 1. **Pairwise Coulomb repulsion** (`k_rep / dist²`, all pairs).
    ///    Calibrated `k_rep = meanSeedSpacing²` so the repulsive force is
    ///    unit-magnitude at the MDS-seeded mean spacing. This is the
    ///    canvas-filling term — without it, MDS leaves semantically-similar
    ///    bags compressed into a central pile because their 8D centroids
    ///    are genuinely close, even though the 2D canvas has room to
    ///    spread them.
    ///
    /// 2. **Short-range overlap correction** (full split when
    ///    `dist < radii[i] + radii[j] + padding`). Guarantees min spacing
    ///    is respected by the end-state — Coulomb alone is a soft
    ///    constraint and could leave residual overlap at convergence.
    ///
    /// 3. **Weak Hooke spring to the MDS seed** (`k_seed × (seed - pos)`,
    ///    `k_seed = 0.04`). Preserves the MDS topology so genuine
    ///    semantic outliers (e.g. recipes at MDS x≈2 on AirPad's corpus)
    ///    stay outside the spread cluster instead of being homogenized
    ///    into uniform repulsion-equilibrium. Weak enough that the 14
    ///    near-equidistant non-recipe centroids can freely spread, strong
    ///    enough that the recipes anchor's pre-layout offset is preserved
    ///    in the final layout.
    ///
    /// Cooling schedule: linear from `stepInit` to `stepFinal` across the
    /// iteration budget — large early steps converge from MDS-seed
    /// initial conditions, small late steps polish into a stable
    /// equilibrium.
    ///
    /// Convergence check: returns early when the maximum per-iteration
    /// position update falls below `meanSeedSpacing × 1e-4`. Cheap at
    /// AirPad's scale (K=15 → 105 pairs/iter) and typically converges
    /// well before the cap.
    ///
    /// Coincident-anchor case (`dist < colinearEpsilon`) resolves to a
    /// fixed x-axis split by index parity. No RNG anywhere; output is
    /// byte-identical for identical inputs.
    @discardableResult
    private static func spreadAnchorsByForceLayout(
        anchors: inout [SubstrateCoord2D],
        radii: [Float],
        padding: Float,
        maxIterations: Int = 400
    ) -> Int {
        let n = anchors.count
        guard n >= 2 else { return 0 }
        precondition(radii.count == n,
                     "SubstrateBagLayout.spreadAnchorsByForceLayout: anchors/radii count mismatch")

        // Snapshot MDS positions for the Hooke spring (immutable through
        // the loop). Anchors mutate; seeds don't.
        let seeds = anchors
        let meanSpacing = Float(meanNearestNeighborDistance(points: seeds))
        let kRepel: Float = meanSpacing * meanSpacing   // unit force at mean spacing
        let kSeed: Float = 0.04                          // weak topology-preserving spring
        let stepInit: Float = 0.6
        let stepFinal: Float = 0.02
        let convergenceEpsilon: Float = meanSpacing * 1e-4
        let colinearEpsilon: Float = 1e-6

        for iter in 0..<maxIterations {
            let t = Float(iter) / Float(max(maxIterations - 1, 1))
            let step = stepInit * (1 - t) + stepFinal * t

            var forces = [SubstrateCoord2D](
                repeating: SubstrateCoord2D(x: 0, y: 0),
                count: n
            )

            // Pairwise: Coulomb repulsion + overlap correction.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = anchors[j].x - anchors[i].x
                    let dy = anchors[j].y - anchors[i].y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let required = radii[i] + radii[j] + padding
                    let nx: Float
                    let ny: Float
                    if dist < colinearEpsilon {
                        nx = (i % 2 == 0) ? 1 : -1
                        ny = 0
                    } else {
                        nx = dx / dist
                        ny = dy / dist
                    }

                    // Long-range Coulomb (always active). Clamp denominator
                    // to half the required spacing so the force doesn't
                    // explode at near-coincidence — overlap correction
                    // below handles the truly-close regime.
                    let safeDist = max(dist, required * 0.5)
                    let mag = kRepel / (safeDist * safeDist)
                    forces[i].x -= nx * mag
                    forces[i].y -= ny * mag
                    forces[j].x += nx * mag
                    forces[j].y += ny * mag

                    // Hard overlap correction (only when too close).
                    if dist < required {
                        let overlap = required - dist
                        let half = overlap * 0.5
                        forces[i].x -= nx * half
                        forces[i].y -= ny * half
                        forces[j].x += nx * half
                        forces[j].y += ny * half
                    }
                }
            }

            // Hooke spring to MDS seed (per-anchor).
            for i in 0..<n {
                forces[i].x += (seeds[i].x - anchors[i].x) * kSeed
                forces[i].y += (seeds[i].y - anchors[i].y) * kSeed
            }

            // Apply with cooling; track max update for convergence check.
            var maxUpdate2: Float = 0
            for i in 0..<n {
                let dxApply = forces[i].x * step
                let dyApply = forces[i].y * step
                let m2 = dxApply * dxApply + dyApply * dyApply
                if m2 > maxUpdate2 { maxUpdate2 = m2 }
                anchors[i].x += dxApply
                anchors[i].y += dyApply
            }
            if maxUpdate2.squareRoot() < convergenceEpsilon {
                return iter + 1
            }
        }
        return maxIterations
    }

    private static func recenterAtOrigin(_ coords: inout [SubstrateCoord2D]) {
        guard !coords.isEmpty else { return }
        var sx: Float = 0
        var sy: Float = 0
        for c in coords {
            sx += c.x
            sy += c.y
        }
        let cx = sx / Float(coords.count)
        let cy = sy / Float(coords.count)
        for i in 0..<coords.count {
            coords[i] = SubstrateCoord2D(x: coords[i].x - cx, y: coords[i].y - cy)
        }
    }

    // MARK: - Geometry helpers

    private static func euclidean(_ a: [Double], _ b: [Double]) -> Double {
        precondition(a.count == b.count, "SubstrateBagLayout.euclidean: dim mismatch")
        var s = 0.0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            s += d * d
        }
        return s.squareRoot()
    }

    private static func meanNearestNeighborDistance(points: [SubstrateCoord2D]) -> Double {
        let n = points.count
        guard n >= 2 else { return 1.0 }
        var sum = 0.0
        for i in 0..<n {
            var best = Double.infinity
            for j in 0..<n where j != i {
                let dx = Double(points[i].x - points[j].x)
                let dy = Double(points[i].y - points[j].y)
                let d = (dx * dx + dy * dy).squareRoot()
                if d < best { best = d }
            }
            sum += best
        }
        return sum / Double(n)
    }

    private static func canonicalizeAxisSigns(_ coords: inout [SubstrateCoord2D]) {
        // For each axis, flip so the max-|value| coord projects positive.
        var maxAbsX: Float = 0
        var signX: Float = 1
        for c in coords {
            let a = abs(c.x)
            if a > maxAbsX {
                maxAbsX = a
                signX = c.x >= 0 ? 1 : -1
            }
        }
        var maxAbsY: Float = 0
        var signY: Float = 1
        for c in coords {
            let a = abs(c.y)
            if a > maxAbsY {
                maxAbsY = a
                signY = c.y >= 0 ? 1 : -1
            }
        }
        if signX < 0 || signY < 0 {
            for i in 0..<coords.count {
                coords[i] = SubstrateCoord2D(
                    x: coords[i].x * signX,
                    y: coords[i].y * signY
                )
            }
        }
    }

    private static func safeSqrt(_ x: Float) -> Float {
        x > 0 ? x.squareRoot() : 0
    }
}
