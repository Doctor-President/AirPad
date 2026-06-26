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

    struct Message: Identifiable, Hashable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

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

    /// Wipe the transcript. Used by the "New chat" affordance.
    func reset() {
        messages = []
        streamingText = ""
        pendingUser = nil
        isStreaming = false
    }
}
