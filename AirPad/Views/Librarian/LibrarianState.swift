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
    /// Brief BN3 — a whole entry READ IN FULL (the "find, then read" surface). `text` is the
    /// entire entry (every block joined in order — exactly the D_whole packet Brief BJ proved
    /// answers the lab question completely), OR — when the entry alone exceeds the model-derived
    /// budget — that entry's best passages, with `partial == true` so the prompt tells the model
    /// the read is partial. One per node; because the read unit is whole blocks, a partial read
    /// never truncates mid-row (the exact failure BJ traced to the ≤3/node fragment path).
    struct EntryRead: Sendable {
        let nodeID: String
        let title: String
        let text: String
        /// The entry's aggregate rank score (sum of its passage scores) — for ordering + the trace.
        let score: Float
        /// True → the whole entry didn't fit the budget; `text` is its best passages, prompt says so.
        let partial: Bool
    }

    struct NumberedCandidate: Sendable {
        enum Origin: String, Sendable { case carried, new, pinned }
        enum Payload: Sendable {
            case passage(BlockMatch)
            case card(CardMatch)
            /// Brief BN3 — a whole entry read in full (or its best passages, when `partial`).
            case entry(EntryRead)
        }
        let number: Int
        var payload: Payload
        var origin: Origin

        var nodeID: String {
            switch payload {
            case .passage(let m): return m.nodeID
            case .card(let c):    return c.nodeID
            case .entry(let e):   return e.nodeID
            }
        }
        var score: Float {
            switch payload {
            case .passage(let m): return m.score
            case .card(let c):    return c.score
            case .entry(let e):   return e.score
            }
        }
        var isCard: Bool { if case .card = payload { return true } else { return false } }
        /// Brief BN3 — a whole-entry read-in-full candidate (the READ mode's surface).
        var isEntryRead: Bool { if case .entry = payload { return true } else { return false } }
        /// Brief BN3 — the read entry didn't fully fit → `text` is its best passages, prompt marked partial.
        var isPartialRead: Bool { if case .entry(let e) = payload { return e.partial } else { return false } }
        /// Brief BN1 — the item's own text length (a passage's block text, a card's gist, a full
        /// entry's whole text), for the `-LibrarianTrace` packet dump.
        var charCount: Int {
            switch payload {
            case .passage(let m): return m.block.text.count
            case .card(let c):    return c.gist.count
            case .entry(let e):   return e.text.count
            }
        }

        /// Stable de-dup / carry identity: a passage's blockID, a card's node id
        /// (`card:`-prefixed), a full-entry read's node id (`full:`-prefixed) — so a card, a
        /// passage, and a full read of the same node never collide, and a follow-up that re-reads
        /// the same entry keeps its `[n]`.
        var identity: String {
            switch payload {
            case .passage(let m): return m.block.blockID
            case .card(let c):    return "card:\(c.nodeID)"
            case .entry(let e):   return "full:\(e.nodeID)"
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
        pendingWebSearchOffer = nil      // Brief AI5 — any fresh send clears a stale web-search offer
        pendingReadInFullOffer = nil     // Brief BS3 — a fresh send clears a stale "Read … in full?" offer

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
                Self.logGeneralTurn(query: query, scope: selectedScope, tool: "none", retry: false, store: store)
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
                Self.logGeneralTurn(query: query, scope: selectedScope, tool: "none", retry: false, store: store)
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
            //
            // Brief AI4 — the APP decides when to search. A current-information question
            // (`looksLikeSearchIntent`) REQUIRES the web tool for THIS turn; every other
            // question leaves it merely declared (the model's judgment, as before).
            // `tool_choice` is verified INERT on this stack (curl'd on this Mac: Ollama
            // 0.13.2 ignores it on BOTH `/api/chat` and `/v1/chat/completions`, and the
            // Host decode-struct drops the field before it reaches Ollama), so "require"
            // is a NUDGE appended to the model turn — `sendWithTools(forceWebSearch:)`.
            // That call also runs the refusal guard (a no-tool "I can't access the web"
            // answer on an intent turn → ONE web retry), returning whether it fired.
            let forceWeb = Self.looksLikeSearchIntent(query)
            let didRetry = await chat.sendWithTools(displayText: query,
                                                    systemPrompt: toolChatSystemPrompt,
                                                    executor: WebSearchBackend.make(),
                                                    forceWebSearch: forceWeb)
            Self.logGeneralTurn(query: query, scope: selectedScope,
                                tool: forceWeb ? "required" : "declared", retry: didRetry, store: store)
            return
        }

        // ★ Corpus mode (corpusAware == true). Route the turn (Brief BN2 read-vs-survey), build the
        // numbered candidate list (BN3 read-in-full within a model-derived budget; S2 carry, S3 pin,
        // BN4 working set), then send with the read/skim receipt (BN5).
        let (candidates, empty, receipt) = await corpusCandidates(query: query, store: store, chat: chat)

        if empty {
            // Brief AB3 — nothing in THIS ROOM matched (no candidates, or a survey
            // with < 3 cards and no passages, no pin). Do NOT dress up general
            // knowledge as an answer from the notes: send the bare question under the
            // honest empty-library prompt, with NO candidates → no [n] instruction, no
            // chips. `ChatSession.send` strips any hallucinated [n] (empty valid set).
            // Brief BR3 — EVERY Library turn reports what it read: an empty turn still carries a
            // receipt (0/0) so the footer says "No matching entries" instead of rendering nothing
            // (which read like a plain chat — T's turn-1 symptom: no footer, no chips).
            await chat.send(displayText: query, modelText: query,
                            systemPrompt: emptyLibrarySystemPrompt, citations: nil,
                            readReceipt: ChatSession.Message.ReadReceipt(readInFull: 0, skimmed: 0, partial: false))
            // Brief AI5 — Library mode never searches, but when the empty room meets a
            // current-information question the app OFFERS the web under the answer. Set
            // after the answer commits; the surface renders the offer bar, and tapping it
            // flips to General + re-sends (AI4). App UI only — never model text/citation.
            if Self.looksLikeSearchIntent(query) { pendingWebSearchOffer = query }
            return
        }

        let context = buildAskContext(candidates: candidates, store: store)
        #if DEBUG
        // Brief BN1 — `-LibrarianTrace`: dump the exact Ask packet per Library turn (Release-inert).
        // The instrument BJ's diagnosis recommended and every find-then-read check (BN2–BN5) reads.
        // Now reports the BN2 routing: `mode=read`/`survey`, how many entries were READ IN FULL vs
        // skimmed (BN5 receipt), the BN3 model-DERIVED char budget (was the fixed 12k), and marks
        // which candidates are full reads. Never blocks or mutates.
        if ProcessInfo.processInfo.arguments.contains("-LibrarianTrace") {
            let totalChars = context.count
            let budget = askContextCharBudget()
            let mode = (receipt?.readInFull ?? 0) > 0 ? "read" : "survey"
            NSLog("[LibrarianTrace] mode=%@ provider=%@ window~tokens=%d budgetChars=%d candidates=%d contextChars=%d ~tokens=%d readInFull=%d skimmed=%d partial=%@ overBudget=%@",
                  mode, "\(ModelRouter.active)", ModelRouter.contextWindowTokens, budget, candidates.count,
                  totalChars, totalChars / 4, receipt?.readInFull ?? 0, receipt?.skimmed ?? 0,
                  (receipt?.partial ?? false) ? "yes" : "no", totalChars > budget ? "yes" : "no")
            for c in candidates.sorted(by: { $0.number < $1.number }) {
                let kind = c.isEntryRead ? (c.isPartialRead ? "READ(partial)" : "READ-IN-FULL") : (c.isCard ? "CARD" : "passage")
                NSLog("[LibrarianTrace]   [%d] node=%@ score=%.3f chars=%d %@ origin=%@",
                      c.number, c.nodeID, c.score, c.charCount, kind, c.origin.rawValue)
            }
        }
        #endif
        let modelText = """
        Some of your notes were retrieved for you — they may or may not be relevant to the question:

        \(context)

        Question: \(query)
        """
        // Candidate sources for THIS turn; `ChatSession.send` filters these down to
        // the [n] the model actually cited before committing the message. The read/skim
        // receipt (BN5) rides alongside so the footer can show what was read.
        let chips = Self.citationChips(from: candidates, store: store)
        // Brief BS2 — an entry READ IN FULL is ALWAYS a source chip, even if the model wrote no [n]
        // for it (provenance is the product). `ChatSession.send` keeps these indices regardless of
        // inline citation; skimmed passages/cards still only chip when the prose cites them.
        let alwaysCite = Set(candidates.filter { $0.isEntryRead }.map { $0.number })
        await chat.send(displayText: query, modelText: modelText, systemPrompt: askSystemPrompt,
                        citations: chips, alwaysCiteIndices: alwaysCite, readReceipt: receipt)
    }

    /// Brief AI5 — the user tapped "Search the web instead" under an empty Library
    /// answer. Clear the offer, flip to General (the AH4 chip morph animates on the
    /// surface off the `corpusAware` change), and re-send the SAME question — which now
    /// runs the AI4 General path: with a key the search is forced; without one the AF3
    /// no-key notice appears. Re-sending is exactly `groundedSend`, so nothing about the
    /// tool/nudge/refusal-guard logic is duplicated here.
    func acceptWebSearchOffer(store: CorpusStore, chat: ChatSession) async {
        guard let query = pendingWebSearchOffer else { return }
        pendingWebSearchOffer = nil
        corpusAware = false
        await groundedSend(query: query, store: store, chat: chat)
    }

    /// Brief BS3 — the user tapped "Read *Title* in full?" under a survey answer. Force-read that
    /// entry for the re-asked turn (`forcedReadNodeID`, treated as a pin by `corpusCandidates`) and
    /// re-send the SAME question. Re-sending is exactly `groundedSend`, so routing/delivery/receipt
    /// all flow through the one path — this just changes which entry gets read in full.
    func acceptReadInFullOffer(store: CorpusStore, chat: ChatSession) async {
        guard let offer = pendingReadInFullOffer else { return }
        pendingReadInFullOffer = nil
        forcedReadNodeID = offer.nodeID
        await groundedSend(query: offer.query, store: store, chat: chat)
    }

    /// Brief BN2–BN5 — route the corpus-Ask turn (read vs survey), then assemble the numbered
    /// candidate list + the read/skim receipt. FIND, THEN READ (protocol north star): passages/cards
    /// FIND which entries are relevant; the answer comes from entries READ.
    ///
    /// A turn is a READ when ANY of:
    ///   1/2. An entry is PINNED — the question NAMES an entry (a quoted/verbatim title, `pinnedNodeIDs`).
    ///   3.   It's a WORKING-SET FOLLOW-UP (BN4) — a deixis question ("analyze that document") about an
    ///        entry already read this conversation → re-read the SAME entry, NO fresh similarity search.
    ///   4.   One entry DOMINATES the aggregate passage scores (`dominantReadEntry`).
    /// Otherwise it's a SURVEY (today's cards + ≤3/node passages).
    ///
    /// Mutates the carry state (S2 stable `[n]`) and the chat's working set (BN4). The caller builds
    /// the prompt + chips and sends with the receipt.
    private func corpusCandidates(query: String, store: CorpusStore, chat: ChatSession) async -> (candidates: [NumberedCandidate], empty: Bool, receipt: ChatSession.Message.ReadReceipt?) {
        // BN3 — the char budget for everything retrieved, DERIVED from the active backend's window.
        let budget = askContextCharBudget()

        // S2 — retrieval query = current question + the previous USER turn in this chat (first turn:
        // bare question), so a follow-up keeps its subject.
        let previousUserTurn = chat.messages.last { $0.role == .user }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let retrievalQuery: String = {
            if let prev = previousUserTurn, !prev.isEmpty { return "\(query)\n\(prev)" }
            return query
        }()

        // BS3 — a one-shot forced read (the "Read … in full?" survey-lead offer was tapped) acts
        // exactly like a pin for THIS turn, then clears. Otherwise BN2 trigger #1 — PIN: a quoted
        // title, or a title verbatim in the question (`pinnedNodeIDs`); detect against the CURRENT
        // question, not the augmented query.
        let forcedID = forcedReadNodeID
        forcedReadNodeID = nil
        let pinnedIDs: [String] = {
            if let forcedID, store.nodes.contains(where: { $0.id == forcedID }) { return [forcedID] }
            return Self.pinnedNodeIDs(question: query, store: store)
        }()
        let pinning = !pinnedIDs.isEmpty
        // BN2 trigger #2 — the question NAMES an entry by TITLE MATCH: looser than the strict
        // quoted/verbatim pin (punctuation-normalised, word-order-independent), so "what's in my
        // Medical Lab Tests?" names the "Medical – Lab Tests" entry even without quotes or the exact
        // en-dashed form. A pin wins when both fire (it's the more explicit signal).
        let titleMatchedIDs = pinning ? [] : Self.titleMatchedEntryIDs(question: query, store: store)
        // A NAMED entry (pin OR title match) is an explicit single/few-entry focus → READ it, drop
        // the tangential card survey, hold non-named passages to the higher 0.70 bar.
        let namedIDs = pinning ? pinnedIDs : titleMatchedIDs
        let named = !namedIDs.isEmpty

        let turnIndex = chat.messages.filter { $0.role == .user }.count + 1
        let carriedAll = (carriedChatID == chat.id) ? carriedCandidates : []

        // BN4 — WORKING-SET FOLLOW-UP (trigger #3). If the previous turn READ entries and THIS
        // question is a follow-up about them (deixis; no NEW entry named), RE-READ the same entries
        // in full with NO fresh similarity search (Brief BN4 / verify case 2). The working set lives
        // on the chat, so a reloaded conversation keeps it open.
        if !named, !chat.workingSet.isEmpty, Self.looksLikeWorkingSetFollowUp(query) {
            let targets = chat.workingSet.filter { id in store.nodes.contains { $0.id == id } }
            if !targets.isEmpty {
                let (candidates, receipt) = await buildReadPacket(
                    readTargets: targets, rankedPassages: [], cards: [],
                    carried: carriedAll, budget: budget, queryVector: [], store: store)
                carriedCandidates = candidates; carriedChatID = chat.id
                chat.workingSet = candidates.filter { $0.isEntryRead }.map { $0.nodeID }
                let empty = candidates.isEmpty
                Self.logRouting(turnIndex: turnIndex, query: retrievalQuery, mode: "read(followup)",
                                candidates: candidates, receipt: receipt, budget: budget,
                                scope: selectedScope, store: store)
                return (candidates, empty, empty ? nil : receipt)
            }
        }

        // ── Normal routing ──────────────────────────────────────────────────────────────────────
        // AA1 — embed the retrieval query ONCE; the passage scan and the card scan share it (empty on
        // embed failure → both re-embed and also fail → no candidates → bare question, as before).
        let qvec = await CardEmbeddingService.shared.embed(retrievalQuery) ?? []

        // Passages (DEPTH), diversified ≤3/node. These FIND the relevant entries; they are not the
        // answer surface.
        let general = await store.askMatches(query: retrievalQuery, scope: selectedScope, topK: 12, queryVector: qvec)

        // A NAMED entry (pin or title match) suppresses cards (AA); otherwise the room's cards
        // carry the survey/skim breadth.
        let cards: [CardMatch] = named
            ? []
            : await store.cardMatches(query: retrievalQuery, scope: selectedScope, queryVector: qvec)

        // BN2 — rank ENTRIES by aggregate score, then decide READ vs SURVEY.
        let ranking = Self.entryRanking(passages: general)
        let dominant = Self.dominantReadEntry(ranking: ranking, store: store)   // nil → no single dominator

        if named || dominant != nil {
            // READ targets + BS1 AMBIGUITY. A pin reads all pinned entries; a title match that named
            // ONE entry reads it; a title match that named 2+ entries reads the TOP by aggregate
            // passage score and lists the rest as CHIPS (BS1 — the user still sees the alternatives
            // without learning to pin); dominance reads the single dominant entry.
            func agg(_ id: String) -> Float { ranking.first { $0.nodeID == id }?.aggregate ?? 0 }
            let readTargets: [String]
            var ambiguousChipIDs: [String] = []
            if pinning {
                readTargets = namedIDs
            } else if named {
                if titleMatchedIDs.count <= 1 {
                    readTargets = titleMatchedIDs
                } else {
                    let ranked = titleMatchedIDs.sorted { agg($0) > agg($1) }
                    readTargets = [ranked[0]]
                    ambiguousChipIDs = Array(ranked.dropFirst().prefix(4))   // the other named entries → chips
                }
            } else {
                readTargets = [dominant!]
            }
            let readSet = Set(readTargets)
            // Non-target passages become labelled skim passages; non-target cards become one-line
            // summaries. For a NAMED entry, non-named passages still clear the higher 0.70 bar (S3).
            let bar: Float = named ? 0.70 : CorpusStore.minRelevanceScore
            let skimPassages = general.filter { !readSet.contains($0.nodeID) && $0.score >= bar }
            var skimCards = named ? [] : cards.filter { !readSet.contains($0.nodeID) }
            // BS1 — the other title-matched entries become chips even though a NAMED turn suppresses
            // the survey: build a card per one (its gist = the node summary) so it's a tappable source.
            for id in ambiguousChipIDs where !readSet.contains(id) {
                if let node = store.nodes.first(where: { $0.id == id }) {
                    let gist = (node.substrateSummary?.isEmpty == false ? node.substrateSummary! : node.summary)
                    skimCards.append(CardMatch(nodeID: id, gist: gist, score: agg(id)))
                }
            }
            // A NAMED turn drops carried CARDS (AA); dominance keeps the full carry for stable [n].
            let carried = named ? carriedAll.filter { !$0.isCard } : carriedAll
            let (candidates, receipt) = await buildReadPacket(
                readTargets: readTargets, rankedPassages: skimPassages, cards: skimCards,
                carried: carried, budget: budget, queryVector: qvec, store: store)
            carriedCandidates = candidates; carriedChatID = chat.id
            chat.workingSet = candidates.filter { $0.isEntryRead }.map { $0.nodeID }
            let empty = candidates.isEmpty
            let mode = named ? (pinning ? "read(pin)" : "read(title)") : "read(dominance)"
            Self.logRouting(turnIndex: turnIndex, query: retrievalQuery, mode: mode,
                            candidates: candidates, receipt: receipt, budget: budget,
                            scope: selectedScope, store: store)
            return (candidates, empty, empty ? nil : receipt)
        }

        // ── SURVEY (today's path) ─────────────────────────────────────────────────────────────────
        // AA2 — shape sets the passage/card budget split.
        let verdict = Self.retrievalShape(passages: general, pinning: false, store: store)
        let generalFiltered = general.filter { $0.score >= CorpusStore.minRelevanceScore }
        let newPassages = Array(generalFiltered.prefix(verdict.shape.passageBudget))
        let newCards = Array(cards.prefix(verdict.shape.cardBudget))
        // Carry unions both kinds, but never a stale full-entry read into a survey (a survey is a new
        // topic — a prior read's `.entry` must not leak in as a source).
        let candidates = Self.assembleCandidates(
            carried: carriedAll.filter { !$0.isEntryRead }, pinned: [],
            newPassages: newPassages, newCards: newCards, budget: budget)

        carriedCandidates = candidates
        carriedChatID = chat.id
        chat.workingSet = []   // BN4 — a survey moves on; nothing stays open

        // Brief AB3 — "empty" = a SURVEY that surfaced < 3 cards and no passages (or nothing at all).
        let passageCount = candidates.filter { !$0.isCard }.count
        let cardCount = candidates.count - passageCount
        let empty = candidates.isEmpty
            || (passageCount == 0 && cardCount < 3 && verdict.shape == .survey)

        // Brief BS3 — a survey where ONE entry clearly leads offers "Read *Title* in full?" (so the
        // user need never learn to pin). Fires only when the lead is strong: top aggregate ≥ 1.3
        // (≈ two ~0.65 passages) AND ≥ 2 passages AND ≥ 1.5× the runner-up — set from the fixture
        // (survey tops run ~0.5–0.6, a genuine single-entry lookup sums higher). Not on every survey.
        if !empty, let lead = ranking.first, lead.aggregate >= 1.3, lead.count >= 2,
           (ranking.count == 1 || lead.aggregate >= 1.5 * (ranking[1].aggregate)),
           let node = store.nodes.first(where: { $0.id == lead.nodeID }) {
            pendingReadInFullOffer = ReadInFullOffer(query: query, nodeID: lead.nodeID, title: node.title)
        }

        Self.logCandidates(turnIndex: turnIndex, query: retrievalQuery, candidates: candidates, shape: verdict, scope: selectedScope, empty: empty, store: store)
        let receipt: ChatSession.Message.ReadReceipt? = empty ? nil : Self.surveyReceipt(candidates: candidates)
        return (candidates, empty, receipt)
    }

    // MARK: - Brief BN2/BN3 — entry ranking, the read/survey router, and the read-in-full packet

    /// Brief BN2 — rank ENTRIES (not fragments) by aggregate relevance. Aggregate = SUM of an
    /// entry's passage scores in the diversified ≤3/node list. SUM over MAX (reported in the CC
    /// report): the "find, then read" target is the entry that owns MULTIPLE strong passages — a lab
    /// panel is many rows; the Bolex note, several mentions — which sum rewards and max would tie
    /// against a one-passage tangential hit. The ≤3/node cap already bounds sum's length bias to
    /// three blocks, so a long article can't run away on raw fragment count. Best entry first.
    static func entryRanking(passages: [BlockMatch]) -> [(nodeID: String, aggregate: Float, top: Float, count: Int)] {
        var agg: [String: (sum: Float, top: Float, count: Int)] = [:]
        for m in passages {
            var e = agg[m.nodeID] ?? (0, 0, 0)
            e.sum += m.score
            e.top = max(e.top, m.score)
            e.count += 1
            agg[m.nodeID] = e
        }
        return agg.map { (nodeID: $0.key, aggregate: $0.value.sum, top: $0.value.top, count: $0.value.count) }
            .sorted { $0.aggregate > $1.aggregate }
    }

    /// Brief BN2 — the DOMINANCE test (read trigger #4). The top-ranked entry dominates → READ when:
    ///   (a) its top passage ≥ 0.70 — a genuinely strong hit, above the 0.60 inclusion floor;
    ///   (b) it contributes ≥ 2 passages — concentration, not a lone chunk; AND
    ///   (c) it's a possession the user READS — their own note (`.note`) or a document they added
    ///       (`.document`), NOT a saved web article (`.savedLink`).
    /// (c) is the fixture discriminator (reported): "what do my lab test results reveal?" is
    /// dominated by the Medical *document* → READ; "what are my thoughts on technology?" is dominated
    /// by the *Schema (psychology)* saved article, whose internal passage density is a document
    /// artefact — a broad theme with many entries, not a single-entry target → stays SURVEY. (A named
    /// saved-article read, e.g. the Villanova link, still routes via a pin, not dominance.) Returns
    /// the dominant node id, or nil when no entry dominates.
    static func dominantReadEntry(ranking: [(nodeID: String, aggregate: Float, top: Float, count: Int)], store: CorpusStore) -> String? {
        guard let leader = ranking.first else { return nil }
        guard leader.top >= 0.70, leader.count >= 2 else { return nil }
        guard let node = store.nodes.first(where: { $0.id == leader.nodeID }) else { return nil }
        let kind = node.cardProvenance().kind
        guard kind == .note || kind == .document else { return nil }
        return leader.nodeID
    }

    /// Brief BN4 — does this question read as a FOLLOW-UP about the open entry (the working set)
    /// rather than a fresh topic? A deliberately simple matcher — no classifier (T's standing "no
    /// question classifier" ruling; same posture as `looksLikeSearchIntent`): an explicit reference
    /// phrase ("that document", "tell me more", "analyze it", "go deeper"…), OR a SHORT question
    /// (≤ 6 words) leaning on a bare deictic ("it", "that", "this", "those"). A fresh, self-contained
    /// question introduces its own nouns → matches none of these → routes normally (new topic).
    static func looksLikeWorkingSetFollowUp(_ query: String) -> Bool {
        let q = query.lowercased()
        let phrases = ["that document", "this document", "that entry", "this entry", "the entry",
                       "that article", "this article", "the article", "that note", "this note", "the note",
                       "that page", "this page", "tell me more", "more about", "more detail", "go deeper",
                       "dig deeper", "analyze it", "analyse it", "analyze that", "analyse that",
                       "expand on", "summarize it", "summarise it", "explain it", "explain that",
                       "what else", "read it", "read that", "in full"]
        if phrases.contains(where: { q.contains($0) }) { return true }
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.count <= 6 {
            let deictics: Set<String> = ["it", "that", "this", "them", "those", "these"]
            if words.contains(where: { deictics.contains($0) }) { return true }
        }
        return false
    }

    /// Brief BN3 — assemble the READ-mode packet. Fill order is the brief's: the TOP target's whole
    /// text → the second target's whole text if it fits → labelled passages for the next entries →
    /// one-line summaries for the rest, all within `budget`. An entry too big for the remaining
    /// budget degrades to its best passages ("partial", the model is told). Numbers continue from the
    /// carry (stable `[n]`); a re-read entry reuses its number. Never truncates mid-row — the read
    /// unit is whole blocks. Returns the candidates + the BN5 read/skim receipt.
    private func buildReadPacket(
        readTargets: [String],
        rankedPassages: [BlockMatch],
        cards: [CardMatch],
        carried: [NumberedCandidate],
        budget: Int,
        queryVector: [Float],
        store: CorpusStore
    ) async -> (candidates: [NumberedCandidate], receipt: ChatSession.Message.ReadReceipt) {
        var byIDNumber: [String: Int] = [:]
        for c in carried { byIDNumber[c.identity] = c.number }
        var maxNumber = carried.map(\.number).max() ?? 0
        func number(for identity: String) -> (n: Int, carried: Bool) {
            if let n = byIDNumber[identity] { return (n, true) }
            maxNumber += 1; return (maxNumber, false)
        }
        // Per-item overhead = the numbered header line ("[n] document — Title — read in full") +
        // the "\n\n———\n\n" / "\n\n---\n\n" separators `buildAskContext` inserts. `sectionReserve`
        // covers the once-per-turn framing (up to three "SECTION:\n" headers + the "Some of your
        // notes… Question:" wrapper) so the RENDERED packet never exceeds `budget` (BN3: never
        // overflow). Both are conservative — a slightly smaller packet is always safe.
        let overheadPerItem = 120
        let sectionReserve = 320
        let ranking = Self.entryRanking(passages: rankedPassages)
        func aggregate(_ nodeID: String) -> Float { ranking.first { $0.nodeID == nodeID }?.aggregate ?? 1.0 }

        var out: [NumberedCandidate] = []
        var used = sectionReserve
        var partialAny = false
        let readSet = Set(readTargets)

        // 1/2. Read targets in full (top, then second if it fits, …).
        for nodeID in readTargets {
            guard let node = store.nodes.first(where: { $0.id == nodeID }) else { continue }
            let full = await store.fullEntryText(nodeID: nodeID)
            let (num, wasCarried) = number(for: "full:\(nodeID)")
            let origin: NumberedCandidate.Origin = wasCarried ? .carried : .new
            let remaining = budget - used
            if !full.isEmpty && full.count + overheadPerItem <= remaining {
                let e = EntryRead(nodeID: nodeID, title: node.title, text: full, score: aggregate(nodeID), partial: false)
                out.append(NumberedCandidate(number: num, payload: .entry(e), origin: origin))
                used += full.count + overheadPerItem
            } else if out.isEmpty {
                // The FIRST target doesn't fit → its best passages (today's behaviour), marked partial.
                let text = await bestPassagesText(nodeID: nodeID, rankedPassages: rankedPassages,
                                                  queryVector: queryVector, budget: max(0, remaining - overheadPerItem), store: store)
                if !text.isEmpty {
                    let e = EntryRead(nodeID: nodeID, title: node.title, text: text, score: aggregate(nodeID), partial: true)
                    out.append(NumberedCandidate(number: num, payload: .entry(e), origin: origin))
                    used += text.count + overheadPerItem
                    partialAny = true
                }
            }
            // A LATER target that doesn't fit falls through to the skim sections below.
        }

        // 3. Labelled skim passages (≤3/node) from entries not read in full.
        var perNode: [String: Int] = [:]
        for m in rankedPassages where !readSet.contains(m.nodeID) {
            let cost = m.block.text.count + overheadPerItem
            guard used + cost <= budget else { break }
            let k = perNode[m.nodeID, default: 0]
            guard k < CorpusStore.maxBlocksPerNode else { continue }
            let (num, wasCarried) = number(for: m.block.blockID)
            out.append(NumberedCandidate(number: num, payload: .passage(m), origin: wasCarried ? .carried : .new))
            used += cost
            perNode[m.nodeID] = k + 1
        }

        // 4. One-line summaries (cards) for the rest — not already read or shown as a passage.
        let shownNodes = Set(out.map { $0.nodeID })
        for card in cards where !readSet.contains(card.nodeID) && !shownNodes.contains(card.nodeID) {
            let cost = card.gist.count + overheadPerItem
            guard used + cost <= budget else { break }
            let (num, wasCarried) = number(for: "card:\(card.nodeID)")
            out.append(NumberedCandidate(number: num, payload: .card(card), origin: wasCarried ? .carried : .new))
            used += cost
        }

        // BN5/BS3 receipt — entries read in full (with their TITLES, in packet order) vs distinct
        // entries merely skimmed. `partialModel` names the model for the BS3 "too long for {model}"
        // line (only when a read was partial).
        let readEntries = out.filter { $0.isEntryRead }
        let readNodes = Set(readEntries.map { $0.nodeID })
        let skimmedNodes = Set(out.filter { !$0.isEntryRead }.map { $0.nodeID }).subtracting(readNodes)
        let readTitles = readEntries.compactMap { c -> String? in
            if case .entry(let e) = c.payload { return e.title } else { return nil }
        }
        let receipt = ChatSession.Message.ReadReceipt(
            readInFull: readNodes.count, skimmed: skimmedNodes.count, partial: partialAny,
            readTitles: readTitles.isEmpty ? nil : readTitles,
            partialModel: partialAny ? activeModelLabel : nil)
        return (out, receipt)
    }

    /// Brief BN3 — the partial-read text for an entry too big for the budget: its best passages
    /// (today's fragment behaviour), as WHOLE blocks joined (never mid-row). Prefers the scored
    /// blocks already retrieved for this entry; else, with a query vector, fetches the entry's best
    /// blocks; else (a no-retrieval follow-up) falls back to the entry's HEAD blocks — always whole
    /// blocks, added until the budget is reached. Guarantees at least the first block (never empty).
    private func bestPassagesText(nodeID: String, rankedPassages: [BlockMatch], queryVector: [Float], budget: Int, store: CorpusStore) async -> String {
        var blocks: [String] = rankedPassages.filter { $0.nodeID == nodeID }.map { $0.block.text }
        if blocks.count < 3, !queryVector.isEmpty {
            let more = await store.blocksForNodes(query: "", nodeIDs: [nodeID], topK: 40, queryVector: queryVector)
            if !more.isEmpty { blocks = more.map { $0.block.text } }
        }
        if blocks.isEmpty { blocks = await store.entryBlockTexts(nodeID: nodeID) }
        var out = ""
        for b in blocks {
            let add = out.isEmpty ? b : "\n\n" + b
            if !out.isEmpty && out.count + add.count > budget { break }
            out += add
        }
        if out.isEmpty, let first = blocks.first { out = String(first.prefix(max(budget, 200))) }
        return out
    }

    /// Brief BN5 — the survey turn's receipt: nothing read in full; every distinct entry in the
    /// packet was skimmed. Footer → "Skimmed N entries".
    static func surveyReceipt(candidates: [NumberedCandidate]) -> ChatSession.Message.ReadReceipt {
        ChatSession.Message.ReadReceipt(readInFull: 0, skimmed: Set(candidates.map { $0.nodeID }).count, partial: false)
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
        let (candidates, _, _) = await corpusCandidates(query: query, store: store, chat: ChatSession())
        return candidates.map { ($0.number, $0.nodeID) }
    }

    /// Brief BN verify — build the EXACT Ask packet (system prompt + model text) + routing receipt
    /// for `query` WITHOUT sending, so `-LibrarianRoutingDiag` can confirm the route and dump the
    /// packet. Runs the full corpus router (BN2 route, BN3 read-in-full/budget, BN4 working set) and
    /// appends the user turn so a follow-up call exercises the working set + S2 carry.
    func debugBuildAskPacket(query: String, store: CorpusStore, chat: ChatSession) async
        -> (mode: String, nodeIDs: [String], model: String, receipt: ChatSession.Message.ReadReceipt?) {
        corpusAware = true
        let (candidates, empty, receipt) = await corpusCandidates(query: query, store: store, chat: chat)
        defer { chat.debugAppendUser(query) }   // so the NEXT call sees this as the previous user turn
        if empty { return ("empty", [], query, nil) }
        let context = buildAskContext(candidates: candidates, store: store)
        let modelText = """
        Some of your notes were retrieved for you — they may or may not be relevant to the question:

        \(context)

        Question: \(query)
        """
        let mode = (receipt?.readInFull ?? 0) > 0 ? "read" : "survey"
        let readNodeIDs = candidates.filter { $0.isEntryRead }.map { $0.nodeID }
        return (mode, readNodeIDs, modelText, receipt)
    }

    /// Brief BN3 verify — FORCE a read of specific node ids (bypassing the router), so the
    /// read-in-full packet, the model-derived budget, and the partial/receipt are testable
    /// DETERMINISTICALLY on the Simulator — whose CPU BGE scores too low to trigger dominance, and
    /// whose title-matching is the same code as device. `windowOverride` forces the backend window
    /// (4096 = FM's tight window). Returns the assembled context + the read receipt.
    func debugForceReadPacket(readTargets: [String], store: CorpusStore, windowOverride: Int? = nil) async
        -> (context: String, receipt: ChatSession.Message.ReadReceipt) {
        corpusAware = true
        let budget = askContextCharBudget(windowOverride: windowOverride)
        let (candidates, receipt) = await buildReadPacket(
            readTargets: readTargets, rankedPassages: [], cards: [],
            carried: [], budget: budget, queryVector: [], store: store)
        return (buildAskContext(candidates: candidates, store: store), receipt)
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
        case .entry:          return node.cardProvenance()   // BN3 — whole-entry read → whole-node provenance
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
            // BN3 — a full-entry read chip carries a lead-in snippet of the entry (+ "read in full").
            case .entry(let e):
                let lead = String(e.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
                body = e.partial ? "read (partial) · \(lead)" : "read in full · \(lead)"
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
    /// Brief BN3 — the derived char budget for everything RETRIEVED into the Ask prompt
    /// (read-in-full entries + labelled passages + one-line summaries). It replaces the old fixed
    /// `askPassageCharBudget = 12,000` / `contextBudgetChars = 14,000` constants (both sized by
    /// hand for a 4096-token stock window). Now the budget comes from the ACTIVE backend's real
    /// context window (`ModelRouter.contextWindowTokens`) minus the system prompt, the accrued
    /// session history, and an answer reserve — ×4 (the app's standing char≈token/4 heuristic).
    /// The SAME formula gives the Host a generous ~120K-char budget (a whole entry fits several
    /// times over) and FM a tight ~10K (a big entry degrades to its best passages, marked
    /// "partial"), so it never overflows the small window nor starves the big one.
    ///
    /// `windowOverride` lets the routing/budget self-test exercise a specific backend's window
    /// headlessly (the Simulator has no Host/FM). Read LIVE here — this runs in the async send
    /// path, OFF the SwiftUI render path, so the `ModelRouter.active` Keychain read is safe.
    #if DEBUG
    /// Brief BN3 verify — force the derived budget's window (tokens) for `-LibrarianRoutingDiag`
    /// (e.g. 4096 to reproduce FM's tight window on the Simulator, which has no FM). No-op when nil.
    var debugContextWindowOverride: Int? = nil
    #endif
    func askContextCharBudget(windowOverride: Int? = nil) -> Int {
        #if DEBUG
        let windowTokens = windowOverride ?? debugContextWindowOverride ?? ModelRouter.contextWindowTokens
        #else
        let windowTokens = windowOverride ?? ModelRouter.contextWindowTokens
        #endif
        let answerReserveTokens = min(1_024, windowTokens / 4)   // room for the reply (FM: 1024 of 4096)
        let sysTokens = askSystemPrompt.count / 4
        let historyChars = (compactedSummary?.count ?? 0)
            + sessionHistory.reduce(0) { $0 + $1.query.count + $1.responseText.count }
        let historyTokens = historyChars / 4
        let questionReserveTokens = 128            // the question + section-header framing overhead
        let budgetTokens = windowTokens - answerReserveTokens - sysTokens - historyTokens - questionReserveTokens
        // Never return a non-positive or absurd budget — always ship at least one entry's worth.
        return max(2_000, budgetTokens * 4)
    }

    /// 0…1 estimate of how much of the context window will be consumed
    /// by the current/next query. Drives the ring color/fill in the
    /// surface header.
    ///
    /// Counts: system-prompt baseline + current input length +
    /// compacted summary + accrued session history (per-exchange query
    /// + responseText). The retrieval reservation (the read-in-full /
    /// passage budget) is *not* counted here — it's committed per query,
    /// not held across turns, so adding it to the standing fill would
    /// make the ring read "almost full" before the user has typed
    /// anything. After a compaction pass, the `sessionHistory` term
    /// shrinks to zero and the summary term replaces it — net effect is
    /// the ring drains and color shifts back toward cyan.
    ///
    /// Brief BN3 — the denominator is now the active backend's full window
    /// (`activeContextWindowTokens`, cached off the render path by
    /// `refreshActiveModel`) ×4 chars, not the retired fixed 14,000. So the
    /// ring reads against FM's tight 4K and the Host's 32K correctly.
    var contextFillFraction: Double {
        let baseline = askSystemPrompt.count
        let questionChars = inputText.count
        let compactedChars = compactedSummary?.count ?? 0
        let historyChars = sessionHistory.reduce(0) { acc, ex in
            acc + ex.query.count + ex.responseText.count
        }
        let used = baseline + questionChars + compactedChars + historyChars
        return min(1.0, Double(used) / Double(max(4_000, activeContextWindowTokens * 4)))
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
            if c.isCard || c.isEntryRead { out.append(c); continue }   // cards + full reads are one-per-node, exempt
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
            case .entry(let e):   return e.text.count + 80   // BN3 — a full-entry read (survey never carries one)
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

    /// Brief BS1 (READ trigger #2) — the question NAMES an entry by its TITLE, matched on TOKEN
    /// OVERLAP (not the whole-phrase subset BN2 first shipped, which missed "what do my lab test
    /// results reveal?" ↔ "Medical – Lab Tests" because the question omits "medical" and says
    /// "test*s* results"). Now: lowercase, split punctuation (en-dash/parens/slash), drop stopwords +
    /// sub-3-char words, LIGHT-STEM (tests→test, results→result, studies→study). An entry with ≥ 2
    /// distinctive title tokens matches when **the question shares ≥ 2 of them, OR ≥ 60% of them**
    /// (the reported rule). "lab test results" → {lab, test, result}; "Medical – Lab Tests" →
    /// {medical, lab, test}; overlap {lab, test} = 2 → MATCH. Returned BEST-FIRST by overlap; when
    /// two entries both match (ambiguous), the caller READS the top by passage score and lists the
    /// rest as chips (BS1). Empty for the common no-named-entry question. Never called when a pin
    /// fired.
    static func titleMatchedEntryIDs(question: String, store: CorpusStore) -> [String] {
        let q = contentTokens(question)
        guard !q.isEmpty else { return [] }
        var matches: [(id: String, overlap: Int)] = []
        for node in store.nodes {
            let t = contentTokens(node.title)
            guard t.count >= 2 else { continue }   // single distinctive-token titles are too grabby
            let overlap = t.intersection(q).count
            guard overlap >= 1 else { continue }
            let frac = Double(overlap) / Double(t.count)
            if overlap >= 2 || frac >= 0.6 {
                matches.append((node.id, overlap))
            }
        }
        // Best (most shared tokens) first — the caller reads the top and lists the rest as chips.
        return matches.sorted { $0.overlap > $1.overlap }.map(\.id)
    }

    /// Distinctive, light-stemmed tokens of a string for title matching: lowercased, punctuation
    /// split out (so an en-dashed / parenthesised title tokenises the same as the question),
    /// stopwords + sub-3-char words dropped, then a conservative plural stem (tests→test,
    /// results→result, studies→study; never touches "…ss"). Shared by the question and each title so
    /// both are normalised the same way. Stopwords are matched on the RAW word (function words
    /// aren't pluralised), so "does" isn't stemmed to "doe".
    private static func contentTokens(_ s: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "and", "for", "with", "about", "what", "whats", "tell", "does", "did",
            "entry", "note", "notes", "document", "documents", "article", "articles", "page", "pages",
            "this", "that", "these", "those", "your", "you", "reveal", "reveals", "say", "says",
            "have", "has", "are", "was", "were", "can", "how", "why", "who", "when", "where", "which",
            "from", "into", "get", "got", "any", "all", "some", "more", "call", "called", "named",
            "titled", "show", "give", "find", "want", "would", "could", "should", "please", "thing"]
        var out: Set<String> = []
        for w in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        where w.count >= 3 && !stop.contains(w) {
            out.insert(Self.stemToken(w))
        }
        return out
    }

    /// Conservative plural stem: `…ies`→`…y` (studies→study), else a trailing `s` dropped unless it's
    /// a double-s (tests→test, results→result; business→business). Not a real stemmer — just enough
    /// to make singular/plural title↔question tokens agree.
    private static func stemToken(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
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
            case .entry(let e):
                // BN3 — a survey never carries a full read, but log it for exhaustiveness.
                lines.append("  [read]    [\(c.number)] \(e.title) :: \(e.text.count) chars\(e.partial ? " (PARTIAL)" : "") · \(c.origin.rawValue)")
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

    /// Brief BN2/BN5 — the READ-mode analogue of the S5 candidate log. One record with the routing
    /// mode (`read(pin)` / `read(dominance)` / `read(followup)`), the read/skim counts (BN5 receipt),
    /// the model-derived char budget (BN3), then each candidate — full-entry reads first. Shares the
    /// os_log + "Copy Librarian log" buffer, so `-LibrarianRetrievalDiag` / device diagnostics show it.
    private static func logRouting(turnIndex: Int, query: String, mode: String, candidates: [NumberedCandidate], receipt: ChatSession.Message.ReadReceipt, budget: Int, scope: CanvasScope, store: CorpusStore) {
        var lines: [String] = []
        let q = query.replacingOccurrences(of: "\n", with: " ⏎ ")
        lines.append("turn \(turnIndex) · scope=\(scopeLabel(scope, store: store)) · mode=\(mode) · read=\(receipt.readInFull) skim=\(receipt.skimmed) partial=\(receipt.partial) · budgetChars=\(budget) · \(candidates.count) candidate(s) · query=\"\(q)\"")
        for c in candidates.sorted(by: { $0.number < $1.number }) {
            switch c.payload {
            case .entry(let e):
                lines.append("  [read]    [\(c.number)] \(e.title) :: \(e.text.count) chars\(e.partial ? " (PARTIAL)" : "") · \(c.origin.rawValue)")
            case .passage:
                lines.append("  [passage] \(passageHeader(for: c, store: store)) · \(String(format: "%.3f", c.score)) · \(c.origin.rawValue)")
            case .card:
                lines.append("  [card]    \(cardLogLine(for: c, store: store)) · \(String(format: "%.3f", c.score)) · \(c.origin.rawValue)")
            }
        }
        let record = lines.joined(separator: "\n")
        candidateLog.log("\(record, privacy: .public)")
        recentCandidateLog.append(record)
        if recentCandidateLog.count > recentCandidateLogCap {
            recentCandidateLog.removeFirst(recentCandidateLog.count - recentCandidateLogCap)
        }
    }

    /// Brief AI4 — the General-mode analogue of the S5 line (corpus mode has no
    /// candidates to log). One record per General turn carrying the web-tool state:
    /// `tool=required` (app forced the search via the nudge), `declared` (tool offered,
    /// model's choice), or `none` (FM / no-key). `retry=web` appears when the refusal
    /// guard fired a second attempt. Shares the same os_log + "Copy Librarian log" buffer.
    private static func logGeneralTurn(query: String, scope: CanvasScope, tool: String, retry: Bool, store: CorpusStore) {
        let q = query.replacingOccurrences(of: "\n", with: " ⏎ ")
        let record = "general · scope=\(scopeLabel(scope, store: store)) · tool=\(tool)\(retry ? " · retry=web" : "") · query=\"\(q)\""
        candidateLog.log("\(record, privacy: .public)")
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
        let base = "You are a reflective AI that helps someone think across their OWN entries. Up to three labelled sections may appear below the question: ENTRIES READ IN FULL contains the COMPLETE text of the user's most relevant entries — these are the PRIMARY source, answer from them directly and thoroughly; ENTRIES ON THIS TOPIC lists other related entries (one line each); and PASSAGES are excerpts. They were pulled from the user's library and MAY OR MAY NOT all be relevant. When an entry is READ IN FULL, base your answer on its whole text — give the specifics it actually contains (names, values, dates, figures) rather than a vague summary. For broad questions about what the user thinks or has, synthesise across ENTRIES and cite them; for specific facts, answer from the full entry or the PASSAGES. Treat anything that genuinely helps as authoritative about the user's own world — if it defines a term, use THEIR definition over a generic one — and cite it inline with bracket numbers like [1] [2] matching the numbered sections. If a full entry is marked PARTIAL, only its best excerpts were included — answer from what's there and don't invent the rest. Ignore items that don't help and answer normally from your own knowledge. Never say the entries don't contain the answer and never refuse for lack of a matching passage — just answer the question directly. Be specific, concise, and never generic. Cite only items you actually used. Do not connect entries the question did not ask about. If an entry distinguishes an estimate from an actual figure, say which. Entries marked saved article, document, or image text are things the user collected, not their own words. For questions about the user's own views, answer from their entries and refer to collected sources as such. Do not append a References, Sources, or Citations section — AirPad renders citations separately. End your reply at the end of the prose answer."
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
        // Brief AI4 — the "current-information" cue set. ONE matcher is the single
        // source of truth for BOTH the no-key notice (AF3) and the app-forced search
        // (AI4 General-mode force + AI5 Library offer). Broadened from the original
        // five to the AI4 list; false positives stay cheap (General mode with a key
        // just runs a search the user may not have needed; without a key, the
        // one-line "add a key" reply).
        let cues = ["search", "look up", "latest", "today", "current", "news",
                    "what happened", "who won", "score", "weather", "price"]
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

    /// Brief AI5 — a Library-mode turn that found NOTHING in the room AND read as a
    /// current-information question parks the user's query here; the surface renders an
    /// app-level "Search the web instead" offer under the answer (NOT model text, never
    /// a citation). Tapping flips to General and re-sends (AI4 applies). Set after the
    /// empty-library answer commits; cleared on the next send, an accept, or a manual
    /// mode flip. Observable so the surface shows/hides the offer bar.
    var pendingWebSearchOffer: String? = nil

    /// Brief BS3 — a SURVEY turn where ONE entry clearly leads parks a "Read *Title* in full?" offer
    /// here; the surface renders it under the answer, and tapping re-asks the SAME question with that
    /// entry force-read (`acceptReadInFullOffer`) — so the user never has to learn that pinning is
    /// the trick. Set only when the lead is strong (see `surveyLeadOffer`); cleared on the next send
    /// or an accept. Never model text / never a citation.
    struct ReadInFullOffer: Equatable { let query: String; let nodeID: String; let title: String }
    var pendingReadInFullOffer: ReadInFullOffer? = nil

    // Brief BS3 note — a "Use {larger model}" ACTION is deliberately NOT wired: `ModelRouter.active`
    // already selects Host (32K) over FM/Ollama (4K) whenever a Host is paired, so a PARTIAL read
    // only ever happens on a 4K provider with NO larger model reachable — i.e. the brief's "otherwise
    // no button" is the ONLY reachable state. The footer still explains the partial and names the
    // model (`ReadReceipt.partialModel`); there is simply nothing larger to offer.

    /// Brief BS3 — a one-turn forced read target set by `acceptReadInFullOffer`: `corpusCandidates`
    /// treats this node exactly like a pin (READ it in full) for the single re-asked turn, then it's
    /// cleared. Lets the survey-lead offer re-read an entry the router had only skimmed.
    @ObservationIgnored var forcedReadNodeID: String? = nil

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

    /// Brief BN3 — the active backend's context window (tokens), CACHED off the render path (same
    /// reason as `activeModelLabel`: `ModelRouter.contextWindowTokens` reads the Keychain via
    /// `active`). Drives ONLY the standing `contextFillFraction` ring, which may be read from a
    /// `body`; the per-turn budget (`askContextCharBudget`) reads the window LIVE in the async send
    /// path instead. Defaults to FM's 4K so the ring is sane before the first refresh.
    private(set) var activeContextWindowTokens: Int = 4_096

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
        activeContextWindowTokens = ModelRouter.contextWindowTokens   // Brief BN3 — cache for the ring
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

    /// Brief AA3 + BN3 — the ask context in up to THREE labelled sections, continuous numbering:
    /// `ENTRIES READ IN FULL` (BN3 — whole entries, the answer surface) → `ENTRIES ON THIS TOPIC`
    /// (cards, one line each — breadth) → `PASSAGES` (block excerpts — depth). Each section is
    /// omitted when empty. The read-in-full section leads because "find, then read": the whole
    /// entries are what the answer comes from; cards/passages are what FOUND the rest.
    private func buildAskContext(
        candidates: [NumberedCandidate],
        store: CorpusStore
    ) -> String {
        guard !candidates.isEmpty else { return "" }
        let reads = candidates.filter { $0.isEntryRead }
        let cards = candidates.filter { $0.isCard }
        let passages = candidates.filter { !$0.isCard && !$0.isEntryRead }
        var sections: [String] = []
        if !reads.isEmpty {
            let blocks = reads.compactMap { c -> String? in
                guard case .entry(let e) = c.payload else { return nil }
                return "\(Self.entryReadHeader(for: c, store: store))\n\(e.text)"
            }.joined(separator: "\n\n———\n\n")
            sections.append("ENTRIES READ IN FULL (the complete text of your most relevant entries — answer from these):\n\(blocks)")
        }
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

    /// Brief BN3 — the header for a full-entry read: `[n] <provenance> — <Title>[ (domain)] — read
    /// in full` (or `— PARTIAL: best excerpts of a long entry` when it didn't fit the budget, so the
    /// model knows the read is incomplete and never invents the missing part).
    private static func entryReadHeader(for c: NumberedCandidate, store: CorpusStore) -> String {
        guard case .entry(let e) = c.payload else { return "" }
        let (kind, domain) = provenance(for: c, store: store)
        let suffix = (kind == .savedLink) ? (domain.map { " (\($0))" } ?? "") : ""
        let tail = e.partial ? " — PARTIAL: best excerpts of a long entry" : " — read in full"
        return "[\(c.number)] \(provenanceLabel(kind)) — \(e.title)\(suffix)\(tail)"
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
