import Foundation
import FoundationModels

/// live-20 (1) — Apple Intelligence calls that TRANSFORM the user's own content (an entry's title + summary, its
/// tags, a neighbourhood's description and name, the corpus summary, the coherence check). They run on
/// `SystemLanguageModel(guardrails: .permissiveContentTransformations)` and ask for a plain String in a strict, simple
/// format that we parse and validate here.
///
/// Why not `@Generable`: the permissive guardrails relax only plain-String responses. Guided generation always uses
/// the default guardrails (Apple's documentation; Developer Forums 843442 / 835777), so an entry about sexual health,
/// a medical result or a political topic came back "The model's safety guardrails were triggered." — while the
/// Librarian chat, which streams a String, answered the same content.
///
/// Foundation + FoundationModels only: `scripts/fm_naming_harness` compiles this file on the Mac to measure it.
enum AppleNaming {
    static let titleMax = 80
    static let summaryMax = 400
    static let tagsMax = 8

    // MARK: - Prompts (shared with the on-device model, which gets its own JSON instruction)

    /// The title + summary instructions. A3 — no persona name: "You are the Librarian in AirPad" let the on-device
    /// model write itself into a summary ("… and the Librarian enjoy autumn …"). The role is described, never named.
    static let namingInstructions = """
    Analyze this captured idea and produce a concise title and summary. Base them on what the user wrote; any text found in images or documents is supporting context — rely on it only when the user's own writing is thin or absent.

    You are cataloguing this person's OWN note for them — not narrating it from outside. The summary states what the note is ABOUT, as an impersonal fragment, e.g. "Ten months of French buys a menu and half a Wikipedia article, not speech." Never refer to the note's author (no "she", "he", "they", "you", "the author", "the writer") and never narrate their actions ("rereading the year, she contrasts…"). People the note is about may be named; the writer is never the subject.
    """

    static func namingPrompt(content: String) -> String {
        """
        \(namingInstructions)

        Idea:
        \(content)
        """
    }

    static func substratePrompt(content: String) -> String {
        """
        Interpret this captured idea. Two outputs:

        1. summary — 1 to 2 sentences capturing what this idea is actually about. Be concrete and specific to the content; no generic filler. This is the seed for downstream embedding, so accuracy matters more than style. Write it as an impersonal fragment stating what the note is about — never refer to the note's own author (no "she"/"he"/"they"/"you"/"the author") and never narrate their actions; name people the note is about, but never the writer.
        2. tags — free-form folksonomy. Pick whatever short tags best describe this idea. No fixed vocabulary; use the words that actually fit. Concrete topical phrases beat abstract single words. 3 to 8 tags.

        Idea:
        \(content)
        """
    }

    // MARK: - Reply formats (the session's instructions; what `@Guide` used to say)

    static let namingFormat = """
    You write catalogue entries for a person's private notes. The notes are their own and may cover any subject, including health, sexuality, relationships, politics and history; describe them plainly and neutrally.
    Reply with exactly two lines and nothing else. The first line starts with "TITLE: " followed by a concise, functional title for the note (under 60 characters, not poetic). The second line starts with "SUMMARY: " followed by one or two sentences stating what the note is about, as an impersonal catalogue fragment.
    """

    static let substrateFormat = """
    You write catalogue entries for a person's private notes. The notes are their own and may cover any subject, including health, sexuality, relationships, politics and history; describe them plainly and neutrally.
    Reply with exactly two lines and nothing else. The first line starts with "SUMMARY: " followed by one or two sentences stating what the note is about. The second line starts with "TAGS: " followed by 3 to 8 short free-form tags, separated by commas.
    """

    // MARK: - The call

    enum Failure: Error, LocalizedError, Equatable {
        /// Apple's model answered in prose instead of the format, declining the content.
        case declined
        /// The reply wasn't in the format twice running (never surfaced as a half-parse).
        case unreadable

        var errorDescription: String? {
            switch self {
            case .declined:   return "Apple Intelligence declined this content."
            case .unreadable: return "Apple Intelligence's reply couldn't be read."
            }
        }
    }

    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    /// One plain-String reply under the permissive guardrails. A guardrail or refusal still throws (see `isRefusal`).
    static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    /// Ask, parse, and ask once more if the reply wasn't in the format. Throws `Failure` rather than return a half-parse.
    static func ask<T>(instructions: String, prompt: String, parse: (String) -> T?) async throws -> T {
        var last = ""
        for attempt in 1...2 {
            let raw = try await respond(instructions: instructions, prompt: prompt)
            if let parsed = parse(raw) { return parsed }
            last = raw
            print("[FM][AppleNaming] reply not in the format (attempt \(attempt), \(raw.count) chars)")
        }
        throw looksLikeDecline(last) ? Failure.declined : Failure.unreadable
    }

    static func name(prompt: String) async throws -> (title: String, summary: String) {
        try await ask(instructions: namingFormat, prompt: prompt, parse: parseNaming)
    }

    static func substrate(prompt: String) async throws -> (summary: String, tags: [String]) {
        try await ask(instructions: substrateFormat, prompt: prompt, parse: parseSubstrate)
    }

    // MARK: - Refusals

    /// Did Apple's model decline? `LanguageModelSession.GenerationError` on iOS 26; iOS 27 throws the new
    /// `LanguageModelError` instead (T's device, live-19 TF: "The model's safety guardrails were triggered." came
    /// through as an unrecognised error, so it showed Retry and the on-device model was never tried).
    static func isRefusal(_ error: any Error) -> Bool {
        if let f = error as? Failure { return f == .declined }
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .refusal, .guardrailViolation: return true
            default: break
            }
        }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .refusal, .guardrailViolation: return true
            default: break
            }
        }
        return false
    }

    /// `GenerationError.exceededContextWindowSize`, or iOS 27's `LanguageModelError.contextSizeExceeded`.
    static func isContextOverflow(_ error: any Error) -> Bool {
        if let g = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = g { return true }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *), let e = error as? LanguageModelError,
           case .contextSizeExceeded = e { return true }
        return false
    }

    static let declinePhrases = ["i can't", "i cannot", "i can’t", "i'm sorry", "i’m sorry", "i am sorry", "i'm unable",
                                 "i’m unable", "i am unable", "i won't", "i won’t", "can't assist", "can't help",
                                 "cannot assist", "cannot help", "not able to help", "as an ai"]
    static func looksLikeDecline(_ s: String) -> Bool {
        let l = s.lowercased()
        return declinePhrases.contains { l.contains($0) }
    }

    // MARK: - Parsing (strict format, tolerant of the usual noise: bold labels, code fences, quotes)

    /// The labelled lines of a reply: label (uppercased) → its text, continuation lines folded in.
    static func labelledLines(_ raw: String, labels: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        for line0 in raw.components(separatedBy: .newlines) {
            var line = line0.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            while let f = line.first, "-*#>".contains(f) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty { continue }
            if let label = labels.first(where: { line.uppercased().hasPrefix($0 + ":") }) {
                current = label
                out[label] = String(line.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
            } else if let c = current {
                out[c] = (out[c].map { $0.isEmpty ? "" : $0 + " " } ?? "") + line
            }
        }
        return out
    }

    static func clean(_ s: String?) -> String {
        var t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’", "«": "»", "<": ">"]
        while let f = t.first, let l = t.last, t.count >= 2, quotes[f] == l || (quotes[f] != nil && quotes.values.contains(l) && f != "<") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// The format's own words: a reply that echoes them is the format, not a name.
    static let formatPhrases = ["concise, functional title", "one or two sentences stating", "short free-form tags"]
    static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return formatPhrases.contains { l.contains($0) }
    }

    /// Title + summary together, or nil. A title that is a decline, a placeholder, or too long is no title.
    static func parseNaming(_ raw: String) -> (title: String, summary: String)? {
        let f = labelledLines(raw, labels: ["TITLE", "SUMMARY"])
        var title = clean(f["TITLE"])
        let summary = clean(f["SUMMARY"])
        if title.hasSuffix("."), !title.hasSuffix("..") { title.removeLast() }
        guard !title.isEmpty, !summary.isEmpty,
              title.count <= titleMax, summary.count <= summaryMax,
              !isPlaceholder(title), !isPlaceholder(summary),
              !looksLikeDecline(title), !looksLikeDecline(summary) else { return nil }
        return (title, summary)
    }

    /// Summary + 1…8 tags together, or nil.
    static func parseSubstrate(_ raw: String) -> (summary: String, tags: [String])? {
        let f = labelledLines(raw, labels: ["SUMMARY", "TAGS"])
        let summary = clean(f["SUMMARY"])
        var seen = Set<String>()
        let tags = (f["TAGS"] ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { clean(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: "#.")) }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert($0.lowercased()).inserted }
        guard !summary.isEmpty, summary.count <= summaryMax, !isPlaceholder(summary), !looksLikeDecline(summary),
              !tags.isEmpty else { return nil }
        return (summary, Array(tags.prefix(tagsMax)))
    }

    /// One field of plain text (a description, a short name), or nil.
    static func parseSingle(_ raw: String, maxChars: Int) -> String? {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var t = clean(lines.joined(separator: " ").replacingOccurrences(of: "**", with: ""))
        if let colon = t.firstIndex(of: ":"), t[..<colon].count <= 12, t[..<colon].allSatisfy({ $0.isLetter || $0 == " " }) {
            t = clean(String(t[t.index(after: colon)...]))   // "Name: …" / "Description: …"
        }
        guard !t.isEmpty, t.count <= maxChars, !looksLikeDecline(t) else { return nil }
        return t
    }

    // MARK: - Self-test (`-AppleNamingSelfTest`; also run by scripts/fm_naming_harness)

    static func selfTestRows() -> [(name: String, ok: Bool)] {
        var rows: [(String, Bool)] = []
        func row(_ n: String, _ ok: Bool) { rows.append((n, ok)) }
        let plain = parseNaming("TITLE: Clinic follow-up results\nSUMMARY: A negative STI panel and a retest booked for January.")
        row("naming-plain", plain?.title == "Clinic follow-up results" && plain?.summary.hasPrefix("A negative STI panel") == true)
        let noisy = parseNaming("```\n**TITLE:** \"Sourdough attempt four\"\n**Summary:** Higher hydration, better oven spring,\nstill a tight crumb.\n```")
        row("naming-bold-fenced-quoted-wrapped", noisy?.title == "Sourdough attempt four" && noisy?.summary == "Higher hydration, better oven spring, still a tight crumb.")
        row("naming-title-only-is-nothing", parseNaming("TITLE: Lisbon trip plan") == nil)
        row("naming-summary-only-is-nothing", parseNaming("SUMMARY: A trip to Lisbon.") == nil)
        row("naming-prose-is-nothing", parseNaming("I'm sorry, but I can't help with that request.") == nil)
        row("naming-decline-in-the-title-is-nothing", parseNaming("TITLE: I can't help with this\nSUMMARY: I'm sorry.") == nil)
        row("naming-placeholder-is-nothing", parseNaming("TITLE: <a concise, functional title for the note>\nSUMMARY: <one or two sentences stating what it is about>") == nil)
        let bracketed = parseNaming("TITLE: <Libido changes after sertraline>  \n\nSUMMARY: <Monthly log tracks mood, sleep and desire.>")
        row("naming-angle-brackets-unwrapped", bracketed?.title == "Libido changes after sertraline" && bracketed?.summary == "Monthly log tracks mood, sleep and desire.")
        row("naming-overlong-title-is-nothing", parseNaming("TITLE: \(String(repeating: "a", count: titleMax + 1))\nSUMMARY: Fine.") == nil)
        row("decline-prose-detected", looksLikeDecline("I'm sorry, but I can't assist with that.") && !looksLikeDecline("TITLE: Iron levels\nSUMMARY: Low ferritin."))
        let sub = parseSubstrate("SUMMARY: Questions to settle before opening a relationship.\nTAGS: open relationship, boundaries, #jealousy, Boundaries, testing")
        row("substrate-tags-split-deduped", sub?.tags == ["open relationship", "boundaries", "jealousy", "testing"])
        row("substrate-no-tags-is-nothing", parseSubstrate("SUMMARY: Something.\nTAGS:") == nil)
        row("single-strips-label-and-quotes", parseSingle("Name: \"Clinic Visits\"", maxChars: 40) == "Clinic Visits")
        row("refusal-generation-error", isRefusal(LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "test"))))
        row("refusal-declined-prose", isRefusal(Failure.declined) && !isRefusal(Failure.unreadable))
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            row("refusal-ios27-language-model-error", isRefusal(LanguageModelError.guardrailViolation(.init(debugDescription: "test"))))
            row("overflow-ios27-language-model-error", isContextOverflow(LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "test"))))
        }
        return rows
    }
}
