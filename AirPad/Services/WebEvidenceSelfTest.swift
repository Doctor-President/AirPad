import Foundation

#if DEBUG
/// live-32 (2) — `-WebEvidenceSelfTest`: the evidence, its weighing and the server model's reasoning, pure parts (synthetic
/// content: the invented Lakeview Republic and its First Minister). live-33 — the pipeline (`WebEvidence`): every search
/// uses the rewrite, the rerank's floor and selection (the real on-device embedder; run with `-EmbedCPUOnly` on the
/// Simulator). RED: `-Live32Web YES` (live-32's query and evidence). The send itself is checked on the stub stack
/// (`scripts/runaway/run.sh`, `WebEvidenceUI`) and live (`scripts/live`).
enum WebEvidenceSelfTest {
    @MainActor static func run() async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let red = WebEvidence.live32
        let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

        // T's two turns (live-32) and his TF 202610211551 sentence (live-33).
        let t2 = "you're not showing the current president. Joe Biden is no longer president"
        let tSentence = "Can you print for me a table of the last 10 US presidents up until today"

        // Whether to search: today's decision logic, unchanged.
        let plan = WebGrounding.hostPrefetch(t2, searchIntent: false, lastAnswerSearched: true)
        row("T's-correction-is-a-follow-up", plan.prefetch == "search" && plan.followUp, "\(plan)")
        row("a-new-question-is-no-correction", !AppleWebQuery.isCorrection("What is the capital of the Lakeview Republic?")
            && AppleWebQuery.isCorrection("That's out of date — the First Minister changed in March"))

        // 1. The query: every search uses the rewrite (a first turn too), then the year rule; no rewrite → the request words go.
        let fresh = ChatSession()
        WebEvidence.debugRewrite = .some("US presidents list")
        let q1 = await WebEvidence.searchQuery(for: tSentence, chat: fresh, now: now)
        WebEvidence.debugRewrite = nil
        row("every-search-uses-the-rewrite", q1.how.hasPrefix("rewritten") && q1.query == "US presidents list 2026" && q1.wikiQuery == "US presidents list",
            "\(q1.how): \(q1.query) | wiki: \(q1.wikiQuery)")
        AppleWebGrounding.debugRewriteFails = true
        let q2 = await WebEvidence.searchQuery(for: tSentence, chat: fresh, now: now)
        AppleWebGrounding.debugRewriteFails = false
        row("no-rewrite-→-request-words-removed-never-the-raw-sentence", q2.how == "request words removed"
            && q2.query == "the last 10 US presidents up until today 2026", "\(q2.how): \(q2.query)")
        row("request-words", WebEvidence.strippedQuestion("could you make me a list of the last five popes?") == "the last five popes"
            && WebEvidence.strippedQuestion("show me the current justices of the US Supreme Court") == "current justices of the US Supreme Court"
            && WebEvidence.strippedQuestion("Who is Japan's prime minister?") == "Who is Japan's prime minister",
            [WebEvidence.strippedQuestion("could you make me a list of the last five popes?"),
             WebEvidence.strippedQuestion("show me the current justices of the US Supreme Court")].joined(separator: " | "))
        row("rewrite-ms-measured", q1.ms >= 0, "\(q1.ms) ms (self-test seam)")

        // 3. The rerank: passages, the floor, the selection.
        let car = WebEvidence.Source(title: "When Is the Best Time to Buy a New Car? | Edmunds", url: "https://www.edmunds.com/car-buying/best-time",
                                     published: nil, wikipedia: false,
                                     text: "The best time to buy a new car is at the end of the year, when dealers push to hit their sales targets. October, November and December bring the year-end clearance. Holiday weekends such as Memorial Day and Labor Day also bring discounts on outgoing models.")
        let wikiPres = WebEvidence.Source(title: "List of presidents of the United States", url: WikipediaGrounding.articleURL("List of presidents of the United States"),
                                          published: ISO8601DateFormatter().date(from: "2026-10-20T10:57:51Z"), wikipedia: true,
                                          // the article's lead as Wikipedia served it on 2026-10-21 (its first two paragraphs)
                                          text: "The president of the United States is the head of state and head of government of the United States, indirectly elected to a four-year term via the Electoral College. Under the U.S. Constitution, the officeholder leads the executive branch of the federal government and is the commander-in-chief of the United States Armed Forces.\nThe first president, George Washington, won a unanimous vote of the Electoral College. The incumbent president is Donald Trump, who assumed office on January 20, 2025. Since the office was established in 1789, 45 men have served in 47 presidencies. The discrepancy is due to the nonconsecutive terms of Grover Cleveland (counted as the 22nd and 24th president) and Donald Trump (counted as the 45th and 47th president).")
        // the query the on-device rewrite wrote for T's sentence (the Mac harness, live-33)
        let rr = await WebEvidence.rerank(query: "List of US presidents from the last 10 up to today", sources: [car, wikiPres], budget: WebEvidence.hostBudget)
        let scores = rr.scored.map { "\($0.source == 0 ? "car" : "wiki") \(String(format: "%.3f", $0.score))\($0.kept ? "*" : "")" }.joined(separator: ", ")
        row("rerank-floor-drops-an-off-topic-page", rr.links.map(\.url) == [wikiPres.url] && rr.links.first.map(WikipediaGrounding.isPassage) == true
            && rr.links.first?.snippet?.contains("The incumbent president is Donald Trump") == true, "\(scores) · \(rr.ms) ms")
        let lone = await WebEvidence.rerank(query: "List of US presidents from the last 10 up to today", sources: [car], budget: WebEvidence.hostBudget)
        row("a-lone-off-topic-page-is-never-passed", lone.links.isEmpty, lone.scored.map { String(format: "%.3f", $0.score) }.joined(separator: ", "))
        let dupe = await WebEvidence.rerank(query: "last 10 US presidents", sources: [wikiPres, WebEvidence.Source(title: "List of presidents of the United States - Wikipedia",
            url: "https://en.wikipedia.org/wiki/List_of_presidents_of_the_United_States/", published: nil, wikipedia: false, text: "Joe Biden served as the 46th president from 2021 to 2025.")],
            budget: WebEvidence.hostBudget)
        row("one-source-per-page", dupe.links.count == 1 && dupe.sources.count == 1 && dupe.links.first.map(WikipediaGrounding.isPassage) == true, "\(dupe.links.map(\.url))")
        let filler = String(repeating: "Portraits and biographies of every holder of the office hang in the assembly hall. ", count: 10)
        let lake = WebEvidence.Source(title: "First Minister of the Lakeview Republic", url: "https://lakeview.example.gov/first-minister", published: nil,
                                      wikipedia: false, text: filler + "Ilsa Vane became First Minister of the Lakeview Republic on 14 March 2026, succeeding Mara Quill.")
        let rl = await WebEvidence.rerank(query: "current First Minister of the Lakeview Republic", sources: [lake], budget: WebEvidence.hostBudget)
        row("the-passage-that-answers-is-kept", rl.links.first?.snippet?.contains("Ilsa Vane became First Minister") == true,
            rl.scored.map { "\(String(format: "%.3f", $0.score))\($0.kept ? "*" : "")" }.joined(separator: ", "))
        // calibration (diagnostic): more pairs, the scores logged
        var cal: [String] = []
        for (q, t) in [("who won the latest NBA championship 2026", "The New York Knicks won the 2026 NBA Finals, beating the Oklahoma City Thunder in six games."),
                       ("who won the latest NBA championship 2026", "The Knicks' new arena seating plan was revealed on Tuesday."),
                       ("Japan prime minister 2026", "Sanae Takaichi became Prime Minister of Japan in October 2025."),
                       ("Japan prime minister 2026", "Tokyo's cherry blossoms peak in late March and early April."),
                       ("why is the sky blue", "Rayleigh scattering of sunlight by air molecules makes the sky appear blue."),
                       ("why is the sky blue", "Blue Sky Studios was an American animation studio.")] {
            if let a = await CardEmbeddingService.shared.embed(q), let b = await CardEmbeddingService.shared.embed(t) {
                cal.append("\(String(format: "%.3f", WebEvidence.cosine(a, b))) \(t.prefix(28))")
            }
        }
        row("calibration (diagnostic)", true, cal.joined(separator: " · "))
        let pure = (0..<8).map { WebEvidence.Scored(source: $0 % 2, text: String(repeating: "x", count: 400), score: 0.9 - Float($0) * 0.01, kept: false) }
        let sel = WebEvidence.select(pure, floor: 0.5, budget: 2_000)
        row("select-top-k-per-source-budget", sel.filter(\.kept).count == 5 && sel.filter { $0.kept && $0.source == 0 }.count == 3,
            "\(sel.filter(\.kept).count) kept")
        let ps = WebEvidence.passages(filler + "Ilsa Vane took office.")
        row("passages-on-sentence-boundaries", ps.count >= 2 && ps.allSatisfy { $0.count <= WebEvidence.passageChars } && ps.last?.hasSuffix("Ilsa Vane took office.") == true,
            "\(ps.count) passages")

        // Wikipedia: markup to text, the infobox, the edit date (no "current evidence" framing).
        row("wiki-markup-to-text", WikipediaGrounding.plain("[[Ilsa Vane|Ilsa Vane]]<ref name=a>x</ref>") == "Ilsa Vane"
            && WikipediaGrounding.plain("{{Death date and age|2024|12|29|1950|1|2}}") == "29 December 2024",
            WikipediaGrounding.plain("{{Death date and age|2024|12|29|1950|1|2}}"))
        let wikitext = """
        {{Infobox official post
        | post = First Minister
        | incumbent = [[Ilsa Vane]]
        | incumbent_since = {{start date|2026|3|14}}
        }}
        """
        let facts = WikipediaGrounding.infoboxFacts(wikitext)
        row("wiki-infobox-holder", facts.first == "Current holder: Ilsa Vane (since 14 March 2026)", facts.joined(separator: " · "))
        let edited = WikipediaGrounding.editedLine(ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z"), now: now)
        row("wiki-edit-date-stated-plainly", edited == "Wikipedia article, last edited 18 October 2026.", edited)
        row("user-agent-names-the-app", WikipediaGrounding.userAgent.hasPrefix("AirPad/") && WikipediaGrounding.userAgent.contains("https://")
            && !WikipediaGrounding.userAgent.contains("@"), WikipediaGrounding.userAgent)

        // The rules the model gets: where the results come from, that they beat memory, the citation, the honest line.
        row("one-sources-over-memory-line", WebGrounding.appSearchClause.contains(WebGrounding.sourcesRule)
            && AppleWebQuery.turnInstructions.contains("they are right") && !WebGrounding.appSearchClause.contains("Never present"))

        // The server model's reasoning: read (to the Thought process), never in the answer; off for a web turn.
        var content = ""; var accum: [Int: (id: String, name: String, args: String)] = [:]
        let seen = ReasoningBox()
        ModelRouter.accumulateAgentDelta(["reasoning_content": "Thinking Process: 1. Analyze"], content: &content, accum: &accum,
                                         onContentDelta: { _ in }, onReasoningDelta: { seen.add($0) })
        row("reasoning_content-goes-to-the-thought-process", seen.text == "Thinking Process: 1. Analyze" && content.isEmpty, "seen='\(seen.text)' content='\(content)'")
        row("reasoning-off-where-the-server-offers-it", ModelRouter.reasoningEffort(allowedOptions: ["off", "on"]) == "none"
            && ModelRouter.reasoningEffort(allowedOptions: ["low", "medium", "high"]) == "low"
            && ModelRouter.reasoningEffort(allowedOptions: []) == nil)

        // The providers' text: Brave's extra snippets and Tavily's content are kept past 300 characters (for the rerank).
        let brave = #"{"web":{"results":[{"title":"First Minister","url":"https://lakeview.example.gov/fm","description":"The office.","extra_snippets":["Ilsa Vane took office in March 2026."]}]}}"#
        let bl = BraveSearchToolExecutor.parseBrave(Data(brave.utf8))
        row("brave-extra-snippets", bl.first?.snippet?.contains("Ilsa Vane took office") == true, bl.first?.snippet ?? "nil")
        let tav = #"{"results":[{"title":"T","url":"https://lakeview.example.gov/t","content":"\#(filler)"}]}"#
        let tl = TavilySearchToolExecutor.parse(Data(tav.utf8))
        row("tavily-text-kept-for-the-rerank", (tl.first?.snippet?.count ?? 0) > 600, "\(tl.first?.snippet?.count ?? 0) chars")

        let passed = rows.filter { $0.1 }.count
        let lines = rows.map { "\($0.1 ? "ok  " : "BAD ") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined(separator: "\n")
        return "\(passed == rows.count ? "PASS" : "FAIL") — \(passed)/\(rows.count)\(red ? " (RED: -Live32Web)" : "")\n\(lines)"
    }
}

private final class ReasoningBox: @unchecked Sendable {
    private let lock = NSLock(); private var s = ""
    func add(_ r: String) { lock.withLock { s += r } }
    var text: String { lock.withLock { s } }
}
#endif
