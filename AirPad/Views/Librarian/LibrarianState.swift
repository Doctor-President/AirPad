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

    /// One completed query+response pair. Errors are *not* appended —
    /// the transcript is meant to be a record of what the session
    /// produced, not what it tried and failed at. `citationNodeIDs`
    /// carries the source notes for Ask responses or the retrieved
    /// notes for Navigate / legacy-retrieval; empty for synthesis-only
    /// responses (Insight). Scope is captured per-exchange so a
    /// session that crossed scopes preserves which slice each turn
    /// drew from.
    struct LibrarianExchange: Identifiable, Sendable {
        let id: String
        let mode: Mode
        let scope: CanvasScope
        let query: String
        /// Synthesis text. Empty string for pure-retrieval responses
        /// where the "answer" is the node list itself.
        let responseText: String
        /// Cited or retrieved node IDs in rank order. Title resolution
        /// happens at transcript-build time so renamed nodes show
        /// their current title, not a frozen snapshot.
        let citationNodeIDs: [String]
        let timestamp: Date

        init(
            mode: Mode,
            scope: CanvasScope,
            query: String,
            responseText: String,
            citationNodeIDs: [String],
            timestamp: Date = Date()
        ) {
            self.id = UUID().uuidString
            self.mode = mode
            self.scope = scope
            self.query = query
            self.responseText = responseText
            self.citationNodeIDs = citationNodeIDs
            self.timestamp = timestamp
        }
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

    /// Completed exchanges in the current session. Appended in order
    /// by each pipeline on successful completion (errors are skipped).
    /// c6c: history is threaded back into Ask prompts so the model
    /// sees prior turns; compaction folds older turns into
    /// `compactedSummary` once `contextFillFraction` crosses the
    /// threshold, so this list represents the *uncompacted* tail.
    var sessionHistory: [LibrarianExchange] = []

    /// Timestamp the current session began — set when the first
    /// exchange lands, cleared on `clearSession()`. Drives the session
    /// node's `createdAt` on save so the saved node anchors to when
    /// the user actually started, not when they tapped End.
    var sessionStartedAt: Date? = nil

    /// LLM-generated paragraph summarizing older session turns that
    /// were folded into a single block to keep prompt size in check.
    /// `nil` until the first compaction pass fires. Threaded into the
    /// next Ask prompt as an "Earlier in this session" preamble so the
    /// model retains the gist without paying the full token cost.
    var compactedSummary: String? = nil

    /// Number of original turns folded into `compactedSummary`. Surfaces
    /// to the model in the preamble ("compacted summary of N turns") so
    /// it knows roughly how much history is behind the summary, and is
    /// rendered into the save-transcript so the saved Node reflects the
    /// real session shape, not just the post-compaction tail.
    var compactedExchangeCount: Int = 0

    /// Node IDs cited or retrieved during the now-compacted turns.
    /// Preserved separately because `compactedSummary` is prose — we
    /// still want `provenance` on the saved Node to point at every
    /// referenced source across the full session.
    private var compactedCitationIDs: [String] = []

    /// Fill fraction that triggers a compaction pass before the next
    /// Ask turn fires. Picked to drain the ring well before the
    /// model's hard window (≈4096 tokens / 16k chars on a stock LM
    /// Studio Mistral), with enough margin that the post-compaction
    /// prompt still fits comfortably even if the summary runs long.
    static let compactionThreshold: Double = 0.85

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
            appendExchange(
                mode: .navigate,
                scope: selectedScope,
                query: query,
                responseText: "",
                citationNodeIDs: matchedIDs
            )
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
    /// Counts: system-prompt baseline + current input length +
    /// compacted summary + accrued session history (per-exchange query
    /// + responseText). The retrieval reservation
    /// (`askPassageCharBudget`) is *not* counted here — passages are
    /// committed per query, not held across turns, so adding them to
    /// the standing fill would make the ring read "almost full" before
    /// the user has typed anything. After a compaction pass, the
    /// `sessionHistory` term shrinks to zero and the summary term
    /// replaces it — net effect is the ring drains and color shifts
    /// back toward cyan.
    var contextFillFraction: Double {
        let baseline = askSystemPrompt.count
        let questionChars = inputText.count
        let compactedChars = compactedSummary?.count ?? 0
        let historyChars = sessionHistory.reduce(0) { acc, ex in
            acc + ex.query.count + ex.responseText.count
        }
        let used = baseline + questionChars + compactedChars + historyChars
        return min(1.0, Double(used) / Double(Self.contextBudgetChars))
    }

    /// Centralized exchange recorder. Called by each pipeline on
    /// successful completion. Stamps `sessionStartedAt` on the first
    /// exchange so saving picks up the actual session start.
    private func appendExchange(
        mode: Mode,
        scope: CanvasScope,
        query: String,
        responseText: String,
        citationNodeIDs: [String]
    ) {
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
        sessionHistory.append(LibrarianExchange(
            mode: mode,
            scope: scope,
            query: query,
            responseText: responseText,
            citationNodeIDs: citationNodeIDs
        ))
    }

    /// Wipes the session — history, start time, last response, and
    /// the input field. Called by the End-session "Clear" branch and
    /// after a successful Save so the surface returns to a clean
    /// pre-session state. `selectedScope` and `activeMode` survive so
    /// the next session inherits the user's last working slice.
    func clearSession() {
        sessionHistory.removeAll()
        sessionStartedAt = nil
        response = nil
        inputText = ""
        compactedSummary = nil
        compactedExchangeCount = 0
        compactedCitationIDs = []
    }

    /// Builds a corpus Node from the current session and persists it
    /// via `CorpusStore.addNode`. Transcript renders as a single
    /// `.text` item — readable in detail view, embeddable by the
    /// substrate later. Returns the new node ID so the caller can
    /// optionally jump into it (today the caller just clears the
    /// session). No-ops when history is empty.
    @discardableResult
    func saveSessionAsNode(store: CorpusStore) async -> String? {
        guard !sessionHistory.isEmpty || compactedSummary != nil else { return nil }
        let now = Date()
        let started = sessionStartedAt ?? now
        let title = buildSessionTitle()
        let summary = buildSessionSummary()
        let transcript = buildTranscript(store: store)
        let liveIDs = sessionHistory.flatMap(\.citationNodeIDs)
        let referencedIDs = Array(Set(liveIDs + compactedCitationIDs))
        await store.ensureLibrarianSessionsCollection()
        let node = Node(
            id: UUID().uuidString,
            createdAt: started,
            updatedAt: now,
            title: title,
            summary: summary,
            tags: [],
            isMeta: true,
            provenance: referencedIDs.isEmpty ? nil : referencedIDs,
            items: [NodeItem.text(content: transcript)],
            needsAIProcessing: false,
            collectionIDs: [NodeCollection.librarianSessionsID],
            source: "librarian-session",
            entrySchemaVersion: 1
        )
        await store.addNode(node, position: .zero)
        return node.id
    }

    /// First user query, trimmed to a readable list-row length. Falls
    /// back to a date-stamped generic when the first query is empty
    /// or only whitespace (shouldn't happen — `executeQuery` guards —
    /// but keep the safety rail). After compaction, the original
    /// first query is gone, so we fall back to the date-stamped form
    /// rather than picking a still-recent turn that's not actually
    /// the session opener.
    private func buildSessionTitle() -> String {
        let firstQuery: String
        if compactedExchangeCount > 0 {
            firstQuery = ""
        } else {
            firstQuery = sessionHistory.first?.query
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if firstQuery.isEmpty {
            return "Librarian session — \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        if firstQuery.count > 60 {
            return String(firstQuery.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return firstQuery
    }

    private func buildSessionSummary() -> String {
        let totalTurns = sessionHistory.count + compactedExchangeCount
        let modes = Array(Set(sessionHistory.map(\.mode.displayName))).sorted()
        let modeList = modes.isEmpty ? "compacted" : modes.joined(separator: " + ")
        return "Librarian session — \(totalTurns) turn\(totalTurns == 1 ? "" : "s") (\(modeList))"
    }

    /// Render the session as markdown-ish plain text. Scope and mode
    /// labels live in the per-exchange header so a session that
    /// crossed scopes preserves which slice each turn drew from.
    /// Source notes appear as a trailing list per turn so the
    /// transcript reads back without needing to chase chips.
    ///
    /// When compaction has fired at least once, the saved transcript
    /// is prefaced with the compaction summary so the saved Node
    /// reflects the *full* session shape, not just the post-compaction
    /// tail. The summary block is set off with the same em-dash
    /// separator the per-turn blocks use so the reader's eye treats
    /// it as the first "turn" in the conversation.
    private func buildTranscript(store: CorpusStore) -> String {
        var blocks: [String] = []
        if let summary = compactedSummary, !summary.isEmpty {
            blocks.append("[Earlier in session — \(compactedExchangeCount) turn\(compactedExchangeCount == 1 ? "" : "s") compacted]\n\(summary)")
        }
        for exchange in sessionHistory {
            let modeLabel = exchange.mode.displayName
            let scopeLabel = scopeDisplayName(exchange.scope, store: store)
            var lines: [String] = []
            lines.append("[\(modeLabel) · \(scopeLabel)]")
            lines.append("Q: \(exchange.query)")
            if !exchange.responseText.isEmpty {
                lines.append("")
                lines.append(exchange.responseText)
            }
            if !exchange.citationNodeIDs.isEmpty {
                let titles = exchange.citationNodeIDs.map { id -> String in
                    store.nodes.first { $0.id == id }?.title ?? "Untitled"
                }
                lines.append("")
                lines.append("Sources: " + titles.joined(separator: ", "))
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n———\n\n")
    }

    private func scopeDisplayName(_ scope: CanvasScope, store: CorpusStore) -> String {
        switch scope {
        case .corpus:
            return "Corpus"
        case .collection(let id):
            if id == NodeCollection.journalID { return "Journal" }
            return store.collections.first { $0.id == id }?.name ?? "Collection"
        }
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
        await runCompactionIfNeeded()
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
            var seen = Set<String>()
            let citedNodeIDs = citations.compactMap { match -> String? in
                seen.insert(match.nodeID).inserted ? match.nodeID : nil
            }
            appendExchange(
                mode: .ask,
                scope: selectedScope,
                query: query,
                responseText: text,
                citationNodeIDs: citedNodeIDs
            )
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
        let historyBlock = buildHistoryBlock()
        if hasCitations {
            return """
            \(historyBlock)Relevant passages from the user's corpus:

            \(context)

            Question: \(query)

            Answer in 2-4 paragraphs. Reference passages inline with their bracket numbers when relevant. Stay specific to the passages above — don't invent content. Do not append a References, Sources, or Citations section — stop after the prose answer.
            """
        }
        return """
        \(historyBlock)Question: \(query)

        The user's corpus has nothing semantically close to this query. Answer briefly (2-3 sentences) and let them know you didn't find specific source material.
        """
    }

    /// Composes the session-memory preamble that rides ahead of the
    /// retrieval passages and current question. Emits one of three
    /// shapes (empty / summary-only / summary+recent / recent-only)
    /// and always ends with a trailing blank line so it concatenates
    /// cleanly into the rest of the prompt. Skipped entirely when
    /// there's no history *and* no compacted summary — keeps the
    /// first-turn prompt identical to pre-c6c so single-shot use
    /// doesn't regress.
    private func buildHistoryBlock() -> String {
        let hasSummary = compactedSummary?.isEmpty == false
        let hasRecent = !sessionHistory.isEmpty
        guard hasSummary || hasRecent else { return "" }

        var parts: [String] = []
        if let summary = compactedSummary, !summary.isEmpty {
            parts.append("Earlier in this session (compacted summary of \(compactedExchangeCount) turn\(compactedExchangeCount == 1 ? "" : "s")):\n\(summary)")
        }
        if hasRecent {
            let recent = sessionHistory.map { ex in
                "Q: \(ex.query)\nA: \(ex.responseText)"
            }.joined(separator: "\n---\n")
            parts.append("Recent turns in this session:\n\(recent)")
        }
        return parts.joined(separator: "\n\n") + "\n\n"
    }

    /// Compaction pass — fires before an LLM call when the running
    /// fill estimate would push us into the danger zone for the
    /// model's context window. Feeds `sessionHistory` (plus any
    /// existing `compactedSummary`) to the same model the user is
    /// talking to, asks for a single dense paragraph, then folds the
    /// turns away. Net effect: `contextFillFraction` drops back into
    /// the cyan band and the next prompt fits.
    ///
    /// Failure is non-fatal — if the compaction call errors, history
    /// stays intact and the user's actual query proceeds with the
    /// uncompacted prompt. The user-visible Ask call may then itself
    /// fail with a window error, which is no worse than what would
    /// have happened without this commit. A log line surfaces the
    /// failure for diagnostic purposes.
    ///
    /// Runs only when at least two turns are pending — single-turn
    /// "compaction" would just paraphrase one exchange at no benefit.
    private func runCompactionIfNeeded() async {
        guard contextFillFraction >= Self.compactionThreshold else { return }
        guard sessionHistory.count >= 2 else { return }

        let toFold = sessionHistory
        let foldCount = toFold.count
        let priorSummary = compactedSummary

        let exchangesText = toFold.map { ex in
            "Q: \(ex.query)\nA: \(ex.responseText)"
        }.joined(separator: "\n---\n")

        let priorBlock: String
        if let priorSummary, !priorSummary.isEmpty {
            priorBlock = "Earlier conversation (already compacted once): \(priorSummary)\n\n"
        } else {
            priorBlock = ""
        }

        let compactionPrompt = """
        \(priorBlock)Conversation turns to summarize:

        \(exchangesText)

        Summarize the conversation above into a single dense paragraph (~120 words) that preserves the key themes, what the user concluded, and any unresolved threads. Write in third person ("the user asked…"). Be specific. Do not include a header or label — just the paragraph.
        """

        do {
            let summary = try await ModelRouter.generate(
                systemPrompt: compactionSystemPrompt,
                userPrompt: compactionPrompt
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            compactedSummary = trimmed
            compactedExchangeCount += foldCount
            compactedCitationIDs.append(contentsOf: toFold.flatMap(\.citationNodeIDs))
            sessionHistory.removeAll()
            print("[Librarian] Compacted \(foldCount) turns into \(trimmed.count) chars; ring drains to \(String(format: "%.2f", contextFillFraction))")
        } catch {
            print("[Librarian] Compaction failed: \(error). Proceeding with full history.")
        }
    }

    /// System prompt for the compaction pass. Distinct from
    /// `askSystemPrompt` because the model is doing summarization,
    /// not reflection — different shape, different stopping criteria.
    private var compactionSystemPrompt: String {
        "You are a precise summarizer. Given a conversation between a user and an AI assistant that helps them think across their notes, produce a single dense paragraph capturing the substantive content: what was asked, what was found or concluded, and any threads still open. Specific, not generic. Output only the paragraph — no preface, no header, no trailing meta."
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
                if !matchedIDs.isEmpty {
                    appendExchange(
                        mode: activeMode,
                        scope: selectedScope,
                        query: query,
                        responseText: "",
                        citationNodeIDs: matchedIDs
                    )
                }
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
                appendExchange(
                    mode: activeMode,
                    scope: selectedScope,
                    query: query,
                    responseText: result,
                    citationNodeIDs: []
                )
            }
            isLoading = false
        } catch {
            response = .error("Something went wrong. Try again.")
            isLoading = false
        }
    }
}
