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

    /// Generate `.fm` labels for any persistent clusters in
    /// `persistentIDByNodeID` whose registry identity has `label == nil`.
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
    ///
    /// Best-effort: per-cluster failures are caught + logged so one bad
    /// FM call doesn't strand the others. Clusters with empty member
    /// content (all summaries nil/blank) are skipped silently — they'll
    /// retry on the next fit when summaries are populated.
    func labelMissingClusters(
        persistentIDByNodeID: [String: UUID],
        summaryProvider: (String) -> String?
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
            do {
                guard let label = try await generateLabel(
                    persistentID: pid,
                    nodeIDs: nodeIDs,
                    summaryProvider: summaryProvider
                ) else {
                    // Silent skip path before today: members empty OR
                    // sanitize wiped FM output to nothing. Both now log
                    // inside generateLabel; this catch-all just notes the
                    // loop kept going past the skipped cluster.
                    print("[SubstrateClusterLabelService] skipped cluster \(pid) (see generateLabel log above)")
                    continue
                }
                registry.setLabel(persistentID: pid, label: label, source: .fm)
                print("[SubstrateClusterLabelService] labeled cluster \(pid) → \(label)")
            } catch {
                print("[SubstrateClusterLabelService] label failed for \(pid): \(error)")
            }
        }
        print("[SubstrateClusterLabelService] pass complete")
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
