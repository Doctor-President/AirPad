import Foundation

/// MAP-RELAYOUT regression GATE (ws-map-relayout). No XCTest target — mirrors
/// `ProposalSelfTest` / `SubstrateSelfTest`: `run() -> String`, fired by the
/// `-TerritoryRestoreSelfTest` launch arg (wired in `CorpusStore.load`) and by a
/// button on the Substrate Inspect diagnostic screen (the only channel T can read
/// a self-test result on TestFlight — Console print/os_log are dead there).
///
/// WHAT IT GUARDS: the tag-anchored Map must RESTORE its persisted card-basis
/// geography on relaunch and NOT re-form / re-animate. The regression (94e5a48
/// added an on-appear warm-reform) re-laid-out the map on every launch; the
/// original fix (8331bfc) had made it "form once". This test pins the pure
/// decision logic in `TerritoryLayoutRestore` so a THIRD resurrection fails here
/// instead of shipping quietly:
///   1 — the input signature is STABLE + order-independent across "launches"
///       (SHA-256, not the per-process-random `hashValue` — the exact trap that
///       would silently break restore).
///   2 — ANY territory-determining change (node set, a node's anchor tag /
///       collection, the anchor set, a weight, the basis) ⇒ a different signature.
///   3 — identical membership ⇒ identical signature (a title/summary/content edit,
///       which never enters `NodeMembership`, cannot invalidate a restore).
///   4 — a current-version CARD snapshot whose signature matches ⇒ canRestore
///       (relaunch restores, zero re-sim); a legacy snapshot / version drift /
///       signature mismatch / nil ⇒ NOT canRestore (re-form + re-persist).
///   5 — the snapshot round-trips through JSON with coordinate-identical positions.
@MainActor
enum TerritoryLayoutRestoreSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        func mem(_ id: String, cols: [String] = [], tags: [String] = []) -> TerritoryLayoutRestore.NodeMembership {
            .init(id: id, collectionIDs: cols, anchorTags: tags)
        }
        func sig(_ m: [TerritoryLayoutRestore.NodeMembership],
                 anchors: [String] = ["blue", "red"],
                 cols: [String] = ["c1"],
                 w: TagTerritoryLayout.SignalWeights = .default,
                 basis: LayoutBasis = .card) -> String {
            TerritoryLayoutRestore.signature(
                memberships: m, anchorNames: anchors, userCollectionIDs: cols, weights: w, basis: basis)
        }
        let base = [mem("n2", tags: ["blue"]), mem("n1", cols: ["c1"]), mem("n3")]

        // 1 — deterministic, order-independent, 64-hex SHA-256 (a "relaunch"
        //     recomputes it; it must land on the same value).
        ran += 1
        let s1 = sig(base)
        if s1 != sig(base.reversed()) { failures.append("1: signature not order-independent") }
        if s1 != sig(base) { failures.append("1: signature not deterministic across calls") }
        if s1.count != 64 { failures.append("1: expected 64-hex SHA-256, got \(s1.count) chars") }

        // 2 — every territory-determining input change ⇒ a different signature.
        ran += 1
        if sig(base + [mem("n4", tags: ["red"])]) == s1 { failures.append("2: node-set change didn't differ") }
        if sig([mem("n2", tags: ["red"]), mem("n1", cols: ["c1"]), mem("n3")]) == s1 {
            failures.append("2: a node's anchor-tag change didn't differ")
        }
        if sig([mem("n2", tags: ["blue"]), mem("n1", cols: ["c2"]), mem("n3")]) == s1 {
            failures.append("2: a node's collection change didn't differ")
        }
        if sig(base, anchors: ["blue"]) == s1 { failures.append("2: anchor-set change didn't differ") }
        if sig(base, cols: ["c1", "c2"]) == s1 { failures.append("2: collection-set change didn't differ") }
        var w2 = TagTerritoryLayout.SignalWeights.default; w2.language = 0.9
        if sig(base, w: w2) == s1 { failures.append("2: weight change didn't differ") }
        if sig(base, basis: .legacy) == s1 { failures.append("2: basis change didn't differ") }

        // 3 — identical membership ⇒ identical signature (order aside). Non-territory
        //     node attributes never enter `NodeMembership`, so this is structural.
        ran += 1
        if sig([mem("n1", cols: ["c1"]), mem("n2", tags: ["blue"]), mem("n3")]) != s1 {
            failures.append("3: identical membership produced a different signature")
        }

        // 4 — the restore decision.
        ran += 1
        let card = makeSnapshot(basis: .card, signature: s1)
        if !TerritoryLayoutRestore.canRestore(card, currentCardSignature: s1) { failures.append("4: card+match should restore") }
        if TerritoryLayoutRestore.canRestore(card, currentCardSignature: "deadbeef") { failures.append("4: signature mismatch must NOT restore") }
        if TerritoryLayoutRestore.canRestore(makeSnapshot(basis: .legacy, signature: s1), currentCardSignature: s1) {
            failures.append("4: legacy basis must NOT restore")
        }
        if TerritoryLayoutRestore.canRestore(nil, currentCardSignature: s1) { failures.append("4: nil must NOT restore") }
        if TerritoryLayoutRestore.canRestore(makeSnapshot(basis: .card, signature: s1, version: 999), currentCardSignature: s1) {
            failures.append("4: version drift must NOT restore")
        }

        // 5 — JSON round-trip preserves positions coordinate-identically.
        ran += 1
        do {
            let data = try JSONEncoder.airPad.encode(card)
            let decoded = try JSONDecoder.airPad.decode(TerritoryLayoutSnapshot.self, from: data)
            if decoded.positions != card.positions { failures.append("5: positions changed across JSON round-trip") }
            if decoded.signature != card.signature || decoded.basis != card.basis {
                failures.append("5: metadata changed across round-trip")
            }
        } catch {
            failures.append("5: round-trip threw \(error)")
        }

        if failures.isEmpty {
            return "TerritoryRestore PASS: \(ran)/\(ran) checks"
        } else {
            return "TerritoryRestore FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    private static func makeSnapshot(basis: LayoutBasis,
                                     signature: String,
                                     version: Int = TerritoryLayoutSnapshot.currentVersion) -> TerritoryLayoutSnapshot {
        TerritoryLayoutSnapshot(
            version: version,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            basis: basis,
            signature: signature,
            positions: ["n1": CanvasPosition(x: 12.5, y: -30.25), "n2": CanvasPosition(x: -7.0, y: 4.0)],
            nodeTerritory: ["n1": "col:c1", "n2": "tag:blue"],
            territories: [.init(key: "col:c1", name: "Cee"), .init(key: "tag:blue", name: "blue")],
            centers: ["col:c1": .init(x: 100, y: 0), "tag:blue": .init(x: -100, y: 0)],
            centroids: ["col:c1": [0.1, 0.2], "tag:blue": [0.3, 0.4]],
            colorsHex: ["n1": "#1B59C2", "n2": "#E8820A"]
        )
    }
}
