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

    /// Label sanitization word cap. Matches the prompt's "1 to 4 words"
    /// instruction — anything longer is FM ignoring the constraint and
    /// gets trimmed.
    private static let maxLabelWords = 4

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
        for pid in orderedPIDs {
            let nodeIDs = unlabeled[pid] ?? []
            do {
                guard let label = try await generateLabel(
                    persistentID: pid,
                    nodeIDs: nodeIDs,
                    summaryProvider: summaryProvider
                ) else { continue }
                registry.setLabel(persistentID: pid, label: label, source: .fm)
                print("[SubstrateClusterLabelService] labeled cluster \(pid) → \(label)")
            } catch {
                print("[SubstrateClusterLabelService] label failed for \(pid): \(error)")
            }
        }
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
        guard !members.isEmpty else { return nil }

        let numbered = members.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let systemPrompt = """
        You name clusters of personal notes. Given the notes in one cluster, produce a short label that captures their shared theme. The label MUST be 1 to 4 words, Title Case, no punctuation, no quotes, no trailing period. Return ONLY the label — nothing else.
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
        return sanitized.isEmpty ? nil : sanitized
    }

    /// Strip FM filler, surrounding quotes/markdown, trailing punctuation,
    /// and cap to `maxLabelWords` words. Exposed `internal` so the dev
    /// inspect view can echo the sanitization rules in a "how labels are
    /// produced" tooltip (Commit E adjacent), and for ad-hoc verification
    /// on device until a XCTest target exists.
    static func sanitize(_ raw: String) -> String {
        var line = raw
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

        let words = line.split(whereSeparator: { $0.isWhitespace })
        let capped = words.prefix(maxLabelWords).joined(separator: " ")
        return capped.trimmingCharacters(in: .whitespaces)
    }
}
