import Foundation

// MARK: - Thread suggestion type
//
// Pre-Stage-2 this file held an FM-driven `ThreadService` actor that asked
// the Foundation Model to identify three latent threads across the corpus.
// SB139 Stage 2 retires that path: thread candidates are now produced
// deterministically from substrate similarity (no FM call in the threads
// path). The `ThreadSuggestion` shape is unchanged so callers (CorpusStore,
// ThreadSuggestionCard, ContentView) keep working.

struct ThreadSuggestion: Identifiable, Equatable {
    let id: UUID
    let nodeIDs: [String]
    let description: String
    let confidence: Double
}

// MARK: - Substrate-driven candidate generation (SB139 Stage 2)

/// Produces thread candidates from substrate pair similarity. Geometric-only
/// signal: pairs that are near in embedding space but share no
/// user-intentional tag and are not already connected through a pulled
/// thread. Tag-friction and convergent threads are deferred per the brief.
///
/// All work is deterministic. No FM call in the threads path.
@available(iOS 17.0, *)
@MainActor
enum SubstrateThreadService {

    /// Stage 2 threshold T. Calibrated against the SB139 Stage 1 close-out
    /// diagnostic on the 206-node corpus: top-1-per-node blended cosines were
    /// p75=0.60, p90=0.73, max=0.87 (mean 0.53); top-5 pair distribution
    /// p90=0.66, p95=0.70. 0.65 sits at p90 of top-5 pairs and just below
    /// p90 of top-1 — high enough to surface only clearly-above-median
    /// connections, low enough that ~10–25% of nodes will see at least one
    /// candidate. Tunable from the dev inspect view; the brief expects
    /// post-ship adjustment as real use surfaces noise/silence patterns.
    static let candidateThreshold: Double = 0.65

    /// Tags that count as a "user-intentional connection." Explicit user
    /// assignment plus model-assigned tags the user explicitly accepted.
    /// `.model` (unconfirmed) does not count — those are still presentation,
    /// not user intent. Mirrors the diagnostic export's `userIntentionalTags`
    /// helper so the inspect view and Stage 2 share one definition.
    static func userIntentionalTags(_ node: Node) -> Set<String> {
        var out = Set<String>()
        for tag in node.tags {
            if let s = node.tagSources[tag]?.source, s == .user || s == .promoted {
                out.insert(tag)
            }
        }
        return out
    }

    /// Stable, order-independent identifier for a node pair. Used as the
    /// session-only dismissal key and the already-connected lookup key so
    /// (a, b) and (b, a) collapse to the same entry.
    static func pairKey(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    struct Candidate {
        let other: Node
        let blended: Double
        /// Nil when the pair survives the geometric-only filter and is a
        /// real Stage 2 candidate. Non-nil when the pair sits ≥ threshold
        /// but is filtered out for the named reason (still surfaced in the
        /// inspect view so threshold tuning is informed).
        let exclusion: Exclusion?

        enum Exclusion: String {
            case sharesUserTag = "shares_user_tag"
            case alreadyConnected = "already_connected"
        }
    }

    /// Top suggestions across the corpus, sorted by blended cosine
    /// descending. The caller decides how many to enqueue; surface logic in
    /// `CorpusStore` shows one at a time per the existing threads UX.
    ///
    /// Excluded from candidate generation:
    /// - meta-nodes (already represent connections)
    /// - non-rankable nodes (`thin_content` per `SubstrateService.isRankable`)
    /// - pairs sharing any user-intentional tag (geometric-only signal)
    /// - pairs already connected through a pulled meta-node
    /// - pairs the user dismissed in this session
    static func candidates(
        in nodes: [Node],
        dismissedPairKeys: Set<String> = []
    ) -> [ThreadSuggestion] {
        let substrate = SubstrateService.shared
        let alreadyConnected = alreadyConnectedPairs(in: nodes)
        let rankable = nodes.filter { !$0.isMeta && substrate.isRankable($0) }

        var picks: [(score: Double, a: Node, b: Node)] = []

        for i in 0..<rankable.count {
            let a = rankable[i]
            let aTags = userIntentionalTags(a)
            for j in (i + 1)..<rankable.count {
                let b = rankable[j]
                let key = pairKey(a.id, b.id)
                if dismissedPairKeys.contains(key) { continue }
                if alreadyConnected.contains(key) { continue }
                if !aTags.isDisjoint(with: userIntentionalTags(b)) { continue }

                let p = substrate.rankingPairSimilarity(a, b)
                guard let blended = p.blended, blended >= candidateThreshold else { continue }
                picks.append((blended, a, b))
            }
        }

        return picks
            .sorted { $0.score > $1.score }
            .map { p in
                ThreadSuggestion(
                    id: UUID(),
                    nodeIDs: [p.a.id, p.b.id],
                    description: describe(p.a, p.b),
                    confidence: p.score
                )
            }
    }

    /// Per-node candidate list for the dev inspect view. Returns every pair
    /// at or above threshold including those that the geometric-only filter
    /// would exclude (so threshold tuning can see what's getting dropped and
    /// why). Ordered by blended cosine descending.
    static func candidates(forNode node: Node, in nodes: [Node]) -> [Candidate] {
        guard !node.isMeta else { return [] }
        let substrate = SubstrateService.shared
        guard substrate.isRankable(node) else { return [] }

        let alreadyConnected = alreadyConnectedPairs(in: nodes)
        let nodeUserTags = userIntentionalTags(node)

        var out: [Candidate] = []
        for other in nodes where other.id != node.id && !other.isMeta {
            guard substrate.isRankable(other) else { continue }
            let p = substrate.rankingPairSimilarity(node, other)
            guard let blended = p.blended, blended >= candidateThreshold else { continue }

            let key = pairKey(node.id, other.id)
            let exclusion: Candidate.Exclusion?
            if alreadyConnected.contains(key) {
                exclusion = .alreadyConnected
            } else if !nodeUserTags.isDisjoint(with: userIntentionalTags(other)) {
                exclusion = .sharesUserTag
            } else {
                exclusion = nil
            }
            out.append(Candidate(other: other, blended: blended, exclusion: exclusion))
        }
        return out.sorted { $0.blended > $1.blended }
    }

    // MARK: - Internals

    /// All node-pair keys already connected through a pulled meta-node. A
    /// meta with provenance [a, b, c] contributes (a,b), (a,c), (b,c) — any
    /// further "thread" between them would be redundant.
    private static func alreadyConnectedPairs(in nodes: [Node]) -> Set<String> {
        var out = Set<String>()
        for m in nodes where m.isMeta {
            let ids = m.provenance ?? []
            guard ids.count >= 2 else { continue }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    out.insert(pairKey(ids[i], ids[j]))
                }
            }
        }
        return out
    }

    /// Honest substrate readout — no FM-narrative facade. The card UI shows
    /// node titles below this line, so users see what's being connected
    /// either way. SB135 visual model work owns richer presentation.
    private static func describe(_ a: Node, _ b: Node) -> String {
        let aFolk = Set((a.folksonomy ?? []).map { $0.lowercased() })
        let bFolk = Set((b.folksonomy ?? []).map { $0.lowercased() })
        let shared = aFolk.intersection(bFolk).sorted()
        if !shared.isEmpty {
            let top = shared.prefix(2).joined(separator: ", ")
            return "Shared themes: \(top)"
        }
        return "Geometric resonance"
    }
}
