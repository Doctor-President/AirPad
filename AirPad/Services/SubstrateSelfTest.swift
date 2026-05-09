import Foundation

/// SB139 Stage 1 — synthetic-node correctness checks for `SubstrateService`.
///
/// AirPad has no XCTest target, so the brief's "unit-tested on a handful of
/// synthetic nodes" requirement is met by deterministic assertion-style checks
/// that the dev inspect view fires on demand. Each case constructs nodes
/// from in-memory vectors (no embedder, no FM), runs `pairSimilarity`, and
/// validates the blend formula and content fallback path.
///
/// Returns a one-line summary string suitable for inline display. Every
/// failure is described; on full pass, returns `"OK · N tests"`.
@available(iOS 17.0, *)
@MainActor
enum SubstrateSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // Reset means before tests so synthetic vectors aren't centered against
        // unrelated production state. Empty array = no nodes = nil means.
        SubstrateService.shared.recomputeMeans(from: [])

        // Helper: build a Node carrying only the substrate fields we care
        // about. Other fields are placeholders consistent with the existing
        // memberwise init contract.
        func makeNode(
            id: String,
            summary: [Float]? = nil,
            folksonomy: [Float]? = nil,
            content: [Float]? = nil
        ) -> Node {
            Node(
                id: id,
                createdAt: Date(),
                updatedAt: Date(),
                title: id,
                summary: "",
                tags: [],
                items: [],
                summaryEmbedding: summary,
                folksonomyEmbedding: folksonomy,
                contextualContentEmbedding: content,
                embeddingVersion: 1
            )
        }

        // Test 1 — identical summary + folksonomy vectors → cosine 1.0 on
        // both channels → blended ≈ 1.0 via blendedSummaryFolksonomy path.
        do {
            let v: [Float] = [1, 0, 0, 0]
            let a = makeNode(id: "id-eq", summary: v, folksonomy: v)
            let b = makeNode(id: "id-eq2", summary: v, folksonomy: v)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if abs((p.blended ?? 0) - 1.0) > 1e-4 { failures.append("T1 blended != 1.0 (got \(p.blended ?? .nan))") }
            if p.path != .blendedSummaryFolksonomy { failures.append("T1 path != blended (got \(p.path.rawValue))") }
        }

        // Test 2 — orthogonal vectors → cosine 0 on both channels →
        // blended ≈ 0 via blended path.
        do {
            let u: [Float] = [1, 0, 0, 0]
            let v: [Float] = [0, 1, 0, 0]
            let a = makeNode(id: "ortho-a", summary: u, folksonomy: u)
            let b = makeNode(id: "ortho-b", summary: v, folksonomy: v)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if abs(p.blended ?? .infinity) > 1e-4 { failures.append("T2 orthogonal blended != 0") }
            if p.path != .blendedSummaryFolksonomy { failures.append("T2 path != blended") }
        }

        // Test 3 — blend formula: summaryCos = 1.0, folkCos = 0.0 →
        // blended = 0.5.
        do {
            let s: [Float] = [1, 0, 0, 0]
            let fA: [Float] = [1, 0, 0, 0]
            let fB: [Float] = [0, 1, 0, 0]
            let a = makeNode(id: "mix-a", summary: s, folksonomy: fA)
            let b = makeNode(id: "mix-b", summary: s, folksonomy: fB)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if abs((p.blended ?? 0) - 0.5) > 1e-4 { failures.append("T3 blend != 0.5 (got \(p.blended ?? .nan))") }
            if p.path != .blendedSummaryFolksonomy { failures.append("T3 path != blended") }
        }

        // Test 4 — content fallback: one side missing summary → must fall
        // back to content cosine, not silently use folksonomy alone.
        do {
            let v: [Float] = [1, 1, 0, 0]
            let a = makeNode(id: "fb-a", summary: nil, folksonomy: v, content: v)
            let b = makeNode(id: "fb-b", summary: v,   folksonomy: v, content: v)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if p.path != .contentFallback { failures.append("T4 path != contentFallback (got \(p.path.rawValue))") }
            if abs((p.blended ?? 0) - 1.0) > 1e-4 { failures.append("T4 fallback blended != content cosine") }
        }

        // Test 5 — both summary and folksonomy missing on one side, content
        // present → content fallback.
        do {
            let v: [Float] = [0.5, 0.5, 0, 0]
            let a = makeNode(id: "ref-a", summary: nil, folksonomy: nil, content: v)
            let b = makeNode(id: "ref-b", summary: v,   folksonomy: v,   content: v)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if p.path != .contentFallback { failures.append("T5 path != contentFallback") }
            if (p.blended ?? -1) < 0.99 { failures.append("T5 fallback blended < 0.99") }
        }

        // Test 6 — no signal at all on one side → noSignal path, blended nil.
        do {
            let v: [Float] = [1, 0, 0, 0]
            let a = makeNode(id: "ns-a")
            let b = makeNode(id: "ns-b", summary: v, folksonomy: v, content: v)
            let p = SubstrateService.shared.pairSimilarity(a, b)
            ran += 1
            if p.path != .noSignal { failures.append("T6 path != noSignal (got \(p.path.rawValue))") }
            if p.blended != nil { failures.append("T6 blended should be nil") }
        }

        // Test 7 — mean-centering shifts the cosine. Two raw vectors that
        // have positive raw cosine collapse toward 0 once the corpus mean is
        // recomputed to a value close to one of them.
        do {
            let a: [Float] = [1.0, 0.0, 0.0, 0.0]
            let b: [Float] = [0.9, 0.1, 0.0, 0.0]
            let nA = makeNode(id: "mc-a", content: a)
            let nB = makeNode(id: "mc-b", content: b)
            // Recompute means against [a, b] — mean ≈ midpoint, centering
            // pulls both vectors toward zero, the residual signal flips
            // direction → centered cosine should be -1 (or very close).
            SubstrateService.shared.recomputeMeans(from: [nA, nB])
            let p = SubstrateService.shared.pairSimilarity(nA, nB)
            ran += 1
            // After centering, residuals are equal-magnitude opposite — exact.
            if abs((p.contentCos ?? 0) + 1.0) > 1e-4 {
                failures.append("T7 centered contentCos != -1 (got \(p.contentCos ?? .nan))")
            }
            // Reset so subsequent inspect-view cosines are uncontaminated.
            SubstrateService.shared.recomputeMeans(from: [])
        }

        if failures.isEmpty {
            return "OK · \(ran) tests"
        } else {
            return "FAIL (\(failures.count)/\(ran)) — " + failures.joined(separator: "; ")
        }
    }
}
