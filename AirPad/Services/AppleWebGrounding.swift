import Foundation
import FoundationModels

/// live-29 (B5) — Apple Intelligence + web, option (a): APP-ROUTED grounding. The on-device model never calls a tool
/// here: live-28 (A6) measured it calling a FoundationModels tool 30 / 30 times but writing stale years into its own
/// queries. The app decides to search (the same rule as the Host path: a search-intent or current-state request, or a
/// factual question), writes the query itself (today's year on a current-state request), asks the active provider
/// (Tavily or Brave, the Web search switch and key as everywhere), and hands the model the top three results — title,
/// date, ≤ 300-character snippet — numbered, inside the turn. The app builds the sources and chips from the [n] the
/// answer cites, exactly as on the Host path; the caption reads "Apple Intelligence + web"; and after a search the
/// training-data line never shows (B3): an answer no result supports says "The search results didn't confirm this."
/// live-30 (A1) — follow-ups search a standalone query (rewritten on-device, `searchQuery`); the results are labelled as
/// the app's own search today, not something the user provided (`AppleWebQuery.turnPacket`); social / video hosts are
/// left out; the turn shows the "Searched the web" row; an answer that says the results don't answer it is unconfirmed.
enum AppleWebGrounding {
    /// How many results go into the turn (Apple's on-device window is small; three snippets ≈ 1,200 characters).
    static let maxResults = 3
    static let snippetCap = 300
    /// live-32 (2) — a Wikipedia passage's share of the turn (with two snippets ≈ 1,500 characters).
    static let wikiCap = 900

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

    /// live-30 (A1) — the query this turn searches, and how it was made ("first turn" · "standalone" · "rewritten" · "fallback").
    /// First turn of a chat: the question (`query(for:)`, unchanged). A follow-up: a short separate on-device call
    /// rewrites it into a standalone query from the last few turns (`AppleWebQuery`); then the app's year rule (a year
    /// the user typed anywhere in the chat stays, any other goes, today's on a current-state request). The rewrite fails,
    /// refuses, times out or comes back empty → the previous search's query + the new question.
    @MainActor static func searchQuery(for question: String, chat: ChatSession, now: Date = Date()) async -> (query: String, how: String) {
        let prior = priorTurns(chat)
        guard !prior.isEmpty, !live29 else { return (query(for: question, now: now), "first turn") }
        // live-31 — a question that doesn't lean on the chat is searched as written (no rewrite, no previous topic).
        guard AppleWebQuery.needsContext(question) else { return (query(for: question, now: now), "standalone") }
        let typed = (prior.map(\.question) + [question]).joined(separator: " ")
        if let rewritten = await rewrite(turns: prior, latest: question) {
            let current = WebGrounding.asksCurrentState(question) || WebGrounding.asksCurrentState(rewritten)
            return (AppleWebQuery.applyYearRule(rewritten, userText: typed, currentState: current, now: now), "rewritten")
        }
        let fallback = AppleWebQuery.fallbackQuery(previousQuery: previousSearchQuery(chat), question: question)
        return (AppleWebQuery.applyYearRule(fallback, userText: typed, currentState: WebGrounding.asksCurrentState(question), now: now), "fallback")
    }

    /// Did the latest answer come from a search? (A follow-up to it is searched again — `AppleWebQuery.isFollowUpQuestion`.)
    @MainActor static func lastAnswerSearched(_ chat: ChatSession) -> Bool {
        chat.messages.last(where: { $0.role == .assistant })?.provenance?.web == true
    }

    /// The answered turns so far (a declined turn and its question never count), the last three.
    @MainActor static func priorTurns(_ chat: ChatSession) -> [(question: String, answer: String)] {
        var out: [(String, String)] = []
        var pending: String?
        for m in chat.messages {
            switch m.role {
            case .user: pending = m.text
            case .assistant:
                if let q = pending, m.declined != true, !m.text.isEmpty { out.append((q, m.text)) }
                pending = nil
            case .activity: break
            }
        }
        return Array(out.suffix(3)).map { (question: $0.0, answer: $0.1) }
    }

    /// The query the last search row shows.
    @MainActor static func previousSearchQuery(_ chat: ChatSession) -> String? {
        chat.messages.last(where: { $0.role == .activity && $0.activity?.icon == "magnifyingglass" })?.activity?.detail
    }

    /// DEBUG `-AppleWebFollowUpOff YES` — live-29's Apple + web turn (the RED baseline for `-AppleWebSelfTest`): no rewrite,
    /// no follow-up rule, no search row, social hosts kept, no "the results don't answer it" rule. Always false in Release.
    static var live29: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "AppleWebFollowUpOff")
        #else
        false
        #endif
    }

    #if DEBUG
    /// `-AppleWebSelfTest` — the rewrite fails (the fallback row).
    static var debugRewriteFails = false
    /// The last query an Apple Intelligence + web turn searched, and how it was made.
    static var debugLastQuery = ""
    static var debugLastHow = ""
    #endif

    /// The rewrite call: on-device, no tools, ≤ 40 tokens, 5 s. nil = no usable query.
    private static func rewrite(turns: [(question: String, answer: String)], latest: String) async -> String? {
        #if DEBUG
        if debugRewriteFails { return nil }
        if UserDefaults.standard.bool(forKey: "StubOnDeviceModel") {
            // Stub: names the earlier topic and writes a STALE year (the year rule must take it out).
            return turns.contains { $0.question.contains("Lakeview") } ? "Lakeview Observatory telescope status 2024" : nil
        }
        #endif
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = AppleWebQuery.rewritePrompt(turns: turns, latest: latest)
        let raw: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: AppleWebQuery.rewriteInstructions)
                return try? await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 40)).content
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let raw, !AppleChat.isRefusalText(raw) else { return nil }
        return AppleWebQuery.cleanRewrite(raw)
    }

    /// The results that go into the turn: social / video hosts out (`AppleWebQuery.isSocial`), then the top three —
    /// title, date, ≤ 300-character snippet — and the citations they become.
    static func packet(links: [ToolLink], now: Date = Date())
        -> (results: [(title: String, date: String?, snippet: String)], citations: [ChatSession.Message.Citation]) {
        let top = Array(links.filter { live29 || !AppleWebQuery.isSocial($0.url) }.prefix(maxResults))
        var results: [(title: String, date: String?, snippet: String)] = []
        var cites: [ChatSession.Message.Citation] = []
        for (i, l) in top.enumerated() {
            let title = MarkdownPlain.label(l.title)
            let snippet = MarkdownPlain.label(l.snippet ?? "")
            // live-32 (2) — a Wikipedia passage keeps more (it is the answer's evidence), dated by its last edit.
            let wiki = WikipediaGrounding.isPassage(l)
            let cap = wiki ? wikiCap : snippetCap
            let clipped = snippet.count > cap ? String(snippet.prefix(cap)) + "…" : snippet
            let date = wiki ? l.published.map { "Wikipedia, last edited " + WebGrounding.dayString($0) }
                            : l.published.map { "published " + WebGrounding.dayString($0) }
            results.append((title, date, clipped))
            cites.append(.init(index: i + 1, url: l.url, title: title, snippet: String(clipped.prefix(snippetCap))))
        }
        return (results, cites)
    }

    /// The answer turn (`AppleWebQuery.turnPacket` / `turnInstructions`): the results in the turn, labelled as the app's
    /// own search today; the question at the end. (Kept short: refusal rate is the constraint — live-23.)
    static func turn(question: String, query: String, results: [(title: String, date: String?, snippet: String)],
                     voice: String, currentState: Bool = true, now: Date = Date()) -> (systemPrompt: String, modelText: String) {
        (voice + " " + AppleWebQuery.turnInstructions + (WikipediaGrounding.live31 || !currentState ? "" : " " + AppleWebQuery.evidenceInstruction),
         AppleWebQuery.turnPacket(day: WebGrounding.dayString(now), query: query, question: question, results: results))
    }
}

#if DEBUG
/// `-AppleWebSelfTest` (with `-StubOnDeviceModel YES -WebSearchMock YES`) — B5 through the REAL General send:
/// Apple Intelligence (stubbed) + a stubbed provider → the packet is in the turn → the answer's [n] become web chips →
/// "Apple Intelligence + web" → no training-data line; an uncited answer gets "didn't confirm"; the switch off → the
/// "Web search is off" notice. RED (today's code): no search, no packet, no chips.
/// live-30 (A1) — + follow-ups (the rewrite, its year rule, the fallback, "thanks" isn't searched), the results in the
/// instructions, the search row, social hosts out, "the results don't answer it" → unconfirmed. RED: `-AppleWebFollowUpOff YES`.
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
        let pk = AppleWebGrounding.packet(links: links, now: fixedNow)
        row("packet-is-top-3-plain-capped", pk.citations.count == 3 && pk.results.allSatisfy { !$0.title.contains("####") && !$0.snippet.contains("**") }
            && pk.results[2].title == "Result 3" && pk.citations.allSatisfy { $0.snippet.count <= 301 }, pk.results.map(\.title).joined(separator: ", "))
        // live-30 (A1) — pure rows (also run by the Mac harness).
        for r in AppleWebQuery.selfTestRows(now: fixedNow) { row(r.name, r.ok, r.detail) }
        let social = [ToolLink(title: "Clip", url: "https://www.youtube.com/watch?v=1", snippet: "a"),
                      ToolLink(title: "Post", url: "https://www.instagram.com/p/1", snippet: "b")] + links
        let pkS = AppleWebGrounding.packet(links: social, now: fixedNow)
        row("social-hosts-never-reach-the-packet", pkS.citations.count == 3 && !pkS.citations.contains { AppleWebQuery.isSocial($0.url ?? "") },
            "\(pkS.citations.map { $0.url ?? "-" })")

        // The real send path — Apple Intelligence (stub) + the mock provider.
        let lib = LibrarianState(); lib.corpusAware = false
        let chat = ChatSession()
        let q1 = "What is the latest news about the Lakeview Observatory telescope?"
        await lib.groundedSend(query: q1, store: store, chat: chat)
        let a1 = chat.messages.last { $0.role == .assistant }
        row("first-turn-query-unchanged", AppleWebGrounding.debugLastQuery == AppleWebGrounding.query(for: q1) && AppleWebGrounding.debugLastHow == "first turn",
            "\(AppleWebGrounding.debugLastHow): \(AppleWebGrounding.debugLastQuery)")
        row("results-are-labelled-as-the-app's-search", ModelRouter.debugLastApplePrompt.hasPrefix("Web results the app found today")
            && ModelRouter.debugLastApplePrompt.contains("[1] ") && ModelRouter.debugLastApplePrompt.hasSuffix("Question: \(q1)")
            && ModelRouter.debugLastAppleInstructions.contains("not from the user"), "prompt=\(ModelRouter.debugLastApplePrompt.prefix(60))")
        row("the-turn-shows-the-search-row", chat.messages.contains { $0.role == .activity && $0.activity?.label == "Searched the web"
            && $0.activity?.detail == AppleWebGrounding.debugLastQuery }, "\(chat.messages.map(\.role.rawValue))")
        row("the-answer's-[n]-are-web-chips", (a1?.citations ?? []).contains { $0.url?.contains("gauntlet.example") == true },
            "\(a1?.citations?.map { $0.url ?? "-" } ?? [])")
        row("caption-Apple-Intelligence-+-web", a1?.provenance?.caption == "Apple Intelligence + web", a1?.provenance?.caption ?? "nil")
        row("no-training-data-line-after-a-search", a1?.datedKnowledge != true && a1?.generalKnowledge != true,
            "dated=\(a1?.datedKnowledge ?? false) general=\(a1?.generalKnowledge ?? false)")

        // A vague follow-up: searched again, with the rewrite (stub: names the topic, writes a stale 2024) + the year rule.
        await lib.groundedSend(query: "So where does it stand now?", store: store, chat: chat)
        let y = String(Calendar(identifier: .gregorian).component(.year, from: Date()))
        row("follow-up-searches-the-rewrite", AppleWebGrounding.debugLastHow == "rewritten" && AppleWebGrounding.debugLastQuery.contains("Lakeview"),
            "\(AppleWebGrounding.debugLastHow): \(AppleWebGrounding.debugLastQuery)")
        row("year-rule-on-the-rewrite", !AppleWebGrounding.debugLastQuery.contains("2024") && AppleWebGrounding.debugLastQuery.hasSuffix(y),
            AppleWebGrounding.debugLastQuery)
        // The rewrite fails → the previous search's query + the new question.
        let before = AppleWebGrounding.debugLastQuery
        AppleWebGrounding.debugRewriteFails = true
        await lib.groundedSend(query: "Who built it?", store: store, chat: chat)
        AppleWebGrounding.debugRewriteFails = false
        row("rewrite-fails-falls-back", AppleWebGrounding.debugLastHow == "fallback"
            && AppleWebGrounding.debugLastQuery == AppleWebQuery.fallbackQuery(previousQuery: before, question: "Who built it?"),
            "\(AppleWebGrounding.debugLastHow): \(AppleWebGrounding.debugLastQuery)")
        // Chit-chat after a search isn't searched.
        let rows0 = chat.messages.filter { $0.role == .activity }.count
        await lib.groundedSend(query: "Thanks!", store: store, chat: chat)
        row("thanks-isn't-searched", chat.messages.filter { $0.role == .activity }.count == rows0)

        // An answer that cites nothing: the (B3) line, never training data. (The stub cites nothing for "lighthouse".)
        let chat2 = ChatSession()
        await lib.groundedSend(query: "What is the latest news about the Lakeview Observatory lighthouse?", store: store, chat: chat2)
        let a2 = chat2.messages.last { $0.role == .assistant }
        row("uncited-after-a-search-says-didn't-confirm", a2?.searchUnconfirmed == true && a2?.datedKnowledge != true,
            "unconfirmed=\(a2?.searchUnconfirmed ?? false) dated=\(a2?.datedKnowledge ?? false)")
        // live-30 (A1) — an answer that cites [1] [2] only to say they don't answer it: unconfirmed, no chips, no markers.
        let chat4 = ChatSession()
        await lib.groundedSend(query: "When does the Lakeview Observatory telescope reopen to visitors?", store: store, chat: chat4)
        let a4 = chat4.messages.last { $0.role == .assistant }
        row("says-the-results-don't-answer-→-unconfirmed", a4?.searchUnconfirmed == true && a4?.citations == nil && a4?.text.contains("[1]") == false,
            "unconfirmed=\(a4?.searchUnconfirmed ?? false) chips=\(a4?.citations?.count ?? 0) text=\(a4?.text.prefix(60) ?? "")")

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
