import Foundation
import FoundationModels

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
        row("every-search-uses-the-rewrite", q1.how.hasPrefix("rewritten") && q1.query == "US presidents list" + (Live35.red ? "" : " 2026")
            && q1.wikiQuery == "US presidents list",
            "\(q1.how): \(q1.query) | wiki: \(q1.wikiQuery)")
        AppleWebGrounding.debugRewriteFails = true
        let q2 = await WebEvidence.searchQuery(for: tSentence, chat: fresh, now: now)
        AppleWebGrounding.debugRewriteFails = false
        row("no-rewrite-→-request-words-removed-never-the-raw-sentence", q2.how == "request words removed"
            // live-37 (1): "up until today" isn't news any more, so T's list is a current-state query (today's year on it)
            && q2.query == "the last 10 US presidents up until today" + (Live37.query && !Live35.red ? " 2026" : ""), "\(q2.how): \(q2.query)")
        row("request-words", WebEvidence.strippedQuestion("could you make me a list of the last five popes?") == "the last five popes"
            && WebEvidence.strippedQuestion("show me the current justices of the US Supreme Court") == "current justices of the US Supreme Court"
            && WebEvidence.strippedQuestion("Who is Japan's prime minister?") == "Who is Japan's prime minister",
            [WebEvidence.strippedQuestion("could you make me a list of the last five popes?"),
             WebEvidence.strippedQuestion("show me the current justices of the US Supreme Court")].joined(separator: " | "))
        row("rewrite-ms-measured", q1.ms >= 0, "\(q1.ms) ms (self-test seam)")

        // live-34 (1) — provider freshness instead of a pasted year: the model's stale years still go, a typed year stays.
        WebEvidence.debugRewrite = .some("List of US presidents from 1977 to 2024")
        let q3 = await WebEvidence.searchQuery(for: tSentence, chat: fresh, now: now)
        WebEvidence.debugRewrite = .some("Aftermath of the 1648 treaty")   // live-37: a rewrite that names no one the user didn't
        let q4 = await WebEvidence.searchQuery(for: "What happened after the 1648 treaty?", chat: fresh, now: now)
        WebEvidence.debugRewrite = nil
        row("model-years-stripped-typed-year-kept", q3.query == "List of US presidents" + (Live35.red ? "" : " 2026")
            && q4.query == "Aftermath of the 1648 treaty", "\(q3.query) | \(q4.query)")
        // live-35 (1) — today's year back on a current-state query only: news keeps the provider window (no year),
        // timeless gets neither; Wikipedia never gets the year.
        var yr: [String] = []
        for (question, rewrite) in [(tSentence, "List of US presidents"), ("Who is Japan's prime minister?", "Japan prime minister"),
                                    ("what happened in the news today?", "top news headlines today"),
                                    ("Why is the sky blue?", "why is the sky blue")] {
            WebEvidence.debugRewrite = .some(rewrite)
            let r = await WebEvidence.searchQuery(for: question, chat: fresh, now: now)
            yr.append(r.query + " | wiki: " + r.wikiQuery)
        }
        WebEvidence.debugRewrite = nil
        row("year-back-on-current-state-only-not-news-not-timeless",
            yr == ["List of US presidents 2026 | wiki: List of US presidents", "Japan prime minister 2026 | wiki: Japan prime minister",
                   "top news headlines today | wiki: top news headlines today", "why is the sky blue | wiki: why is the sky blue"],
            yr.joined(separator: " · "))
        let fr = [("what happened in the news today?", SearchFreshness.day), ("any news on the Lakeview election this week?", .week),
                  ("Who is the chancellor of Germany?", SearchFreshness.currentState), ("Why is the sky blue?", .none),
                  ("What is the capital of Australia?", .none)]
        row("freshness-window-from-what-the-question-needs", fr.allSatisfy { SearchFreshness.pick($0.0) == $0.1 },
            fr.map { "\($0.0) → \(SearchFreshness.pick($0.0).rawValue)" }.joined(separator: " · "))
        row("follow-up-takes-its-query's-window", SearchFreshness.forTurn(question: "how long has he been in office?",
                                                                          query: "latest news Lakeview First Minister today") == .day)
        // live-34 — T's sentence says "up until today" but isn't news: its search is a current-state one (the first
        // build searched Tavily news for the past day and got one off-topic page)
        row("T's-'up-until-today'-is-not-news", SearchFreshness.forTurn(question: tSentence, query: "List of US presidents") == SearchFreshness.currentState
            && SearchFreshness.forTurn(question: "what happened in the news today?", query: "top news headlines today") == .day
            && SearchFreshness.forTurn(question: "what happened in the news today?", query: "world news headlines") == .day,
            SearchFreshness.forTurn(question: tSentence, query: "List of US presidents").rawValue)
        row("provider-values", SearchFreshness.day.brave == "pd" && SearchFreshness.week.brave == "pw" && SearchFreshness.year.brave == "py"
            && SearchFreshness.none.brave == nil && SearchFreshness.month.tavilyRange == "month" && SearchFreshness.day.tavilyDays == 1
            && SearchFreshness.day.general == .week)

        // live-34 (2) — "didn't confirm" judged by the passages, not by [n] marks. T's TF 202610212033 case: a correct table
        // with no [n] at all (passages as the server's turn had them).
        let presPassages = """
        US Presidents List
        | 43 | George W. Bush | Jan. 20, 2001-Jan. 20, 2009 | | 44 | Barack Obama | Jan. 20, 2009-Jan. 20, 2017 | | 45 | Donald Trump | Jan. 20, 2017-Jan. 20, 2021 | | 46 | Joe Biden | Jan. 20, 2021-Jan. 20, 2025 | | 47 | Donald Trump | Jan. 20, 2025-present |
        Wikipedia: List of presidents of the United States
        Gerald Ford (1974–1977) 39. Jimmy Carter (1977–1981) 40. Ronald Reagan (1981–1989) 41. George H. W. Bush (1989–1993) 42. Bill Clinton (1993–2001) 43. George W. Bush (2001–2009) 44. Barack Obama (2009–2017) 45. Donald Trump (2017–2021) 46. Joe Biden (2021–2025) 47. Donald Trump (2025–present)
        """
        let tTable = """
        Here is the list of the last 10 U.S. Presidents up to October 21, 2026:

        | # | President | Term Start | Term End |
        |---|-----------|------------|----------|
        | 38 | Gerald Ford | Aug. 9, 1974 | Jan. 20, 1977 |
        | 39 | Jimmy Carter | Jan. 20, 1977 | Jan. 20, 1981 |
        | 40 | Ronald Reagan | Jan. 20, 1981 | Jan. 20, 1989 |
        | 41 | George H.W. Bush | Jan. 20, 1989 | Jan. 20, 1993 |
        | 42 | Bill Clinton | Jan. 20, 1993 | Jan. 20, 2001 |
        | 43 | George W. Bush | Jan. 20, 2001 | Jan. 20, 2009 |
        | 44 | Barack Obama | Jan. 20, 2009 | Jan. 20, 2017 |
        | 45 | Donald Trump | Jan. 20, 2017 | Jan. 20, 2021 |
        | 46 | Joe Biden | Jan. 20, 2021 | Jan. 20, 2025 |
        | 47 | Donald Trump | Jan. 20, 2025 | Present |

        Donald Trump appears twice because he served two non-consecutive terms.
        """
        func note(_ answer: String, _ q: String, _ passages: String, results: Int, cited: Int) -> String {
            let sup = EvidenceSupport.supported(answer: answer, question: q, passages: passages, now: now)
            return WebGrounding.answerNote(question: q, searchRan: true, resultCount: results, citedCount: cited, rateLimited: false,
                                           supported: sup)?.text ?? "none"
        }
        let n1 = note(tTable, tSentence, presPassages, results: 2, cited: 0)
        row("T's-correct-uncited-table-→-no-line", n1 == "none", n1)
        let lakePassages = "Wikipedia: First Minister of the Lakeview Republic\nIlsa Vane took office as First Minister of the Lakeview Republic on 3 March 2026, after the snap election."
        let memory = "The First Minister of the Lakeview Republic is Tomas Reed of the Harbour Party, who has led the government since 2019."
        let n2 = note(memory, "Who is the First Minister of the Lakeview Republic?", lakePassages, results: 1, cited: 0)
        let n2c = note(memory + " [1]", "Who is the First Minister of the Lakeview Republic?", lakePassages, results: 1, cited: 1)
        row("memory-answer-contradicting-the-passages-→-the-line-even-cited", n2 == WebGrounding.searchUnconfirmedNote
            && n2c == WebGrounding.searchUnconfirmedNote, "\(n2) | cited: \(n2c)")
        let right = "The First Minister of the Lakeview Republic is Ilsa Vane, in office since 3 March 2026."
        let n3 = note(right, "Who is the First Minister of the Lakeview Republic?", lakePassages, results: 1, cited: 0)
        row("right-uncited-prose-→-no-line", n3 == "none", n3)
        let n4 = note(right, "Who is the First Minister of the Lakeview Republic?", "", results: 0, cited: 0)
        row("no-web-passages-→-the-honest-line-as-before", n4 == WebGrounding.searchUnconfirmedNote, n4)
        let sky = "The sky looks blue because molecules in Earth's atmosphere scatter blue sunlight more than red light."
        let n5 = note(sky, "Why is the sky blue?", "Why is the sky blue? | NASA Space Place\nBlue light is scattered in all directions by the tiny molecules of air in Earth's atmosphere.", results: 1, cited: 0)
        row("timeless-uncited-answer-from-the-passages-→-no-line", n5 == "none", n5)
        // Apple Intelligence's stale table (live-34 run): every name in the passages, but a term ending in 2029
        let staleTable = "| President | Term Start | Term End |\n|---|---|---|\n| Joe Biden | 2021 | 2029 |\n| Donald Trump | 2017 | 2021 |\n| Barack Obama | 2009 | 2017 |\n| George W. Bush | 2001 | 2009 |"
        let n6 = note(staleTable, tSentence, presPassages, results: 2, cited: 0)
        row("a-future-year-the-passages-don't-have-→-the-line", n6 == WebGrounding.searchUnconfirmedNote, n6)
        row("tables-end-with-a-sources-line", WebGrounding.appSearchClause.contains("Sources: [1], [2]")
            && AppleWebQuery.turnInstructions.contains("Sources: [1], [2]"))

        // live-34 (3) — the training cutoff beside today's date: shelf models only (Apple and server models: none).
        let base = LibrarianState.toolChatBase(today: "Tuesday, October 20, 2026")
        let shelf = TrainingCutoff.stamp(base, model: "qwen3:4b-instruct-2507-q4_K_M")
        row("shelf-model-gets-the-cutoff-line", shelf.contains("Your training data ends around 2024; today's real date is Tuesday, October 20, 2026")
            && TrainingCutoff.cutoff(model: "qwen3:8b-q4_K_M") == "2024" && TrainingCutoff.cutoff(model: "qwen3:30b-a3b-instruct-2507-q4_K_M") == "2024",
            String(shelf.prefix(0)))
        row("server-or-unknown-model-no-cutoff-line", TrainingCutoff.stamp(base, model: "qwen3.6-35b-a3b") == base
            && TrainingCutoff.cutoff(model: "llama3.2:latest") == nil && TrainingCutoff.cutoff(model: "qwen3.5:9b") == nil)

        // 3. The rerank: passages, the floor, the selection.
        let car = WebEvidence.Source(title: "When Is the Best Time to Buy a New Car? | Edmunds", url: "https://www.edmunds.com/car-buying/best-time",
                                     published: nil, wikipedia: false,
                                     text: "The best time to buy a new car is at the end of the year, when dealers push to hit their sales targets. October, November and December bring the year-end clearance. Holiday weekends such as Memorial Day and Labor Day also bring discounts on outgoing models.")
        let wikiPres = WebEvidence.Source(title: "List of presidents of the United States", url: WikipediaGrounding.articleURL("List of presidents of the United States"),
                                          published: ISO8601DateFormatter().date(from: "2026-10-20T10:57:51Z"), wikipedia: true,
                                          // the article's lead as Wikipedia served it on 2026-10-21 (its first two paragraphs)
                                          text: "The president of the United States is the head of state and head of government of the United States, indirectly elected to a four-year term via the Electoral College. Under the U.S. Constitution, the officeholder leads the executive branch of the federal government and is the commander-in-chief of the United States Armed Forces.\nThe first president, George Washington, won a unanimous vote of the Electoral College. The incumbent president is Donald Trump, who assumed office on January 20, 2025. Since the office was established in 1789, 45 men have served in 47 presidencies. The discrepancy is due to the nonconsecutive terms of Grover Cleveland (counted as the 22nd and 24th president) and Donald Trump (counted as the 45th and 47th president).")
        // the query the on-device rewrite wrote for T's sentence (the Mac harness, live-33)
        let rr = await WebEvidence.rerank(query: "List of US presidents from the last 10 up to today", sources: [car, wikiPres], budget: WebEvidence.hostWebBudget(model: "qwen3:4b-instruct-2507-q4_K_M"))
        let scores = rr.scored.map { "\($0.source == 0 ? "car" : "wiki") \(String(format: "%.3f", $0.score))\($0.kept ? "*" : "")" }.joined(separator: ", ")
        row("rerank-floor-drops-an-off-topic-page", rr.links.map(\.url) == [wikiPres.url] && rr.links.first.map(WikipediaGrounding.isPassage) == true
            && rr.links.first?.snippet?.contains("The incumbent president is Donald Trump") == true, "\(scores) · \(rr.ms) ms")
        let lone = await WebEvidence.rerank(query: "List of US presidents from the last 10 up to today", sources: [car], budget: WebEvidence.hostWebBudget(model: "qwen3:4b-instruct-2507-q4_K_M"))
        row("a-lone-off-topic-page-is-never-passed", lone.links.isEmpty, lone.scored.map { String(format: "%.3f", $0.score) }.joined(separator: ", "))
        let dupe = await WebEvidence.rerank(query: "last 10 US presidents", sources: [wikiPres, WebEvidence.Source(title: "List of presidents of the United States - Wikipedia",
            url: "https://en.wikipedia.org/wiki/List_of_presidents_of_the_United_States/", published: nil, wikipedia: false, text: "Joe Biden served as the 46th president from 2021 to 2025.")],
            budget: WebEvidence.hostWebBudget(model: "qwen3:4b-instruct-2507-q4_K_M"))
        row("one-source-per-page", dupe.links.count == 1 && dupe.sources.count == 1 && dupe.links.first.map(WikipediaGrounding.isPassage) == true, "\(dupe.links.map(\.url))")
        let filler = String(repeating: "Portraits and biographies of every holder of the office hang in the assembly hall. ", count: 10)
        let lake = WebEvidence.Source(title: "First Minister of the Lakeview Republic", url: "https://lakeview.example.gov/first-minister", published: nil,
                                      wikipedia: false, text: filler + "Ilsa Vane became First Minister of the Lakeview Republic on 14 March 2026, succeeding Mara Quill.")
        let rl = await WebEvidence.rerank(query: "current First Minister of the Lakeview Republic", sources: [lake], budget: WebEvidence.hostWebBudget(model: "qwen3:4b-instruct-2507-q4_K_M"))
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
        // live-37 (2) — the budget by the model's window; the best sources first and last.
        let b4 = WebEvidence.hostWebBudget(model: "qwen3:4b-instruct-2507-q4_K_M"), b30 = WebEvidence.hostWebBudget(model: "qwen3:30b-a3b-instruct-2507-q4_K_M")
        let ba = WebEvidence.appleWebBudget
        row("budget-sized-to-the-model", Live37.selection ? (b4.chars == 12_000 && b30.chars == 20_000 && ba.chars == 4_080
            && b4.topK > 6 && b30.topK > b4.topK && ba.topK > 6 && ba.perSource >= 3) : (b4.chars == 3_000 && ba.chars == 1_500 && b4.topK == 6),
            "apple \(ba.chars)/\(ba.topK)/\(ba.perSource) · 4b \(b4.chars)/\(b4.topK)/\(b4.perSource) · 30b \(b30.chars)/\(b30.topK)/\(b30.perSource)")
        row("best-first-and-last", WebEvidence.edgesFirst([1, 2, 3, 4, 5]) == (Live37.selection ? [1, 3, 5, 4, 2] : [1, 2, 3, 4, 5]),
            "\(WebEvidence.edgesFirst([1, 2, 3, 4, 5]))")
        // live-37 (3) — the boilerplate test on live-36's CNBC menu passages; prose, a table row and a price line stay.
        let menus = ["Skip Navigation Markets Pre-Markets U.S.",
                     "Markets Currencies Prediction Markets Cryptocurrency Futures & Commodities Bonds Funds & ETFs Business Economy Finance Health & Science Media Real Estate Energy Climate Transportation Investigations Industrials Retail Wealth Sports Life Small Business Investing",
                     "Schedule CNBC Podcasts CEO Interv…"]
        let prose = ["The new iPhone 18 Pro will start at $1,199, while the iPhone 18 Pro Max will start at $1,299, Apple announced Wednesday.",
                       "Joe Biden 46th 2021 2025 Democratic Kamala Harris", "Ilsa Vane took office.",
                       "The incumbent president is Donald Trump, who assumed office on January 20, 2025."]
        row("boilerplate-out-content-kept", menus.allSatisfy(WebEvidence.isBoilerplate) && !prose.contains(where: WebEvidence.isBoilerplate),
            (menus + prose).map { WebEvidence.isBoilerplate($0) ? "B" : "c" }.joined())
        let cnbc = WebEvidence.Source(title: "Apple reveals iPhone 15 pricing: $799 for base model and $899 for iPhone 15+", url: "https://www.cnbc.com/video/x",
                                      published: nil, wikipedia: false, text: menus.joined(separator: "\n"))
        let news = WebEvidence.Source(title: "Apple raises iPhone prices", url: "https://www.newsnationnow.com/x", published: nil, wikipedia: false,
                                      text: prose[0])
        let rc = await WebEvidence.rerank(query: "price of an iPhone", sources: [cnbc, news], budget: WebEvidence.Budget(chars: 3_000, topK: 1, perSource: 1, label: "top-1"))
        row("the-answer-outranks-the-menu", rc.scored.first(where: \.kept)?.text == prose[0],
            rc.scored.map { "\($0.source == 0 ? "menu" : "answer") \(String(format: "%.3f", $0.score))\($0.kept ? "*" : "")" }.joined(separator: ", "))

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
        return "\(passed == rows.count ? "PASS" : "FAIL") — \(passed)/\(rows.count)\(red ? " (RED: -Live32Web)" : Live34.red ? " (RED: -Live33Web)" : Live35.red ? " (RED: -Live34Web)" : "")\n\(lines)"
    }
}

private final class ReasoningBox: @unchecked Sendable {
    private let lock = NSLock(); private var s = ""
    func add(_ r: String) { lock.withLock { s += r } }
    var text: String { lock.withLock { s } }
}

/// live-37 (4) — `-WebRetrievalRun <cases.json> -RetrievalTier apple|4b|8b|30b` (with `-WebTrace YES`): the fast loop.
/// Each chat's turns go through what a live turn does up to the model — whether it searches, the query, the provider +
/// Wikipedia (+ the page read on the Host path), the rerank within the tier's budget — and the trace gets an `evidence`
/// row with the text the model would receive. No answer is generated: a follow-up sees the chat's canned answer
/// (`canned`, the earlier turn's live-36 qwen3:4b answer). `scripts/live/smoke.sh --retrieval` grades it.
/// The tier sets the budget (and for the Host tiers, the Host's decision to read the top page); every tier's query is the
/// on-device rewrite here (the Host's own rewrite runs only where Apple Intelligence is unavailable).
enum WebRetrievalRun {
    static let models = ["4b": "qwen3:4b-instruct-2507-q4_K_M", "8b": "qwen3:8b-q4_K_M", "30b": "qwen3:30b-a3b-instruct-2507-q4_K_M"]

    @MainActor static func run(path: String, tier: String) async -> String {
        let t0 = Date()
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chats = json["chats"] as? [[String: Any]] else { return "FAIL — can't read \(path)" }
        let apple = tier == "apple"
        var turns = 0, searched = 0
        // The on-device model's first call after launch is cold (the first smoke run: 5.0 s, timed out; later ones
        // 0.8–1.9 s); one untraced rewrite first, so every measured turn's rewrite runs warm.
        _ = await WebEvidence.searchQuery(for: "Who wrote Hamlet?", chat: ChatSession())
        for c in chats {
            let qs = c["turns"] as? [String] ?? []
            let canned = c["canned"] as? [String] ?? []
            let chat = ChatSession()
            for (k, q0) in qs.enumerated() {
                turns += 1
                if q0.hasPrefix("LIB:") {   // a Library question never reaches the web pipeline (Library mode)
                    WebTrace.shared.beginTurn(String(q0.dropFirst(4)))
                    WebTrace.shared.note("evidence", ["tier": tier, "path": "library", "text": "", "searched": false])
                    continue
                }
                let q = q0
                let intent = LibrarianState.looksLikeSearchIntent(q)
                var text = "", query = "", links: [ToolLink] = [], didSearch = false
                if apple {
                    let followUp = !AppleWebGrounding.live29 && AppleWebGrounding.lastAnswerSearched(chat) && AppleWebQuery.isFollowUpQuestion(q)
                    if AppleWebGrounding.shouldSearch(q, searchIntent: intent) || followUp {
                        let (sq, _, rr) = await WebEvidence.appleEvidence(question: q, chat: chat, webKey: true)
                        query = sq.query; links = rr.links; didSearch = true
                        let pk = AppleWebGrounding.packet(links: links)
                        text = links.isEmpty ? "" : AppleWebGrounding.turn(question: q, query: sq.query, results: pk.results, voice: "").modelText
                    } else {
                        WebTrace.shared.beginTurn(q)
                    }
                } else {
                    let plan = WebGrounding.hostPrefetch(q, searchIntent: intent, lastAnswerSearched: AppleWebGrounding.lastAnswerSearched(chat))
                    WebTrace.shared.beginTurn(q)
                    WebTrace.shared.note("plan", ["prefetch": plan.prefetch, "followUp": plan.followUp])
                    if plan.prefetch != "none" {
                        let sq = await WebEvidence.searchQuery(for: q, chat: chat)
                        WebTrace.shared.note("query", ["query": sq.query, "wikiQuery": sq.wikiQuery, "how": sq.how, "rewriteMs": sq.ms])
                        async let wiki = WikipediaGrounding.isOn ? WikipediaGrounding.sources(query: sq.wikiQuery) : []
                        let executor = WebSearchBackend.make()
                        let args: [String: Any] = ["query": sq.query, "count": AppleWebQuery.requestCount,
                                                   "freshness": SearchFreshness.forTurn(question: q, query: sq.query).rawValue]
                        let start = WebTrace.shared.ms
                        let result = await executor.execute(name: AgentTools.webSearch, arguments: args)
                        WebTrace.shared.note("tool", ["name": AgentTools.webSearch, "id": "app_search", "startMs": start,
                                                      "args": args.mapValues { "\($0)" }, "links": WebTrace.links(result.links),
                                                      "failed": result.failed, "rateLimited": result.rateLimited, "text": ""])
                        let rr = await WebEvidence.hostEvidence(result, appSearch: true, fetchTop: plan.prefetch == "searchAndFetch",
                                                                executor: executor, wiki: await wiki, query: sq.wikiQuery,
                                                                budget: WebEvidence.hostWebBudget(model: models[tier]), callStart: start)
                        query = sq.query; links = rr.links; didSearch = true
                        text = links.isEmpty ? "" : WebGrounding.appSearchTurn(query: sq.query, question: q, links: links, now: Date())
                    }
                }
                var tokens = -1
                if apple, !text.isEmpty, #available(iOS 26.4, *) {
                    tokens = (try? await SystemLanguageModel.default.tokenCount(for: AppleWebQuery.turnInstructions + "\n\n" + text)) ?? -1
                }
                let passages = links.map { $0.snippet ?? "" }.joined(separator: "\n")
                WebTrace.shared.note("evidence", ["tier": tier, "searched": didSearch, "query": query, "text": text, "chars": text.count,
                                                  "passageChars": passages.count, "sources": links.count, "appleTokens": tokens])
                if didSearch { searched += 1 }
                // what the next turn sees: the question, the search row, the answer (canned)
                chat.debugAppendUser(q)
                if didSearch {
                    chat.debugAppendActivity(icon: "magnifyingglass", label: "Searched the web", detail: query, links: links)
                }
                chat.debugAppendAnswer(k < canned.count ? canned[k] : "(answer)", web: didSearch)
            }
        }
        return "DONE — \(turns) turns, \(searched) searched, tier \(tier), \(Int(Date().timeIntervalSince(t0))) s"
    }
}
#endif
