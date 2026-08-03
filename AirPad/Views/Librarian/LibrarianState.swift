import Foundation
import NaturalLanguage
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

    /// Librarian mode — which pipeline runs on send. For c3 this is
    /// purely state + visual (the dropdown changes the active icon);
    /// per-mode pipelines land in c4+ (Navigate first). Today every
    /// mode runs the same classify → respond pipeline.
    /// Sole surviving mode. Navigate / Research / Provoke were deleted (part
    /// 1 of the Librarian rebuild). The one-case enum is kept for now because
    /// `activeMode` and `LibrarianExchange.mode` still type against it — full
    /// removal rides with the chrome teardown in part 2.
    enum Mode: Sendable, CaseIterable {
        case ask

        var displayName: String { "Ask" }
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

    /// Instant-search query — independent of the mode pipeline's
    /// `inputText`. Drives the MATCHES section (and, in C2, RELATED)
    /// that takes over the transcript area while non-empty. Lives on
    /// state so a half-typed query survives surface remount.
    var searchText: String = ""

    /// Text-search matches in rank order. Stored as node IDs so a
    /// node renamed or deleted between query and render resolves
    /// against the live store (matches the `LibrarianExchange`
    /// pattern). Recomputed synchronously on every `searchText`
    /// change — text filter is O(nodes) and stays well under a
    /// frame for typical corpus sizes.
    /// One MATCHES result. `snippet` is set only for ENTRY-BODY hits (a pull
    /// quote built around the match); title/summary/tag hits leave it nil and
    /// the row shows the node summary. A node appears at most once (its highest
    /// tier).
    struct SearchMatch: Identifiable, Sendable {
        let id: String        // nodeID
        var snippet: String?
    }
    var searchMatches: [SearchMatch] = []

    /// Image (OCR) results — a SEPARATE section by INTENT: the user usually
    /// knows whether they're hunting typed text or something inside a picture.
    /// One row per matching gallery image; matched against
    /// `GalleryItem.analysis.recognizedText` with the same literal substring
    /// `contains` (substring is load-bearing — noisy OCR like "WARY PoPPINS"
    /// still has to be reachable via "poppins").
    struct SearchImageMatch: Identifiable, Sendable {
        let id: String          // GalleryItem.id, or "hero:<nodeID>" for a hero
        let nodeID: String
        let recognizedText: String
        let source: Source
        enum Source: Sendable {
            case gallery(entryID: String)   // the .imageVideo NodeItem.id (tile parentItem)
            case hero                        // renders from the node's coverImageRelativePath
        }
    }
    var searchImageMatches: [SearchImageMatch] = []

    /// Semantic-search results (RELATED). Block-level granularity:
    /// multiple blocks from the same node each get their own row with
    /// a distinct pull quote. Repopulated by `kickOffSemanticSearch`
    /// after a short debounce on each `searchText` change.
    struct SearchRelated: Identifiable, Sendable {
        let id: String        // blockID
        let nodeID: String
        let snippet: String
        let score: Float
    }
    var searchRelated: [SearchRelated] = []

    /// True from search kickoff until the semantic results land.
    /// Drives a subtle spinner next to the RELATED header so the user
    /// knows results are still arriving (typically resolves in
    /// 100-300ms after MATCHES).
    var searchSemanticInFlight: Bool = false

    /// In-flight debounce + embedding task. Cancelled on every new
    /// keystroke so only the latest query reaches `findRelevantBlocks`.
    /// `@ObservationIgnored` because the Observable macro otherwise
    /// emits init accessors that fight with the lazy-cancel pattern.
    @ObservationIgnored private var semanticSearchTask: Task<Void, Never>? = nil

    /// Last query response. Stays visible while the user types a new
    /// query; cleared at the start of the next `executeQuery` run.
    var response: QueryResponse? = nil

    /// True while a query is in flight against the language model.
    var isLoading: Bool = false

    /// True from streaming-request start until stream completion. Drives
    /// the shimmering "Thinking…" indicator and the per-token tail in
    /// `LibrarianSurface`. Distinct from `isLoading` because legacy
    /// non-streaming pipelines (Navigate, Research/Provoke classify) still
    /// set `isLoading` without ever entering streaming mode.
    var isStreaming: Bool = false

    /// Running buffer of streamed deltas for the in-flight Ask turn.
    /// Empty before the first token arrives and again after stream
    /// completion (text moves into `response` and `sessionHistory`).
    /// While non-empty during `isStreaming`, the surface renders the raw
    /// content with a blinking cursor.
    var streamingText: String = ""

    /// Snapshot of the user's query at the moment `executeQuery` fires.
    /// Lets the chat transcript render a pending bubble for the
    /// in-flight question while the model is still working — without
    /// it, the user's just-sent message would be invisible until the
    /// response lands and `appendExchange` adds the pair to history.
    /// Cleared when the pipeline completes (success, error, or
    /// retrieval no-match).
    var pendingQuery: String? = nil

    /// Completed exchanges in the current session. Appended in order
    /// by each pipeline on successful completion (errors are skipped).
    /// c6c: history is threaded back into Ask prompts so the model
    /// sees prior turns; compaction folds older turns into
    /// `compactedSummary` once `contextFillFraction` crosses the
    /// threshold, so this list represents the *uncompacted* tail.
    var sessionHistory: [LibrarianExchange] = []

    /// True whenever the user has an in-progress conversation worth
    /// preserving — uncompacted turns and/or a compacted summary
    /// from this session. Drives the session-aware posture rule: the
    /// surface refuses to collapse to the pill while a session is
    /// live, so a transcript can't be hidden behind the pill by an
    /// accidental tap or drag. (Gates on the same session-history signal
    /// the removed `endSessionFooter` used.)
    var hasActiveSession: Bool {
        !sessionHistory.isEmpty || compactedSummary != nil
    }

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


    // MARK: - Instant search

    /// Recomputes `searchMatches` from the current `searchText` against
    /// node titles, summaries (substrate summary if present, else
    /// legacy summary), and tags. Empty query → empty matches.
    /// Match order: title hits before body hits, ties broken by the
    /// store's natural order (recency-favored). Case-insensitive
    /// substring; trims whitespace so trailing-space typing doesn't
    /// drop matches.
    /// ws-librarian-perf Part 1 — debounced wrapper around `updateSearchMatches`.
    /// The substring scan is O(nodes) on the main actor; running it on every
    /// keystroke was a typing-path cost. Empty query clears immediately (no
    /// lingering stale matches); otherwise debounce 120ms.
    private var searchMatchesTask: Task<Void, Never>?
    func scheduleSearchMatches(store: CorpusStore) {
        searchMatchesTask?.cancel()
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchMatches = []
            searchImageMatches = []
            return
        }
        searchMatchesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            self?.updateSearchMatches(store: store)
        }
    }

    func updateSearchMatches(store: CorpusStore) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = []
            searchImageMatches = []
            return
        }
        let q = query.lowercased()
        // Three LITERAL tiers, in authorship order:
        //   1. TITLE       — user-authored AND navigational.
        //   2. ENTRY BODY  — what the USER actually wrote (notes, transcripts…).  ← NEW
        //   3. SUMMARY+TAGS — the summary is a MACHINE paraphrase of the node;
        //      ranking the paraphrase above the source inverts authorship. Today's
        //      order (summary before body) was never a considered ranking — entry
        //      bodies simply weren't searched, so the question never arose.
        // Stays literal: lowercased substring `contains`, NO scoring. MATCHES is
        // the instant half; RELATED is the strength-ranked one (two sections, two
        // jobs). A scored blend would also reorder on every keystroke — instability
        // on a surface the user watches change character by character.
        var titleHits: [SearchMatch] = []
        var bodyHits: [SearchMatch] = []
        var summaryTagHits: [SearchMatch] = []
        var imageHits: [SearchImageMatch] = []
        for node in store.nodes {
            if node.title.lowercased().contains(q) {
                titleHits.append(SearchMatch(id: node.id, snippet: nil))
            } else if let snippet = Self.bodyMatchSnippet(node: node, q: q, query: query) {
                bodyHits.append(SearchMatch(id: node.id, snippet: snippet))
            } else {
                let summary = (node.substrateSummary?.isEmpty == false ? node.substrateSummary! : node.summary)
                if summary.lowercased().contains(q) || node.tags.contains(where: { $0.lowercased().contains(q) }) {
                    summaryTagHits.append(SearchMatch(id: node.id, snippet: nil))
                }
            }
            // Images — scanned INDEPENDENTLY of the tier above (separate section
            // by intent). A node can be a title MATCH and also carry a picture
            // whose OCR matches, exactly as RELATED can co-occur with MATCHES.
            for item in node.items where item.type == .imageVideo {
                for media in item.mediaItems ?? [] {
                    if let text = media.analysis?.recognizedText,
                       text.lowercased().contains(q) {
                        imageHits.append(SearchImageMatch(
                            id: media.id, nodeID: node.id, recognizedText: text,
                            source: .gallery(entryID: item.id)
                        ))
                    }
                }
            }
            // Hero — ONLY a directly-picked hero (no gallery entry). DEDUPE: a
            // gallery-derived hero is already covered by its gallery item above,
            // so `directlyPickedHeroPath` returns nil for it → no second row.
            if node.directlyPickedHeroPath != nil,
               let text = node.heroAnalysis?.recognizedText,
               text.lowercased().contains(q) {
                imageHits.append(SearchImageMatch(
                    id: "hero:\(node.id)", nodeID: node.id, recognizedText: text, source: .hero
                ))
            }
        }
        searchMatches = titleHits + bodyHits + summaryTagHits
        searchImageMatches = imageHits
    }

    /// Scans a node's TEXTUAL entries for `q` and returns a pull quote built
    /// around the first match, else nil. Covers the entry types that carry text,
    /// read straight off the item model (NOT `AIService.extractContent`, which is
    /// the processNode path): `.text` content, `.audio`/`.video` transcript,
    /// `.link` title/preview, `.document` description. Reuses `pullQuote` —
    /// RELATED's snippet logic — so a hit inside a 900-word note shows the region
    /// around the term, not the summary.
    private static func bodyMatchSnippet(node: Node, q: String, query: String) -> String? {
        for item in node.items {
            let text: String
            switch item.type {
            case .text:              text = item.content ?? ""
            case .audio, .video:     text = item.transcript ?? ""
            case .link:              text = [item.title, item.preview].compactMap { $0 }.joined(separator: " ")
            case .document:          text = item.description ?? ""
            case .image, .imageVideo, .rating, .field, .chats:
                text = ""   // no free text (image OCR is the separate section;
                            // .chats is a reference — no extraction in V1)
            }
            if !text.isEmpty, text.lowercased().contains(q) {
                return pullQuote(from: text, query: query)
            }
        }
        return nil
    }

    /// Kicks off the semantic RELATED pass for the current `searchText`.
    /// Cancels any in-flight task first so only the latest query
    /// reaches the embedder. Debounces ~150ms before embedding so a
    /// fast typist doesn't trigger N embedding calls per second; the
    /// total budget (debounce + embed + rank) targets the 100-300ms
    /// fast-follow window after MATCHES.
    ///
    /// Block-level: multiple blocks from the same node each get a row
    /// with a distinct pull quote. No dedup against `searchMatches` —
    /// "this note's title matches" and "this passage is semantically
    /// related" are distinct signals worth showing separately.
    func kickOffSemanticSearch(store: CorpusStore) {
        semanticSearchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchRelated = []
            searchSemanticInFlight = false
            return
        }
        searchSemanticInFlight = true
        semanticSearchTask = Task { @MainActor [weak self, store] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            let matches = await store.findRelevantBlocks(query: query, topK: 10)
            if Task.isCancelled { return }
            guard let self else { return }
            self.searchRelated = matches.map { match in
                // ws-related-scoring Change 2 — snippet floor + fallback (display
                // only; the match/ranking is unchanged). A degenerate matched
                // block (e.g. a bare "-" bullet, or a sub-20-char / punctuation-
                // only fragment) renders as a blank/dash body, so fall back to the
                // node's summary for the row text.
                let blockText = match.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isDegenerate = blockText.count < 20
                    || !blockText.contains(where: { $0.isLetter || $0.isNumber })
                let snippet: String
                if isDegenerate,
                   let node = store.nodes.first(where: { $0.id == match.nodeID }) {
                    let summary = (node.substrateSummary?.isEmpty == false ? node.substrateSummary! : node.summary)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    snippet = summary.isEmpty
                        ? Self.pullQuote(from: match.block.text, query: query)
                        : summary
                } else {
                    snippet = Self.pullQuote(from: match.block.text, query: query)
                }
                return SearchRelated(
                    id: match.block.blockID,
                    nodeID: match.nodeID,
                    snippet: snippet,
                    score: match.score
                )
            }
            self.searchSemanticInFlight = false
        }
    }

    /// Extracts a 1-2 sentence pull quote from `text` using
    /// `NLTokenizer(.sentence)`. Sentence with the most query-word
    /// hits wins; ties go to the earliest sentence so context order
    /// is preserved when nothing distinguishes them. Falls back to
    /// the first sentence when no overlap is found, and truncates at
    /// ~240 chars so row height stays bounded for very long sentences.
    static func pullQuote(from text: String, query: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let s = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        guard !sentences.isEmpty else { return Self.cap(trimmed) }

        let queryWords = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }

        func score(_ s: String) -> Int {
            let lower = s.lowercased()
            return queryWords.reduce(0) { acc, w in acc + (lower.contains(w) ? 1 : 0) }
        }

        let bestIdx = sentences.indices.max { a, b in
            let sa = score(sentences[a])
            let sb = score(sentences[b])
            if sa != sb { return sa < sb }
            return a > b   // earlier sentence wins on tie
        } ?? 0
        return Self.cap(sentences[bestIdx])
    }

    private static func cap(_ s: String) -> String {
        if s.count <= 240 { return s }
        return String(s.prefix(240)) + "…"
    }

    /// Live Ask entry — retrieval-INFORMED, NO mode routing (Part 2). ALWAYS
    /// retrieves and hands the top passages to the model under ONE honest-framing
    /// prompt ("these came from your notes by similarity search and may not be
    /// relevant — use and cite any that help, otherwise answer normally"). The
    /// MODEL judges relevance; we never pre-select a "grounded" vs "open" answer
    /// from a score, so a general-knowledge question can no longer be refused for
    /// lack of a matching passage (BUG 7).
    ///
    /// `minRelevanceScore` is now a budget/inclusion control — don't spend a small
    /// local model's context on sub-bar passages — NOT a correctness switch (it
    /// still gates the RELATED surface). Every included passage is a *candidate*
    /// source; `ChatSession.send` keeps only the ones the answer actually cites
    /// inline, so a turn that ignores the passages can't show phantom sources.
    /// LibrarianState owns retrieval + prompt construction; the composed turn is
    /// handed to the dumb `ChatSession` streaming lane (which owns the transcript).
    func groundedSend(query rawQuery: String, store: CorpusStore, chat: ChatSession) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // ★ Private mode (DEFAULT, corpusAware == false): do NOT retrieve. Send the
        // bare question with a plain assistant prompt — no passages, no citation
        // chips, no "answer from your notes" framing. On T's corpus BGE scores
        // everything 0.5–0.7, so forced retrieval feeds hard-negative noise into
        // every Ask and a small model drowns in it; grounding is now a mode the
        // user turns ON only when interrogating their notes. `corpusAware` is a
        // stored+persisted property read live here, so a toggle flip lands on the
        // very next send.
        guard corpusAware else {
            // ★ Private mode. REMOTE endpoint → agentic web-search loop (the tool
            // schema is attached and the model may call web_search / fetch_url). FM
            // → plain chat with NO tools (different tool API, not the near-term
            // target — behaves exactly as before). A non-tool remote model simply
            // never calls a tool and answers normally, so this degrades silently.
            if case .ollama = ModelRouter.active {
                // Tool loop steers with the tool-aware prompt (real date + "trust the
                // live results, don't hedge") — NOT the plain private prompt, which
                // told the model to answer "from your own knowledge" (the bug).
                // `WebSearchBackend.make()` picks Brave (reliable) when a key is set,
                // else the keyless DDG scraper — the loop is agnostic to which.
                await chat.sendWithTools(displayText: query,
                                         systemPrompt: toolChatSystemPrompt,
                                         executor: WebSearchBackend.make())
            } else {
                await chat.send(displayText: query, modelText: query,
                                systemPrompt: privateSystemPrompt, citations: nil)
            }
            return
        }

        // ★ Corpus mode (corpusAware == true): current behaviour exactly. Retrieve,
        // include the passages worth the budget (≥ the bar) — a budget filter, NOT a
        // correctness switch — and hand them to the honest-framing corpus prompt.
        let matches = await store.askMatches(query: query, scope: selectedScope, topK: 8)
        let candidates = Self.trimToCharBudget(
            matches.filter { $0.score >= CorpusStore.minRelevanceScore },
            budget: Self.askPassageCharBudget
        )

        let modelText: String
        if candidates.isEmpty {
            // No worthwhile passages — hand the model the bare question. The
            // honest-framing system prompt still says "answer normally," no refusal.
            modelText = query
        } else {
            let context = buildAskContext(citations: candidates, store: store)
            modelText = """
            Some passages retrieved from your notes by similarity search — they may or may not be relevant to the question:

            \(context)

            Question: \(query)
            """
        }

        // Candidate sources for THIS turn; `ChatSession.send` filters these down to
        // the [n] the model actually cited before committing the message.
        let chips = candidates.isEmpty ? nil : Self.citationChips(from: candidates, store: store)
        await chat.send(displayText: query, modelText: modelText, systemPrompt: askSystemPrompt, citations: chips)
    }

    /// Per-passage citations, `index` = the `[n]` the prompt/model uses. Stored
    /// PER-BLOCK (not node-deduped) so an inline `[n]` tap can resolve its exact
    /// node — the footer dedups by node for display (Piece 2). Ordered by `[n]`.
    private static func citationChips(from cited: [BlockMatch], store: CorpusStore) -> [ChatSession.Message.Citation] {
        cited.enumerated().map { i, match in
            let title = store.nodes.first { $0.id == match.nodeID }?.title ?? "Untitled"
            let snippet = String(match.block.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            return .init(index: i + 1, nodeID: match.nodeID, title: title, snippet: snippet)
        }
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

    /// Wipes the session — history, start time, last response, and the
    /// input field, returning the surface to a clean pre-session state.
    /// `selectedScope` and `activeMode` survive so the next session
    /// inherits the user's last working slice. (Its former caller, the
    /// End-session "Clear" branch, was removed with `endSessionFooter`;
    /// kept as the reset entry point for a future session-save re-wire.)
    func clearSession() {
        sessionHistory.removeAll()
        sessionStartedAt = nil
        response = nil
        inputText = ""
        compactedSummary = nil
        compactedExchangeCount = 0
        compactedCitationIDs = []
        pendingQuery = nil
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

    // ws-card-catalog Ask hybrid — the old grounded pipeline (executeQuery →
    // runAskPipeline) was orphaned when the Ask button was rewired to the
    // ChatSession lane; retrieval was replaced by `groundedSend` above (the one
    // live Ask path). Its prompt builders (buildAskUserPrompt, buildHistoryBlock)
    // are now deleted. `appendExchange` (the sessionHistory writer) and the
    // compaction path are LEFT as the data source for a future session-save.
    // The UI was REMOVED 2026-08-01: the End-session footer/dialog (dead since
    // the ChatSession rewire — `appendExchange` uncalled ⇒ `sessionHistory`
    // always empty ⇒ its "Save to corpus" always no-op'd) is gone. Ending a
    // chat now flows through the active-chat pill × dialog (Save-to-Chats /
    // Delete). `saveSessionAsNode`/`clearSession` are KEPT as the wired target
    // for when `appendExchange` is reconnected; re-wire is a product call.

    /// Standing system prompt for Ask. Composed of the optional user-set
    /// personal voice (c7) followed by the baseline steering.
    ///
    /// The "do not append a References / Sources section" clause is load-
    /// bearing for Mistral and Llama-family instruct templates, which
    /// otherwise hallucinate a `References:` block at the end — AirPad
    /// renders citations as chips below the answer, so an in-text list
    /// is a duplicate the user never asked for.
    private var askSystemPrompt: String {
        let base = "You are a reflective AI that helps someone think across their OWN notes. Passages from the user's notes may appear below the question; they were pulled by similarity search and MAY OR MAY NOT be relevant. Treat any that genuinely help as authoritative about the user's own world — if a passage defines a term, use THEIR definition over a generic one — and cite it inline with bracket numbers like [1] [2] matching the numbered passages. Ignore passages that don't help and answer normally from your own knowledge. Never say the notes don't contain the answer and never refuse for lack of a matching passage — just answer the question directly. Be specific, concise, and never generic. Do not append a References, Sources, or Citations section — AirPad renders citations separately. End your reply at the end of the prose answer."
        return personalVoicePrefix + base
    }

    /// ★ Private-mode system prompt (corpusAware OFF). A plain, direct assistant —
    /// deliberately ZERO corpus language: no "notes", no passages, no citation
    /// framing, no "answer from your own knowledge if the notes don't help" hedging.
    /// Sending corpus framing when there IS no corpus in the prompt is exactly what
    /// confuses a small model; this is the LM-Studio-quality private-chat experience.
    /// Keeps `personalVoicePrefix` because the standing voice is about tone, not
    /// grounding — it applies to both modes.
    private var privateSystemPrompt: String {
        let base = "You are a helpful, direct, and concise assistant. Answer the user's question clearly and accurately from your own knowledge. Be specific and genuinely useful; don't pad the answer."
        return personalVoicePrefix + base
    }

    /// ★ Tool-loop system prompt (private + REMOTE). Distinct from `privateSystemPrompt`
    /// because a web search has ALREADY run — the model must synthesize from the LIVE
    /// tool results in the conversation, NOT from its training data. This directly
    /// fixes the "tools fired but the answer ignored them + dated itself to 2024" bug:
    /// it injects the REAL current date (the model otherwise guesses its training-cutoff
    /// year) and explicitly counters the trained "as an AI I don't have real-time access"
    /// reflex. Read fresh at send time so the date is always today's.
    private var toolChatSystemPrompt: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, MMMM d, yyyy"
        let today = df.string(from: Date())
        let base = """
        You are a helpful, direct, concise assistant with LIVE web tools (web_search, fetch_url). \
        Today's real date is \(today). When a question needs current, local, or factual information, \
        call the tools.

        CRITICAL — how to use tool results: any tool results already present in this conversation were \
        fetched JUST NOW. They are live, current, and authoritative. Answer FROM those results, not from \
        your training data. Do NOT say you lack real-time access. Do NOT claim a knowledge cutoff. Do NOT \
        guess or invent the date — today is \(today), and the current information is already in front of \
        you. If the results genuinely don't cover the question, say what you found and what is missing — \
        but never refuse on the grounds that you cannot access the web, because you just did.

        CITING SOURCES: the search results are numbered ([1], [2], …). When you use a result, cite it \
        inline with its bracket number like [1] or [2] matching that numbered result. Do NOT paste raw \
        URLs into your prose — the app renders the real links from your [n] citations, and any URL you \
        type yourself will be shown as plain, non-clickable text.
        """
        return personalVoicePrefix + base
    }

    #if DEBUG
    /// Headless-verification accessor — lets `-Screen` dump the resolved tool prompt
    /// (with today's real date injected) so STEP 0 can SEE the corrected context.
    var debugToolSystemPrompt: String { toolChatSystemPrompt }
    #endif

    /// ★ Corpus-grounding toggle (default FALSE = private chat). Stored so the
    /// surface pill re-renders on flip (observation-tracked), and persisted via
    /// `didSet` so it survives surface remounts and app restarts — a standing
    /// preference, like personal voice. `groundedSend` reads it live at send time.
    var corpusAware: Bool = UserDefaults.standard.bool(forKey: "librarianCorpusAware") {
        didSet { UserDefaults.standard.set(corpusAware, forKey: "librarianCorpusAware") }
    }

    /// Read-only indicator of the model that will answer the next Ask (the FM
    /// friendly name, or a remote endpoint's model id). STORED + observable so the
    /// surface updates when an async probe lands; refreshed via `refreshActiveModel()`
    /// — deliberately NOT read per render, because resolving the provider hits the
    /// Keychain (XPC) and a remote endpoint hits the network, neither of which
    /// belongs in `body`. Defaults to the FM name.
    private(set) var activeModelLabel: String = ModelRouter.foundationModelName

    /// Refresh the model indicator OFF the render path. Resolves the live provider
    /// (so an endpoint swapped in Settings is reflected on the next turn) and probes
    /// a remote endpoint's model id (best-effort → resting label). Cheap for FM (no
    /// network). Called on surface appear and when the Ask field focuses — mirroring
    /// the personal-voice hook's "read fresh right before it matters" cadence.
    func refreshActiveModel() async {
        #if DEBUG
        // `-MockModelName <id>` forces the label (headless verification of the
        // remote-endpoint state without a live server). No-op without the arg.
        if let mock = UserDefaults.standard.string(forKey: "MockModelName"), !mock.isEmpty {
            activeModelLabel = mock
            return
        }
        #endif
        activeModelLabel = await ModelRouter.resolveActiveModelName()
    }

    /// User-defined standing voice (c7) — read fresh on each prompt build
    /// so Settings edits take effect on the next Ask without re-creating
    /// the session. Returns "" when unset or whitespace-only; otherwise
    /// returns the trimmed text followed by a blank line so it
    /// concatenates cleanly into whatever follows.
    private var personalVoicePrefix: String {
        let raw = UserDefaults.standard.string(forKey: "librarianPersonalPrompt") ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed + "\n\n"
    }

    /// Surface-visible flag for the personal-voice indicator. Pure UI hook —
    /// the prompt builder reads UserDefaults directly so changes in Settings
    /// land on the next Ask regardless of whether the surface re-evaluated.
    var hasPersonalVoice: Bool {
        let raw = UserDefaults.standard.string(forKey: "librarianPersonalPrompt") ?? ""
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

}
