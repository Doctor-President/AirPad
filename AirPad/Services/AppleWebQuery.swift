import Foundation

/// live-30 (A1) — Apple Intelligence + web, follow-ups. The pure parts (no app types, Foundation only), so the macOS
/// harness (`scripts/fm_chat_harness`) compiles exactly what the app runs.
///
/// T (TF 202610191843, iOS 27, General, Apple Intelligence): single questions searched well, but a vague follow-up ("…so
/// where does it stand now?") searched its own literal words and came back with sports "where does X stand" headlines.
/// The Host path doesn't have this: there the model writes the query with the chat in view. The standard fix (the
/// "condense the follow-up into a standalone query" step RAG chat apps use): a short separate on-device call rewrites the
/// latest question into a standalone search query from the last few turns; then the APP applies its year rule (the model
/// writes stale years — live-28 A6). Also here: the results framed as a search the app ran today (the model said "the
/// sources you provided" when they sat in the user's turn), answers in the model's own words, no social / video hosts,
/// and an answer that says the results don't answer the question counts as unconfirmed.
enum AppleWebQuery {

    // MARK: The standalone query

    /// The rewrite call's instructions (kept short: Apple's refusal rate is the constraint — live-23).
    static let rewriteInstructions = "You write web search queries. Given a conversation and the user's latest question, write one standalone search query that would find the answer, naming what the question refers to. Reply with the query only."

    /// The rewrite call's prompt: the last few turns (each question and the start of its answer), then the latest question.
    static func rewritePrompt(turns: [(question: String, answer: String)], latest: String) -> String {
        let recent = turns.suffix(3).map { t in
            let a = t.answer.replacingOccurrences(of: "\n", with: " ")
            return "Question: \(t.question)\nAnswer: \(a.count > 240 ? String(a.prefix(240)) + "…" : a)"
        }
        return (recent + ["Latest question: \(latest)", "Search query:"]).joined(separator: "\n\n")
    }

    /// The model's reply → a query, or nil when it isn't one (empty, a refusal, a sentence of chat, far too long).
    static func cleanRewrite(_ raw: String) -> String? {
        var line = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for prefix in ["search query:", "query:", "search:", "standalone query:"] where line.lowercased().hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: #"[\[\]{}<>]"#, with: "", options: .regularExpression)   // "[Panama Canal] …" (seen)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*_. "))
        // live-31 — a JSON-shaped reply ({"query": "…"}, seen on the Simulator): the key goes, the value stays.
        line = line.replacingOccurrences(of: #"^(search[ _]?)?query"?\s*:\s*"?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*_. "))
        let lower = line.lowercased()
        let refusal = ["i cannot", "i can't", "i'm sorry", "i am sorry", "sorry", "i'm unable", "i am unable", "as an ai"]
        guard line.count >= 3, line.count <= 160, !refusal.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return line
    }

    private static let yearPattern = #"\b(19|20)\d{2}\b"#

    /// The app's year rule on any query: a year the user typed stays; any other year the model wrote goes; a current-state
    /// request gets today's year ("…so where does it stand now?" → "… 2026"), so the provider favours this year.
    static func applyYearRule(_ query: String, userText: String, currentState: Bool, now: Date = Date()) -> String {
        let typed = Set(matches(yearPattern, in: userText))
        var q = query
        for y in Set(matches(yearPattern, in: query)) where !typed.contains(y) {
            q = q.replacingOccurrences(of: #"\b\#(y)\b"#, with: "", options: .regularExpression)
        }
        q = q.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if currentState, matches(yearPattern, in: q).isEmpty {
            q += " " + String(Calendar(identifier: .gregorian).component(.year, from: now))
        }
        return q
    }

    /// When the rewrite fails, refuses, times out or comes back empty: the previous search's query plus the new question
    /// (the topic carries; the question says what is wanted now). No previous search → the question as written.
    static func fallbackQuery(previousQuery: String?, question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = previousQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return q }
        return p.replacingOccurrences(of: yearPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) + " " + q
    }

    /// "Thanks", "ok", "great, got it" — not a question to search again.
    static func isChitChat(_ q: String) -> Bool {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.isEmpty { return true }
        let phrases = ["thanks", "thank you", "thx", "ok", "okay", "cool", "great", "nice", "got it", "perfect", "awesome",
                       "makes sense", "interesting", "wow", "good to know", "cheers", "ty", "sounds good", "lol", "haha"]
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        return words.count <= 5 && phrases.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) }
    }

    /// A real follow-up question (searched again after a turn that searched): asks something, and isn't chit-chat.
    static func isFollowUpQuestion(_ q: String) -> Bool {
        let t = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isChitChat(t) else { return false }
        if t.hasSuffix("?") { return true }
        let openers = ["what", "who", "when", "where", "why", "how", "which", "is ", "are ", "was ", "were ", "did ", "does ",
                       "do ", "can ", "could ", "will ", "would ", "has ", "have ", "so ", "and ", "tell me", "any ", "more on"]
        return openers.contains { t.hasPrefix($0) }
    }

    // MARK: Sources

    /// Social and video hosts stay out of the packet (a post or a clip isn't a source to cite).
    static let socialHosts = ["instagram.com", "facebook.com", "fb.com", "tiktok.com", "x.com", "twitter.com", "threads.net",
                              "threads.com", "pinterest.com", "youtube.com", "youtu.be"]
    static func isSocial(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return socialHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// The provider is asked for this many so three remain after the filter.
    static let requestCount = 8

    // MARK: The answer turn

    /// The answer turn. The results stay IN the turn, labelled as the app's own search today that the user hasn't seen
    /// (live-29 put them under "Web results (searched …)", and the model said "the sources you provided"); the
    /// instructions say where they come from and how to use them. Measured on this Mac (synthetic, ×5): results in the
    /// session instructions instead → citing 77/85 and the measles text tripping the guardrail 4 of 5; in the turn
    /// without "not from the user" → "you provided" 5 times; this → 0 refusals, 83/85 cite, 0 "you provided", news 25/25.
    static let turnInstructions = "Each question comes with web results the app found for it today; they come from the app's search, not from the user, who hasn't seen them. Answer the question from them in your own words, not by copying their sentences, and put the result's number in brackets, like [1], after each fact you take from one. If they don't answer it, say so plainly."
    static func turnPacket(day: String, query: String, question: String, results: [(title: String, date: String?, snippet: String)]) -> String {
        let list = results.enumerated().map { i, r in "[\(i + 1)] \(r.title)\(r.date.map { " — published " + $0 } ?? "")\n\(r.snippet)" }
        return (["Web results the app found today (\(day)) for \"\(query)\":"] + list + ["Question: \(question)"]).joined(separator: "\n\n")
    }

    /// The answer says the results don't answer the question (in its opening): it is unconfirmed, whatever [n] it cites.
    /// "The results don't mention X, but [1] says Y" (a partial answer that goes on) still counts as an answer.
    static func saysResultsDontAnswer(_ answer: String) -> Bool {
        let t = answer.lowercased().replacingOccurrences(of: "’", with: "'")
        let opening = String(t.split(whereSeparator: { ".!?\n".contains($0) }).first ?? Substring(t))
        guard opening.count <= 260 else { return false }
        let subject = #"(the |these |those )?(search |web )?(results?|sources?|articles?|snippets?|pages?)( provided| given| above| here)?"#
        let denial = #"(do(es)?n't|do(es)? not|did not|didn't|don't|fail to|aren't|are not|isn't|is not) (seem to )?(answer|mention|say|cover|address|contain|include|provide|give|specify|state|discuss|talk about|have|offer)"#
        let patterns = [subject + #"\s+(\[\d+\](,? ?(and )?\[\d+\])*\s*)?"# + denial,
                        #"none of (the |these )?(search |web )?(results?|sources?|articles?)"#,
                        #"(no|not any) (information|details?|mention|answer)[^.]{0,40}\b(in|from) (the |these )?(search |web )?(results?|sources?|articles?)"#,
                        #"(the |these )?(search |web )?(results?|sources?) (only|just) (mention|cover|discuss|talk about)"#]
        guard patterns.contains(where: { opening.range(of: $0, options: .regularExpression) != nil }) else { return false }
        // "…, but [1] says …" — a partial answer that goes on to answer from a result.
        return opening.range(of: #",? but (\[\d+\]|according to|it|they|the)"#, options: .regularExpression) == nil
    }

    /// The [n] markers out of an answer that turned out unconfirmed (they would read as support).
    static func strippingCitationMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s?\[\d+\](\s?[-–,]\s?\[\d+\])*"#, with: "", options: .regularExpression)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    // MARK: Pure rows (`-AppleWebSelfTest` and the Mac harness)

    static func selfTestRows(now: Date) -> [(name: String, ok: Bool, detail: String)] {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let y = String(Calendar(identifier: .gregorian).component(.year, from: now))
        let r1 = applyYearRule("Lakeview Observatory telescope status 2024", userText: "So where does it stand now?", currentState: true, now: now)
        row("year-rule-drops-a-model-year-and-adds-today's", r1 == "Lakeview Observatory telescope status \(y)", r1)
        let r2 = applyYearRule("Treaty of Westphalia 1648 aftermath", userText: "What happened after the 1648 treaty?", currentState: false, now: now)
        row("year-rule-keeps-a-year-the-user-typed", r2 == "Treaty of Westphalia 1648 aftermath", r2)
        row("rewrite-cleaned", cleanRewrite("Search query: \"Artemis II launch date\".\nThis finds…") == "Artemis II launch date",
            cleanRewrite("Search query: \"Artemis II launch date\".") ?? "nil")
        row("rewrite-json-shape", cleanRewrite("{\"query\": \"list of US presidents, their parties and causes of death\"}") == "list of US presidents, their parties and causes of death",
            cleanRewrite("{\"query\": \"list of US presidents, their parties and causes of death\"}") ?? "nil")
        row("rewrite-brackets-dropped", cleanRewrite("[Panama Canal] water restrictions current status") == "Panama Canal water restrictions current status")
        row("rewrite-refusal-is-no-query", cleanRewrite("I'm sorry, but I can't help with that.") == nil && cleanRewrite("  ") == nil)
        row("fallback-carries-the-previous-query", fallbackQuery(previousQuery: "Lakeview Observatory telescope 2026", question: "Who won?")
            == "Lakeview Observatory telescope Who won?", fallbackQuery(previousQuery: "Lakeview Observatory telescope 2026", question: "Who won?"))
        row("follow-up-vs-chit-chat", isFollowUpQuestion("so where does it stand now?") && isFollowUpQuestion("What happened next?")
            && isFollowUpQuestion("who won") && !isFollowUpQuestion("Thanks!") && !isFollowUpQuestion("ok cool") && !isFollowUpQuestion("Great, got it."))
        row("social-hosts-out", isSocial("https://www.instagram.com/p/abc") && isSocial("https://m.youtube.com/watch?v=1") && isSocial("https://x.com/a/status/1")
            && !isSocial("https://www.reuters.com/world/") && !isSocial("https://example.com/x.com-review"))
        row("says-results-don't-answer", saysResultsDontAnswer("The search results [1], [2] and [3] don't mention who won the final. As of my knowledge, …")
            && saysResultsDontAnswer("None of the results say when the bridge reopens.")
            && saysResultsDontAnswer("The provided results do not specify the current status of the project."))
        row("a-partial-answer-is-still-an-answer", !saysResultsDontAnswer("The results don't give the exact date, but [1] says the launch slipped to spring.")
            && !saysResultsDontAnswer("The telescope saw first light in November [1]."))
        row("markers-stripped", strippingCitationMarkers("They don't say [1], [2]. Nor [3]–[4].") == "They don't say. Nor.",
            strippingCitationMarkers("They don't say [1], [2]. Nor [3]–[4]."))
        let pk = turnPacket(day: "20 October 2026", query: "q", question: "Q?", results: [("T", "19 October 2026", "S")])
        row("framed-as-the-app's-search", pk.hasPrefix("Web results the app found today (20 October 2026) for \"q\":")
            && pk.contains("[1] T — published 19 October 2026\nS") && pk.hasSuffix("Question: Q?")
            && turnInstructions.contains("not from the user") && turnInstructions.contains("own words"))
        return rows
    }
}
