import Foundation
import NaturalLanguage

/// SB139 Stage 1 — Semantic substrate.
///
/// Owns the `NLContextualEmbedding(.english)` instance, mean-pools token
/// vectors, caches per-channel corpus means, and exposes the pair-similarity
/// blend used by Stage 2 thread candidates and the dev inspect view.
///
/// **Storage decision:** vectors are stored RAW on `Node`. Mean-centering is
/// applied at read time inside `pairSimilarity`. Rationale: the corpus mean
/// recomputes on backfill or after N new embeds, and storing centered would
/// require rewriting every node's three vectors on each shift. Storing raw
/// keeps the substrate's per-node writes small and idempotent.
///
/// **Mean recompute trigger:** the manual backfill control unconditionally
/// recomputes after each batch; the live capture path bumps a counter and
/// recomputes when it crosses `meanRecomputeThreshold`. The threshold below
/// (`N = 20`) is a starting heuristic — calibrate against real-corpus growth
/// patterns once Stage 2 surfaces threads. Tuning is on the SB139 defer list.
///
/// **Embedder version:** `currentEmbeddingVersion = 1` corresponds to
/// `NLContextualEmbedding(.english)` mean-pooled, summary + folksonomy
/// generated via `AIService.processSubstrate`. Any change to embedder, prompt
/// shape, or pooling strategy bumps this so backfills can find stale vectors.
@available(iOS 17.0, *)
@MainActor
final class SubstrateService {

    // MARK: - Constants

    /// SB139 v1 = NLContextualEmbedding mean-pooled + processSubstrate prompt.
    static let currentEmbeddingVersion: Int = 1

    /// Skip the FM call below this character threshold; mark `thin_content`.
    static let thinContentThreshold: Int = 20

    /// New embeds since last mean recompute that trigger a fresh recompute.
    /// 20 is a starting heuristic — calibrate against real-corpus growth.
    static let meanRecomputeThreshold: Int = 20

    /// Same input-size cap used by `AIService.processSubstrate` so the
    /// content embedding samples roughly the same window as the FM call.
    private let maxEmbedChars: Int = 3200

    // MARK: - Singleton

    static let shared = SubstrateService()

    private init() {}

    // MARK: - Embedder lifecycle

    private var embedder: NLContextualEmbedding?
    private var loadedDimension: Int = 0
    private var loadAttempted = false
    private var loadSucceeded = false

    /// Lazy-load the embedder. Returns false if assets aren't available yet.
    /// First call may trigger an asset download via `requestAssets()`.
    @discardableResult
    func ensureLoaded() async -> Bool {
        if loadSucceeded { return true }
        if loadAttempted && !loadSucceeded { return false }
        loadAttempted = true

        guard let e = NLContextualEmbedding(language: .english) else {
            print("[Substrate] NLContextualEmbedding init failed")
            return false
        }
        if !e.hasAvailableAssets {
            print("[Substrate] Requesting NLContextualEmbedding assets…")
            do {
                let result = try await e.requestAssets()
                print("[Substrate] requestAssets result: \(result.rawValue)")
            } catch {
                print("[Substrate] requestAssets error: \(error)")
                return false
            }
        }
        do {
            try e.load()
            self.embedder = e
            self.loadedDimension = e.dimension
            self.loadSucceeded = true
            print("[Substrate] NLContextualEmbedding loaded: dim=\(e.dimension) maxLen=\(e.maximumSequenceLength)")
            return true
        } catch {
            print("[Substrate] NLContextualEmbedding load error: \(error)")
            return false
        }
    }

    var isLoaded: Bool { loadSucceeded }
    var dimension: Int { loadedDimension }

    // MARK: - Embedding

    /// Mean-pool token vectors from `NLContextualEmbedding`. Returns nil for
    /// empty input, embedder unavailable, or zero-token results. Vectors are
    /// returned as `[Float]` (matching `Node` field types) but pooling is
    /// done in `Double` for numerical stability.
    func embed(_ text: String) -> [Float]? {
        guard loadSucceeded, let e = embedder else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let truncated = trimmed.count > maxEmbedChars ? String(trimmed.prefix(maxEmbedChars)) : trimmed
        do {
            let result = try e.embeddingResult(for: truncated, language: .english)
            let dim = e.dimension
            var sum = [Double](repeating: 0, count: dim)
            var tokens = 0
            result.enumerateTokenVectors(in: truncated.startIndex..<truncated.endIndex) { vec, _ in
                for i in 0..<min(dim, vec.count) { sum[i] += vec[i] }
                tokens += 1
                return true
            }
            guard tokens > 0 else { return nil }
            let inv = 1.0 / Double(tokens)
            return sum.map { Float($0 * inv) }
        } catch {
            print("[Substrate] embeddingResult error: \(error)")
            return nil
        }
    }

    // MARK: - Corpus means (cached, read-time centering)

    /// Per-channel corpus mean vectors. Recomputed by `recomputeMeans(from:)`.
    /// Channels: summary / folksonomy / contextualContent. Nil channel means
    /// "no centering for this channel" (no nodes had a vector yet).
    private(set) var summaryMean: [Float]?
    private(set) var folksonomyMean: [Float]?
    private(set) var contentMean: [Float]?
    private(set) var meansUpdatedAt: Date?

    /// New successful embeds since the last mean recompute. Crosses
    /// `meanRecomputeThreshold` → recompute on next opportunity.
    private(set) var embedsSinceRecompute: Int = 0

    /// Walks all nodes and recomputes per-channel means from scratch. Cheap
    /// enough at this corpus size to do unconditionally on backfill or when
    /// the live-capture counter crosses threshold.
    func recomputeMeans(from nodes: [Node]) {
        summaryMean = mean(of: nodes.compactMap { $0.summaryEmbedding })
        folksonomyMean = mean(of: nodes.compactMap { $0.folksonomyEmbedding })
        contentMean = mean(of: nodes.compactMap { $0.contextualContentEmbedding })
        meansUpdatedAt = Date()
        embedsSinceRecompute = 0
        let s = summaryMean?.count ?? 0
        let f = folksonomyMean?.count ?? 0
        let c = contentMean?.count ?? 0
        print("[Substrate] Means recomputed (summary=\(s) folk=\(f) content=\(c) dim)")
    }

    /// Bump the post-recompute counter. Caller (CorpusStore) checks
    /// `shouldRecomputeMeans` after this to decide whether to act.
    func registerNewEmbed() {
        embedsSinceRecompute += 1
    }

    var shouldRecomputeMeans: Bool {
        embedsSinceRecompute >= Self.meanRecomputeThreshold
    }

    // MARK: - Pair similarity

    /// SB139 pair similarity blend.
    ///
    /// `average(summaryCos, folksonomyCos)` when both channels are present on
    /// both nodes. When either side is missing on either node, fall back to
    /// `contextualContentCos`. When even content is missing, returns nil
    /// (the caller treats this as "no signal").
    ///
    /// All cosines are computed on RAW vectors centered against the cached
    /// per-channel corpus mean at read time. If the mean for a channel is
    /// unavailable, that channel is treated as zero-centered (raw cosine).
    func pairSimilarity(_ a: Node, _ b: Node) -> PairSimilarity {
        let aSum = a.summaryEmbedding
        let bSum = b.summaryEmbedding
        let aFolk = a.folksonomyEmbedding
        let bFolk = b.folksonomyEmbedding
        let aContent = a.contextualContentEmbedding
        let bContent = b.contextualContentEmbedding

        let summaryCos = centeredCosine(aSum, bSum, mean: summaryMean)
        let folksonomyCos = centeredCosine(aFolk, bFolk, mean: folksonomyMean)
        let contentCos = centeredCosine(aContent, bContent, mean: contentMean)

        let blended: Double?
        let path: PairSimilarity.Path
        if let s = summaryCos, let f = folksonomyCos {
            blended = (s + f) / 2.0
            path = .blendedSummaryFolksonomy
        } else if let c = contentCos {
            blended = c
            path = .contentFallback
        } else {
            blended = nil
            path = .noSignal
        }

        return PairSimilarity(
            summaryCos: summaryCos,
            folksonomyCos: folksonomyCos,
            contentCos: contentCos,
            blended: blended,
            path: path
        )
    }

    // MARK: - Internal math

    private func mean(of vecs: [[Float]]) -> [Float]? {
        guard let first = vecs.first, !first.isEmpty else { return nil }
        let dim = first.count
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        for v in vecs where v.count == dim {
            for i in 0..<dim { sum[i] += Double(v[i]) }
            n += 1
        }
        guard n > 0 else { return nil }
        let inv = 1.0 / Double(n)
        return sum.map { Float($0 * inv) }
    }

    /// Apply mean-centering at read time (subtract mean from each side), then
    /// cosine. Returns nil when either input is nil/empty/dimension-mismatched.
    /// `mean` may be nil → treat as zero-vector (raw cosine).
    private func centeredCosine(_ a: [Float]?, _ b: [Float]?, mean: [Float]?) -> Double? {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return nil }
        let dim = a.count
        if let mean, mean.count != dim {
            // Dimension mismatch (e.g. mean stale across an embedder bump).
            // Fall through to raw cosine — better than crashing.
            return rawCosine(a, b)
        }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<dim {
            let m = mean.map { Double($0[i]) } ?? 0.0
            let x = Double(a[i]) - m
            let y = Double(b[i]) - m
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : nil
    }

    private func rawCosine(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0; var na = 0.0; var nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : nil
    }
}

// MARK: - Pair similarity output

struct PairSimilarity {
    let summaryCos: Double?
    let folksonomyCos: Double?
    let contentCos: Double?
    /// Final blended score per the SB139 spec. Nil only when no channel had
    /// a usable signal on both sides.
    let blended: Double?
    let path: Path

    enum Path: String {
        /// Both summary and folksonomy cosines defined → averaged.
        case blendedSummaryFolksonomy
        /// One or both of summary/folksonomy missing → used content cosine.
        case contentFallback
        /// All channels missing or dimension-mismatched → no signal.
        case noSignal
    }
}

// MARK: - Coverage stats (for dev inspect view)

struct SubstrateCoverage {
    let totalNodes: Int
    /// Substrate has been processed (`embeddingVersion >= 1`) AND all three
    /// embeddings landed.
    let full: Int
    /// Substrate processed but at least one channel missing (typically
    /// guardrail-refused: only content embedding present).
    let partial: Int
    /// Substrate processed but every channel failed (rare — usually thin
    /// content with no embeddable text).
    let failedAll: Int
    /// Substrate never processed (`embeddingVersion == 0`).
    let unprocessed: Int
    /// Per-reason histogram of `embeddingFailureReason`.
    let failuresByReason: [String: Int]

    static func compute(_ nodes: [Node]) -> SubstrateCoverage {
        var full = 0, partial = 0, failedAll = 0, unprocessed = 0
        var reasons: [String: Int] = [:]
        for n in nodes {
            if n.embeddingVersion < 1 {
                unprocessed += 1
                continue
            }
            if let r = n.embeddingFailureReason {
                reasons[r, default: 0] += 1
            }
            let s = (n.summaryEmbedding?.isEmpty == false)
            let f = (n.folksonomyEmbedding?.isEmpty == false)
            let c = (n.contextualContentEmbedding?.isEmpty == false)
            switch (s, f, c) {
            case (true, true, true):  full += 1
            case (false, false, false): failedAll += 1
            default: partial += 1
            }
        }
        return SubstrateCoverage(
            totalNodes: nodes.count,
            full: full, partial: partial, failedAll: failedAll, unprocessed: unprocessed,
            failuresByReason: reasons
        )
    }
}
