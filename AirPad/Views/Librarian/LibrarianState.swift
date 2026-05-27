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

    /// Result of a mode pipeline. `retrieval` carries node IDs (resolved
    /// against the store at render time) so the list stays correct if a
    /// node was deleted between query and display. `ask` carries both
    /// the rendered text and the citation blocks used to build the
    /// prompt — the chip row reads from the same retrieval pass that
    /// produced the text so the two never disagree.
    enum QueryResponse: Sendable {
        case insight(String)
        case retrieval([String])
        case ask(text: String, citations: [BlockMatch], provider: String)
        case error(String)
    }

    var surfaceMode: SurfaceMode = .collapsed

    /// Active mode — drives the mode-icon symbol in the expanded header
    /// and (in later commits) which pipeline runs on send. Defaults to
    /// `.ask`, matching the pre-c3 single-pipeline behavior.
    var activeMode: Mode = .ask

    /// Active scope — narrows retrieval to a slice of the corpus. Seeded
    /// from the host surface's scope at first mount (so a Librarian opened
    /// on a Collection canvas defaults to that collection). User can
    /// change it via the chip row above the input. Navigate + Ask honor
    /// this; Research / Provoke (still on the legacy pipeline) currently
    /// ignore it and will be brought in when each lands its own pipeline.
    var selectedScope: CanvasScope = .corpus

    /// Key of the host scope that last seeded `selectedScope`. The surface
    /// re-seeds on appear when the host scope changes, but leaves the
    /// user's explicit selection alone within the same host. Without this,
    /// every remount would clobber a manually-picked scope.
    var lastSeededHostKey: String? = nil

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
    /// embedding retrieval (no LLM); Ask uses block-embedding retrieval
    /// to feed prompt context and routes via `ModelRouter` (FM default,
    /// Ollama if configured). Research and Provoke still share the
    /// legacy classify → respond pipeline absorbed from `CorpusQuerySheet`
    /// until each lands its own. Store is injected at call site because
    /// LibrarianState doesn't own a reference.
    func executeQuery(store: CorpusStore) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isLoading = true
        response = nil

        switch activeMode {
        case .navigate:
            await runNavigatePipeline(query: query, store: store)
        case .ask:
            await runAskPipeline(query: query, store: store)
        case .research, .provoke:
            await runLegacyClassifyPipeline(query: query, store: store)
        }
    }

    /// Navigate mode — block-embedding retrieval. Returns the top nodes
    /// ranked by best-block cosine similarity to the query. No LLM call,
    /// no title hallucination, no iOS 26 gate. Empty result surfaces as
    /// an error so the user sees explicit no-match feedback rather than
    /// a confusing empty list.
    ///
    /// Scope is threaded *into* the candidate set (not applied as a
    /// post-filter) so a narrow collection can fill its `topK` from
    /// in-scope blocks rather than losing every top corpus match to the
    /// scope cut.
    private func runNavigatePipeline(query: String, store: CorpusStore) async {
        let matchedIDs = await store.findRelevantNodes(query: query, scope: selectedScope, topK: 5)
        if matchedIDs.isEmpty {
            response = .error("No matches yet. Try a different phrasing, or wait for content to finish embedding.")
        } else {
            response = .retrieval(matchedIDs)
        }
        isLoading = false
    }

    /// Ask mode — block-embedding retrieval feeds the prompt context,
    /// the same matches surface as citation chips. The response is a
    /// rich-text answer routed through `ModelRouter` (FM by default,
    /// Ollama when an endpoint is configured). The citations and the
    /// text come from one retrieval pass so the chip row can't drift
    /// from what the model actually saw.
    ///
    /// Citation markers (`[1] [2]`) are *requested* in the prompt but
    /// not enforced post-hoc — even if the model omits them, the chips
    /// still anchor the answer to its sources. Inline-marker parsing
    /// lands when the citation sheet does (c5c).
    /// Soft cap on passage content sent in the Ask prompt. Local models
    /// (Ollama / LM Studio) often run with a context window much smaller
    /// than the underlying model supports — LM Studio defaults a
    /// 32k-context Mistral-7B to 4096 unless reconfigured, which blows up
    /// silently with a Channel Error mid-stream. 12,000 chars (~3000
    /// tokens) leaves headroom for the system prompt, the user question,
    /// and the model's response inside a 4096-token window.
    ///
    /// Tunable: raise once the surface exposes a model-side window value
    /// or once we add a model name → known-window-size map.
    static let askPassageCharBudget: Int = 12_000

    /// Full-context char budget — drives the context ring visualization.
    /// Wider than `askPassageCharBudget` because the ring tracks
    /// everything that flows to the model (system prompt + retrieved
    /// passages + question + future multi-turn history) against the
    /// model's full window, not just the passage reservation. Sized to a
    /// 4096-token (~16k char) Mistral / LM Studio default with a small
    /// safety margin so the ring hits ~85% before the model errors.
    static let contextBudgetChars: Int = 14_000

    /// 0…1 estimate of how much of the context window will be consumed
    /// by the current/next query. Drives the ring color/fill in the
    /// surface header.
    ///
    /// c6a scope: system-prompt baseline + current input length only.
    /// The retrieval reservation (`askPassageCharBudget`) is *not*
    /// counted here — passages are committed per query, not held across
    /// turns, so adding them to the standing fill makes the ring read
    /// "almost full" before the user has typed anything. Multi-turn
    /// history accrual lands the `sessionHistory` term in c6b/c6c.
    var contextFillFraction: Double {
        let baseline = askSystemPrompt.count
        let questionChars = inputText.count
        let used = baseline + questionChars
        return min(1.0, Double(used) / Double(Self.contextBudgetChars))
    }

    /// Greedy first-fit trim by character count. The `!result.isEmpty` guard
    /// guarantees at least one passage is sent even if the top match alone
    /// blows the budget — better to overshoot by one block than to send a
    /// citation-free prompt that quietly drops the user's corpus. Per-block
    /// overhead (~50 chars) accounts for the numbered label and separator
    /// in `buildAskContext`.
    private static func trimToCharBudget(_ matches: [BlockMatch], budget: Int) -> [BlockMatch] {
        var used = 0
        var result: [BlockMatch] = []
        for match in matches {
            let cost = match.block.text.count + 50
            if used + cost > budget && !result.isEmpty {
                break
            }
            result.append(match)
            used += cost
        }
        return result
    }

    private func runAskPipeline(query: String, store: CorpusStore) async {
        let allMatches = await store.findRelevantBlockMatches(query: query, scope: selectedScope, topK: 8)
        let citations = Self.trimToCharBudget(allMatches, budget: Self.askPassageCharBudget)
        if citations.count < allMatches.count {
            print("[Librarian] Ask: trimmed citations \(allMatches.count) → \(citations.count) to fit \(Self.askPassageCharBudget)-char budget")
        }
        let context = buildAskContext(citations: citations, store: store)
        let userPrompt = buildAskUserPrompt(query: query, context: context, hasCitations: !citations.isEmpty)

        let provider = ModelRouter.active.displayName
        do {
            let text = try await ModelRouter.generate(
                systemPrompt: askSystemPrompt,
                userPrompt: userPrompt
            )
            response = .ask(text: text, citations: citations, provider: provider)
        } catch let error as ModelRouter.RouterError {
            response = .error(error.errorDescription ?? "Couldn't reach the model.")
        } catch {
            response = .error("Something went wrong. Try again.")
        }
        isLoading = false
    }

    /// Standing system prompt for Ask. Personal-model-prompt prefix lands
    /// in c11; until then this is the only steering the user gets.
    ///
    /// The "do not append a References / Sources section" clause is load-
    /// bearing for Mistral and Llama-family instruct templates, which
    /// otherwise hallucinate a `References:` block at the end — AirPad
    /// renders citations as chips below the answer, so an in-text list
    /// is a duplicate the user never asked for.
    private var askSystemPrompt: String {
        "You are a reflective AI that helps someone think across their own corpus. Be specific, concise, and never generic. When you reference a passage, mark it inline with bracket numbers like [1] [2] matching the numbered passages in the user prompt. Do not append a References, Sources, or Citations section at the end of your response — AirPad renders citations separately. End your reply at the end of the prose answer."
    }

    private func buildAskContext(
        citations: [BlockMatch],
        store: CorpusStore
    ) -> String {
        guard !citations.isEmpty else { return "" }
        return citations.enumerated().map { idx, match in
            let title = store.nodes.first { $0.id == match.nodeID }?.title ?? "Untitled"
            return "[\(idx + 1)] From \"\(title)\":\n\(match.block.text)"
        }.joined(separator: "\n\n---\n\n")
    }

    private func buildAskUserPrompt(query: String, context: String, hasCitations: Bool) -> String {
        if hasCitations {
            return """
            Relevant passages from the user's corpus:

            \(context)

            Question: \(query)

            Answer in 2-4 paragraphs. Reference passages inline with their bracket numbers when relevant. Stay specific to the passages above — don't invent content. Do not append a References, Sources, or Citations section — stop after the prose answer.
            """
        }
        return """
        Question: \(query)

        The user's corpus has nothing semantically close to this query. Answer briefly (2-3 sentences) and let them know you didn't find specific source material.
        """
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
