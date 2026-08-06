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
    static let defaultThreshold: Float = 0.80
    /// Step 2 — per-node ceiling on chips shown (§ C2). The 0.80 gate + best-per-tag
    /// dedupe already hold a node to a handful; this is the guarantee against the
    /// 5,394-phrase corpus ever flooding one tray. Sorted best-first, then capped.
    static let defaultMaxSuggestions = 8

    var threshold: Float {
        didSet { UserDefaults.standard.set(Double(threshold), forKey: Self.key) }
    }
    var maxSuggestions: Int {
        didSet { UserDefaults.standard.set(maxSuggestions, forKey: Self.capKey) }
    }
    private init() {
        threshold = (UserDefaults.standard.object(forKey: Self.key) as? Double).map(Float.init)
            ?? Self.defaultThreshold
        let storedCap = UserDefaults.standard.object(forKey: Self.capKey) as? Int
        maxSuggestions = (storedCap.map { max(1, $0) }) ?? Self.defaultMaxSuggestions
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
