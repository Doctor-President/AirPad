import Foundation

#if DEBUG
/// live-32 (2) — `-WebEvidenceSelfTest`: the evidence, its weighing and the server model's reasoning, pure parts (synthetic
/// content: the invented Lakeview Republic and its First Minister). RED: `-Live31Web YES` (live-31's web turn). The send
/// itself is checked on the stub stack (`scripts/runaway/run.sh`, `WebSearchAnswerUI`) and live (`scripts/live`).
enum WebEvidenceSelfTest {
    @MainActor static func run() async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let red = WikipediaGrounding.live31
        let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

        // T's two turns.
        let t1 = "a table of the last ten US presidents"
        let t2 = "you're not showing the current president. Joe Biden is no longer president"

        // The follow-up is a correction of the last answer: searched again as a follow-up, its query the topic's current state.
        let plan = WebGrounding.hostPrefetch(t2, searchIntent: false, lastAnswerSearched: true)
        row("T's-correction-is-a-follow-up", plan.prefetch == "search" && plan.followUp, "\(plan)")
        let fb = AppleWebQuery.fallbackQuery(previousQuery: "a table of the last ten US presidents 2026", question: t2)
        row("a-correction-searches-the-topic's-current-state", fb == "a table of the last ten US presidents current", fb)
        row("a-new-question-is-no-correction", !AppleWebQuery.isCorrection("What is the capital of the Lakeview Republic?")
            && AppleWebQuery.isCorrection("That's out of date — the First Minister changed in March"))

        // The today's-news framing is for news, not for "the current president".
        row("current-isn't-news", !WebGrounding.wantsNews(t2) && !WebGrounding.wantsNews("Who is the current First Minister of the Lakeview Republic?")
            && WebGrounding.wantsNews("What's the top news in the Lakeview Republic today?"))
        let ref = ToolLink(title: "First Minister of the Lakeview Republic", url: "https://lakeview.example.gov/first-minister",
                           snippet: "The First Minister heads the government.")
        let pk = WebGrounding.packet([ref], start: 0, now: now, freshness: WebGrounding.wantsNews(t2))
        row("no-'no-article-from-today'-on-a-current-state-question", !pk.contains("COMPUTED FACT") && !pk.contains("Not a dated news article"),
            String(pk.suffix(120)))

        // Wikipedia: the subject, the article, the infobox, the passage, the edit date.
        row("wiki-terms", WikipediaGrounding.searchTerms(t1 + " 2026") == "us presidents"
            && WikipediaGrounding.searchTerms("Is Pope Francis still alive?") == "pope francis"
            && WikipediaGrounding.searchTerms("Who is the current First Minister of the Lakeview Republic?") == "first minister of the lakeview republic",
            "\(WikipediaGrounding.searchTerms(t1 + " 2026")) | \(WikipediaGrounding.searchTerms("Is Pope Francis still alive?")) | \(WikipediaGrounding.searchTerms("Who is the current First Minister of the Lakeview Republic?"))")
        row("wiki-article-choice", WikipediaGrounding.pickTitle(["Lakeview (disambiguation)", "First Minister of the Lakeview Republic"], terms: "first minister of the lakeview republic")
            == "First Minister of the Lakeview Republic" && WikipediaGrounding.pickTitle(["The Last of Us"], terms: "us presidents") == nil)
        row("wiki-markup-to-text", WikipediaGrounding.plain("[[Ilsa Vane|Ilsa Vane]]<ref name=a>x</ref>") == "Ilsa Vane"
            && WikipediaGrounding.plain("{{Death date and age|2024|12|29|1950|1|2}}") == "29 December 2024",
            WikipediaGrounding.plain("{{Death date and age|2024|12|29|1950|1|2}}"))
        let wikitext = """
        {{Infobox official post
        | post = First Minister
        | incumbent = [[Ilsa Vane]]
        | incumbent_since = {{start date|2026|3|14}}
        }}
        The '''First Minister of the Lakeview Republic''' heads its government.
        """
        let facts = WikipediaGrounding.infoboxFacts(wikitext)
        row("wiki-infobox-holder", facts.first == "Current holder: Ilsa Vane (since 14 March 2026)", facts.joined(separator: " · "))
        let extract = "The First Minister of the Lakeview Republic is the head of its government. The office was created in 1921. "
            + String(repeating: "The First Minister chairs the cabinet and answers to the assembly. ", count: 8)
            + "The incumbent First Minister is Ilsa Vane, who took office on 14 March 2026.\n== History ==\nMara Quill was First Minister from 2019 until 2026."
        let passage = WikipediaGrounding.passageText(extract: extract, wikitext: wikitext, terms: "first minister of the lakeview republic", cap: 500)
        row("wiki-passage-leads-with-the-holder", passage.hasPrefix("Current holder: Ilsa Vane") && passage.contains("The incumbent First Minister is Ilsa Vane")
            && passage.count <= 502, passage)
        let edited = WikipediaGrounding.editedLine(ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z"), now: now)
        row("wiki-edit-date-is-current-evidence", edited.contains("last edited 18 October 2026 (2 days before today)") && edited.contains("current evidence"), edited)
        let wl = WikipediaGrounding.link(.init(title: "First Minister of the Lakeview Republic", url: WikipediaGrounding.articleURL("First Minister of the Lakeview Republic"),
                                              lastEdited: ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z"), text: passage))
        let pkW = WebGrounding.packet([wl, ref], start: 0, now: now, freshness: false)
        row("wiki-passage-is-[1]-with-its-edit-date", pkW.contains("[1] Wikipedia: First Minister of the Lakeview Republic\nhttps://en.wikipedia.org/wiki/First_Minister_of_the_Lakeview_Republic\nWikipedia article, last edited 18 October 2026"),
            String(pkW.prefix(200)))
        row("user-agent-names-the-app", WikipediaGrounding.userAgent.hasPrefix("AirPad/") && WikipediaGrounding.userAgent.contains("https://")
            && !WikipediaGrounding.userAgent.contains("@"), WikipediaGrounding.userAgent)

        // Each result's part that answers, not its first 300 characters.
        let long = String(repeating: "Portraits and biographies of every holder of the office. ", count: 14)
            + "Mara Quill (2019–2026) Ilsa Vane (2026–present)"
        let win = WebGrounding.relevantWindow(long, terms: WebGrounding.evidenceTerms("Who is the current First Minister of the Lakeview Republic?", now: now), cap: 300)
        row("the-window-keeps-the-newest-row", win.contains("Ilsa Vane (2026–present)") && win.count <= 302, win)
        row("text-that-fits-is-kept-whole", WebGrounding.relevantWindow("Short.", terms: ["x"], cap: 300) == "Short.")

        // Source quality for a current-state question.
        let links = [ToolLink(title: "Who is First Minister now? - Quora", url: "https://www.quora.com/who", snippet: "Mara Quill, I think"),
                     ToolLink(title: "Lakeview cabinet", url: "https://news.example.com/cabinet", snippet: "As of 2024, Mara Quill leads the cabinet."),
                     ToolLink(title: "Vane sworn in", url: "https://news.example.com/vane", snippet: "Ilsa Vane was sworn in.",
                              published: ISO8601DateFormatter().date(from: "2026-03-14T12:00:00Z")),
                     ref, wl]
        let q = WebGrounding.currentStateLinks(links, now: now)
        row("current-state-sources", q.map(\.url) == [wl.url, ref.url, "https://news.example.com/vane"], q.map(\.url).joined(separator: " "))
        row("never-empties", WebGrounding.currentStateLinks([links[0]], now: now).count == 1)

        // The weighing: results over memory, reference pages count, no thinking aloud.
        let base = LibrarianState.toolChatBase(today: "Tuesday, October 20, 2026")
        let sys = WebGrounding.withEvidenceRules(base, currentState: true)
        row("prompt-results-over-memory", sys.contains("THE RESULTS ARE RIGHT") && sys.contains("edited recently is current evidence")
            && sys.contains("don't think out loud") && WebGrounding.withEvidenceRules(base, currentState: false) == base,
            "a plain factual turn keeps the base prompt")
        let apple = AppleWebGrounding.turn(question: "Q?", query: "q", results: [], voice: "V.")
        row("apple-prompt-results-over-memory", apple.systemPrompt.contains("they are right") && apple.systemPrompt.contains("Wikipedia"))

        // The server model's reasoning: read (to the Thought process), never in the answer; off for a web turn.
        var content = ""; var accum: [Int: (id: String, name: String, args: String)] = [:]
        let seen = ReasoningBox()
        ModelRouter.accumulateAgentDelta(["reasoning_content": "Thinking Process: 1. Analyze"], content: &content, accum: &accum,
                                         onContentDelta: { _ in }, onReasoningDelta: { seen.add($0) })
        row("reasoning_content-goes-to-the-thought-process", seen.text == "Thinking Process: 1. Analyze" && content.isEmpty, "seen='\(seen.text)' content='\(content)'")
        row("reasoning-off-where-the-server-offers-it", ModelRouter.reasoningEffort(allowedOptions: ["off", "on"]) == "none"
            && ModelRouter.reasoningEffort(allowedOptions: ["low", "medium", "high"]) == "low"
            && ModelRouter.reasoningEffort(allowedOptions: []) == nil)

        // The providers' text: Brave's extra snippets and Tavily's content are kept past 300 characters.
        let brave = #"{"web":{"results":[{"title":"First Minister","url":"https://lakeview.example.gov/fm","description":"The office.","extra_snippets":["Ilsa Vane took office in March 2026."]}]}}"#
        let bl = BraveSearchToolExecutor.parseBrave(Data(brave.utf8))
        row("brave-extra-snippets", bl.first?.snippet?.contains("Ilsa Vane took office") == true, bl.first?.snippet ?? "nil")
        let tav = #"{"results":[{"title":"T","url":"https://lakeview.example.gov/t","content":"\#(long)"}]}"#
        let tl = TavilySearchToolExecutor.parse(Data(tav.utf8))
        row("tavily-text-kept-for-the-window", (tl.first?.snippet?.count ?? 0) > 600, "\(tl.first?.snippet?.count ?? 0) chars")

        let passed = rows.filter { $0.1 }.count
        let lines = rows.map { "\($0.1 ? "ok  " : "BAD ") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined(separator: "\n")
        return "\(passed == rows.count ? "PASS" : "FAIL") — \(passed)/\(rows.count)\(red ? " (RED: -Live31Web)" : "")\n\(lines)"
    }
}

private final class ReasoningBox: @unchecked Sendable {
    private let lock = NSLock(); private var s = ""
    func add(_ r: String) { lock.withLock { s += r } }
    var text: String { lock.withLock { s } }
}
#endif
