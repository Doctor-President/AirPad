import Foundation

/// live-29 (B5) — Apple Intelligence + web, option (a): APP-ROUTED grounding. The on-device model never calls a tool
/// here: live-28 (A6) measured it calling a FoundationModels tool 30 / 30 times but writing stale years into its own
/// queries. The app decides to search (the same rule as the Host path: a search-intent or current-state request, or a
/// factual question), writes the query itself (today's year on a current-state request), asks the active provider
/// (Tavily or Brave, the Web search switch and key as everywhere), and hands the model the top three results — title,
/// date, ≤ 300-character snippet — numbered, inside the turn. The app builds the sources and chips from the [n] the
/// answer cites, exactly as on the Host path; the caption reads "Apple Intelligence + web"; and after a search the
/// training-data line never shows (B3): an answer no result supports says "The search results didn't confirm this."
enum AppleWebGrounding {
    /// How many results go into the turn (Apple's on-device window is small; three snippets ≈ 1,200 characters).
    static let maxResults = 3
    static let snippetCap = 300

    /// Does this General question get searched first? The Host path's rule: a search-intent or current-state request,
    /// or a factual question (the Host path also reads the top page for those; here the snippets are the packet).
    static func shouldSearch(_ q: String, searchIntent: Bool) -> Bool {
        searchIntent || WebGrounding.asksCurrentState(q) || WebGrounding.isFactualQuestion(q)
    }

    /// The query the app writes: the question, plus today's year on a current-state request that names no year
    /// ("Who is the current president?" → "Who is the current president? 2026"), so the provider favours this year.
    static func query(for q: String, now: Date = Date()) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WebGrounding.asksCurrentState(t), t.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) == nil else { return t }
        return t + " " + String(Calendar(identifier: .gregorian).component(.year, from: now))
    }

    /// The turn: the numbered results (title, date, snippet) then the question; and the citations they become.
    static func packet(question: String, links: [ToolLink], now: Date = Date())
        -> (text: String, citations: [ChatSession.Message.Citation]) {
        let top = Array(links.prefix(maxResults))
        var lines = ["Web results (searched \(WebGrounding.dayString(now))):"]
        var cites: [ChatSession.Message.Citation] = []
        for (i, l) in top.enumerated() {
            let n = i + 1
            let title = MarkdownPlain.label(l.title)
            let snippet = MarkdownPlain.label(l.snippet ?? "")
            let clipped = snippet.count > snippetCap ? String(snippet.prefix(snippetCap)) + "…" : snippet
            let date = l.published.map { " — published " + WebGrounding.dayString($0) } ?? ""
            lines.append("[\(n)] \(title)\(date)\n\(clipped)")
            cites.append(.init(index: n, url: l.url, title: title, snippet: clipped))
        }
        lines.append("Question: \(question)")
        return (lines.joined(separator: "\n\n"), cites)
    }

    /// The instructions line added to General's (kept short: Apple's refusal rate is the constraint — live-23).
    /// It REPLACES General's "answer from your own knowledge … may be out of date" ending for this turn (results are there).
    static let instructions = "Numbered web results for the question come with it, with today's date. Answer the question from them, clearly and to the point, and put the result's number in brackets, like [1], after each fact you take from one. If they don't answer it, say so plainly."
}

#if DEBUG
/// `-AppleWebSelfTest` (with `-StubOnDeviceModel YES -WebSearchMock YES`) — B5 through the REAL General send:
/// Apple Intelligence (stubbed) + a stubbed provider → the packet is in the turn → the answer's [n] become web chips →
/// "Apple Intelligence + web" → no training-data line; an uncited answer gets "didn't confirm"; the switch off → the
/// "Web search is off" notice. RED (today's code): no search, no packet, no chips.
enum AppleWebSelfTest {
    @MainActor static func run(store: CorpusStore) async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let d = UserDefaults.standard
        let priorEnabled = d.object(forKey: WebSearchBackend.enabledKey)
        defer { if let priorEnabled { d.set(priorEnabled, forKey: WebSearchBackend.enabledKey) } else { d.removeObject(forKey: WebSearchBackend.enabledKey) } }
        d.set(true, forKey: WebSearchBackend.enabledKey)

        // Pure parts.
        let fixedNow = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        row("query-adds-the-year-to-a-current-state-request", AppleWebGrounding.query(for: "Who is the current president?", now: fixedNow)
            == "Who is the current president? 2026", AppleWebGrounding.query(for: "Who is the current president?", now: fixedNow))
        row("query-keeps-a-fact-question", AppleWebGrounding.query(for: "Who wrote Pride and Prejudice?", now: fixedNow) == "Who wrote Pride and Prejudice?")
        let links = (1...5).map { ToolLink(title: "#### Result \($0)", url: "https://example.com/\($0)",
                                           snippet: "**Snippet** \($0) " + String(repeating: "x", count: 400)) }
        let pk = AppleWebGrounding.packet(question: "Q?", links: links, now: fixedNow)
        row("packet-is-top-3-plain-capped", pk.citations.count == 3 && !pk.text.contains("####") && !pk.text.contains("**")
            && pk.text.contains("[3] Result 3") && !pk.text.contains("[4]") && pk.citations.allSatisfy { $0.snippet.count <= 301 },
            String(pk.text.prefix(120)))

        // The real send path — Apple Intelligence (stub) + the mock provider.
        let lib = LibrarianState(); lib.corpusAware = false
        let chat = ChatSession()
        await lib.groundedSend(query: "What is the latest news about the Lakeview Observatory telescope?", store: store, chat: chat)
        let a1 = chat.messages.last { $0.role == .assistant }
        row("searched-and-the-packet-was-in-the-turn", ModelRouter.debugLastApplePrompt.contains("Web results")
            && ModelRouter.debugLastApplePrompt.contains("[1] "), String(ModelRouter.debugLastApplePrompt.prefix(140)))
        row("the-answer's-[n]-are-web-chips", (a1?.citations ?? []).contains { $0.url?.contains("gauntlet.example") == true },
            "\(a1?.citations?.map { $0.url ?? "-" } ?? [])")
        row("caption-Apple-Intelligence-+-web", a1?.provenance?.caption == "Apple Intelligence + web", a1?.provenance?.caption ?? "nil")
        row("no-training-data-line-after-a-search", a1?.datedKnowledge != true && a1?.generalKnowledge != true,
            "dated=\(a1?.datedKnowledge ?? false) general=\(a1?.generalKnowledge ?? false)")

        // An answer that cites nothing: the (B3) line, never training data. (The stub cites nothing for "lighthouse".)
        let chat2 = ChatSession()
        await lib.groundedSend(query: "What is the latest news about the Lakeview Observatory lighthouse?", store: store, chat: chat2)
        let a2 = chat2.messages.last { $0.role == .assistant }
        row("uncited-after-a-search-says-didn't-confirm", a2?.searchUnconfirmed == true && a2?.datedKnowledge != true,
            "unconfirmed=\(a2?.searchUnconfirmed ?? false) dated=\(a2?.datedKnowledge ?? false)")

        // The switch off: a search-intent question gets the notice; nothing is searched.
        d.set(false, forKey: WebSearchBackend.enabledKey)
        ModelRouter.debugLastApplePrompt = ""
        let chat3 = ChatSession()
        await lib.groundedSend(query: "Search the web for the Lakeview Observatory telescope news", store: store, chat: chat3)
        let a3 = chat3.messages.last { $0.role == .assistant }
        row("switch-off-says-web-search-is-off", a3?.text.hasPrefix("Web search is off.") == true && ModelRouter.debugLastApplePrompt.isEmpty,
            a3.map { String($0.text.prefix(60)) } ?? "nil")

        let fails = rows.filter { !$0.1 }
        return (fails.isEmpty ? "PASS — \(rows.count)/\(rows.count)" : "FAIL — \(rows.count - fails.count)/\(rows.count)")
            + rows.map { "\n\($0.1 ? "PASS" : "FAIL") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined()
    }
}
#endif
