import Foundation
import FoundationModels

/// live-33 (T ruled 2026-10-21) — the web pipeline on the pattern established chat apps converged on (Perplexica,
/// HuggingChat chat-ui, Open WebUI, LibreChat — Ops `sounding-board/2026-10-21-web-search-prior-art.md`):
///
/// 1. QUERY — a model writes the search query from the chat (the A1 standalone rewrite, now for EVERY search): on-device
///    (Apple Foundation Models); where that's unavailable, a short call to the answering model; last resort, the question
///    with its request words removed. Then the app's year rule (small models write stale years — live-28).
/// 2. FETCH — the provider's results with their page text, the Wikipedia articles for the same query, the top page where
///    it is read.
/// 3. RERANK BY MEANING — the text split into passages; the query and each passage embedded on-device (the app's BGE
///    embedder, the one the Library's retrieval uses; unit vectors, raw cosine); the closest passages above a floor are
///    what the model sees, numbered by source. Nothing clears the floor → no web passages (the honest line follows).
///
/// It replaces live-27…32's word rules (host / Q&A / undated / stale-year drops, subject-word windows, the news and
/// current-state framings, computed-fact notes). Nothing leaves the phone for the rerank.
extension WebEvidence {

    // MARK: - 1. The query

    #if DEBUG
    /// Self-test seams: a fixed rewrite (or none), and the last query made.
    nonisolated(unsafe) static var debugRewrite: String?? = nil
    nonisolated(unsafe) static var debugLast: (query: String, how: String, ms: Int) = ("", "", 0)
    #endif

    /// The query this search uses and how it was written ("rewritten on-device" · "rewritten by the model" · "request
    /// words removed"). The rewrite sees the last few turns when the question leans on them (`needsContext`; a new
    /// standalone question is rewritten on its own — the gauntlet saw an unrelated earlier topic carried into it).
    @MainActor static func searchQuery(for question: String, chat: ChatSession, now: Date = Date()) async
        -> (query: String, wikiQuery: String, how: String, ms: Int) {
        let t0 = Date()
        let prior = AppleWebGrounding.priorTurns(chat)
        let turns = AppleWebQuery.needsContext(question) ? prior : []
        let typed = (prior.map(\.question) + [question]).joined(separator: " ")
        var raw: String? = nil, how = ""
        if live32 {
            raw = prior.isEmpty || !AppleWebQuery.needsContext(question) ? question : nil
            how = "live-32 (as written)"
        } else {
            #if DEBUG
            if let fixed = debugRewrite { raw = fixed; how = "rewritten (self-test)" }
            #endif
            if how.isEmpty {
                let r = await onDeviceRewrite(turns: turns, latest: question)
                if let q = r.query { raw = q; how = "rewritten on-device" }
                // live-37 (1) — an on-device rewrite that timed out isn't followed by a second one on the answering model
                // (live-36: with the 30B resident, 5 s on-device + 10 s on the Host = ~15 s per turn, then the fallback).
                else if !(Live37.query && r.timedOut), let q = await modelRewrite(turns: turns, latest: question) { raw = q; how = "rewritten by the model" }
                else if r.timedOut { how = "rewrite timed out" }
            }
        }
        // live-37 (1) — the rewrite may resolve what the conversation refers to ("he" → the chancellor it named), never add:
        // a name or a number that isn't in the conversation came from the model's memory (live-36: "iPhone 15", "Pixel 8",
        // "Angela Merkel", "from George H. W. Bush to Joe Biden") → the rewrite is discarded and the user's own words are
        // searched (live-36's accidental A/B: the user's words won 4 cases and lost none).
        if Live37.query, let r = raw, how.hasPrefix("rewritten") {
            let conversation = (prior.flatMap { [$0.question, $0.answer] } + [question]).joined(separator: "\n")
            let added = AppleWebQuery.addedTerms(r, conversation: conversation)
            if !added.isEmpty { raw = nil; how = "rewrite added \(added.joined(separator: ", "))" }
        }
        if raw == nil {
            raw = AppleWebQuery.fallbackQuery(previousQuery: turns.isEmpty ? nil : AppleWebGrounding.previousSearchQuery(chat),
                                              question: strippedQuestion(question))
            how = how.hasPrefix("rewrite ") ? how + " → request words removed" : "request words removed"
        }
        let base = raw ?? question
        // live-35 (1) — today's year goes back on a CURRENT-STATE query only (measured best in live-34: 27/40 results
        // carried the current fact vs 23/40 with no year and 22/40 with Tavily's past-year filter). News keeps the
        // provider's freshness window and gets no year (decided by the query, like `SearchFreshness.forTurn`); timeless
        // questions get neither. The model's stale years still go; a year the user typed stays.
        // (live-34 RED `-Live34Web`: no year at all; live-33 RED `-Live33Web`: the year on news too.)
        let cs = WebGrounding.asksCurrentState(question) || WebGrounding.asksCurrentState(base)
        let current = Live34.red ? cs : (!Live35.red && cs && !WebGrounding.isNewsQuestion(base))
        let q = AppleWebQuery.applyYearRule(base, userText: typed, currentState: current, now: now)
        // Wikipedia's search takes the same query without a freshness year (it would favour "2026 in …" articles).
        let wq = AppleWebQuery.applyYearRule(base, userText: typed, currentState: false, now: now)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        #if DEBUG
        debugLast = (q, how, ms)
        #endif
        return (q, wq, how, ms)
    }

    /// The on-device rewrite (Apple Foundation Models): no tools, ≤ 40 tokens, 5 s. nil when unavailable or unusable;
    /// `timedOut` when it didn't answer in time.
    /// live-37 (1) — measured on live-36's runs (this Mac's Apple Intelligence, the Simulator): a rewrite that answers takes
    /// 3.5 s median, 3.9–5.0 s at the 95th percentile (Apple 3.9, with the 4B resident 4.6, the 8B 5.0); with the 30B
    /// resident it never answered. A 3 s cap would have cut almost every rewrite, so the cap stays 5 s and a timeout goes
    /// straight to the user's words (no second rewrite on the Host: worst case 5 s instead of ~15 s).
    @MainActor private static func onDeviceRewrite(turns: [(question: String, answer: String)], latest: String) async -> (query: String?, timedOut: Bool) {
        #if DEBUG
        if AppleWebGrounding.debugRewriteFails { return (nil, false) }
        if UserDefaults.standard.bool(forKey: "StubOnDeviceModel") {
            // Stub: names the earlier topic and writes a STALE year (the year rule must take it out).
            return (turns.contains { $0.question.contains("Lakeview") } ? "Lakeview Observatory telescope status 2024" : nil, false)
        }
        #endif
        guard SystemLanguageModel.default.isAvailable else { return (nil, false) }
        let prompt = AppleWebQuery.rewritePrompt(turns: turns, latest: latest)
        let answered = await withTimeoutReporting(5) {
            let r = try? await LanguageModelSession(instructions: AppleWebQuery.rewriteInstructions)
                .respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 40)).content
            return r ?? ""
        }
        guard let raw = answered else { return (nil, true) }
        guard !raw.isEmpty, !AppleChat.isRefusalText(raw) else { return (nil, false) }
        return (AppleWebQuery.cleanRewrite(raw), false)
    }

    /// Where the on-device model is unavailable: one short call to the answering model (the Host's or the server's).
    @MainActor private static func modelRewrite(turns: [(question: String, answer: String)], latest: String) async -> String? {
        #if DEBUG
        if AppleWebGrounding.debugRewriteFails { return nil }
        #endif
        switch ModelRouter.active {
        case .host, .ollama: break
        default: return nil
        }
        let prompt = AppleWebQuery.rewritePrompt(turns: turns, latest: latest)
        // live-37 (1) — 5 s (was 10): the same cap as the on-device rewrite; then the user's words.
        let raw = await withTimeout(Live37.query ? 5 : 10) {
            try? await ModelRouter.generate(systemPrompt: AppleWebQuery.rewriteInstructions, userPrompt: prompt, maxTokens: 40)
        }
        return raw.map(ChatSession.stripThinkTags).flatMap(AppleWebQuery.cleanRewrite)
    }

    private static func withTimeout(_ seconds: Double, _ work: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    /// The same, telling a timeout (nil) from an answer, empty when the call failed.
    private static func withTimeoutReporting(_ seconds: Double, _ work: @escaping @Sendable () async -> String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - The evidence a turn gets (shared by the live paths and `-WebRetrievalRun`)

    /// The Apple Intelligence path's evidence: the query, the provider's results + the Wikipedia articles for the same
    /// query, reranked (`appleWebBudget`). Starts the trace's turn. live-37 (4) — one function for the live turn and the
    /// retrieval-only run, so the run measures what the turn does.
    @MainActor static func appleEvidence(question: String, chat: ChatSession, webKey: Bool) async
        -> (sq: (query: String, wikiQuery: String, how: String, ms: Int), result: ToolResult,
            rr: (links: [ToolLink], scored: [Scored], ms: Int, sources: [Source])) {
        let sq = await searchQuery(for: question, chat: chat)
        let searchQuery = sq.query
        #if DEBUG
        AppleWebGrounding.debugLastQuery = searchQuery
        AppleWebGrounding.debugLastHow = sq.how
        NSLog("[AppleWeb] query (%@): %@", sq.how, searchQuery)
        WebTrace.shared.beginTurn(question)
        WebTrace.shared.note("query", ["query": searchQuery, "wikiQuery": sq.wikiQuery, "how": sq.how, "rewriteMs": sq.ms,
                                       "path": webKey ? "app-search" : "wikipedia-only"])
        let fetchStart = WebTrace.shared.ms
        #endif
        async let wikiSources = WikipediaGrounding.sources(query: sq.wikiQuery)
        var result = ToolResult(textForModel: "", links: [])
        if webKey {
            result = await WebSearchBackend.make().execute(name: AgentTools.webSearch,
                                                           arguments: ["query": searchQuery, "count": AppleWebQuery.requestCount,
                                                                       "freshness": SearchFreshness.forTurn(question: question, query: searchQuery).rawValue])
        }
        let web = result.links.filter { AppleWebGrounding.live29 || !AppleWebQuery.isSocial($0.url) }
        let wiki = await wikiSources
        // the meaning to match: the query without the app's freshness year (that is for the provider)
        let budget = appleWebBudget
        let rr = await rerank(query: sq.wikiQuery, sources: wiki + web.map(source), budget: budget)
        #if DEBUG
        WebTrace.shared.note("tool", ["name": "web_search", "id": "app_search", "startMs": fetchStart, "args": ["query": searchQuery],
                                      "links": WebTrace.links(result.links), "failed": result.failed, "rateLimited": result.rateLimited, "text": ""])
        WebTrace.shared.note("rerank", WebTrace.rerank(rr).merging(["budget": budget.label, "budgetChars": budget.chars, "topK": budget.topK,
                                                                    "perSource": budget.perSource]) { $1 })
        #endif
        return (sq, result, rr)
    }

    /// The Host / server path's evidence from one web search's results: social / video hosts out; for the app's own search
    /// the top page's text (`fetchTop`, a factual question) and the Wikipedia articles join; every passage reranked against
    /// `query` within the model's budget.
    static func hostEvidence(_ result: ToolResult, appSearch: Bool, fetchTop: Bool, executor: ToolExecutor,
                             wiki: [Source]?, query: String, budget: Budget, callStart: Int = 0) async
        -> (links: [ToolLink], scored: [Scored], ms: Int, sources: [Source]) {
        let web = WebGrounding.hostLinks(result.links)
        var sources = web.map(source)
        if appSearch {
            if fetchTop, let top = web.first {
                let page = await executor.execute(name: AgentTools.fetchURL, arguments: ["url": top.url])
                if !page.failed, !page.textForModel.hasPrefix("Couldn't fetch"), !page.textForModel.hasPrefix("Invalid URL") {
                    sources[0] = Source(title: top.title, url: top.url, published: top.published, wikipedia: false,
                                        text: (top.snippet ?? "") + "\n" + String(page.textForModel.prefix(pageChars)))
                }
                #if DEBUG
                WebTrace.shared.note("tool", ["name": AgentTools.fetchURL, "id": "app_fetch", "startMs": callStart, "url": top.url,
                                              "args": ["url": top.url], "links": [], "failed": page.failed, "rateLimited": false,
                                              "text": String(page.textForModel.prefix(4_000))])
                #endif
            }
            if let wiki { sources = wiki + sources }
        }
        let rr = await rerank(query: query, sources: sources, budget: budget)
        #if DEBUG
        WebTrace.shared.note("rerank", WebTrace.rerank(rr).merging(["budget": budget.label, "budgetChars": budget.chars, "topK": budget.topK,
                                                                    "perSource": budget.perSource]) { $1 })
        #endif
        return rr
    }

    // MARK: - 3. The rerank

    /// The kept passages as the sources the model sees: one link per source that kept any, best source first, its
    /// passages in page order. (A Wikipedia source keeps the "Wikipedia: " title — `WikipediaGrounding.isPassage`.)
    /// live-37 (2) — the best source first, the second best last (`edgesFirst`).
    static func links(_ sources: [Source], _ scored: [Scored]) -> [ToolLink] {
        let kept = scored.filter(\.kept)
        let best = Dictionary(grouping: kept, by: \.source).mapValues { $0.map(\.score).max() ?? 0 }
        return edgesFirst(best.keys.sorted { best[$0]! > best[$1]! }).map { i in
            let s = sources[i]
            let text = kept.filter { $0.source == i }.map(\.text).joined(separator: " … ")
            return ToolLink(title: (s.wikipedia ? WikipediaGrounding.titlePrefix : "") + s.title, url: s.url, snippet: text, published: s.published)
        }
    }

    /// Rerank the fetched sources against the query: the passages the model sees (as links), every passage's score, the
    /// time, and the sources as scored (duplicates merged).
    /// live-32 (`-Live32Web`): every source passed whole, in order, no rerank.
    static func rerank(query: String, sources: [Source], budget: Budget) async -> (links: [ToolLink], scored: [Scored], ms: Int, sources: [Source]) {
        let t0 = Date()
        guard !live32 else {
            return (sources.map { ToolLink(title: ($0.wikipedia ? WikipediaGrounding.titlePrefix : "") + $0.title, url: $0.url,
                                           snippet: String($0.text.prefix(300)), published: $0.published) }, [], 0, sources)
        }
        guard !sources.isEmpty else { return ([], [], 0, []) }
        // one source per page: the provider's copy of a Wikipedia article joins the article (seen: "2026 NBA Finals" twice)
        var merged: [Source] = []
        for src in sources {
            func key(_ u: String) -> String { let n = WebGrounding.normalize(u); return n.removingPercentEncoding ?? n }
            if let k = merged.firstIndex(where: { key($0.url) == key(src.url) }) {
                let m = merged[k]
                merged[k] = Source(title: m.title, url: m.url, published: m.published ?? src.published, wikipedia: m.wikipedia || src.wikipedia,
                                   text: m.text + "\n" + src.text)
            } else { merged.append(src) }
        }
        let sources = merged
        // every passage, with its source's title (it says what the page is about; the model sees the passage only)
        // live-37 (3) — boilerplate passages out: the title embedded with every passage lifted a page's menu text with it
        // (CNBC's "Skip Navigation Markets…" under an iPhone-pricing title scored 0.82, the answer 0.75). The passage alone
        // (`Live37.titleOut`) is measured but off: it needs the floor recalibrated.
        // (Kept in the scores at 0, never embedded, so the trace shows what was dropped.)
        let all = sources.enumerated().flatMap { i, s in passages(s.text).map { (source: i, text: $0) } }
        let boiler = all.filter { Live37.boilerplate && isBoilerplate($0.text) }
        let items = all.filter { !(Live37.boilerplate && isBoilerplate($0.text)) }
            .map { (source: $0.source, text: $0.text, embed: Live37.titleOut ? $0.text : MarkdownPlain.label(sources[$0.source].title) + ". " + $0.text) }
        let vs = await CardEmbeddingService.shared.embedBatch([query] + items.map(\.embed))
        guard let qv = vs.first ?? nil else { return ([], [], 0, sources) }
        var scored: [Scored] = []
        for (k, it) in items.enumerated() {
            guard let v = vs[k + 1] else { continue }
            scored.append(Scored(source: it.source, text: it.text, score: cosine(qv, v), kept: false))
        }
        scored += boiler.map { Scored(source: $0.source, text: $0.text, score: 0, kept: false) }
        scored = select(scored, floor: floor, budget: budget)
        return (links(sources, scored), scored, Int(Date().timeIntervalSince(t0) * 1000), sources)
    }

    /// A provider result as a source (its page text as the provider gave it).
    static func source(_ l: ToolLink) -> Source {
        Source(title: l.title, url: l.url, published: l.published, wikipedia: false, text: l.snippet ?? "")
    }

}
