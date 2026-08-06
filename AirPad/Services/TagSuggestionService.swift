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
    static let defaultThreshold: Float = 0.80

    var threshold: Float {
        didSet { UserDefaults.standard.set(Double(threshold), forKey: Self.key) }
    }
    private init() {
        threshold = (UserDefaults.standard.object(forKey: Self.key) as? Double).map(Float.init)
            ?? Self.defaultThreshold
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

/// Caches BGE-micro embeddings by string. Deterministic → never stale: a new tag or
/// term embeds on first use (satisfying "recompute only when the set changes"); a
/// reopen of the same node is free. `missed` avoids re-trying strings the model
/// couldn't embed. Uses the shipped `CardEmbeddingService`.
actor TagEmbeddingCache {
    static let shared = TagEmbeddingCache()
    private var cache: [String: [Float]] = [:]
    private var missed: Set<String> = []

    func embedding(for text: String) async -> [Float]? {
        if let v = cache[text] { return v }
        if missed.contains(text) { return nil }
        guard let v = await CardEmbeddingService.shared.embed(text) else {
            missed.insert(text); return nil
        }
        cache[text] = v
        return v
    }
}

/// Cosine of two L2-normalized BGE vectors = dot product (no mean-centering).
func tagCosine(_ a: [Float], _ b: [Float]) -> Float {
    var d: Float = 0
    for i in 0..<min(a.count, b.count) { d += a[i] * b[i] }
    return d
}
