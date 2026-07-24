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
        enum Role: String, Codable { case user, assistant }

        /// A grounded-answer source: one cited passage, `index` = its `[n]` in the
        /// prompt's numbered passages. Piece 1 restores these as collapsible chips.
        struct Citation: Codable, Hashable, Identifiable {
            let index: Int
            let nodeID: String
            let title: String
            let snippet: String
            var id: Int { index }
        }

        let id: UUID
        let role: Role
        var text: String
        /// Grounded-Ask citations for an assistant turn. Nil for user turns,
        /// OPEN/partial answers, and plain chat. Optional → synthesized Codable
        /// uses decodeIfPresent, so legacy transcripts decode with `nil`
        /// (mirrors `Node.titleSource` / `isJournalEntry`).
        var citations: [Citation]?

        init(id: UUID = UUID(), role: Role, text: String, citations: [Citation]? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.citations = citations
        }
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

    /// One-shot FM title generation guard. Flipped to `true` the moment
    /// a title gen is dispatched (so a fast second turn doesn't double-
    /// fire) OR when an already-titled chat is loaded (don't overwrite
    /// titles the user has already seen). Reset to `false` in
    /// `reset()` / `startNew()`.
    @ObservationIgnored
    private var didGenerateTitle: Bool = false

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

        let prompt = buildPrompt(current: modelText)

        do {
            for try await delta in ModelRouter.generateStreaming(
                systemPrompt: systemPrompt,
                userPrompt: prompt
            ) {
                streamingText += delta
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
                messages.append(Message(role: .assistant, text: finalText, citations: citedOnly))
            }
        } catch {
            // Endpoint / network / discovery failure. Surface it as a
            // distinct, non-message failure state — NOT an assistant turn —
            // so the transcript stays clean of raw error strings. The
            // trailing `.user` message remains so retry can re-send it.
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = reason
        }

        streamingText = ""
        isStreaming = false

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
        guard let store, !messages.isEmpty else { return }
        let snapshotID = id
        let snapshotCreatedAt = createdAt
        let snapshotMessages = messages
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
        guard let recent = store.mostRecent() else { return }
        id = recent.id
        createdAt = recent.createdAt
        messages = recent.messages
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
