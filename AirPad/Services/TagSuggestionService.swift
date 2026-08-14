import Foundation

/// THE TAG PRODUCER — the cosine threshold for the "already yours" matcher, as a
/// DEV DIAL, not a literal (ws-lever.md). Step 0 calibration: real same-concept
/// matches land 0.82–0.94; wrong grabs sit below ~0.75 — a genuine gap, so 0.80 is a
/// safe start, and T can turn it.
@Observable
@MainActor
final class TagMatchTuning {
    static let shared = TagMatchTuning()
    private static let key = "tagMatch.threshold"
    private static let capKey = "tagMatch.maxSuggestions"
    private static let lambdaKey = "tagMatch.mmrLambda"
    private static let newCapKey = "tagMatch.newTagCap"
    static let defaultThreshold: Float = 0.80
    /// Step 2 — per-node ceiling on chips shown (§ C2). The 0.80 gate + best-per-tag
    /// dedupe already hold a node to a handful; this is the guarantee against the
    /// 5,394-phrase corpus ever flooding one tray. MMR-reranked, then capped.
    static let defaultMaxSuggestions = 8
    /// Step 3 — MMR trade-off (§ C2). `score = λ·relevance − (1−λ)·maxSim-to-selected`.
    /// 0.7 favors relevance while still breaking up hub clusters (Human / Human Rights /
    /// Human Experience / People → one slot). 1.0 = pure relevance (pre-Step-3).
    static let defaultMMRLambda: Float = 0.70
    /// STEP 4 — SEPARATE, SMALLER ceiling on the "would be new" tier (§ THE TAG
    /// PRODUCER). The new tier proposes UNMATCHED folksonomy terms as brand-new tags;
    /// a full 8 per capture would regrow the SB139 tag pollution from the other
    /// direction, so this is deliberately << `maxSuggestions`. The same MMR pass runs
    /// FIRST, so near-duplicate proposals ("Identity Crisis" / "Gender Identity")
    /// collapse toward one slot rather than eating the cap. 3 is a start; T dials it.
    static let defaultNewTagCap = 3

    var threshold: Float {
        didSet { UserDefaults.standard.set(Double(threshold), forKey: Self.key) }
    }
    var maxSuggestions: Int {
        didSet { UserDefaults.standard.set(maxSuggestions, forKey: Self.capKey) }
    }
    var mmrLambda: Float {
        didSet { UserDefaults.standard.set(Double(mmrLambda), forKey: Self.lambdaKey) }
    }
    var newTagCap: Int {
        didSet { UserDefaults.standard.set(newTagCap, forKey: Self.newCapKey) }
    }
    private init() {
        threshold = (UserDefaults.standard.object(forKey: Self.key) as? Double).map(Float.init)
            ?? Self.defaultThreshold
        let storedCap = UserDefaults.standard.object(forKey: Self.capKey) as? Int
        maxSuggestions = (storedCap.map { max(1, $0) }) ?? Self.defaultMaxSuggestions
        mmrLambda = (UserDefaults.standard.object(forKey: Self.lambdaKey) as? Double).map(Float.init)
            ?? Self.defaultMMRLambda
        let storedNewCap = UserDefaults.standard.object(forKey: Self.newCapKey) as? Int
        newTagCap = (storedNewCap.map { max(1, $0) }) ?? Self.defaultNewTagCap
    }
}

/// One suggested tag: an existing tag the node's folksonomy is close to, with the best
/// cosine across the node's terms (deduped — several terms hitting the same tag yield
/// ONE suggestion at the best score).
struct TagSuggestion: Identifiable, Equatable {
    var name: String
    var score: Float
    var id: String { name }
}

/// Caches BGE-micro embeddings by string. Deterministic → never stale within an
/// embedder version: a new tag or term embeds on first use (satisfying "recompute
/// only when the set changes"); a reopen of the same node is free. `missed` avoids
/// re-trying strings the model couldn't embed. Uses the shipped `CardEmbeddingService`.
///
/// ★ Step 2 § C4 — the key is prefixed with `CardEmbeddingService.currentEmbeddingVersion`
/// (the same guard `CatalogCard.embeddingVersion` uses), so a future BGE bump can
/// never serve stale vectors: post-bump lookups miss the old-version keys and
/// re-embed. See `ws-embedder-unification.md`.
actor TagEmbeddingCache {
    static let shared = TagEmbeddingCache()
    private var cache: [String: [Float]] = [:]
    private var missed: Set<String> = []

    private func key(_ text: String) -> String {
        "\(CardEmbeddingService.currentEmbeddingVersion)\u{1}\(text)"
    }

    func embedding(for text: String) async -> [Float]? {
        let k = key(text)
        if let v = cache[k] { return v }
        if missed.contains(k) { return nil }
        guard let v = await CardEmbeddingService.shared.embed(text) else {
            missed.insert(k); return nil
        }
        cache[k] = v
        return v
    }
}

/// Cosine of two L2-normalized BGE vectors = dot product (no mean-centering).
func tagCosine(_ a: [Float], _ b: [Float]) -> Float {
    var d: Float = 0
    for i in 0..<min(a.count, b.count) { d += a[i] * b[i] }
    return d
}
