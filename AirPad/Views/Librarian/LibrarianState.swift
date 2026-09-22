import Foundation
import NaturalLanguage
import Observation
import FoundationModels
import os

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

    // MARK: - Brief S — corpus-Ask retrieval (title context, follow-ups, pinning)

    /// One numbered retrieval candidate. `number` is the `[n]` the prompt and the
    /// citation chips use; it is assigned on FIRST appearance and then PRESERVED
    /// across turns (S2) so `[n]` means the same source turn to turn. `origin` feeds
    /// the S5 candidate log only.
    ///
    /// Brief AA — a candidate is EITHER a passage (block-level DEPTH) or a card
    /// (node-level BREADTH). ONE numbered list holds both, so `[n]` is continuous
    /// across the prompt's NOTES and PASSAGES sections and the S2 carry unions the
    /// two kinds.
    struct NumberedCandidate: Sendable {
        enum Origin: String, Sendable { case carried, new, pinned }
        enum Payload: Sendable {
            case passage(BlockMatch)
            case card(CardMatch)
        }
        let number: Int
        var payload: Payload
        var origin: Origin

        var nodeID: String {
            switch payload {
            case .passage(let m): return m.nodeID
            case .card(let c):    return c.nodeID
            }
        }
        var score: Float {
            switch payload {
            case .passage(let m): return m.score
            case .card(let c):    return c.score
            }
        }
        var isCard: Bool { if case .card = payload { return true } else { return false } }

        /// Stable de-dup / carry identity: a passage's blockID, a card's node id
        /// (`card:`-prefixed so a card and a passage of the same node never collide).
        var identity: String {
            switch payload {
            case .passage(let m): return m.block.blockID
            case .card(let c):    return "card:\(c.nodeID)"
            }
        }
    }

    /// Brief AA2 — whether this turn's retrieval looks like a LOOKUP (concentrated:
    /// a strong passage backed by a second passage from the same node) or a SURVEY
    /// (everything else). Set by result SHAPE, never by classifying the question
    /// (T's ruling: no question classifier). Drives the passage/card budget split.
    enum RetrievalShape: String, Sendable {
        case lookup, survey
        /// AA2 budgets. Lookup leans on passages (depth); survey leans on cards (breadth).
        var passageBudget: Int { self == .lookup ? 8 : 4 }
        var cardBudget: Int { self == .lookup ? 12 : 30 }
    }

    struct ShapeVerdict: Sendable {
        let shape: RetrievalShape
        let topPassage: Float
        let topNodeDup: Int
        let dupOwnNote: Bool
    }

    /// The full numbered candidate list handed to the model on the PREVIOUS
    /// corpus-Ask turn, kept so the next turn can carry it forward (S2). Keyed by
    /// `carriedChatID`: when the live chat's id changes (New / switch / reset) the
    /// carry is dropped — a fresh conversation starts numbering at 1.
    @ObservationIgnored private var carriedCandidates: [NumberedCandidate] = []
    @ObservationIgnored private var carriedChatID: UUID? = nil

    /// S5 — one record per corpus-mode turn (turn index, embedder query, each
    /// candidate). Subsystem/category per the brief; logs in DEBUG and Release.
    private static let candidateLog = Logger(subsystem: "com.doctorpresident.airpad", category: "librarian")

    /// AC2 — the last 10 S5 turn records (scope, empty, shape, per-candidate rows),
    /// kept IN MEMORY so Settings → "Copy Librarian log" can put them on the
    /// clipboard. RELEASE-visible (T diagnoses on TestFlight, where os_log isn't
    /// readable — [[testflight-print-dead-channel]]), so no `#if DEBUG`.
    private(set) static var recentCandidateLog: [String] = []
    private static let recentCandidateLogCap = 10

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
        chat.thinkEnabled = thinkEnabled // Phase 2: the Librarian's per-session Thinking toggle → the Host

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
            // The agentic web-search loop runs over a direct .ollama endpoint OR the sealed .host
            // pairing (previously .ollama-ONLY — which is why web search never worked over a paired
            // Host). FM has no tool API → plain chat.
            let toolCapable: Bool
            switch ModelRouter.active {
            case .ollama, .host: toolCapable = true
            default: toolCapable = false
            }
            guard toolCapable else {
                // FM (no tool API) → plain private chat, exactly as before.
                await chat.send(displayText: query, modelText: query,
                                systemPrompt: privateSystemPrompt, citations: nil)
                return
            }

            // Brief AF1 + AF3 — the APP owns the no-key state, not the model. With NO
            // Brave key there is no working web tool, so we must NOT declare it or hint
            // at it (AF1: "declare nothing, say nothing about search"):
            //   • a search-intent message → the app answers in ONE line pointing at
            //     Settings, and NO model call is made (AF3);
            //   • any other message → a plain private chat with the tool-free prompt,
            //     so the model never advertises a capability it can't use.
            guard WebSearchBackend.hasKey else {
                if Self.looksLikeSearchIntent(query) {
                    chat.appendWebSearchKeyNotice(userText: query)
                } else {
                    await chat.send(displayText: query, modelText: query,
                                    systemPrompt: privateSystemPrompt, citations: nil)
                }
                return
            }

            // Key present → the agentic tool loop. It steers with the tool-aware prompt
            // (real date + "trust the live results, don't hedge") — NOT the plain private
            // prompt, which told the model to answer "from your own knowledge" (the bug).
            await chat.sendWithTools(displayText: query,
                                     systemPrompt: toolChatSystemPrompt,
                                     executor: WebSearchBackend.make())
            return
        }

        // ★ Corpus mode (corpusAware == true). Build the numbered candidate list
        // (Brief S: S2 query augmentation + carry, S3 pinning, S5 log), then send.
        let (candidates, empty) = await corpusCandidates(query: query, store: store, chat: chat)

        if empty {
            // Brief AB3 — nothing in THIS ROOM matched (no candidates, or a survey
            // with < 3 cards and no passages, no pin). Do NOT dress up general
            // knowledge as an answer from the notes: send the bare question under the
            // honest empty-library prompt, with NO candidates → no [n] instruction, no
            // chips. `ChatSession.send` strips any hallucinated [n] (empty valid set).
            await chat.send(displayText: query, modelText: query,
                            systemPrompt: emptyLibrarySystemPrompt, citations: nil)
            return
        }

        let context = buildAskContext(candidates: candidates, store: store)
        let modelText = """
        Some of your notes were retrieved by similarity search — they may or may not be relevant to the question:

        \(context)

        Question: \(query)
        """
        // Candidate sources for THIS turn; `ChatSession.send` filters these down to
        // the [n] the model actually cited before committing the message.
        let chips = Self.citationChips(from: candidates, store: store)
        await chat.send(displayText: query, modelText: modelText, systemPrompt: askSystemPrompt, citations: chips)
    }

    /// Brief S — assemble the numbered candidate list for a corpus-Ask turn. S2:
    /// the retrieval query folds in the previous USER turn, and the prior turn's
    /// candidates carry forward with stable numbers. S3: a named entry's passages
    /// pin to the front (non-pinned passages must then clear 0.70). S5: log it.
    /// Mutates the carry state; the caller builds the prompt + chips and sends.
    private func corpusCandidates(query: String, store: CorpusStore, chat: ChatSession) async -> (candidates: [NumberedCandidate], empty: Bool) {
        // S2 — retrieval query = current question + the previous USER turn in this
        // chat (first turn: bare question), so a follow-up keeps its subject.
        let previousUserTurn = chat.messages.last { $0.role == .user }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let retrievalQuery: String = {
            if let prev = previousUserTurn, !prev.isEmpty { return "\(query)\n\(prev)" }
            return query
        }()

        // AA1 — embed the retrieval query ONCE; the passage scan and the card scan
        // share it (empty on embed failure → both re-embed and also fail → no
        // candidates → bare question, same as before).
        let qvec = await CardEmbeddingService.shared.embed(retrievalQuery) ?? []

        // S3 — nodes to pin (quoted title / title verbatim in the question). Detect
        // against the CURRENT question, not the augmented query.
        let pinnedIDs = Set(Self.pinnedNodeIDs(question: query, store: store))
        let pinning = !pinnedIDs.isEmpty

        // Passages (DEPTH). Diversified ≤3/node inside askMatches. When pinning, a
        // named entry shouldn't drag in loosely-related notes, so non-pinned
        // passages must clear a HIGHER bar (0.70); otherwise the usual budget bar.
        let general = await store.askMatches(query: retrievalQuery, scope: selectedScope, topK: 12, queryVector: qvec)
        let bar: Float = pinning ? 0.70 : CorpusStore.minRelevanceScore
        let generalFiltered = general.filter { !pinnedIDs.contains($0.nodeID) && $0.score >= bar }

        // AA1 — cards (BREADTH) over the same room. ★ A PIN SUPPRESSES CARDS entirely
        // (T, 2026-09-21, AA accepted): a named-entry question is an explicit single-
        // entry focus, so the answer stays on that entry + its passages, not a
        // tangential survey. No pin → the whole room's cards (pinnedIDs is empty here,
        // so no filter needed).
        let cards: [CardMatch] = pinning
            ? []
            : await store.cardMatches(query: retrievalQuery, scope: selectedScope, queryVector: qvec)

        // AA2 — shape from the passage list (pinning forces lookup). Sets the split.
        let verdict = Self.retrievalShape(passages: general, pinning: pinning, store: store)
        let newPassages = Array(generalFiltered.prefix(verdict.shape.passageBudget))
        let newCards = Array(cards.prefix(verdict.shape.cardBudget))

        // Pinned passages — ALL blocks of the pinned nodes, regardless of score.
        let pinnedMatches = pinning
            ? await store.blocksForNodes(query: retrievalQuery, nodeIDs: Array(pinnedIDs), topK: 12, queryVector: qvec)
            : []

        // Assemble carry + pin + new (passages + cards) into one numbered list
        // (stable [n] across turns; S2 carry unions both kinds). ★ On a pin turn the
        // carried CARDS are dropped too, so a pin after a survey turn still shows zero
        // cards (the suppression is about the turn, not just its fresh retrieval).
        let carriedAll = (carriedChatID == chat.id) ? carriedCandidates : []
        let carried = pinning ? carriedAll.filter { !$0.isCard } : carriedAll
        let candidates = Self.assembleCandidates(
            carried: carried, pinned: pinnedMatches,
            newPassages: newPassages, newCards: newCards, budget: Self.askPassageCharBudget)

        // Persist for the next turn's carry (keyed to this chat).
        carriedCandidates = candidates
        carriedChatID = chat.id

        // Brief AB3 — "empty" = nothing in this room meaningfully matched: no
        // candidates at all, OR a SURVEY that surfaced < 3 cards and no passages (and
        // no pin). The caller sends the honest empty-library prompt instead of
        // dressing up a thin/absent match as an answer.
        let passageCount = candidates.filter { !$0.isCard }.count
        let cardCount = candidates.count - passageCount
        let pinned = candidates.contains { $0.origin == .pinned }
        let empty = candidates.isEmpty
            || (!pinned && passageCount == 0 && cardCount < 3 && verdict.shape == .survey)

        // S5 — candidate log (turn index = user turns so far + this one).
        let turnIndex = chat.messages.filter { $0.role == .user }.count + 1
        Self.logCandidates(turnIndex: turnIndex, query: retrievalQuery, candidates: candidates, shape: verdict, scope: selectedScope, empty: empty, store: store)
        return (candidates, empty)
    }

    #if DEBUG
    /// Brief S verify — headless retrieval probe. Runs the corpus retrieval +
    /// candidate assembly + S5 log for `query` WITHOUT invoking the model, then
    /// simulates the turn's commit (a user bubble) so a follow-up call exercises
    /// the S2 carry. Used by `-LibrarianRetrievalDiag`.
    func debugCorpusRetrieve(query: String, store: CorpusStore, chat: ChatSession) async {
        corpusAware = true
        _ = await corpusCandidates(query: query, store: store, chat: chat)
        chat.debugAppendUser(query)
    }

    /// Brief AC5 — the numbered candidate list (number → nodeID) for a single-turn
    /// query at `scope`, so `-PinResolveDiag` can map a transcript's `[n]` citations
    /// to the sample node the answer cited. No model, no carry (fresh chat).
    func debugNumberedCandidates(query: String, scope: CanvasScope, store: CorpusStore) async -> [(number: Int, nodeID: String)] {
        corpusAware = true
        selectedScope = scope
        let (candidates, _) = await corpusCandidates(query: query, store: store, chat: ChatSession())
        return candidates.map { ($0.number, $0.nodeID) }
    }

    /// Brief AH2 verify — the carry-forward gate is keyed to the chat id, so the
    /// candidate list a NEW chat sees on its first turn is empty (a room change starts
    /// a new chat → candidates never cross rooms). Seed a carry for one chat id, then
    /// read it back for the same id (carries) and a different id (empty). No retrieval.
    func debugSeedCarry(count: Int, chatID: UUID) {
        carriedCandidates = (0..<count).map {
            NumberedCandidate(number: $0 + 1,
                              payload: .card(CardMatch(nodeID: "seed-\($0)", gist: "g", score: 0.9)),
                              origin: .carried)
        }
        carriedChatID = chatID
    }
    func debugCarriedCount(forChatID id: UUID) -> Int {
        (carriedChatID == id ? carriedCandidates : []).count
    }
    #endif

    // MARK: - Brief W1 — passage provenance (note vs collected source)

    /// The candidate's provenance kind + domain. A passage resolves from its block's
    /// item (W1); a card resolves at the whole-node granularity (AA3 `cardProvenance`).
    private static func provenance(for c: NumberedCandidate, store: CorpusStore) -> (kind: Node.BlockProvenance, domain: String?) {
        guard let node = store.nodes.first(where: { $0.id == c.nodeID }) else { return (.note, nil) }
        switch c.payload {
        case .passage(let m): return node.blockProvenance(forItemID: m.block.itemID)
        case .card:           return node.cardProvenance()
        }
    }

    /// Prompt-header label — the user's own words are "your note"; collected sources
    /// are named so the model won't attribute them to the user.
    private static func provenanceLabel(_ kind: Node.BlockProvenance) -> String {
        switch kind {
        case .note:      return "your entry"
        case .savedLink: return "saved article"
        case .document:  return "document"
        case .imageText: return "image text"
        }
    }

    /// Chip secondary-line prefix — lowercase, no icon (the source list shows it too).
    private static func provenanceChipPrefix(_ kind: Node.BlockProvenance) -> String {
        switch kind {
        case .note:      return "entry"
        case .savedLink: return "saved article"
        case .document:  return "document"
        case .imageText: return "image text"
        }
    }

    /// Per-passage citations, `index` = the candidate's assigned `[n]` (S2 — stable
    /// across turns, NOT positional). W1: only COLLECTED passages (saved article /
    /// document / image text) get a provenance-labelled snippet prefix (T, 2026-09-20
    /// — a plain note carries no label; the unlabelled chip IS the user's own).
    /// Stored PER-BLOCK (not node-deduped) so an inline `[n]` tap can resolve its
    /// exact node — the footer dedups by node for display (Piece 2).
    private static func citationChips(from candidates: [NumberedCandidate], store: CorpusStore) -> [ChatSession.Message.Citation] {
        candidates.map { c in
            let title = store.nodes.first { $0.id == c.nodeID }?.title ?? "Untitled"
            let kind = provenance(for: c, store: store).kind
            // AA4 — a card chip carries its gist as the secondary line; a passage
            // chip carries a 140-char snippet of the block. Both get the W1
            // provenance prefix only for COLLECTED sources (a plain note is unlabelled).
            let body: String
            switch c.payload {
            case .passage(let m): body = String(m.block.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
            case .card(let card): body = card.gist
            }
            let snippet = (kind == .note) ? body : "\(provenanceChipPrefix(kind)) · \(body)"
            return .init(index: c.number, nodeID: c.nodeID, title: title, snippet: snippet)
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
            return "Your library"
        case .collection(let id):
            if id == NodeCollection.journalID { return "Journal" }
            return store.collections.first { $0.id == id }?.name ?? "Collection"
        case .nodeIDs:
            return "Sample Library"
        }
    }

    /// Brief AA2 — classify this turn by result SHAPE (never by the question). A
    /// CONCENTRATED result — a strong top passage (≥ 0.70) backed by a second
    /// passage from the SAME node among the top 4 — reads as a LOOKUP; a pin forces
    /// it. Everything else is a SURVEY. Computed on the diversified passage list
    /// (`askMatches` already caps ≤ 3/node, so a genuine concentration still shows
    /// as a dup ≥ 2 in the top 4).
    ///
    /// ★ Fixture-adjusted (2026-09-21, from the brief's "first guess"): the dominant
    /// node must be the user's OWN note. A long SAVED ARTICLE naturally puts several
    /// of its own passages in the top 4 (Schema (psychology) contributes 3 of the
    /// top 4 for "What are my thoughts on technology?" — top 0.73, dup 3), but that
    /// internal density is a document artefact, not a lookup. Gating on own-note
    /// provenance keeps "technology" a SURVEY (dominant = a saved article) while a
    /// real lookup — "How much did I spend on my Bolex camera?" — stays a LOOKUP
    /// (dominant = the user's "Bolex" note, 3 top passages).
    static func retrievalShape(passages: [BlockMatch], pinning: Bool, store: CorpusStore) -> ShapeVerdict {
        let top = passages.first?.score ?? 0
        var counts: [String: Int] = [:]
        for m in passages.prefix(4) { counts[m.nodeID, default: 0] += 1 }
        let dominant = counts.max { $0.value < $1.value }
        let dup = dominant?.value ?? 0
        let dupOwnNote: Bool = {
            guard dup >= 2, let id = dominant?.key,
                  let node = store.nodes.first(where: { $0.id == id }) else { return false }
            return node.cardProvenance().kind == .note
        }()
        let concentrated = pinning || (top >= 0.70 && dupOwnNote)
        return ShapeVerdict(shape: concentrated ? .lookup : .survey, topPassage: top, topNodeDup: dup, dupOwnNote: dupOwnNote)
    }

    /// Brief S2/S3/AA — assemble the numbered candidate list for a corpus-Ask turn.
    /// Order is PINNED passages (front, S3), then CARRIED-not-pinned (S2, numbers
    /// preserved), then NEW passages, then NEW cards. A source's number is assigned
    /// on its FIRST appearance and reused forever after — so `[n]` is stable turn to
    /// turn across BOTH kinds (AA continuous numbering). De-dupes by `identity`
    /// (blockID for passages, `card:<nodeID>` for cards). Budget is enforced by
    /// `trimByBudget` (oldest carried dropped first).
    private static func assembleCandidates(
        carried: [NumberedCandidate],
        pinned: [BlockMatch],
        newPassages: [BlockMatch],
        newCards: [CardMatch],
        budget: Int
    ) -> [NumberedCandidate] {
        var byID: [String: NumberedCandidate] = [:]
        for c in carried { byID[c.identity] = c }
        var maxNumber = carried.map(\.number).max() ?? 0

        func passageID(_ m: BlockMatch) -> String { m.block.blockID }
        func cardID(_ c: CardMatch) -> String { "card:\(c.nodeID)" }

        // Assign (or reuse) a number for a passage. A carried block keeps its number;
        // if it's now pinned its origin flips to `.pinned` (front placement).
        func assignPassage(_ match: BlockMatch, origin: NumberedCandidate.Origin) -> NumberedCandidate {
            let id = passageID(match)
            if var existing = byID[id] {
                if origin == .pinned { existing.origin = .pinned }
                byID[id] = existing
                return existing
            }
            maxNumber += 1
            let c = NumberedCandidate(number: maxNumber, payload: .passage(match), origin: origin)
            byID[id] = c
            return c
        }
        func assignCard(_ card: CardMatch) -> NumberedCandidate {
            let id = cardID(card)
            if let existing = byID[id] { return existing }
            maxNumber += 1
            let c = NumberedCandidate(number: maxNumber, payload: .card(card), origin: .new)
            byID[id] = c
            return c
        }

        // 1. Pinned first — number them before anything else so a first-turn pin is 1…k.
        var pinnedList: [NumberedCandidate] = []
        for m in pinned { pinnedList.append(assignPassage(m, origin: .pinned)) }
        let pinnedIDs = Set(pinnedList.map { $0.identity })

        // 2. Carried that aren't now pinned — keep order + number.
        var carriedList: [NumberedCandidate] = []
        for c in carried where !pinnedIDs.contains(c.identity) {
            var e = c; e.origin = .carried
            carriedList.append(e)
        }

        // 3. New passages, then 4. new cards — each only if not already present.
        var newList: [NumberedCandidate] = []
        for m in newPassages where byID[passageID(m)] == nil {
            newList.append(assignPassage(m, origin: .new))
        }
        for card in newCards where byID[cardID(card)] == nil {
            newList.append(assignCard(card))
        }

        // Brief Z R4 — enforce ≤3 PASSAGES per node AFTER the union (a card is one
        // per node and is exempt), in list order so the front keeps its best blocks.
        let capped = capPerNode(pinnedList + carriedList + newList, perNode: CorpusStore.maxBlocksPerNode)
        return trimByBudget(capped, budget: budget)
    }

    /// Brief Z R4 — keep at most `perNode` PASSAGES from any one node, in list order
    /// (front wins). Cards are one-per-node and exempt (they carry the node-level
    /// gist, not a competing chunk). Applied after the carried/pinned/new union.
    private static func capPerNode(_ list: [NumberedCandidate], perNode: Int) -> [NumberedCandidate] {
        var count: [String: Int] = [:]
        var out: [NumberedCandidate] = []
        for c in list {
            if c.isCard { out.append(c); continue }
            let k = count[c.nodeID, default: 0]
            guard k < perNode else { continue }
            count[c.nodeID] = k + 1
            out.append(c)
        }
        return out
    }

    /// Enforce the passage char budget. Drops the OLDEST carried passage first (the
    /// carried entry with the smallest number, S2), and only if that's exhausted
    /// trims from the tail — always keeping at least one passage (never send a
    /// citation-free prompt that silently drops the corpus). Pinned/new survive the
    /// carried sweep so a named entry and the freshest hits are protected.
    private static func trimByBudget(_ list: [NumberedCandidate], budget: Int) -> [NumberedCandidate] {
        // A passage costs its block text; a card costs its gist (+ overhead for the
        // numbered label, title, and separators `buildAskContext` adds).
        func cost(_ c: NumberedCandidate) -> Int {
            switch c.payload {
            case .passage(let m): return m.block.text.count + 50
            case .card(let card): return card.gist.count + 60
            }
        }
        var result = list
        var total = result.reduce(0) { $0 + cost($1) }
        while total > budget,
              let idx = result.enumerated()
                  .filter({ $0.element.origin == .carried })
                  .min(by: { $0.element.number < $1.element.number })?.offset {
            total -= cost(result[idx])
            result.remove(at: idx)
        }
        while total > budget, result.count > 1 {
            total -= cost(result[result.count - 1])
            result.removeLast()
        }
        return result
    }

    /// Brief S3 — nodes to PIN for `question`: (1) a node title exactly equal to a
    /// quoted phrase (case-insensitive), else (2) a node title appearing verbatim
    /// in the question (the unquoted "my entry called X" case; short titles guarded
    /// to avoid over-pinning), else (3) a node title beginning with a quoted phrase.
    /// Empty for the common no-named-entry question. Order follows `store.nodes`.
    private static func pinnedNodeIDs(question: String, store: CorpusStore) -> [String] {
        let q = question.lowercased()
        let quoted = extractQuotedPhrases(question)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let all: [(id: String, t: String)] = store.nodes.compactMap { n in
            let t = n.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.isEmpty ? nil : (n.id, t)
        }
        if !quoted.isEmpty {
            let exact = all.filter { quoted.contains($0.t) }.map(\.id)
            if !exact.isEmpty { return exact }
        }
        let contained = all.filter { $0.t.count >= 4 && q.contains($0.t) }.map(\.id)
        if !contained.isEmpty { return contained }
        if !quoted.isEmpty {
            let prefixed = all.filter { n in quoted.contains { n.t.hasPrefix($0) } }.map(\.id)
            if !prefixed.isEmpty { return prefixed }
        }
        return []
    }

    /// Substrings between matching quote marks — straight or curly, single or
    /// double. A curly closer (’ ” — the smart apostrophe) is never treated as an
    /// opener, so apostrophes in prose don't create spurious phrases.
    private static func extractQuotedPhrases(_ s: String) -> [String] {
        let closers: [Character: Character] = ["\"": "\"", "'": "'", "\u{201C}": "\u{201D}", "\u{2018}": "\u{2019}"]
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            if let closer = closers[s[i]] {
                let contentStart = s.index(after: i)
                if contentStart < s.endIndex, let closeIdx = s[contentStart...].firstIndex(of: closer) {
                    let phrase = String(s[contentStart..<closeIdx])
                    if !phrase.isEmpty { out.append(phrase) }
                    i = s.index(after: closeIdx)
                    continue
                }
            }
            i = s.index(after: i)
        }
        return out
    }

    /// AB1 — the resolved room label for the S5 log: the scope case AND which room
    /// it actually searched (a `.corpus` scope silently resolves to the USER room
    /// once a sample is seeded, which is exactly the Brief AB miss). `[…]` marks a
    /// sample-owned scope so a room-crossing search is visible at a glance.
    static func scopeLabel(_ scope: CanvasScope, store: CorpusStore) -> String {
        switch scope {
        case .corpus:
            let room = (store.sampleLibraryPresent && !store.userNodes.isEmpty) ? "user" : "sample"
            return "corpus→\(room):\(store.corpusRoomNodes.count)"
        case .collection(let id):
            let kind = store.sampleCollectionIDs.contains(id) ? "sample" : "user"
            return "collection:\(id)[\(kind)]"
        case .nodeIDs(let ids):
            let kind = (ids == store.sampleNodeIDs) ? "sample" : "adhoc"
            return "nodeIDs:\(ids.count)[\(kind)]"
        }
    }

    /// S5 — one os_log record per corpus-mode turn: scope + shape, the query sent to
    /// the embedder, then each candidate as "n · nodeTitle · score · origin".
    private static func logCandidates(turnIndex: Int, query: String, candidates: [NumberedCandidate], shape: ShapeVerdict, scope: CanvasScope, empty: Bool, store: CorpusStore) {
        var lines: [String] = []
        let distinct = Set(candidates.map { $0.nodeID }).count
        let cardCount = candidates.filter { $0.isCard }.count
        let passageCount = candidates.count - cardCount
        // AA4 + AB1/AB3 — scope (resolved room) + shape verdict + empty flag + split.
        lines.append("turn \(turnIndex) · scope=\(scopeLabel(scope, store: store)) · shape=\(shape.shape.rawValue) top=\(String(format: "%.2f", shape.topPassage)) dup=\(shape.topNodeDup) own=\(shape.dupOwnNote) · empty=\(empty) · query=\"\(query.replacingOccurrences(of: "\n", with: " ⏎ "))\" · \(candidates.count) candidate(s) (\(passageCount)p/\(cardCount)c) · \(distinct) node(s)")
        var perNode: [String: Int] = [:]   // Brief Z R4 — the k/3 running count per node (passages only)
        for c in candidates {
            let score = String(format: "%.3f", c.score)
            // AA4 — card|passage column.
            switch c.payload {
            case .passage:
                let k = (perNode[c.nodeID, default: 0]) + 1
                perNode[c.nodeID] = k
                lines.append("  [passage] \(passageHeader(for: c, store: store)) · \(score) · \(c.origin.rawValue) · \(k)/\(CorpusStore.maxBlocksPerNode)")
            case .card:
                lines.append("  [card]    \(cardLogLine(for: c, store: store)) · \(score) · \(c.origin.rawValue)")
            }
        }
        let record = lines.joined(separator: "\n")
        candidateLog.log("\(record, privacy: .public)")
        // AC2 — retain for "Copy Librarian log" (cap at the last N turns).
        recentCandidateLog.append(record)
        if recentCandidateLog.count > recentCandidateLogCap {
            recentCandidateLog.removeFirst(recentCandidateLog.count - recentCandidateLogCap)
        }
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
        let base = "You are a reflective AI that helps someone think across their OWN entries. Two labelled sections may appear below the question: ENTRIES ON THIS TOPIC lists the user's entries related to the topic (one line each), and PASSAGES are excerpts. They were pulled by similarity search and MAY OR MAY NOT be relevant. For broad questions about what the user thinks or has, synthesise across ENTRIES and cite them; for specific facts, answer from PASSAGES. Treat anything that genuinely helps as authoritative about the user's own world — if a passage defines a term, use THEIR definition over a generic one — and cite it inline with bracket numbers like [1] [2] matching the numbered entries and passages. Ignore items that don't help and answer normally from your own knowledge. Never say the entries don't contain the answer and never refuse for lack of a matching passage — just answer the question directly. Be specific, concise, and never generic. Cite only items you actually used. Do not connect entries the question did not ask about. If an entry distinguishes an estimate from an actual figure, say which. Entries or passages marked saved article, document, or image text are things the user collected, not their own words. For questions about the user's own views, answer from their entries and refer to collected sources as such. Do not append a References, Sources, or Citations section — AirPad renders citations separately. End your reply at the end of the prose answer."
        return personalVoicePrefix + base
    }

    /// Brief AB3 — empty-library prompt: corpus mode found NOTHING in this room
    /// (no candidates, or a survey with < 3 cards and no passages). Say so plainly
    /// instead of answering from general knowledge and hallucinating citations. No
    /// `[n]` instruction — there is nothing to cite. Keeps the personal-voice tone.
    private var emptyLibrarySystemPrompt: String {
        let base = "You are a reflective AI that helps someone think across their OWN entries. No entries in this library match the question. Say so plainly in one sentence. Do not cite anything and do not answer from general knowledge unless the user asks you to."
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
        You are a helpful, direct, concise assistant. You can search the web with the web_search tool \
        when the user asks for current information or explicitly asks you to search (and fetch_url reads \
        a page you found). Today's real date is \(today). When a question needs current, local, or \
        factual information, call the tools.

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

    /// Brief AF3 — a deliberately SIMPLE search-intent match (not an NLP classifier):
    /// does this message read as a request to search the live web? Used ONLY in the
    /// no-Brave-key state to decide between the app's one-line "add a key" reply and a
    /// silent plain-chat turn. False positives are cheap (the user is told how to enable
    /// search); the phrases are the brief's five, matched case-insensitively as whole
    /// substrings. `static` + `internal` so the AF3 unit test can exercise it directly.
    static func looksLikeSearchIntent(_ query: String) -> Bool {
        let q = query.lowercased()
        let cues = ["search", "look up", "latest", "today's news", "current"]
        return cues.contains { q.contains($0) }
    }

    /// ★ Corpus-grounding toggle (default FALSE = private chat). Stored so the
    /// surface pill re-renders on flip (observation-tracked), and persisted via
    /// `didSet` so it survives surface remounts and app restarts — a standing
    /// preference, like personal voice. `groundedSend` reads it live at send time.
    var corpusAware: Bool = UserDefaults.standard.bool(forKey: "librarianCorpusAware") {
        didSet { UserDefaults.standard.set(corpusAware, forKey: "librarianCorpusAware") }
    }
    /// Phase 2 — per-session Thinking toggle, OFF by default. Ephemeral to the Librarian session
    /// (no persistent thread to store it on); the pill/sheet write it; `groundedSend` forwards it
    /// to the ChatSession, which sends `think` to the Host (the only path that honors it).
    var thinkEnabled: Bool = false

    /// Read-only indicator of the model that will answer the next Ask (the FM
    /// friendly name, or a remote endpoint's model id). STORED + observable so the
    /// surface updates when an async probe lands; refreshed via `refreshActiveModel()`
    /// — deliberately NOT read per render, because resolving the provider hits the
    /// Keychain (XPC) and a remote endpoint hits the network, neither of which
    /// belongs in `body`. Defaults to the FM name.
    private(set) var activeModelLabel: String = ModelRouter.foundationModelName

    /// STATE 2 for the Ask field — no free-text provider exists (no ollama endpoint AND FM
    /// unavailable; the local model is NOT wired to Ask). Cached from `ModelRouter.askHasNoProvider`
    /// in `refreshActiveModel` (OFF the render path — it does a Keychain/XPC read via `active`) so
    /// the input gate can read it from `body` without a per-frame XPC hit. When true, Ask is gated
    /// behind a connected model rather than sending into a guaranteed `foundationModelUnavailable`.
    private(set) var askUnavailable: Bool = false

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
            askUnavailable = false   // a mocked label implies a model is present
            return
        }
        // `-AskNoProvider YES` — force STATE 2 so the gate/notice can be exercised in the
        // Simulator (which can't reach it via FM availability alone). No-op without the arg.
        if UserDefaults.standard.bool(forKey: "AskNoProvider") {
            activeModelLabel = "No model"
            askUnavailable = true
            return
        }
        #endif
        activeModelLabel = await ModelRouter.resolveActiveModelName()
        askUnavailable = ModelRouter.askHasNoProvider
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

    /// Brief AA3 — the ask context in TWO labelled sections with continuous
    /// numbering: `NOTES ON THIS TOPIC` (cards — one line each, breadth) then
    /// `PASSAGES` (block excerpts — depth). Either section is omitted when empty.
    private func buildAskContext(
        candidates: [NumberedCandidate],
        store: CorpusStore
    ) -> String {
        guard !candidates.isEmpty else { return "" }
        let cards = candidates.filter { $0.isCard }
        let passages = candidates.filter { !$0.isCard }
        var sections: [String] = []
        if !cards.isEmpty {
            let lines = cards.map { Self.cardContextLine(for: $0, store: store) }.joined(separator: "\n")
            sections.append("ENTRIES ON THIS TOPIC:\n\(lines)")
        }
        if !passages.isEmpty {
            let blocks = passages.compactMap { c -> String? in
                guard case .passage(let m) = c.payload else { return nil }
                return "\(Self.passageHeader(for: c, store: store))\n\(m.block.text)"
            }.joined(separator: "\n\n---\n\n")
            sections.append("PASSAGES:\n\(blocks)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Brief W1 — the passage's prompt header, provenance-labelled:
    /// `[n] your note — Title` / `[n] saved article — Title (domain)` /
    /// `[n] document — Title` / `[n] image text — Title`.
    private static func passageHeader(for c: NumberedCandidate, store: CorpusStore) -> String {
        let title = store.nodes.first { $0.id == c.nodeID }?.title ?? "Untitled"
        let (kind, domain) = provenance(for: c, store: store)
        let suffix = (kind == .savedLink) ? (domain.map { " (\($0))" } ?? "") : ""
        return "[\(c.number)] \(provenanceLabel(kind)) — \(title)\(suffix)"
    }

    /// Brief AA3 — a card's NOTES-section line: `[n] <title> — <gist>`, with the W1
    /// provenance label folded in only for a COLLECTED node so the model doesn't
    /// read a saved article's gist as the user's own words.
    private static func cardContextLine(for c: NumberedCandidate, store: CorpusStore) -> String {
        guard case .card(let card) = c.payload else { return "" }
        let title = store.nodes.first { $0.id == card.nodeID }?.title ?? "Untitled"
        let (kind, domain) = provenance(for: c, store: store)
        let prov: String
        switch kind {
        case .note:      prov = ""
        case .savedLink: prov = " (saved article\(domain.map { ", \($0)" } ?? ""))"
        case .document:  prov = " (document)"
        case .imageText: prov = " (image text)"
        }
        return "[\(c.number)] \(title)\(prov) — \(card.gist)"
    }

    /// AA4 — compact card line for the S5 log (title only, gist omitted to keep the
    /// per-turn record short with up to 30 cards).
    private static func cardLogLine(for c: NumberedCandidate, store: CorpusStore) -> String {
        guard case .card(let card) = c.payload else { return "" }
        let title = store.nodes.first { $0.id == card.nodeID }?.title ?? "Untitled"
        let (kind, _) = provenance(for: c, store: store)
        let label = (kind == .note) ? "" : "\(provenanceLabel(kind)) — "
        return "[\(c.number)] \(label)\(title)"
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
        "You are a precise summarizer. Given a conversation between a user and an AI assistant that helps them think across their entries, produce a single dense paragraph capturing the substantive content: what was asked, what was found or concluded, and any threads still open. Specific, not generic. Output only the paragraph — no preface, no header, no trailing meta."
    }

}
