import Foundation
import Observation

/// SB139 Stage 4c2 commit C — Foundation-Model-driven cluster labeling.
///
/// For each persistent cluster identity with no label yet, builds a prompt
/// from the member nodes' summaries, asks the model router for a short
/// label, sanitizes the response, and writes via
/// `SubstrateClusterRegistry.setLabel(...source: .fm)`.
///
/// **Staleness gating.** "Never re-label unless explicitly cleared" (T
/// 2026-05-28). The service only generates for identities where
/// `label == nil`. Both `.fm` and `.user` labels persist until the
/// inspect surface's `clearLabel` re-opens an identity to regeneration.
/// Membership shifts across refits do *not* trigger a re-label — the 2-
/// cluster ceiling on this corpus (NLContextualEmbedding variance —
/// `feedback_nlcontextual_embedding_cluster_ceiling`) means clusters
/// stay structurally stable and re-labeling would just add FM noise.
///
/// **Privacy.** Routes through `ModelRouter` — defaults to on-device
/// `FoundationModels`. Ollama only fires when the user has explicitly
/// configured an endpoint in Settings; no key, no call.
///
/// **Concurrency.** Clusters are labeled serially. AirPad's cluster
/// count is ≈2 and per-call FM latency on-device is the bottleneck;
/// parallel calls would only contend the same model session.
///
/// **Wiring.** This commit lands the service in isolation — no callers
/// yet. Commit D wires invocation from the canvas view (where corpus +
/// layout service both live) and renders the label overlay.
@available(iOS 17.0, *)
@Observable
@MainActor
final class SubstrateClusterLabelService {

    static let shared = SubstrateClusterLabelService()

    private init() {}

    /// True while a label-generation pass is in flight. The canvas
    /// overlay can read this for a "labels…" placeholder hint while
    /// FM is producing first labels on a fresh fit.
    private(set) var isLabeling: Bool = false

    /// Cap on members fed to the FM per cluster. Keeps the prompt within
    /// FoundationModels' practical context and bounds the dominant-theme
    /// signal — 20 trimmed summaries are plenty for theme detection and
    /// don't push the model toward repetition.
    private static let maxMembersPerPrompt = 20

    /// Per-summary truncation cap. A runaway summary shouldn't dominate
    /// the prompt; 220 chars is roughly two sentences of substrate-summary
    /// output.
    private static let maxSummaryChars = 220

    /// Label sanitization word cap. Matches the prompt's "1 to 3 words"
    /// instruction — anything longer is FM ignoring the constraint and
    /// gets trimmed. Tightened from 4 → 3 on 2026-05-28 after observing
    /// multi-token comma-list leakage ("DataHandlingImpacts, PrivacyRights,
    /// …") — the comma-list rejection in `sanitize` is the primary
    /// defense; this cap is the backstop.
    private static let maxLabelWords = 3

    /// Mean intra-cluster cosine threshold. Above → cluster is coherent
    /// enough for FM to name without confabulating; below → skip FM and
    /// stamp an honest fallback. 0.50 is a starting point — log every
    /// cluster's value so we can tune from device runs. Crisp recipes/
    /// canvas-arch clusters typically sit ≥ 0.55 on NLContextualEmbedding;
    /// grab-bags ≤ 0.40. The dead zone in the middle is exactly what we
    /// want the threshold to bisect.
    static let coherenceThreshold: Float = 0.50

    /// Cap on FM-naming attempts spent on a single cluster across all
    /// passes (incremented in the registry, persists across launches).
    /// On the (N+1)-th failure path, the labeler stamps an `.honest`
    /// label instead of looping forever on a cluster FM can't name.
    /// 2 = "FM gets a second chance after the first refit, then we
    /// stop." Matches T's "low cap" guidance in the brief.
    static let maxFMAttempts = 2

    /// Honest fallback formatting cap — number of top tags concatenated
    /// when a cluster has dominant tag coverage. Matches the spirit of
    /// the FM word cap (3) without exceeding the pill's comfortable
    /// width at serif 13pt.
    private static let maxHonestTopTags = 2

    /// Minimum number of members a tag must appear in to qualify as
    /// "dominant" for the honest-tag fallback. A tag carried by a
    /// single member is not a cluster theme — drop it and fall back to
    /// "Mixed (N notes)".
    private static let minMembersPerTagForHonest = 2

    /// Generate labels for any persistent clusters in
    /// `persistentIDByNodeID` whose registry identity has `label == nil`.
    ///
    /// **Honesty pipeline (2026-05-31).** Each unlabeled cluster runs
    /// through the coherence gate before FM ever sees it:
    /// 1. Compute mean intra-cluster cosine of L2-normalized member
    ///    embeddings (substrate input vectors — same the HDBSCAN cut
    ///    ran on).
    /// 2. If coherence < `coherenceThreshold` → stamp an `.honest`
    ///    fallback ("top tags · top tag" or "Mixed (N notes)") and
    ///    skip FM entirely. The model can't name an incoherent cluster
    ///    without inventing a theme, so don't ask it to.
    /// 3. If coherence ≥ threshold AND attempts < `maxFMAttempts` →
    ///    call FM. Success: stamp `.fm`. Nil/wiped: increment attempts
    ///    counter on the identity; the cluster stays unlabeled and
    ///    will retry on the next pass.
    /// 4. If attempts ≥ `maxFMAttempts` → stamp `.honest` fallback and
    ///    stop. FM has had its chances.
    ///
    /// - Parameters:
    ///   - persistentIDByNodeID: a mapping from node ID to the persistent
    ///     cluster UUID assigned by `SubstrateClusterRegistry`. Noise
    ///     nodes should be absent from the map (or their value can be a
    ///     UUID the caller knows is unmatched — the service simply
    ///     ignores any UUID not present in the registry).
    ///   - summaryProvider: closure returning a node's text basis for
    ///     labeling. The caller picks the field — typically
    ///     `node.summary` with fallback to `node.title`. Decoupling the
    ///     service from `CorpusStore` keeps it pure and testable.
    ///   - embeddingProvider: closure returning a node's cluster-input
    ///     embedding (the substrate vector HDBSCAN saw — see
    ///     `SubstrateLayoutService.fittedModel.trainingPoints`). Nil for
    ///     a node means it can't contribute to coherence; if every
    ///     member's embedding is nil, the cluster falls through to the
    ///     honest fallback path (no FM attempt).
    ///   - tagsProvider: closure returning the tag names attached to a
    ///     node, drives the dominant-tags honest fallback. Empty array
    ///     when the node has no tags.
    ///
    /// Best-effort: per-cluster failures are caught + logged so one bad
    /// FM call doesn't strand the others.
    func labelMissingClusters(
        persistentIDByNodeID: [String: UUID],
        summaryProvider: (String) -> String?,
        embeddingProvider: (String) -> [Float]?,
        tagsProvider: (String) -> [String]
    ) async {
        guard !persistentIDByNodeID.isEmpty else { return }

        var nodesByCluster: [UUID: [String]] = [:]
        for (nodeID, pid) in persistentIDByNodeID {
            nodesByCluster[pid, default: []].append(nodeID)
        }

        let registry = SubstrateClusterRegistry.shared
        let unlabeled = nodesByCluster.filter { pid, _ in
            registry.identity(for: pid) != nil && registry.label(for: pid) == nil
        }
        if unlabeled.isEmpty { return }

        isLabeling = true
        defer { isLabeling = false }

        // Deterministic order across runs so the dev-inspect logs read
        // the same on repeat passes.
        let orderedPIDs = unlabeled.keys.sorted { $0.uuidString < $1.uuidString }
        print("[SubstrateClusterLabelService] starting pass: \(orderedPIDs.count) unlabeled clusters")
        for pid in orderedPIDs {
            let nodeIDs = unlabeled[pid] ?? []
            await processCluster(
                pid: pid,
                nodeIDs: nodeIDs,
                summaryProvider: summaryProvider,
                embeddingProvider: embeddingProvider,
                tagsProvider: tagsProvider,
                registry: registry
            )
        }
        print("[SubstrateClusterLabelService] pass complete")
    }

    /// Per-cluster decision logic — coherence gate → FM-or-honest →
    /// stamp. Carved out of `labelMissingClusters` to keep the outer
    /// loop legible. All side effects (registry writes, attempt
    /// counter increments, logging) happen here.
    private func processCluster(
        pid: UUID,
        nodeIDs: [String],
        summaryProvider: (String) -> String?,
        embeddingProvider: (String) -> [Float]?,
        tagsProvider: (String) -> [String],
        registry: SubstrateClusterRegistry
    ) async {
        let memberCount = nodeIDs.count
        let attemptsSoFar = registry.fmAttempts(for: pid)
        let coherence = Self.meanIntraClusterCosine(
            embeddings: nodeIDs.compactMap(embeddingProvider)
        )

        // Below-threshold path: skip FM entirely, stamp honest.
        // `coherence == nil` (couldn't compute — no embeddings) also
        // takes the honest path; we have no signal that FM would be
        // any better than a guess.
        let belowThreshold = (coherence ?? 0) < Self.coherenceThreshold
        let attemptsExhausted = attemptsSoFar >= Self.maxFMAttempts

        if belowThreshold || attemptsExhausted {
            let honest = Self.honestFallback(
                nodeIDs: nodeIDs,
                tagsProvider: tagsProvider
            )
            registry.setLabel(persistentID: pid, label: honest, source: .honest)
            let reason: String
            if belowThreshold && attemptsExhausted {
                reason = "below-threshold + attempts exhausted"
            } else if belowThreshold {
                reason = String(format: "coherence %.2f < %.2f", coherence ?? -1, Self.coherenceThreshold)
            } else {
                reason = "attempts exhausted (\(attemptsSoFar)/\(Self.maxFMAttempts))"
            }
            print("[SubstrateClusterLabelService] cluster \(pid) → \(honest) [.honest, \(reason), n=\(memberCount)]")
            return
        }

        // Above-threshold path: try FM.
        do {
            guard let label = try await generateLabel(
                persistentID: pid,
                nodeIDs: nodeIDs,
                summaryProvider: summaryProvider
            ) else {
                registry.incrementFMAttempts(persistentID: pid)
                let next = attemptsSoFar + 1
                print("[SubstrateClusterLabelService] cluster \(pid) FM returned nil [coherence \(coherence.map { String(format: "%.2f", $0) } ?? "n/a"), attempts \(next)/\(Self.maxFMAttempts)] — will retry next pass" + (next >= Self.maxFMAttempts ? " (cap reached; next pass will go honest)" : ""))
                return
            }
            registry.setLabel(persistentID: pid, label: label, source: .fm)
            print("[SubstrateClusterLabelService] cluster \(pid) → \(label) [.fm, coherence \(coherence.map { String(format: "%.2f", $0) } ?? "n/a"), n=\(memberCount)]")
        } catch {
            print("[SubstrateClusterLabelService] cluster \(pid) FM threw: \(error)")
        }
    }

    /// Mean pairwise cosine similarity over L2-normalized embeddings.
    /// Returns nil when fewer than 2 vectors are available (no pairs
    /// → no signal); 1 input or 0 inputs both fall through to the
    /// honest path with "n/a" logged for coherence.
    ///
    /// L2-normalizes a copy of each vector — we never mutate the input
    /// (caller may be holding onto the substrate training array for
    /// other reads). Zero-norm vectors are dropped so a corrupt
    /// embedding doesn't poison the average with NaN.
    static func meanIntraClusterCosine(embeddings: [[Float]]) -> Float? {
        let normalized: [[Float]] = embeddings.compactMap { v in
            var norm: Float = 0
            for x in v { norm += x * x }
            norm = norm.squareRoot()
            guard norm > 0 else { return nil }
            return v.map { $0 / norm }
        }
        guard normalized.count >= 2 else { return nil }
        var sum: Float = 0
        var pairs: Int = 0
        for i in 0..<normalized.count {
            let a = normalized[i]
            for j in (i + 1)..<normalized.count {
                let b = normalized[j]
                var dot: Float = 0
                for k in 0..<a.count {
                    dot += a[k] * b[k]
                }
                sum += dot
                pairs += 1
            }
        }
        return sum / Float(pairs)
    }

    /// Compose an honest fallback label from member tags.
    ///
    /// Counts tag frequency across all members; keeps tags that appear
    /// in ≥ `minMembersPerTagForHonest` members; takes the top
    /// `maxHonestTopTags` by frequency (ties broken alphabetically
    /// for determinism); joins with " · ".
    ///
    /// When no tag qualifies as dominant, falls through to
    /// "Mixed (N notes)" — explicit about being a fallback rather
    /// than miming a confident label.
    static func honestFallback(
        nodeIDs: [String],
        tagsProvider: (String) -> [String]
    ) -> String {
        var freq: [String: Int] = [:]
        for nodeID in nodeIDs {
            for tag in tagsProvider(nodeID) {
                freq[tag, default: 0] += 1
            }
        }
        let dominant = freq
            .filter { $0.value >= minMembersPerTagForHonest }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(maxHonestTopTags)
            .map { $0.key }
        if dominant.isEmpty {
            return "Mixed (\(nodeIDs.count) notes)"
        }
        return dominant.joined(separator: " · ")
    }

    /// Produce a single label for one cluster. Returns nil when the
    /// member content is empty (no summaries to feed FM) or when
    /// sanitization rejects the FM output entirely.
    private func generateLabel(
        persistentID: UUID,
        nodeIDs: [String],
        summaryProvider: (String) -> String?
    ) async throws -> String? {
        let members = nodeIDs.prefix(Self.maxMembersPerPrompt).compactMap { nodeID -> String? in
            guard let raw = summaryProvider(nodeID) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return String(trimmed.prefix(Self.maxSummaryChars))
        }
        guard !members.isEmpty else {
            print("[SubstrateClusterLabelService] cluster \(persistentID): no member text from \(nodeIDs.count) nodes — summaryProvider returned nil/empty for all")
            return nil
        }

        let numbered = members.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let systemPrompt = """
        You name clusters of personal notes. Given the notes in one cluster, produce a short label that captures their shared theme. The label MUST be 1 to 3 words, Title Case, no punctuation, no quotes, no commas, no trailing period, no list. Return ONLY the label — nothing else.
        """

        let userPrompt = """
        Notes in this cluster:
        \(numbered)

        Label:
        """

        let raw = try await ModelRouter.generate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
        let sanitized = Self.sanitize(raw)
        if sanitized.isEmpty {
            // FM produced bytes but sanitize wiped them. Most common
            // cause post-2026-05-28: comma-amputate-first truncated to
            // empty because the FM response started with a comma. Log
            // the raw bytes so we can see what came back.
            let preview = raw.prefix(120).replacingOccurrences(of: "\n", with: "⏎")
            print("[SubstrateClusterLabelService] cluster \(persistentID): FM raw \(raw.count) chars sanitized to empty. raw[..120]=\"\(preview)\"")
            return nil
        }
        return sanitized
    }

    /// Strip FM filler, surrounding quotes/markdown, trailing punctuation,
    /// and cap to `maxLabelWords` words. Exposed `internal` so the dev
    /// inspect view can echo the sanitization rules in a "how labels are
    /// produced" tooltip (Commit E adjacent), and for ad-hoc verification
    /// on device until a XCTest target exists.
    static func sanitize(_ raw: String) -> String {
        // Comma-list amputation FIRST, on the raw FM bytes — before any
        // newline-pick, prefix-strip, or quote-trim. FM has been
        // returning comma-separated tag lists even after the system
        // prompt was tightened; truncating at the first comma the moment
        // bytes arrive guarantees downstream steps only ever see the
        // leading phrase. (2026-05-28: T-reported "labels still contain
        // commas" after the post-prefix variant — moving this to the top
        // of the pipeline is the harder fix.)
        var working = raw
        if let commaIdx = working.firstIndex(of: ",") {
            working = String(working[..<commaIdx])
        }

        var line = working
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""

        // FM sometimes echoes the prompt key. Strip a few common variants.
        let prefixes = ["Label:", "Cluster:", "Theme:", "Topic:", "Answer:"]
        for p in prefixes {
            if line.lowercased().hasPrefix(p.lowercased()) {
                line = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Strip surrounding quotes / backticks / markdown emphasis.
        let stripChars: Set<Character> = ["\"", "'", "`", "*", "_", "“", "”", "‘", "’"]
        while let f = line.first, stripChars.contains(f) {
            line = String(line.dropFirst())
        }
        while let l = line.last, stripChars.contains(l) {
            line = String(line.dropLast())
        }

        // Drop trailing punctuation.
        let trailingPunct: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let l = line.last, trailingPunct.contains(l) {
            line = String(line.dropLast())
        }

        // CamelCase split. FM frequently returns CamelCase tokens
        // ("InformationOrganization", "IdeasExploration") that pass the
        // word cap because split-on-whitespace counts them as one word.
        // Insert a space at every lower→upper boundary so the cap can
        // see them as the multi-word phrases they are. Done before the
        // cap so the truncation operates on human-readable words.
        line = splitCamelCase(line)

        let words = line.split(whereSeparator: { $0.isWhitespace })
        let capped = words.prefix(maxLabelWords).joined(separator: " ")
        return capped.trimmingCharacters(in: .whitespaces)
    }

    /// Insert a space at every lowercase→uppercase character boundary,
    /// turning "DataHandlingImpacts" → "Data Handling Impacts" and
    /// "IdeasExploration" → "Ideas Exploration". Leaves runs of
    /// consecutive capitals intact ("URLPath" stays "URLPath" rather
    /// than "U R L Path") — FM rarely emits acronym-CamelCase mixes,
    /// and the simple lower→upper rule avoids mangling legitimate
    /// initialisms when it does. Internal so the inspect view can
    /// surface the rule alongside other sanitization steps.
    static func splitCamelCase(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 4)
        var prevWasLower = false
        for ch in s {
            if prevWasLower && ch.isUppercase {
                out.append(" ")
            }
            out.append(ch)
            prevWasLower = ch.isLowercase
        }
        return out
    }
}
