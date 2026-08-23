import Foundation
import Observation

/// Passage-free FM instrument. A separate chat lane that threads
/// conversation history WITHOUT corpus retrieval, so Apple FM's small
/// real context window isn't crowded out by injected chunks. The
/// Librarian path (`LibrarianState` → passage selection → `ModelRouter`)
/// stays untouched; this state lives in parallel and only renders prior
/// turns as plain "User: …\nAssistant: …" lines into the user prompt.
@MainActor
@Observable
final class ChatSession {

    struct Message: Identifiable, Hashable, Codable {
        /// `.activity` is a tool-loop phase row (web search / fetch), NOT a chat turn —
        /// rendered as a collapsible activity strip and skipped when building the
        /// model's message array. A String raw enum stays decode-safe: legacy
        /// transcripts never carry `.activity`.
        enum Role: String, Codable { case user, assistant, activity }

        /// A cited source, `index` = its `[n]` in the numbered context. ONE type, TWO
        /// source kinds: corpus (a `nodeID` → tap navigates to the node) OR web (a
        /// `url` → tap opens the page). Exactly one is set per citation. Both optional
        /// so the synthesized Codable is back-compatible: a legacy corpus transcript
        /// decodes `nodeID` (present) + `url` (decodeIfPresent → nil).
        struct Citation: Codable, Hashable, Identifiable {
            let index: Int
            let nodeID: String?
            let url: String?
            let title: String
            let snippet: String
            var id: Int { index }

            /// Corpus source — navigates to a node.
            init(index: Int, nodeID: String, title: String, snippet: String) {
                self.index = index; self.nodeID = nodeID; self.url = nil
                self.title = title; self.snippet = snippet
            }
            /// Web source — opens a real (scraped) URL.
            init(index: Int, url: String, title: String, snippet: String) {
                self.index = index; self.nodeID = nil; self.url = url
                self.title = title; self.snippet = snippet
            }
        }

        let id: UUID
        let role: Role
        var text: String
        /// Grounded-Ask citations for an assistant turn. Nil for user turns,
        /// OPEN/partial answers, and plain chat. Optional → synthesized Codable
        /// uses decodeIfPresent, so legacy transcripts decode with `nil`
        /// (mirrors `Node.titleSource` / `isJournalEntry`).
        var citations: [Citation]?
        /// Tool-loop activity payload for a `.activity` row (icon, label, the query/url,
        /// and the tappable links returned). Nil for chat turns. Optional →
        /// decodeIfPresent keeps legacy transcripts decoding with `nil`.
        var activity: ToolActivity?
        /// ★ BUG 36 — an assistant turn that stopped EARLY: the stream dropped
        /// mid-answer (the app backgrounded and iOS/CF severed the connection)
        /// so this text is what arrived before the drop, kept rather than
        /// discarded. The bubble renders a calm "Continue" affordance instead of
        /// a red failure banner. `nil`/`false` = a complete turn. Optional +
        /// synthesized Codable → legacy transcripts decode with `isPartial ==
        /// nil` (mirrors `citations` / `activity`).
        var isPartial: Bool?
        /// ★ BUG 36 Pillar 2 — the client-generated id under which the HOST is holding the
        /// full answer for this dropped turn. Set only on a Host partial; lets foreground
        /// (or a cold-launch restore) re-attach via `/v1/chat/resume` and replace the
        /// partial with the authoritative full answer. Optional + Codable → survives an app
        /// kill (D3) and decodes nil on legacy transcripts.
        var requestID: String?

        init(id: UUID = UUID(), role: Role, text: String, citations: [Citation]? = nil, activity: ToolActivity? = nil, isPartial: Bool? = nil, requestID: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.citations = citations
            self.activity = activity
            self.isPartial = isPartial
            self.requestID = requestID
        }
    }

    /// One tool phase in the private-mode web-search loop, rendered as a collapsible
    /// activity row. Reads by icon + label (colourblind-safe); `links` render tappable.
    struct ToolActivity: Codable, Hashable {
        var icon: String          // SF Symbol
        var label: String         // "Searched the web" / "Fetched a page"
        var detail: String?       // the query or the url
        var links: [ToolLink]     // tappable {title, url, snippet}
    }

    /// Identity of the current chat. Survives encode/decode so a
    /// resumed conversation upserts onto its own record rather than
    /// creating duplicates. Reset to a fresh UUID on `reset()`.
    var id: UUID = UUID()
    /// First-message wall-clock. Stable across resumes so the chats
    /// list (step 2) can group by day. Reset on `reset()`.
    var createdAt: Date = Date()

    /// Permanent transcript. Each completed turn appends one user message
    /// then one assistant message; `streamingText` is the in-flight tail
    /// that hasn't been committed yet.
    private(set) var messages: [Message] = []
    /// True while a response is streaming in. The view uses this to swap
    /// the send glyph for a streaming indicator and disable input.
    private(set) var isStreaming: Bool = false
    /// ★ BUG 36 Pillar 2 — true while auto-re-attaching to a HELD Host result on
    /// foreground (fetching the full answer to replace a dropped partial). Distinct
    /// from `isStreaming` (a new turn): the view shows a quiet "Resuming…" state on the
    /// partial bubble and disables input, without mounting a fresh streaming tail.
    private(set) var isResuming: Bool = false
    /// In-flight assistant delta. Drained into a new `.assistant` message
    /// at stream end and reset to "".
    private(set) var streamingText: String = ""
    /// Echoed back as a `.user` message the moment send() fires so the
    /// transcript shows the turn instantly while the model starts.
    private(set) var pendingUser: String? = nil
    /// Non-message failure state for the most recent send. Endpoint /
    /// network / model-discovery errors set this INSTEAD of being appended
    /// to `messages`, so the transcript never carries raw error strings.
    /// Rendered as a transient inline banner (with retry), not an assistant
    /// turn. Cleared when a new send starts, on `reset()`, and on
    /// `clearError()` / `retryLastUserTurn()`.
    private(set) var lastError: String? = nil

    /// Persistence seam. Wired once by AppRouter after both this session
    /// and the store exist. Weak so AppRouter remains the sole owner —
    /// no retain cycle between the singleton router and its child state.
    @ObservationIgnored
    weak var store: ChatStore?

    /// Cross-launch restore guard. Flipped to `true` on the first
    /// restore attempt OR on `reset()` so a fresh chat is never
    /// clobbered by a stale most-recent record.
    @ObservationIgnored
    private var didRestore: Bool = false

    /// Persisted id (uuidString) of the ACTIVE, unended chat. Set whenever a
    /// non-empty session is flushed (each turn + scene-background); CLEARED by
    /// `reset()` — which Save / Delete / New all route through. A cold launch
    /// resumes ONLY this chat, so a chat the user explicitly ended stays in the
    /// Chats list without coming back as a live active-chat pill. nil ⇒ no
    /// active chat ⇒ launch starts fresh. (Was: resume `mostRecent()`
    /// unconditionally, which resurrected a just-saved chat on relaunch.)
    private static let activeChatIDKey = "librarian.activeChatID"
    private static var persistedActiveChatID: String? {
        get { UserDefaults.standard.string(forKey: activeChatIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: activeChatIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeChatIDKey)
            }
        }
    }

    /// One-shot FM title generation guard. Flipped to `true` the moment
    /// a title gen is dispatched (so a fast second turn doesn't double-
    /// fire) OR when an already-titled chat is loaded (don't overwrite
    /// titles the user has already seen). Reset to `false` in
    /// `reset()` / `startNew()`.
    @ObservationIgnored
    private var didGenerateTitle: Bool = false

    /// ★ BUG 36 — stable identity for the assistant turn currently streaming.
    /// The incrementally-persisted partial (`flush()` during the stream), the
    /// partial committed if the stream drops, and any later continuation all
    /// carry THIS id, so they upsert onto one turn rather than duplicating.
    /// Re-minted at the start of every streamed turn.
    @ObservationIgnored
    private var streamingMessageID = UUID()

    /// ★ BUG 36 Pillar 2 — the requestID of the turn currently streaming over the Host
    /// path (nil for FM/Ollama or when no turn is in flight). `flush()` tags the persisted
    /// in-flight partial with it, so an app KILL mid-stream restores a partial that still
    /// knows how to resume (D3). Cleared at turn end.
    @ObservationIgnored
    private var currentRequestID: String?

    /// Coalesce incremental partial persistence to ~this many newly-streamed
    /// characters (BUG 36) — durable-as-it-arrives without a per-token disk
    /// write. The `.background` flush (ChatView) captures whatever remains the
    /// instant the app leaves the foreground, which is the measured drop
    /// trigger; this threshold only adds crash/kill safety between backgroundings.
    private static let partialPersistThreshold = 240

    static let systemPrompt = """
    You are a thoughtful conversational assistant. The user is thinking out loud \
    and will ask follow-up questions that depend on earlier turns — always take \
    the full conversation into account. Be specific and concise; avoid generic \
    filler.

    The user's questions may contain false or leading premises. Before agreeing \
    with a claim embedded in a question, evaluate whether it's actually true. If \
    the premise is shaky, oversimplified, or wrong, say so directly before \
    answering — do not affirm a framing just because the user stated it \
    confidently. It is more helpful to correct a wrong assumption than to be \
    agreeable.
    """

    /// Send a user message. Renders prior turns + the new prompt through
    /// `ModelRouter.generateStreaming` and streams the response into
    /// `streamingText`, then commits.
    func send(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await send(displayText: trimmed, modelText: trimmed, systemPrompt: Self.systemPrompt)
    }

    /// Streams a caller-composed turn. `displayText` is the transcript bubble;
    /// `modelText` is the current-turn text handed to the model (woven with prior
    /// turns by `buildPrompt`); `systemPrompt` steers it. ChatSession stays a dumb
    /// lane — it appends the bubble, streams, and persists; it does NOT retrieve
    /// or build the grounded prompt (LibrarianState owns that — step 3/Ask hybrid).
    func send(displayText: String, modelText: String, systemPrompt: String, citations: [Message.Citation]? = nil) async {
        guard !displayText.isEmpty, !isStreaming else { return }

        // New attempt clears any prior transient failure banner.
        lastError = nil
        messages.append(Message(role: .user, text: displayText))
        pendingUser = nil
        isStreaming = true
        streamingText = ""

        streamingMessageID = UUID()
        // ★ BUG 36 Pillar 2 — a HOST turn gets a client-generated requestID (D1) so a
        // mid-stream drop can be RESUMED (the Host holds the full answer). Only the host
        // path uses it; FM/Ollama ignore it. `currentRequestID` lets flush() tag a partial
        // that survives an app KILL (D3), so a cold-launch restore can still re-attach.
        let hostRequestID: String? = { if case .host = ModelRouter.active { return UUID().uuidString } else { return nil } }()
        currentRequestID = hostRequestID
        let prompt = buildPrompt(current: modelText)

        // ★ BUG 36 — incremental delta persistence. The partial is made durable
        // AS IT ARRIVES (coalesced by `partialPersistThreshold`), so a mid-stream
        // background / drop / kill never loses what's already on screen. `flush()`
        // folds the in-flight `streamingText` into the persisted snapshot.
        var lastPersistedLength = 0
        do {
            for try await delta in ModelRouter.generateStreaming(
                systemPrompt: systemPrompt,
                userPrompt: prompt,
                requestID: hostRequestID
            ) {
                streamingText += delta
                if streamingText.count - lastPersistedLength >= Self.partialPersistThreshold {
                    lastPersistedLength = streamingText.count
                    flush()
                }
            }
            let finalText = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                // Keep ONLY the sources the answer actually cited inline ([n]).
                // Retrieval hands over candidates; a passage becomes a citation
                // only when the prose references it — so a turn that ignores the
                // passages (or answers from general knowledge) can't render
                // phantom "sources" under it (BUG 7 / Part 2).
                let citedOnly: [Message.Citation]? = citations.flatMap { candidates in
                    let used = CitationReference.citedIndices(in: finalText)
                    let kept = candidates.filter { used.contains($0.index) }
                    return kept.isEmpty ? nil : kept
                }
                messages.append(Message(id: streamingMessageID, role: .assistant, text: finalText, citations: citedOnly))
            }
        } catch {
            // ★ BUG 36 — do NOT discard the partial. A mid-stream drop (the app
            // backgrounded and iOS/CF severed the stream) previously threw away
            // everything already streamed and showed a red banner — the measured
            // "already-streamed text entirely LOST." Instead KEEP what arrived as
            // a PARTIAL assistant turn (no banner); the bubble offers "Continue".
            // Only when NOTHING streamed do we surface a failure banner, so a
            // genuine unreachable-Host error is still visible (and the trailing
            // `.user` message remains so retry can re-send it).
            let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                // Carry the requestID so foreground / relaunch can fetch the FULL answer.
                messages.append(Message(id: streamingMessageID, role: .assistant, text: partial, isPartial: true, requestID: hostRequestID))
            } else {
                // Nothing streamed — a genuine failure. Classify it into a human
                // banner (field findings #2/#3): unreachable/530 reads as "offline
                // or asleep", and raw upstream HTML is never shown.
                lastError = Self.humanError(for: error)
            }
        }

        streamingText = ""
        isStreaming = false
        currentRequestID = nil

        // Turn boundary — persist now that the assistant message is
        // committed. Not per-token: the store coalesces nothing today
        // but per-turn keeps the disk write count proportional to user
        // intent rather than to streaming chunk count.
        flush()

        // After the first complete turn (user + assistant), fire a
        // background title generation. Guarded so it runs at most once
        // per chat; the next send() in this chat is a no-op for this
        // path. Runs detached so it never blocks the next user turn.
        scheduleTitleGenerationIfNeeded()

        // ★ BUG 36 Pillar 2 — if this turn dropped into a resumable Host partial, try to
        // re-attach right now. This covers the ordering where the drop's `catch` runs AFTER
        // the app has already returned to the foreground; the scenePhase `.active` hook
        // (ChatView) covers the reverse order. `resumeHeldIfNeeded` is idempotent + guarded.
        if let last = messages.last, last.role == .assistant, last.isPartial == true, last.requestID != nil {
            await resumeHeldIfNeeded()
        }
    }

    /// ★ Agentic web-search turn (PRIVATE MODE + REMOTE ENDPOINT only). Runs the
    /// OpenAI tool-calling loop: send the user turn WITH the tool schema; if the
    /// model answers normally it streams as today; if it emits tool_calls, run each
    /// via the injected `ToolExecutor` (the seam), append a collapsible activity row,
    /// feed results back as tool-role messages, and repeat — capped at `maxToolSteps`
    /// against an infinite loop. The OpenAI messages working-set is kept SEPARATE from
    /// the display transcript (which owns rendering + persistence): the transcript gets
    /// the user bubble, one activity row per phase, and the final answer.
    func sendWithTools(displayText: String, systemPrompt: String, executor: ToolExecutor) async {
        guard !displayText.isEmpty, !isStreaming else { return }
        guard case .ollama(let endpoint) = ModelRouter.active else {
            // Caller guarantees remote; defensive fallback to plain chat.
            await send(displayText: displayText, modelText: displayText, systemPrompt: systemPrompt)
            return
        }

        lastError = nil
        messages.append(Message(role: .user, text: displayText))
        pendingUser = nil
        isStreaming = true
        streamingText = ""

        let maxToolSteps = 5
        // Declared outside `do` so the `catch` can read it (Swift scoping).
        var producedActivity = false

        do {
            let model = try await ModelRouter.firstModelID(endpoint: endpoint)

            // OpenAI working-set (system + prior chat turns + this turn). Activity
            // rows are display-only — skipped here.
            var working: [[String: Any]] = [["role": "system", "content": systemPrompt]]
            for m in messages.dropLast() where m.role == .user || m.role == .assistant {
                working.append(["role": m.role == .user ? "user" : "assistant", "content": m.text])
            }
            working.append(["role": "user", "content": displayText])

            var finalAnswer = ""
            // Accumulates web_search result links across the turn, GLOBALLY numbered,
            // so the answer's cited [n] maps unambiguously to its {title, url}.
            var citationLinks: [ToolLink] = []
            // Whether any tool reported a provider throttle this turn — used only to
            // word the give-up message honestly (the cap/backoff live in the executor).
            var sawRateLimit = false
            // Whether any tool reported it has NO backend (web search with no Brave key).
            // Once true, the tool schema is WITHHELD from the next model turn so the model
            // can't retry a tool that cannot succeed — one attempt, one honest chip.
            var sawUnavailable = false
            for step in 0..<maxToolSteps {
                streamingText = ""
                let turn = try await ModelRouter.streamAgentTurn(
                    endpoint: endpoint,
                    model: model,
                    messages: working,
                    // Withhold the tool schema once a tool reported it has no backend — the
                    // model can't retry a tool that can't succeed, so it answers honestly.
                    tools: sawUnavailable ? nil : AgentTools.schema,
                    onContentDelta: { [weak self] delta in
                        Task { @MainActor in self?.streamingText += delta }
                    }
                )

                if turn.toolCalls.isEmpty {
                    finalAnswer = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }

                // Record the assistant tool-call turn in the OpenAI working-set.
                working.append([
                    "role": "assistant",
                    "content": turn.content,
                    "tool_calls": turn.toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.argumentsJSON]]
                    }
                ])
                streamingText = ""

                // Run each tool through the seam; show an activity row; feed results back.
                for call in turn.toolCalls {
                    let result = await executor.execute(name: call.name, arguments: call.arguments)
                    appendActivity(for: call, result: result)
                    producedActivity = true
                    if result.rateLimited { sawRateLimit = true }
                    if result.unavailable { sawUnavailable = true }
                    // Web results feed the answer's citations. Renumber GLOBALLY across
                    // the turn so the model's [n] is unambiguous even across multiple
                    // searches, and accumulate so cited [n] → {title, url}.
                    let toolContent: String
                    if call.name == AgentTools.webSearch, !result.links.isEmpty {
                        let start = citationLinks.count
                        toolContent = result.links.enumerated().map { i, l in
                            "[\(start + i + 1)] \(l.title)\n\(l.url)\n\(l.snippet ?? "")"
                        }.joined(separator: "\n\n")
                        citationLinks.append(contentsOf: result.links)
                    } else {
                        toolContent = result.textForModel
                    }
                    working.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": toolContent
                    ])
                }

                if step == maxToolSteps - 1 {
                    // Loop backstop (the model never settled on an answer). Word it by
                    // CAUSE: a throttle reads as honest degradation, not surrender.
                    finalAnswer = sawRateLimit
                        ? "Web search is temporarily rate-limited right now, so I couldn't pull fresh sources for this. Please try again in a little while — or ask me to answer from what I already know."
                        : "I reached the tool-step limit (\(maxToolSteps)) for this question. Here's what I have so far — ask me to continue if you'd like."
                }
            }

            streamingText = ""
            if !finalAnswer.isEmpty {
                // ★ Gate chips to CITED, not searched (the corpus rule via the SAME
                // `citedIndices` parser): attach a web citation ONLY for the [n] the
                // answer actually referenced, each mapped to its real scraped URL. No
                // [n] → no footer, exactly like corpus.
                let cited = CitationReference.citedIndices(in: finalAnswer)
                let webCitations: [Message.Citation] = cited.sorted().compactMap { n in
                    guard n >= 1, n <= citationLinks.count else { return nil }
                    let link = citationLinks[n - 1]
                    return Message.Citation(index: n, url: link.url, title: link.title, snippet: link.snippet ?? "")
                }
                messages.append(Message(role: .assistant, text: finalAnswer,
                                        citations: webCitations.isEmpty ? nil : webCitations))
            }
        } catch {
            // Degrade SILENTLY if the FIRST turn failed (e.g. the endpoint/model
            // doesn't advertise tool support and 400s on the `tools` param): drop the
            // user bubble and re-run as a normal chat turn — no tools, no error. If a
            // tool already ran (mid-loop failure), keep the activity rows and surface
            // the error banner instead of silently discarding the work.
            if !producedActivity, messages.last?.role == .user {
                messages.removeLast()
                streamingText = ""
                isStreaming = false
                await send(displayText: displayText, modelText: displayText, systemPrompt: systemPrompt)
                return
            }
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        streamingText = ""
        isStreaming = false
        flush()
        scheduleTitleGenerationIfNeeded()
    }

    /// Append a collapsible activity row for one completed tool call.
    private func appendActivity(for call: ToolCall, result: ToolResult) {
        let icon: String
        let label: String
        let detail: String?
        switch call.name {
        case AgentTools.webSearch:
            icon = "magnifyingglass"
            if result.unavailable {
                // NOTHING searched — the backend isn't configured. Reuse the executor's own
                // factual line so the chip AGREES with the model's prose (never "no results",
                // which would assert a search that never happened).
                label = result.textForModel
            } else {
                label = result.links.isEmpty ? "Searched the web — no results" : "Searched the web"
            }
            detail = call.arguments["query"] as? String
        case AgentTools.fetchURL:
            icon = "doc.text"
            label = "Fetched a page"
            detail = call.arguments["url"] as? String
        default:
            icon = "wrench.and.screwdriver"
            label = "Ran \(call.name)"
            detail = nil
        }
        messages.append(Message(
            role: .activity,
            text: label,
            activity: ToolActivity(icon: icon, label: label, detail: detail, links: result.links)
        ))
    }

    #if DEBUG
    /// Headless verification hook — inject a settled assistant turn (used to prove
    /// model-authored inline URLs render de-linked / plain).
    func debugAppendAssistant(_ text: String) {
        messages.append(Message(role: .assistant, text: text))
    }

    /// Headless verification hook (BUG 36) — inject a user turn + a PARTIAL
    /// assistant turn (the stream dropped mid-answer) so `-Screen` can shoot the
    /// calm "Stopped early / Continue" affordance — NOT a red failure banner —
    /// without driving a live mid-stream background.
    func debugAppendPartialTurn(user: String, partial: String) {
        messages.append(Message(role: .user, text: user))
        messages.append(Message(role: .assistant, text: partial, isPartial: true))
    }

    /// Headless verification hook (BUG 36 Pillar 2) — inject a partial turn AND flip the
    /// auto-re-attach state, so `-Screen` can shoot the quiet "Resuming…" bubble that
    /// replaces "Stopped early / Continue" while the held answer is being fetched.
    func debugSetResuming(user: String, partial: String) {
        messages.append(Message(role: .user, text: user))
        messages.append(Message(role: .assistant, text: partial, isPartial: true, requestID: "debug"))
        isResuming = true
    }

    /// Headless verification hook — inject a web answer + its CITED chips, using the
    /// SAME `citedIndices` gating as the live loop, so `-Screen` can prove chips gate
    /// to cited (not searched).
    func debugAppendWebAnswer(_ text: String, links: [ToolLink]) {
        let cited = CitationReference.citedIndices(in: text)
        let cites: [Message.Citation] = cited.sorted().compactMap { n in
            guard n >= 1, n <= links.count else { return nil }
            let l = links[n - 1]
            return Message.Citation(index: n, url: l.url, title: l.title, snippet: l.snippet ?? "")
        }
        messages.append(Message(role: .assistant, text: text, citations: cites.isEmpty ? nil : cites))
    }

    /// Headless verification hook — inject a completed activity row (from a REAL
    /// executor run) so `-Screen` can screenshot the scrape + the collapsible row
    /// without a live LM Studio loop.
    func debugAppendActivity(icon: String, label: String, detail: String?, links: [ToolLink]) {
        messages.append(Message(role: .activity, text: label,
                                activity: ToolActivity(icon: icon, label: label, detail: detail, links: links)))
    }
    #endif

    // MARK: - Failure presentation (BUG 36 field findings #2 / #3)

    /// Turn a raw send failure into a calm, human banner. Field findings from the
    /// device test: (#2) a 530 / unreachable / network-lost error means the Host
    /// Mac is offline or asleep — say THAT, not a status code; (#3) NEVER render
    /// raw upstream HTML (a Cloudflare 530 body is a full HTML page) in the
    /// banner. Reached only when NOTHING streamed — a mid-stream drop that
    /// already has partial text is kept as a partial turn (no banner), see send().
    static func humanError(for error: Error) -> String {
        let offline = "Your computer appears to be offline or asleep. Make sure the AirPad Host is running on it, then try again."

        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .timedOut, .secureConnectionFailed:
                return offline
            default:
                // A URLError we don't specifically classify — its own description
                // is already human (and never HTML).
                return urlError.localizedDescription
            }
        }

        if let routerError = error as? ModelRouter.RouterError {
            switch routerError {
            case .ollamaTransport:
                // Couldn't reach the endpoint at all — same human meaning.
                return offline
            case .ollamaHTTPError(_, let status, let body):
                // 530 (Cloudflare: origin unreachable — tunnel down / Mac asleep)
                // and the 502/503/504 gateway family read, to a person, as "the
                // computer isn't answering."
                if status == 530 || (502...504).contains(status) { return offline }
                // Any other HTTP error: show the status, but strip the body FIRST
                // so a raw HTML error page can never reach the banner (#3).
                let clean = Self.sanitizedErrorBody(body)
                return clean.isEmpty
                    ? "Your computer's model returned an error (HTTP \(status))."
                    : "Your computer's model returned an error (HTTP \(status)): \(clean)"
            default:
                return routerError.errorDescription ?? offline
            }
        }

        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Strip HTML (#3) so an error page never renders as raw markup in the
    /// banner. Reuses the app's readability helpers (`WebReadability`), collapses
    /// whitespace, and caps length. Empty → the caller shows a status-only line.
    private static func sanitizedErrorBody(_ body: String) -> String {
        let looksHTML = body.range(of: "<[a-zA-Z!/]", options: .regularExpression) != nil
        var s = looksHTML ? WebReadability.decodeEntities(WebReadability.stripTags(body)) : body
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    /// Dismiss the transient failure banner without retrying.
    func clearError() {
        lastError = nil
    }

    /// Re-attempt the most recent user turn after a failed send. On error we
    /// never appended an assistant turn, so the trailing entry is still that
    /// user message — pop it and re-send its text through the normal path so
    /// there's no duplicate user bubble. No-op mid-stream.
    func retryLastUserTurn() async {
        guard !isStreaming, let last = messages.last, last.role == .user else {
            lastError = nil
            return
        }
        messages.removeLast()
        await send(last.text)
    }

    /// Re-run the most recent exchange. Pops the trailing assistant turn and
    /// the user turn beneath it, then re-sends that user text through the
    /// normal path (send() re-appends the user message). No-op mid-stream or
    /// if the transcript doesn't end in an assistant turn. Does NOT reset
    /// `didGenerateTitle` — the chat is already titled and send()'s title
    /// hook is a no-op once that guard is set, so regenerate never re-titles.
    func regenerateLast() async {
        guard !isStreaming else { return }
        guard messages.count >= 2,
              messages.last?.role == .assistant,
              messages[messages.count - 2].role == .user else { return }
        messages.removeLast()               // assistant
        let userText = messages.removeLast().text
        await send(userText)
    }

    // MARK: - Host re-attach (BUG 36 Pillar 2 — the true walk-away)

    /// ★ Automatic re-attach on foreground / relaunch. If the transcript ends in a HOST
    /// partial turn (dropped mid-stream) carrying a `requestID`, and that Host is still
    /// paired, fetch the HELD full answer over `/v1/chat/resume` and REPLACE the partial
    /// with it — the true walk-away (background through the ENTIRE generation → return →
    /// complete answer waiting). The Host replays from start, so the resumed text passes
    /// through the partial's exact prefix; we GROW-ONLY the bubble (the shown text never
    /// shrinks → no flicker), then clear `isPartial`. A 404 (held expired/consumed) or any
    /// error leaves the partial + its "Continue" re-prompt fallback intact — never a
    /// banner. Idempotent + guarded (safe to call from both scenePhase and send()).
    func resumeHeldIfNeeded() async {
        guard !isStreaming, !isResuming else { return }
        guard let last = messages.last, last.role == .assistant,
              last.isPartial == true, let requestID = last.requestID else { return }
        guard case .host(let pairing) = ModelRouter.active else { return }
        let partialID = last.id
        let shownHead = last.text

        isResuming = true            // set BEFORE the first await so a concurrent call no-ops
        defer { isResuming = false }

        var resumed = ""
        do {
            for try await delta in ModelRouter.resumeHostStream(pairing: pairing, requestID: requestID) {
                resumed += delta
                // Grow-only: the held answer's prefix == what we already showed, so extend
                // only once resume surpasses the partial. Re-find by id each time (a reset /
                // load may have removed it → stop safely).
                guard let i = messages.firstIndex(where: { $0.id == partialID }) else { return }
                if resumed.count > messages[i].text.count {
                    messages[i].text = resumed
                }
            }
            // Completed — install the authoritative full answer + mark it complete.
            let finalText = resumed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let i = messages.firstIndex(where: { $0.id == partialID }) else { return }
            if !finalText.isEmpty {
                messages[i].text = finalText
                messages[i].isPartial = nil
                messages[i].requestID = nil
                flush()
            }
        } catch {
            // 404 (held gone) or transport error → keep the partial + the "Continue"
            // fallback, silently. Restore the shown head if a truncated resume grew it.
            if let i = messages.firstIndex(where: { $0.id == partialID }),
               messages[i].isPartial == true, messages[i].text.count < shownHead.count {
                messages[i].text = shownHead
            }
        }
    }

    /// ★ BUG 36 — resume a turn that STOPPED EARLY. When the stream dropped
    /// mid-answer (app backgrounded), `send()` kept the arrived text as a
    /// trailing `isPartial` assistant turn. "Continue" re-prompts the model with
    /// the conversation + that partial and MERGES the continuation onto the same
    /// bubble, clearing the partial flag on success. This is the iOS-side
    /// interim resume: a re-prompt, NOT a byte-exact splice of the original
    /// generation — that is the Host finish-and-hold + resume arc (next). No-op
    /// unless the transcript ends in a partial assistant turn preceded by its
    /// user turn. Regenerate remains the robust fallback if a continuation drifts.
    func continuePartial() async {
        guard !isStreaming,
              let last = messages.last,
              last.role == .assistant,
              last.isPartial == true,
              messages.count >= 2,
              messages[messages.count - 2].role == .user else { return }

        let head = last.text
        lastError = nil
        isStreaming = true
        streamingText = ""
        streamingMessageID = last.id   // continuation upserts onto the same turn

        let prompt = buildContinuationPrompt(partialHead: head)
        do {
            for try await delta in ModelRouter.generateStreaming(
                systemPrompt: Self.systemPrompt,
                userPrompt: prompt
            ) {
                streamingText += delta
            }
            mergeContinuation(tail: streamingText, complete: true)
        } catch {
            // Dropped AGAIN — keep whatever extra arrived and stay partial so the
            // user can resume once more. Nothing new streamed → the turn is left
            // exactly as it was (still resumable), no banner.
            mergeContinuation(tail: streamingText, complete: false)
        }

        streamingText = ""
        isStreaming = false
        flush()
    }

    /// Merge a continuation `tail` onto the trailing partial assistant turn.
    /// `complete` clears the partial flag; otherwise the turn stays resumable.
    private func mergeContinuation(tail: String, complete: Bool) {
        guard let idx = messages.indices.last, messages[idx].role == .assistant else { return }
        var merged = messages[idx]
        merged.text = Self.spliceContinuation(head: merged.text, tail: tail)
        // Clear the flag only on a clean finish; a re-dropped continuation stays
        // partial (nil vs true, never false — a "complete" turn just has no flag).
        merged.isPartial = complete ? nil : true
        messages[idx] = merged
    }

    /// Join a continuation onto a partial head. The drop lands at a token
    /// boundary, so a bare concat is usually right; insert a single space only
    /// when both sides are letters (avoids gluing two words) — the common case
    /// where the model resumes at the next word without a leading space.
    private static func spliceContinuation(head: String, tail: String) -> String {
        guard !tail.isEmpty else { return head }
        let needsSpace = (head.last?.isLetter ?? false) && (tail.first?.isLetter ?? false)
        return needsSpace ? head + " " + tail : head + tail
    }

    /// Continuation prompt — the folded conversation ending on the partial
    /// assistant text (no fresh "Assistant:" mid-cue), then an explicit
    /// continue-from-here instruction. Mirrors `buildPrompt`'s User:/Assistant:
    /// format so every provider (FM one-shot, Ollama/Host SSE) reads it the same.
    private func buildContinuationPrompt(partialHead: String) -> String {
        var lines: [String] = []
        for m in messages.dropLast() where m.role == .user || m.role == .assistant {
            lines.append(m.role == .user ? "User: \(m.text)" : "Assistant: \(m.text)")
        }
        lines.append("Assistant: \(partialHead)")
        lines.append("")
        lines.append("[The assistant's answer above was cut off. Continue it from exactly where it stopped — do not repeat any of it, do not restate the question, just continue the text.]")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }

    /// Render the prior transcript + the new user turn as a single text
    /// blob. Provider-agnostic — works on FM (one chunk) and Ollama (SSE)
    /// identically. No passages, no retrieval, no citations.
    private func buildPrompt(current: String) -> String {
        var lines: [String] = []
        for m in messages.dropLast() {
            lines.append(m.role == .user ? "User: \(m.text)" : "Assistant: \(m.text)")
        }
        lines.append("User: \(current)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }

    /// Wipe the transcript. Used by the "New chat" affordance. Flushes
    /// the in-flight chat to the store BEFORE wiping so the prior
    /// conversation survives the new-chat boundary; then resets identity
    /// so the next turn starts a brand-new record.
    func reset() {
        flush()
        messages = []
        streamingText = ""
        pendingUser = nil
        isStreaming = false
        lastError = nil
        id = UUID()
        createdAt = Date()
        // A fresh chat must not be replaced by the most-recent record
        // on the next ChatView appearance — mark restore consumed.
        didRestore = true
        // Fresh chat → its first complete turn should trigger a new
        // title generation.
        didGenerateTitle = false
        // Ended (Save / Delete / New): no active chat to resume next launch.
        // The flush() above already persisted the outgoing chat to the Chats
        // list; clearing the pointer keeps it there without resurrecting it.
        Self.persistedActiveChatID = nil
    }

    // MARK: - Chats-list handoff

    /// Switch the live session to an existing chat record. Flushes the
    /// current chat first so switching never loses an in-progress
    /// conversation; then hydrates id / createdAt / messages from the
    /// stored record. `didRestore` is marked consumed so the
    /// most-recent-on-launch path can't reach in and clobber a chat the
    /// user has just explicitly opened.
    func load(_ chat: Chat) {
        flush()
        id = chat.id
        createdAt = chat.createdAt
        messages = chat.messages
        streamingText = ""
        pendingUser = nil
        isStreaming = false
        didRestore = true
        // Opening an existing chat must not regenerate its title — the
        // user has already seen the FM (or fallback) title in the list
        // and overwriting it on every reopen would be churn.
        didGenerateTitle = true
        // The opened chat is now the active session → resume it next launch.
        Self.persistedActiveChatID = id.uuidString
    }

    /// "New chat" affordance. Identical to `reset()` — kept as a named
    /// entry point so call sites (Chats list "+" button, future entry
    /// points) read intent rather than mechanism.
    func startNew() {
        reset()
    }

    // MARK: - Persistence seam (ChatStore)

    /// Upsert the current chat into the store and write to disk.
    /// No-op when the session is empty or the store hasn't been wired.
    ///
    /// Snapshot the live state, then BUILD THE CHAT RECORD INSIDE the
    /// Task — not before it. Building eagerly with `updatedAt = Date()`
    /// and writing inside a lagging Task lets a late flush land AFTER
    /// a freshly-arrived FM title update, which previously clobbered
    /// the title (the "appears then reverts" bug). Building at write
    /// time keeps the timestamp honest; `ChatStore.upsert` additionally
    /// refuses to touch `title` on existing-id updates so this race is
    /// also closed at the store layer (belt + suspenders).
    func flush() {
        // ★ BUG 36 — fold the in-flight partial into the persisted snapshot. The
        // live tail lives in `streamingText` (not `messages`) for render
        // isolation; persistence needs it too, so a background / drop / kill
        // mid-stream keeps what's on screen. Keyed by the stable
        // `streamingMessageID` so a later completion or continuation upserts onto
        // the SAME turn (no duplicate) rather than appending a second bubble.
        var snapshotMessages = messages
        if isStreaming {
            let partial = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                // Tag with the live requestID (D3) so an app KILL mid-stream restores a
                // partial that still knows how to resume the held answer on next launch.
                snapshotMessages.append(Message(id: streamingMessageID, role: .assistant, text: partial, isPartial: true, requestID: currentRequestID))
            }
        }
        guard let store, !snapshotMessages.isEmpty else { return }
        // This non-empty session IS the active chat — mark it so a cold launch
        // resumes it. Cleared by reset() when the user ends the chat.
        Self.persistedActiveChatID = id.uuidString
        let snapshotID = id
        let snapshotCreatedAt = createdAt
        Task {
            let chat = Chat(
                id: snapshotID,
                title: Self.truncationTitle(from: snapshotMessages),
                createdAt: snapshotCreatedAt,
                updatedAt: Date(),
                messages: snapshotMessages
            )
            store.upsert(chat)
            await store.save()
        }
    }

    /// One-shot resume on first ChatView appearance. If the live session
    /// is empty (cold launch, no prior in-app activity) and the store
    /// holds a most-recent chat, hydrate this session from it so the
    /// user lands back in their last conversation. Guarded by
    /// `didRestore` so it never clobbers an in-progress session.
    func restoreIfNeededFromStore() async {
        guard !didRestore, !isStreaming, messages.isEmpty, let store else { return }
        didRestore = true
        await store.loadIfNeeded()
        // Resume ONLY the explicitly-active (unended) chat. Save / Delete / New
        // route through reset(), which clears the pointer — so an ended chat
        // stays in the Chats list without returning as a live session. No
        // pointer (fresh launch, or last chat was ended) ⇒ start empty.
        guard let activeID = Self.persistedActiveChatID,
              let chat = store.chats.first(where: { $0.id.uuidString == activeID }) else { return }
        id = chat.id
        createdAt = chat.createdAt
        messages = chat.messages
    }

    /// Header / list display title. Reads the stored title from
    /// `ChatStore` for this chat's id — the FM title once it lands,
    /// otherwise the insert-time truncation. Falls back to the live
    /// truncation for a brand-new chat not yet flushed, and finally
    /// to "Chat" for an empty session. Observable: when
    /// `chatStore.updateTitle` lands, this getter re-reads through the
    /// observable `chats` array and SwiftUI updates the header.
    var displayTitle: String {
        if let store,
           let stored = store.chats.first(where: { $0.id == id }) {
            let t = stored.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let derived = Self.truncationTitle(from: messages)
        return derived.isEmpty ? "Chat" : derived
    }

    /// Truncation-fallback title — first user message clipped to ~40
    /// chars. Used at INSERT time as the seed for a new chat in the
    /// store; after that, title is owned solely by
    /// `ChatStore.updateTitle(id:title:)`. Static so `flush()` can
    /// compute it from a captured message snapshot inside a Task.
    private static func truncationTitle(from messages: [Message]) -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "" }
        let t = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    // MARK: - FM title generation (background, refusal-safe)

    /// Fire-once trigger run after the first turn commits. Captures the
    /// first user + assistant texts and the current chat id, marks the
    /// guard immediately, then dispatches a detached Task so the title
    /// call doesn't sit on the MainActor's queue or hold up the next
    /// user turn. The store hop on success is async (@MainActor); a
    /// failure / refusal / no-op leaves the fallback title intact.
    private func scheduleTitleGenerationIfNeeded() {
        guard !didGenerateTitle else { return }
        guard let firstUser = messages.first(where: { $0.role == .user })?.text else { return }
        guard let firstAssistant = messages.first(where: { $0.role == .assistant })?.text else { return }
        didGenerateTitle = true
        let chatID = self.id
        let storeRef = store
        Task.detached(priority: .utility) {
            await Self.generateTitle(
                chatID: chatID,
                firstUser: firstUser,
                firstAssistant: firstAssistant,
                store: storeRef
            )
        }
    }

    private static let titleSystemPrompt = """
    You write short, specific titles. Output ONLY the title — 3 to 6 words, no \
    quotes, no punctuation at the end, no preamble. If you cannot, output nothing.
    """

    /// Static so the detached Task captures only primitives + a weak
    /// store reference — no `self`. All FM errors / sanitizer rejections
    /// are silent: the existing truncation fallback in the store stays.
    private static func generateTitle(
        chatID: UUID,
        firstUser: String,
        firstAssistant: String,
        store: ChatStore?
    ) async {
        let userExcerpt = String(firstUser.prefix(500))
        let assistantExcerpt = String(firstAssistant.prefix(500))
        let userPrompt = """
        Title this conversation:

        User: \(userExcerpt)
        Assistant: \(assistantExcerpt)
        """
        do {
            let raw = try await ModelRouter.generate(
                systemPrompt: titleSystemPrompt,
                userPrompt: userPrompt
            )
            guard let cleaned = sanitizeTitleCandidate(raw) else { return }
            await store?.updateTitle(id: chatID, title: cleaned)
        } catch {
            // Silent no-op — refusal/error is expected (~18%); the
            // truncation fallback already in the store stays put.
        }
    }

    /// Conservative sanitizer / validator. Strips quotes + trailing
    /// punctuation, takes first line only, caps length. Rejects (returns
    /// nil) on empty, refusal-prefix prose, >10 words, or a long
    /// sentence-shaped result. When unsure, reject → keep the fallback.
    private static func sanitizeTitleCandidate(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // First line only — guards against multi-paragraph refusals
        // that happen to start with a plausible-looking phrase.
        if let firstLine = s.split(whereSeparator: { $0.isNewline }).first {
            s = String(firstLine)
        }
        // Strip surrounding ASCII + curly quotes / backticks.
        let quoteSet = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}")
        s = s.trimmingCharacters(in: quoteSet)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse internal whitespace runs to single spaces.
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.isEmpty { return nil }
        // Refusal-prose sentinels.
        let lower = s.lowercased()
        let refusalPrefixes = [
            "i'm sorry", "im sorry", "i am sorry",
            "i cannot", "i can't", "i can not",
            "as an", "as a language model",
            "sure,", "here is", "here's", "title:"
        ]
        for p in refusalPrefixes {
            if lower.hasPrefix(p) { return nil }
        }
        // Word-count cap — 3–6 was asked for; allow a little slack but
        // anything >10 is prose, not a title.
        let words = s.split(whereSeparator: { $0.isWhitespace })
        if words.count > 10 { return nil }
        // Long sentence-shaped result — probably explanatory text.
        if s.hasSuffix(".") && s.count > 40 { return nil }
        // Drop trailing punctuation per the system prompt instruction.
        while let last = s.last, ".!?;:,".contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 48 { s = String(s.prefix(48)) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tiny / pure-punctuation results — reject.
        if s.count < 2 { return nil }
        return s
    }
}
