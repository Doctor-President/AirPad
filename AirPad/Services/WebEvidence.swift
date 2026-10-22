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
            if how.isEmpty, let r = await onDeviceRewrite(turns: turns, latest: question) { raw = r; how = "rewritten on-device" }
            if raw == nil, how.isEmpty, let r = await modelRewrite(turns: turns, latest: question) { raw = r; how = "rewritten by the model" }
        }
        if raw == nil {
            raw = AppleWebQuery.fallbackQuery(previousQuery: turns.isEmpty ? nil : AppleWebGrounding.previousSearchQuery(chat),
                                              question: strippedQuestion(question))
            how = "request words removed"
        }
        let base = raw ?? question
        let current = WebGrounding.asksCurrentState(question) || WebGrounding.asksCurrentState(base)
        let q = AppleWebQuery.applyYearRule(base, userText: typed, currentState: current, now: now)
        // Wikipedia's search takes the same query without the freshness year (it would favour "2026 in …" articles).
        let wq = AppleWebQuery.applyYearRule(base, userText: typed, currentState: false, now: now)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        #if DEBUG
        debugLast = (q, how, ms)
        #endif
        return (q, wq, how, ms)
    }

    /// The on-device rewrite (Apple Foundation Models): no tools, ≤ 40 tokens, 5 s. nil when unavailable or unusable.
    @MainActor private static func onDeviceRewrite(turns: [(question: String, answer: String)], latest: String) async -> String? {
        #if DEBUG
        if AppleWebGrounding.debugRewriteFails { return nil }
        if UserDefaults.standard.bool(forKey: "StubOnDeviceModel") {
            // Stub: names the earlier topic and writes a STALE year (the year rule must take it out).
            return turns.contains { $0.question.contains("Lakeview") } ? "Lakeview Observatory telescope status 2024" : nil
        }
        #endif
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = AppleWebQuery.rewritePrompt(turns: turns, latest: latest)
        let raw = await withTimeout(5) {
            try? await LanguageModelSession(instructions: AppleWebQuery.rewriteInstructions)
                .respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 40)).content
        }
        guard let raw, !AppleChat.isRefusalText(raw) else { return nil }
        return AppleWebQuery.cleanRewrite(raw)
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
        let raw = await withTimeout(10) {
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

    // MARK: - 3. The rerank

    /// The kept passages as the sources the model sees: one link per source that kept any, best source first, its
    /// passages in page order. (A Wikipedia source keeps the "Wikipedia: " title — `WikipediaGrounding.isPassage`.)
    static func links(_ sources: [Source], _ scored: [Scored]) -> [ToolLink] {
        let kept = scored.filter(\.kept)
        let best = Dictionary(grouping: kept, by: \.source).mapValues { $0.map(\.score).max() ?? 0 }
        return best.keys.sorted { best[$0]! > best[$1]! }.map { i in
            let s = sources[i]
            let text = kept.filter { $0.source == i }.map(\.text).joined(separator: " … ")
            return ToolLink(title: (s.wikipedia ? WikipediaGrounding.titlePrefix : "") + s.title, url: s.url, snippet: text, published: s.published)
        }
    }

    /// Rerank the fetched sources against the query: the passages the model sees (as links), every passage's score, the
    /// time, and the sources as scored (duplicates merged).
    /// live-32 (`-Live32Web`): every source passed whole, in order, no rerank.
    static func rerank(query: String, sources: [Source], budget: Int) async -> (links: [ToolLink], scored: [Scored], ms: Int, sources: [Source]) {
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
        let items = sources.enumerated().flatMap { i, s in passages(s.text).map { (source: i, text: $0, embed: MarkdownPlain.label(s.title) + ". " + $0) } }
        let vs = await CardEmbeddingService.shared.embedBatch([query] + items.map(\.embed))
        guard let qv = vs.first ?? nil else { return ([], [], 0, sources) }
        var scored: [Scored] = []
        for (k, it) in items.enumerated() {
            guard let v = vs[k + 1] else { continue }
            scored.append(Scored(source: it.source, text: it.text, score: cosine(qv, v), kept: false))
        }
        scored = select(scored, floor: floor, budget: budget)
        return (links(sources, scored), scored, Int(Date().timeIntervalSince(t0) * 1000), sources)
    }

    /// A provider result as a source (its page text as the provider gave it).
    static func source(_ l: ToolLink) -> Source {
        Source(title: l.title, url: l.url, published: l.published, wikipedia: false, text: l.snippet ?? "")
    }

}
