import Foundation
import CoreGraphics

/// Strand selection + ring-slot geometry. Used by `CorpusPhysicsScene` to
/// snap a focal node's top substrate neighbors onto a concentric ring during
/// engaged state, then snap them back on disengage.
///
/// Substrate-pure path: pair similarity is `SubstrateService.rankingPairSimilarity`,
/// the same signal `SubstrateThreadService` uses. Thresholds are lower than the
/// threading thresholds — strands are ephemeral + engagement-scoped, so a lower
/// floor is honest (sparse rings are valid output).
@available(iOS 17.0, *)
@MainActor
enum StrandService {

    // MARK: - Defaults

    static let defaultBlendedThreshold: Double = 0.50
    static let defaultContentFallbackThreshold: Double = 0.60
    static let defaultMinAngularSeparationDeg: Double = 30.0
    static let defaultDimAlpha: Double = 0.3
    static let defaultFocalScaleMultiplier: Double = 0.4

    // MARK: - UserDefaults keys (shared with inspect view)

    static let blendedThresholdKey = "strand.blendedThreshold"
    static let contentThresholdKey = "strand.contentThreshold"
    static let minAngularSeparationDegKey = "strand.minAngularSeparationDeg"
    static let ringRadiusMultiplierKey = "strand.ringRadiusMultiplier"
    static let dimAlphaKey = "strand.dimAlpha"
    static let focalScaleMultiplierKey = "strand.focalScaleMultiplier"

    static var blendedThreshold: Double {
        let v = UserDefaults.standard.double(forKey: blendedThresholdKey)
        return v > 0 ? v : defaultBlendedThreshold
    }

    static var contentFallbackThreshold: Double {
        let v = UserDefaults.standard.double(forKey: contentThresholdKey)
        return v > 0 ? v : defaultContentFallbackThreshold
    }

    static var minAngularSeparation: CGFloat {
        let deg = UserDefaults.standard.double(forKey: minAngularSeparationDegKey)
        let effectiveDeg = deg > 0 ? deg : defaultMinAngularSeparationDeg
        return CGFloat(effectiveDeg * .pi / 180.0)
    }

    /// Alpha applied to non-strand, non-focal sprites during engagement.
    /// Clamped to [0.05, 1.0] — fully transparent would hide structure;
    /// 1.0 disables dimming. Default 0.3.
    static var dimAlpha: CGFloat {
        let v = UserDefaults.standard.double(forKey: dimAlphaKey)
        let effective = v > 0 ? v : defaultDimAlpha
        return CGFloat(max(0.05, min(1.0, effective)))
    }

    /// Strand sprites scale to this fraction of the focal's screen-space scale,
    /// preserving relative intrinsic sizing among strands while keeping their
    /// on-screen footprint stable across zoom levels (the focal already uses
    /// screen-space sigmoid scaling). Clamped to [0.05, 1.0]. Default 0.4.
    static var focalScaleMultiplier: CGFloat {
        let v = UserDefaults.standard.double(forKey: focalScaleMultiplierKey)
        let effective = v > 0 ? v : defaultFocalScaleMultiplier
        return CGFloat(max(0.05, min(1.0, effective)))
    }

    static func threshold(for path: PairSimilarity.Path) -> Double? {
        switch path {
        case .blendedSummaryFolksonomy, .blendedFromLegacy: return blendedThreshold
        case .contentFallback: return contentFallbackThreshold
        case .noSignal: return nil
        }
    }

    // MARK: - Selection

    struct Pick {
        let node: Node
        let score: Double
    }

    /// Top-k substrate neighbors of `focal` above strand thresholds, sorted by
    /// blended cosine descending. Sparse rings (fewer than k qualifying) are
    /// valid output. Returns empty when focal is non-rankable or meta.
    static func neighbors(of focal: Node, in nodes: [Node], k: Int = 5) -> [Pick] {
        guard !focal.isMeta else { return [] }
        let substrate = SubstrateService.shared
        guard substrate.isRankable(focal) else { return [] }

        var picks: [Pick] = []
        for other in nodes where other.id != focal.id && !other.isMeta {
            guard substrate.isRankable(other) else { continue }
            let p = substrate.rankingPairSimilarity(focal, other)
            guard let blended = p.blended,
                  let T = threshold(for: p.path),
                  blended >= T else { continue }
            picks.append(Pick(node: other, score: blended))
        }

        return Array(picks.sorted { $0.score > $1.score }.prefix(k))
    }

    // MARK: - Ring slot geometry

    struct NeighborPos {
        let id: String
        let pos: CGPoint
    }

    /// Resolves ring slots for strand-neighbors around a focal at a given
    /// radius in the undistorted (substrate-resting) frame. Each slot's raw
    /// angle is the substrate-direction from focal to neighbor's resting
    /// position — preserves a hint of substrate geography on the temporary
    /// ring (NE neighbor lands NE on the ring).
    ///
    /// Collision resolution: greedy minimum angular separation. Neighbors are
    /// sorted by raw angle; each is nudged forward if it sits within
    /// `minAngularSeparation` of the previous slot. If the total angular
    /// footprint exceeds 2π (which only happens if minSeparation × count > 2π),
    /// slots are distributed evenly around the circle starting from the first
    /// neighbor's raw angle, preserving order.
    static func ringSlots(
        focalRestingPos: CGPoint,
        neighbors: [NeighborPos],
        radius: CGFloat,
        minAngularSeparation: CGFloat
    ) -> [String: CGPoint] {
        guard !neighbors.isEmpty else { return [:] }

        struct Slot { let id: String; var angle: CGFloat }

        var slots: [Slot] = neighbors.map { n in
            let dx = n.pos.x - focalRestingPos.x
            let dy = n.pos.y - focalRestingPos.y
            return Slot(id: n.id, angle: atan2(dy, dx))
        }
        slots.sort { $0.angle < $1.angle }

        let count = CGFloat(slots.count)
        let totalSeparationNeeded = count * minAngularSeparation
        let twoPi: CGFloat = 2 * .pi

        if totalSeparationNeeded > twoPi {
            let step = twoPi / count
            let start = slots[0].angle
            for i in 0..<slots.count {
                slots[i].angle = start + CGFloat(i) * step
            }
        } else {
            for i in 1..<slots.count {
                let needed = slots[i - 1].angle + minAngularSeparation
                if slots[i].angle < needed { slots[i].angle = needed }
            }
            let wrap = (slots[0].angle + twoPi) - slots.last!.angle
            if wrap < minAngularSeparation {
                let step = twoPi / count
                let start = slots[0].angle
                for i in 0..<slots.count {
                    slots[i].angle = start + CGFloat(i) * step
                }
            }
        }

        var out: [String: CGPoint] = [:]
        for s in slots {
            let x = focalRestingPos.x + radius * cos(s.angle)
            let y = focalRestingPos.y + radius * sin(s.angle)
            out[s.id] = CGPoint(x: x, y: y)
        }
        return out
    }
}
