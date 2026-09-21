import Foundation
import CoreGraphics
import CryptoKit

/// Which language-vector basis a territory layout was formed on. Only a `.card`
/// layout is worth persisting/restoring: the map-relayout regression was that
/// every cold launch formed on `.legacy` (the card-gist cache starts cold), then
/// async-warmed the cache and RE-FORMED on `.card`, animating the difference
/// (`CanvasView.warmCardVectorsThenReform`). Persisting the `.card` geography and
/// restoring it on launch makes formation deliberate-only again — the original
/// `8331bfc` "form once" intent.
enum LayoutBasis: String, Codable {
    case legacy
    case card
}

/// Persisted snapshot of the tag-anchored Map's DERIVED territory geography.
///
/// The Map never stored positions as truth — it re-derives them via
/// `TagTerritoryLayout.layout`. This snapshot lets a RELAUNCH restore the last
/// card-basis geography verbatim (placed instantly by `syncScene`, no
/// re-simulation) instead of re-deriving + animating it. Formation still happens
/// on deliberate triggers (Analyze / anchor change / weight dial / batch import)
/// and re-persists here. Mirrors `TagTerritoryLayout.Layout` in full (positions +
/// membership + centers + centroids) so drift-in of a newly-captured node still
/// argmax-places against the restored geography, plus each territory's palette-slot claim.
struct TerritoryLayoutSnapshot: Codable {
    /// v2 (2026-09-17) — `colorsHex` (per-node frozen tint, baked to ONE appearance) replaced by
    /// `territorySlot` (territory key → palette slot). A slot is appearance-agnostic: the colour is
    /// re-resolved from it for whichever ground is current, which a persisted hex cannot do.
    static let currentVersion = 2

    let version: Int
    var updatedAt: Date
    var basis: LayoutBasis
    /// Fingerprint of the territory-determining inputs. A restore is honored only
    /// when this matches the current inputs — see `TerritoryLayoutRestore`.
    var signature: String

    var positions: [String: CanvasPosition]
    var nodeTerritory: [String: String]
    var territories: [TerritoryDTO]
    var centers: [String: PointDTO]
    var centroids: [String: [Float]]
    /// ★ WHICH SPACE `centroids` live in, as a raw `VectorBasis` string. Persisted so a RESTORED
    /// layout can still tell `driftPlacement` what space it is in — without it, a node captured in
    /// a restored session is scored against centroids of unknown provenance.
    var centroidBasis: String?
    /// ★ TERRITORY KEY → PALETTE SLOT — the CLAIM MAP. A territory claims a slot the first time it
    /// is seen and keeps it for life (T's ruling, 2026-09-16), so re-forming never reshuffles
    /// colours. Before this, colour was the territory's INDEX in an alphabetically-sorted array, so
    /// one territory blinking in or out shifted every colour after it — the reshuffle-on-Analyze
    /// defect.
    ///
    /// ★★ THIS FIELD IS NOT GOVERNED BY `signature`. That is the whole point, and it is the one
    /// thing not to "tidy up" later. `signature` asks "is this GEOGRAPHY still valid?" — adding a
    /// node correctly invalidates it. Slots answer a different question, "what colour is this
    /// territory?", whose answer must survive exactly the changes that invalidate geography.
    /// Putting both behind one gate is precisely the defect: it is why adding a node recoloured the
    /// map. Read this map unconditionally (`CanvasView.persistedSlotClaims`); read everything else
    /// through `TerritoryLayoutRestore.canRestore`.
    ///
    /// Retains entries for territories that have DISAPPEARED — their slot stays "held", so a
    /// territory that comes back gets its colour back.
    var territorySlot: [String: Int]

    struct TerritoryDTO: Codable {
        var key: String
        var name: String
    }
    struct PointDTO: Codable {
        var x: Double
        var y: Double
    }

    enum CodingKeys: String, CodingKey {
        case version, basis, signature, positions, nodeTerritory
        case territories, centers, centroids
        case territorySlot = "territory_slot"
        case centroidBasis = "centroid_basis"
        case updatedAt = "updated_at"
    }

    /// Decode-tolerant (codebase norm — `Node`, `Proposal`, `HeroCrop`). A v1 snapshot has no
    /// `territory_slot` key and a `colorsHex` key this type no longer models. Without this it would
    /// THROW, `store.territoryLayout` would be nil, and the load path would lose the snapshot
    /// wholesale rather than degrade. It decodes instead: geography is still refused by the version
    /// check, and the claim map simply starts empty and is re-claimed once.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version        = try c.decode(Int.self, forKey: .version)
        updatedAt      = try c.decode(Date.self, forKey: .updatedAt)
        basis          = try c.decode(LayoutBasis.self, forKey: .basis)
        signature      = try c.decode(String.self, forKey: .signature)
        positions      = try c.decode([String: CanvasPosition].self, forKey: .positions)
        nodeTerritory  = try c.decode([String: String].self, forKey: .nodeTerritory)
        territories    = try c.decode([TerritoryDTO].self, forKey: .territories)
        centers        = try c.decode([String: PointDTO].self, forKey: .centers)
        centroids      = try c.decode([String: [Float]].self, forKey: .centroids)
        centroidBasis  = try c.decodeIfPresent(String.self, forKey: .centroidBasis)
        territorySlot  = try c.decodeIfPresent([String: Int].self, forKey: .territorySlot) ?? [:]
    }

    init(version: Int, updatedAt: Date, basis: LayoutBasis, signature: String,
         positions: [String: CanvasPosition], nodeTerritory: [String: String],
         territories: [TerritoryDTO], centers: [String: PointDTO],
         centroids: [String: [Float]], centroidBasis: String?, territorySlot: [String: Int]) {
        self.version = version
        self.updatedAt = updatedAt
        self.basis = basis
        self.signature = signature
        self.positions = positions
        self.nodeTerritory = nodeTerritory
        self.territories = territories
        self.centers = centers
        self.centroids = centroids
        self.centroidBasis = centroidBasis
        self.territorySlot = territorySlot
    }
}

/// Pure, testable restore-decision logic. This is where the map-relayout gate
/// lives (`TerritoryLayoutRestoreSelfTest`): keep it free of view / store / actor
/// state so a "relaunch" is just "call `signature` again".
enum TerritoryLayoutRestore {

    /// One node's territory-determining membership: ONLY the parts that steer the
    /// layout — the user collections it belongs to, and the anchor tags it carries.
    /// Title / summary / content are deliberately excluded, so editing them must
    /// NOT invalidate a restore (they never move a node between territories).
    struct NodeMembership {
        let id: String
        let collectionIDs: [String]
        let anchorTags: [String]
    }

    /// STABLE (cross-launch) fingerprint of the inputs that determine the layout.
    /// SHA-256, NOT `String.hashValue`: hashValue is per-process randomized, so a
    /// hashValue-based signature would differ on every relaunch and silently
    /// defeat restore — the exact "third resurrection" trap the gate guards.
    static func signature(
        memberships: [NodeMembership],
        anchorNames: [String],
        userCollectionIDs: [String],
        weights: TagTerritoryLayout.SignalWeights,
        basis: LayoutBasis
    ) -> String {
        let w = String(format: "%.5f,%.5f,%.5f,%.5f",
                       weights.collection, weights.anchor, weights.language, weights.backlink)
        let nodePart = memberships
            .sorted { $0.id < $1.id }
            .map { m in
                "\(m.id):\(m.collectionIDs.sorted().joined(separator: "|"))/\(m.anchorTags.sorted().joined(separator: "|"))"
            }
            .joined(separator: ";")
        let raw = [
            "v\(TerritoryLayoutSnapshot.currentVersion)",
            "basis=\(basis.rawValue)",
            "w=\(w)",
            "A=\(anchorNames.sorted().joined(separator: ","))",
            "C=\(userCollectionIDs.sorted().joined(separator: ","))",
            "N=\(nodePart)"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A snapshot may be RESTORED (skipping re-formation + the animated reform)
    /// only when it is a current-version CARD-basis layout whose signature still
    /// matches the live inputs. Everything else — legacy basis, version drift,
    /// changed membership / anchors / weights, or an unreadable snapshot (nil) —
    /// falls through to re-formation, which re-persists a fresh card snapshot.
    static func canRestore(_ snapshot: TerritoryLayoutSnapshot?, currentCardSignature: String) -> Bool {
        guard let snapshot else { return false }
        return snapshot.version == TerritoryLayoutSnapshot.currentVersion
            && snapshot.basis == .card
            && snapshot.signature == currentCardSignature
    }
}

/// THE CLAIM RULE — which palette slot a territory gets, and why it never changes.
///
/// Pure and view-free on purpose: this is the logic the reshuffle defect lived in, so it is the
/// logic that most needs to be exercisable without a corpus (same reason `EnrichmentGate` is its
/// own type). `TerritoryLayoutRestoreSelfTest` covers it.
///
/// ★ T's RULING (2026-09-16): a territory keeps its colour for life. Colour was previously the
/// territory's INDEX in an alphabetically-sorted array, so one territory blinking in or out shifted
/// every colour after it — which is what made Analyze look like it was reshuffling the map.
enum TerritorySlotClaims {

    /// Returns the FULL claim map: existing claims plus one for every current key that lacked one.
    ///
    /// ★ Entries for ABSENT territories are RETAINED, not pruned. Their slots stay "held", so a
    /// territory that disappears and later returns gets its own colour back rather than whatever
    /// happens to be free. Pruning them would reintroduce the defect in slower motion.
    ///
    /// An unclaimed territory takes, in order:
    ///   1. the lowest slot NOBODY has ever claimed;
    ///   2. else the lowest slot held only by an ABSENT territory — held slots become claimable
    ///      once nothing is genuinely free; the absent owner keeps its entry and simply shares;
    ///   3. else (more live territories than slots) the slot carried by the FEWEST current
    ///      territories, ties to the lowest. Reuse is acceptable past `slotCount` because spatial
    ///      separation carries the distinction (T's ruling). Generating-for-N, adjacency-aware
    ///      assignment and lightness subdivision are POST-V1 and deliberately not attempted.
    ///
    /// Claims are granted in sorted key order, so the result is a function of (prior map, key set)
    /// only — never of dictionary iteration order.
    static func claim(currentKeys: [String],
                      existing: [String: Int],
                      slotCount: Int = RegionPalette.slotCount) -> [String: Int] {
        var claims = existing
        let unclaimed = currentKeys.filter { claims[$0] == nil }.sorted()
        guard !unclaimed.isEmpty else { return claims }
        let slots = max(slotCount, 1)
        let currentSet = Set(currentKeys)
        for key in unclaimed {
            var heldByCurrent: [Int: Int] = [:]
            for k in currentSet { if let slot = claims[k] { heldByCurrent[slot, default: 0] += 1 } }
            let claimedByAnyone = Set(claims.values)
            if let free = (0..<slots).first(where: { !claimedByAnyone.contains($0) }) {
                claims[key] = free
            } else if let heldByAbsent = (0..<slots).first(where: { heldByCurrent[$0] == nil }) {
                claims[key] = heldByAbsent
            } else {
                claims[key] = (0..<slots).min {
                    let a = heldByCurrent[$0] ?? 0, b = heldByCurrent[$1] ?? 0
                    return a != b ? a < b : $0 < $1
                } ?? 0
            }
        }
        return claims
    }
}
