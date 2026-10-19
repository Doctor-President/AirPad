import Foundation
import FoundationModels

/// live-23 (5b) — the Librarian's chat on Apple Intelligence (the on-device `SystemLanguageModel`).
///
/// T (iOS 27, General mode, 2026-10-17): a table of local LLMs for an RTX 4090 → "I cannot … I cannot provide
/// information on that topic."; then a table of US presidents → the same; then "is that because you don't know, or
/// you can't make tables?" → the same sentence, verbatim. Two app causes, both fixed here:
///   • REFUSAL POISONING — every prior turn went back to the model, refusals included, folded into ONE prompt string
///     ("Assistant: I cannot …"), so the model continued the pattern on unrelated follow-ups. A declined turn (and
///     the question that drew it) is now never sent back (`ChatSession.historyPlan` drops `declined` turns).
///   • NO ROLE / NO INSTRUCTIONS — the system prompt was pasted in front of the question. Apple's guidance for
///     over-blocking is a clear role at the START of the session's `instructions`; history goes in as a real
///     `Transcript` (prompt / response entries), not a "User:/Assistant:" string.
///
/// Guardrails stay `.default` for General answers. Apple's `permissiveContentTransformations` is documented for
/// TRANSFORMING source material (summarising a news article, explaining sensitive notes, tagging profanity), and the
/// acceptable-use rules forbid circumventing guardrails — open General Q&A has no source material, so it isn't the
/// intended use (see the live-23 report). A refusal can still happen (the model's own safety layer answers in a
/// string, and Apple says it can't always be told apart programmatically), so it is detected by its shape and shown
/// honestly (`isRefusalText`, `declineLine`).
enum AppleChat {
    typealias Turn = (role: String, content: String)

    struct Request {
        var instructions: String
        var history: [Turn]
        var prompt: String
    }

    /// Wire messages (system / user / assistant, in order, the last one the current user turn) → the session's
    /// instructions, its transcript, and this turn's prompt. Empty turns are dropped.
    static func request(_ messages: [[String: String]]) -> Request {
        var instructions: [String] = []
        var turns: [Turn] = []
        for m in messages {
            let c = (m["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty else { continue }
            switch m["role"] {
            case "system": instructions.append(c)
            case "assistant": turns.append(("assistant", c))
            default: turns.append(("user", c))
            }
        }
        var prompt = ""
        if let last = turns.last, last.role == "user" { prompt = last.content; turns.removeLast() }
        return Request(instructions: instructions.joined(separator: "\n\n"), history: turns, prompt: prompt)
    }

    /// The session for a request: instructions first, then the prior turns as real prompt / response entries.
    static func session(_ r: Request, model: SystemLanguageModel = .default) -> LanguageModelSession {
        var entries: [Transcript.Entry] = []
        if !r.instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: r.instructions))],
                                                                 toolDefinitions: [])))
        }
        for t in r.history {
            let seg: [Transcript.Segment] = [.text(.init(content: t.content))]
            entries.append(t.role == "assistant" ? .response(Transcript.Response(assetIDs: [], segments: seg))
                                                 : .prompt(Transcript.Prompt(segments: seg)))
        }
        return LanguageModelSession(model: model, transcript: Transcript(entries: entries))
    }

    /// The one line a declined turn shows (no "general knowledge" label, never a chat title).
    static let declineLine = "Apple Intelligence declined this. Try again, rephrase, or switch model."

    /// Apple's string-mode refusal: a SHORT reply whose first sentence is a refusal ("I cannot …", "I'm sorry, but I
    /// can't …", "I can't help with that"). An answer that merely hedges a detail ("I can't verify the date, but …")
    /// runs on past the limit and isn't one.
    static func isRefusalText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 320 else { return false }
        let lower = t.lowercased().replacingOccurrences(of: "’", with: "'")
        let head = String(lower.prefix(90))
        let openers = ["i cannot", "i can't", "i can not", "i'm sorry, but i can", "i am sorry, but i can", "sorry, i can't",
                       "sorry, but i can't", "i'm sorry, but i still can", "i'm unable to", "i am unable to", "i'm not able to", "i am not able to",
                       "i won't be able to", "i apologize, but i can", "i'm sorry, i can't", "i'm sorry, but i'm unable"]
        guard openers.contains(where: { head.hasPrefix($0) || head.contains(". " + $0) }) else { return false }
        // "I can't verify the date, but …" hedges a detail and then answers: its first sentence turns on ", but".
        let firstSentence = lower.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? lower
        let apology = ["i'm sorry, but", "i am sorry, but", "sorry, but", "i apologize, but"].contains { firstSentence.hasPrefix($0) }
        if !apology && firstSentence.contains(", but ") { return false }
        // A refusal states what it won't do; it doesn't go on to deliver (a table, a list, a second paragraph).
        return !lower.contains("|") && !lower.contains("\n\n")
    }

    /// The pure rows for `-AppleChatSelfTest` (and the Mac harness).
    static func selfTestRows() -> [(name: String, ok: Bool)] {
        let r = request([["role": "system", "content": "Be helpful."], ["role": "user", "content": "Q1"],
                         ["role": "assistant", "content": "A1"], ["role": "user", "content": "Q2"]])
        return [
            ("system-becomes-instructions", r.instructions == "Be helpful."),
            ("prior-turns-keep-their-roles", r.history.map(\.role) == ["user", "assistant"] && r.history.map(\.content) == ["Q1", "A1"]),
            ("last-user-turn-is-the-prompt", r.prompt == "Q2"),
            ("refusal-t-saw", isRefusalText("I cannot fulfill that request. I cannot provide information on that topic.")),
            ("refusal-sorry-cant-help", isRefusalText("I'm sorry, but I can't help with that.")),
            ("refusal-curly-apostrophe", isRefusalText("Sorry, I can’t assist with that request.")),
            ("not-refusal-hedged-answer", !isRefusalText("I can't verify the exact date, but the treaty was signed in 1648 in Münster and Osnabrück, ending the Thirty Years' War. It reshaped the map of Europe and is often taken as the start of the modern system of sovereign states, though historians debate how much it really changed at the time.")),
            ("not-refusal-table", !isRefusalText("I can't list all of them, but here are some:\n\n| Model | VRAM |\n|---|---|\n| Llama 3 8B | 16 GB |")),
            ("not-refusal-normal", !isRefusalText("George Washington was the first president, from 1789 to 1797.")),
            ("not-refusal-empty", !isRefusalText("")),
        ]
    }
}

#if DEBUG
extension AppleChat {
    /// `-AppleChatSelfTest` — live-23 (5b): the request shape, the refusal detector, a declined turn never goes back
    /// to the model, and a refusal never becomes a chat title. Pure.
    @MainActor
    static func selfTest() -> String {
        var rows = selfTestRows()
        typealias M = ChatSession.Message
        let msgs = [M(role: .user, text: "LLM table please"), M(role: .assistant, text: "I cannot fulfill that request.", declined: true),
                    M(role: .user, text: "Presidents table"), M(role: .assistant, text: "I cannot provide information on that topic.", declined: true),
                    M(role: .user, text: "Capital of Australia?"), M(role: .assistant, text: "Canberra.")]
        let hist = ChatSession.historyWire(msgs, replayFrom: nil, reserveChars: 0, windowTokens: 4_096)
        rows.append(("declined-turns-and-their-questions-never-go-back",
                     hist.map { $0["content"] ?? "" } == ["Capital of Australia?", "Canberra."]))
        rows.append(("answered-turns-still-go-back",
                     ChatSession.historyWire([M(role: .user, text: "Q"), M(role: .assistant, text: "A")], replayFrom: nil,
                                             reserveChars: 0, windowTokens: 4_096).count == 2))
        rows.append(("refusal-never-titles-a-chat", ChatSession.debugSanitizeTitle("Unable to work with that request") == nil
                     && ChatSession.debugSanitizeTitle("I cannot help with that") == nil
                     && ChatSession.debugSanitizeTitle("US presidents by party") == "US presidents by party"))
        rows.append(("decline-line-is-honest", declineLine.hasPrefix("Apple Intelligence declined this")
                     && declineLine.contains("switch model") && !declineLine.contains("general knowledge")))
        let fails = rows.filter { !$0.ok }.count
        return "[AppleChatSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.map { "\($0.ok ? "PASS" : "FAIL") \($0.name)" }.joined(separator: "\n")
    }
}
#endif
