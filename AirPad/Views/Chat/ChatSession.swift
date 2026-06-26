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
        let id: UUID
        let role: Role
        var text: String

        init(id: UUID = UUID(), role: Role, text: String) {
            self.id = id
            self.role = role
            self.text = text
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
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(Message(role: .user, text: trimmed))
        pendingUser = nil
        isStreaming = true
        streamingText = ""

        let prompt = buildPrompt(current: trimmed)

        do {
            for try await delta in ModelRouter.generateStreaming(
                systemPrompt: Self.systemPrompt,
                userPrompt: prompt
            ) {
                streamingText += delta
            }
            let finalText = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                messages.append(Message(role: .assistant, text: finalText))
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(Message(role: .assistant, text: "⚠️ \(reason)"))
        }

        streamingText = ""
        isStreaming = false

        // Turn boundary — persist now that the assistant message is
        // committed. Not per-token: the store coalesces nothing today
        // but per-turn keeps the disk write count proportional to user
        // intent rather than to streaming chunk count.
        flush()
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
        id = UUID()
        createdAt = Date()
        // A fresh chat must not be replaced by the most-recent record
        // on the next ChatView appearance — mark restore consumed.
        didRestore = true
    }

    // MARK: - Persistence seam (ChatStore)

    /// Upsert the current chat into the store and write to disk.
    /// No-op when the session is empty or the store hasn't been wired.
    func flush() {
        guard let store else { return }
        guard !messages.isEmpty else { return }
        let chat = buildChatRecord()
        Task {
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

    private func buildChatRecord() -> Chat {
        Chat(
            id: id,
            title: derivedTitle(),
            createdAt: createdAt,
            updatedAt: Date(),
            messages: messages
        )
    }

    /// Dumb title — first user message truncated to ~40 chars. FM-
    /// generated titles arrive in a later step; this exists so step 2's
    /// chats list has something readable to render today.
    private func derivedTitle() -> String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "" }
        let t = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}
