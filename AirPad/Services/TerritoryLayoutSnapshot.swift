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
/// argmax-places against the restored geography, plus the per-node tint.
struct TerritoryLayoutSnapshot: Codable {
    static let currentVersion = 1

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
    /// nodeID → tint hex (`#RRGGBB`).
    var colorsHex: [String: String]

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
        case territories, centers, centroids, colorsHex
        case updatedAt = "updated_at"
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
