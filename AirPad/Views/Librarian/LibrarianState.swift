import Foundation
import Observation
import FoundationModels

/// App-level Librarian session state. Lives on `AppRouter.librarian` and
/// travels across canvas, list, and (future) detail-view mounts so a
/// session in flight survives navigation between surfaces.
///
/// Holds the morphing-surface mode, the in-flight query text, the last
/// response, and the classify → respond pipeline absorbed from the
/// deleted `CorpusQuerySheet` in commit 2. The pipeline is currently
/// single-mode (today's classify-then-retrieve-or-synthesize behavior);
/// the mode dropdown and per-mode pipelines land in subsequent commits.
@Observable
@MainActor
final class LibrarianState {

    /// Surface state — collapsed pill vs expanded chrome. Future commits
    /// add `.iconOnly` once the mode icon can persist as ambient
    /// presence after a chevron-collapse.
    enum SurfaceMode: Sendable {
        case collapsed
        case expanded
    }

    /// Librarian mode — which pipeline runs on send. For c3 this is
    /// purely state + visual (the dropdown changes the active icon);
    /// per-mode pipelines land in c4+ (Navigate first). Today every
    /// mode runs the same classify → respond pipeline.
    enum Mode: Sendable, CaseIterable {
        case navigate
        case ask
        case research
        case provoke

        var displayName: String {
            switch self {
            case .navigate: return "Navigate"
            case .ask: return "Ask"
            case .research: return "Research"
            case .provoke: return "Provoke"
            }
        }

        var sfSymbol: String {
            switch self {
            case .navigate: return "location.magnifyingglass"
            case .ask: return "sparkles"
            case .research: return "graduationcap.fill"
            case .provoke: return "bolt.fill"
            }
        }
    }

    /// Result of the classify → respond pipeline. `retrieval` carries
    /// node IDs (resolved against the store at render time) so the list
    /// stays correct if a node was deleted between query and display.
    enum QueryResponse: Sendable {
        case insight(String)
        case retrieval([String])
        case error(String)
    }

    var surfaceMode: SurfaceMode = .collapsed

    /// Active mode — drives the mode-icon symbol in the expanded header
    /// and (in later commits) which pipeline runs on send. Defaults to
    /// `.ask`, matching the pre-c3 single-pipeline behavior.
    var activeMode: Mode = .ask

    /// User's in-flight query text, lifted into session state so the
    /// surface can be driven from outside (whisper inline-tap pre-load
    /// in a later commit) and so it survives surface remounts when the
    /// host view re-renders.
    var inputText: String = ""

    /// Last query response. Stays visible while the user types a new
    /// query; cleared at the start of the next `executeQuery` run.
    var response: QueryResponse? = nil

    /// True while a query is in flight against the language model.
    var isLoading: Bool = false

    /// Dispatches to the per-mode pipeline. Navigate uses block-level
    /// embedding retrieval (no FM round-trip); every other mode currently
    /// shares the legacy classify → respond pipeline absorbed from
    /// `CorpusQuerySheet` (Ask gets its own pipeline in c5+, Research /
    /// Provoke later still). The store is injected at call site because
    /// LibrarianState doesn't own a reference.
    func executeQuery(store: CorpusStore) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoading = true
        response = nil

        switch activeMode {
        case .navigate:
            await runNavigatePipeline(query: query, store: store)
        case .ask, .research, .provoke:
            await runLegacyClassifyPipeline(query: query, store: store)
        }
    }

    /// Navigate mode — block-embedding retrieval. Returns the top nodes
    /// ranked by best-block cosine similarity to the query. No LLM call,
    /// no title hallucination, no iOS 26 gate. Empty result surfaces as
    /// an error so the user sees explicit no-match feedback rather than
    /// a confusing empty list.
    private func runNavigatePipeline(query: String, store: CorpusStore) async {
        let matchedIDs = await store.findRelevantNodes(query: query, topK: 5)
        if matchedIDs.isEmpty {
            response = .error("No matches yet. Try a different phrasing, or wait for content to finish embedding.")
        } else {
            response = .retrieval(matchedIDs)
        }
        isLoading = false
    }

    /// Legacy classify → respond pipeline carried over from
    /// `CorpusQuerySheet`. Runs for Ask / Research / Provoke until each
    /// mode lands its own pipeline.
    private func runLegacyClassifyPipeline(query: String, store: CorpusStore) async {
        // Truncate to 30 most recent nodes when the corpus is large
        // (matches pre-Librarian CorpusQuerySheet behavior; replaced
        // with embedding-driven retrieval in a later commit).
        let nodesToInclude = store.nodes.count > 30
            ? Array(store.nodes.prefix(30))
            : store.nodes
        let corpusSummary = nodesToInclude.map { node in
            "Title: \(node.title)\nSummary: \(node.summary)\nTags: \(node.tags.joined(separator: ", "))"
        }.joined(separator: "\n---\n")

        let classifyPrompt = """
        Query: \(query)

        Classify this query as either "insight" (requires synthesis, pattern analysis, or reflection across the corpus) or "retrieval" (looking for specific nodes, topics, or content).

        Respond with exactly one word: insight or retrieval
        """

        guard #available(iOS 26.0, *) else {
            response = .error("Requires iOS 26 or later.")
            isLoading = false
            return
        }
        guard SystemLanguageModel.default.isAvailable else {
            response = .error("Foundation Model not available on this device.")
            isLoading = false
            return
        }

        do {
            let classifySession = LanguageModelSession()
            let classification = try await classifySession
                .respond(to: classifyPrompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if classification.contains("retrieval") {
                let retrievalPrompt = """
                Query: \(query)

                Corpus:
                \(corpusSummary)

                Return the titles of nodes that best match this query, one per line, most relevant first. Maximum 5 results. Only return titles that exist exactly in the corpus above.
                """
                let session = LanguageModelSession()
                let result = try await session.respond(to: retrievalPrompt).content
                let titles = result.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let matchedIDs = titles.compactMap { title in
                    store.nodes.first { $0.title == title }?.id
                }
                response = .retrieval(matchedIDs)
            } else {
                let insightPrompt = """
                You are a reflective AI that helps someone understand patterns in their own thinking.

                Their corpus:
                \(corpusSummary)

                Question: \(query)

                Give a thoughtful, concise response (2-4 sentences) that synthesizes patterns from their corpus. Be specific to their actual content. Do not be generic.
                """
                let session = LanguageModelSession()
                let result = try await session.respond(to: insightPrompt).content
                response = .insight(result)
            }
            isLoading = false
        } catch {
            response = .error("Something went wrong. Try again.")
            isLoading = false
        }
    }
}
