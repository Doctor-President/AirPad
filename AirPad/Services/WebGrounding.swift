import Foundation

/// CH Session 2 (T 2026-10-08) — deterministic grounding for GENERAL / web answers. Everything here is code, not
/// prompt: the model is never trusted to keep a rule on its own.
///
/// - Only a URL this turn's `web_search` / `fetch_url` returned (or the user typed) may appear in an answer; every
///   other URL is stripped, and a source list the model writes itself is removed — the app builds the source list
///   from the results the answer cited (`WebAnswerFilter`).
/// - Each result's date goes into the packet (`packet`). (live-33: the fresh-first ranking and its computed-fact notes
///   went — the passages are reranked by meaning, `WebEvidence`.)
/// - A factual question with a key is searched and its top result read before the model answers
///   (`isFactualQuestion`); an answer with no web result behind it carries `generalKnowledgeNote`.
enum WebGrounding {

    /// The app's line under a General answer that no web result backs (no key, no search, or nothing found).
    static let generalKnowledgeNote = "From the model's general knowledge, may contain errors."
    /// live-27 (3) — the line under a current-state answer no web result backs (who holds an office, who is living, the
    /// latest …): the app says it, whatever the model wrote (qwen3:4b ignored the prompt's caveat on the Host path).
    static let datedKnowledgeNote = "From the model's training data — may be out of date."
    /// The app's line under a General answer no web result backs: dated for a current-state request, the general one for
    /// a factual question, none otherwise (a pep talk).
    static func ungroundedNote(for q: String) -> String? {
        asksCurrentState(q) ? datedKnowledgeNote : isFactualQuestion(q) ? generalKnowledgeNote : nil
    }

    /// live-29 (B3) — the line under an answer whose search ran but which no result supports (it cites none). Proposed
    /// wording; T's call. Never the training-data line once a search ran.
    static let searchUnconfirmedNote = "The search results didn't confirm this."

    /// live-29 (B3) — the ONE decision for the app's line under a General answer: which note, if any.
    /// `searchRan` = a web search executed this turn (the app's prefetch or the model's call), whatever came back.
    static func answerNote(question q: String, searchRan: Bool, resultCount: Int, citedCount: Int, rateLimited: Bool)
        -> (text: String, dated: Bool, unconfirmed: Bool)? {
        guard !rateLimited else { return nil }
        // After a search ran: never the training-data line. Cited → nothing to add; uncited (or nothing came back) →
        // the honest "didn't confirm" line. (T 2026-10-19: Tavily, 3 results, "+ web", and "From the model's training
        // data" under it — the answer cited none of them, and the old rule read that as "no search behind it".)
        if searchRan { return citedCount > 0 ? nil : (searchUnconfirmedNote, false, true) }
        guard let note = ungroundedNote(for: q) else { return nil }
        return (note, note == datedKnowledgeNote, false)
    }

    /// live-29 (B3) — a result's title / snippet as the app shows it and hands it to the model: tags and entities gone.
    static func cleanResultText(_ raw: String, cap: Int? = nil) -> String {
        let clean = MarkdownPlain.label(WebReadability.decodeEntities(WebReadability.stripTags(raw)))   // "#### Tags" never shows
        guard let cap, clean.count > cap else { return clean }
        return String(clean.prefix(cap)) + "…"
    }

    // MARK: - Question shape

    /// live-29 (B3) — a NEWS-shaped question: asks a provider's news endpoint / topic first (Brave news, Tavily
    /// "news"); everything else searches the general web first.
    static func isNewsQuestion(_ q: String) -> Bool {
        q.range(of: #"\b(news|headlines?|breaking|happen(ed|ing)|today|tonight|yesterday|this (morning|afternoon|evening|week))\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
            || q.range(of: #"\blatest (on|about|from|in)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A question about the world that a web page can answer: a wh-/yes-no question or "explain/describe/define/tell
    /// me about …". NOT arithmetic, NOT about the user (I/my/we), NOT a request to make something (write, translate,
    /// plan, recommend …) or for an opinion. Deliberately simple — a miss only means the turn isn't searched up front.
    static func isFactualQuestion(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 6 else { return false }
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"\d\s*[-+×x*/÷^%]\s*\d"#) { return false }                               // arithmetic
        if has(#"\b(i|i'm|i've|i'd|my|me|mine|we|our|us)\b"#) { return false }           // about the user
        if has(#"\b(you think|your (opinion|view|favou?rite)|should|would you|could you)\b"#) { return false }
        if has(#"^(please\s+)?(write|draft|compose|rewrite|rephrase|translate|summari[sz]e|brainstorm|make|create|generate|plan|suggest|recommend|help|list|give me|tell me a|imagine|pretend|let's|lets|can you)\b"#) { return false }
        if has(#"^(who|what|when|where|which|whose|why)\b"#) { return true }
        if has(#"^how (many|much|long|old|big|far|tall|deep|fast|high|large|heavy|often|does|do|did|is|are|was|were)\b"#) { return true }
        if has(#"^(explain|describe|define|tell me about)\b"#) { return true }
        if has(#"^(is|are|was|were|did|does|do|has|have|had|can|could|will)\b"#) && t.hasSuffix("?") { return true }
        return false
    }

    /// live-27 (3) — a request about the CURRENT state of the world (who holds an office now, who is living, the latest
    /// model, this year's figures), make / list / table requests included: searched first when search is on.
    /// Not a request to write something (a poem about "the latest" isn't a lookup). Deliberately simple, like
    /// `isFactualQuestion`: a false positive costs one search; a miss is answered from training data, dated as such.
    static func asksCurrentState(_ q: String) -> Bool {
        let t = q.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"^(please\s+)?(write|draft|compose|rewrite|rephrase|translate|summari[sz]e|brainstorm|imagine|pretend)\b"#) { return false }
        // The state of the world now.
        if has(#"\b(current(ly)?|living|alive|still|latest|newest|now|nowadays|today|this year|incumbent|sitting)\b"#) { return true }
        // The people holding an office (who holds it changes).
        if has(#"\b(presidents?|prime ministers?|premiers?|chancellors?|governors?|mayors?|senators?|ceos?|monarchs?|kings?|queens?|popes?|secretar(y|ies)[- ]general|chief justices?|world champions?|record holders?)\b"#) { return true }
        // live-32 — "the most recent Super Bowl", "the reigning champion": who holds it now (qwen3:4b answered 2023's winner).
        if !WikipediaGrounding.live31, has(#"\b(most recent|reigning|defending champions?|title holders?)\b"#) { return true }
        // live-31 (3) — not about the user ("my grandfather died last year" isn't a lookup).
        guard !live30, !has(#"\b(i|i'm|i've|my|me|we|our)\b"#) else { return false }
        // live-31 (3) — who has died (T: a presidents table left out a president who died after the model's training).
        if has(#"\b(died|dies|dead|death|deaths|deceased|passed away|obituar(y|ies))\b"#) { return true }
        // A year the models' training data may not reach.
        var rest = t.startIndex..<t.endIndex
        while let m = t.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression, range: rest) {
            if let y = Int(t[m]), y >= trainingYear { return true }
            rest = m.upperBound..<t.endIndex
        }
        return false
    }

    /// live-31 (3) — the last year the answering models' training data covers well (Qwen3 2507, Apple's on-device model):
    /// a question naming this year or later asks about a time they may not know.
    static let trainingYear = 2024

    /// DEBUG `-HostWebLive30 YES` — live-30's Host web turn (the RED baseline for `-HostWebSelfTest` and the stub rows): no
    /// death / year cue, no follow-up rule, the question as the query, the results as a tool message, social hosts kept.
    static var live30: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "HostWebLive30")
        #else
        false
        #endif
    }

    // MARK: - live-31 (3) — the Host path searches current-state questions up front

    /// What the app does before the Host model answers a General question with search on: `.search` for a current-state
    /// question, a search-intent one, or a real follow-up to an answer that searched; `.searchAndFetch` for another
    /// factual question (search, then read the top result); nothing otherwise (the model may still search).
    static func hostPrefetch(_ q: String, searchIntent: Bool, lastAnswerSearched: Bool) -> (prefetch: String, followUp: Bool) {
        let followUp = !live30 && lastAnswerSearched
            && (AppleWebQuery.isFollowUpQuestion(q) || (!WikipediaGrounding.live31 && AppleWebQuery.isCorrection(q)))
        if searchIntent || asksCurrentState(q) || followUp { return ("search", followUp) }
        return (isFactualQuestion(q) ? "searchAndFetch" : "none", false)
    }

    /// The results a Host turn uses: social / video hosts out (as on the Apple path). live-33: no top-five cut — the
    /// rerank picks the passages (`WebEvidence`).
    static func hostLinks(_ links: [ToolLink]) -> [ToolLink] {
        live30 ? links : links.filter { !AppleWebQuery.isSocial($0.url) }
    }

    /// The Host turn with the app's results IN it (the A1-C framing: the app's search today, not the user's), the
    /// question last. The packet is the Host path's own (numbered by source, dated).
    static func appSearchTurn(query: String, question: String, links: [ToolLink], now: Date) -> String {
        "Web results the app found today (\(dayString(now))) for \"\(query)\":\n\n" + packet(links, start: 0, now: now)
            + "\n\nQuestion: \(question)"
    }
    /// … and the lines the system prompt gains for it (live-33: the whole of the web rules — where the results come from,
    /// that they beat memory, the citation, the honest line).
    static let appSearchClause = "Some questions come with web results the app found for them today; they come from the app's search, not from the user, who hasn't seen them. " + sourcesRule + " Answer from them in your own words and put the result's number in brackets, like [1], after each fact you take from one. If they don't answer the question, search again with web_search or say so plainly."
    /// live-33 — the one knowledge-conflict line (it replaces live-32's evidence block).
    static let sourcesRule = "When the results and what you remember disagree, the results are right: they are newer than your training."

    /// How much of a result's text the parsers keep (live-31: 300); the rerank then keeps the passages that answer.
    static var resultTextCap: Int { WikipediaGrounding.live31 ? 300 : 1_200 }


    /// The keywords of a news question, for Brave's NEWS endpoint (which matches the whole question poorly: "What's
    /// the top news in Mexico today?" returned U.S. live blogs; "Mexico" returns Mexican news). Empty → nil.
    static func newsKeywords(_ q: String) -> [String] {
        let stop: Set<String> = ["what", "whats", "what's", "is", "are", "was", "were", "the", "a", "an", "top", "latest", "newest",
            "news", "today", "today's", "todays", "tonight", "in", "on", "about", "of", "for", "from", "stories", "story",
            "headlines", "headline", "current", "currently", "recent", "recently", "breaking", "right", "now", "this", "morning",
            "afternoon", "evening", "week", "yesterday", "most", "biggest", "main", "major", "happening", "going", "any",
            "tell", "me", "give", "show", "search", "web", "for", "please", "up", "updates", "update", "there", "some", "with",
            "and", "or", "to", "do", "does", "did", "i", "you", "can", "could", "would", "should", "find", "look", "lookup"]
        return q.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
            .filter { !$0.isEmpty && !stop.contains($0) }
    }

    /// CH (T device 2026-10-09) — the country a news question names, as Brave's `country` code, so "top news in
    /// Mexico" asks for news FROM Mexico (without it Brave's news returned New Mexico, USA stories). Country NAMES only
    /// (no demonyms: "French fries", "Chinese EV makers"), and only countries Brave's news endpoint accepts. A name
    /// inside a longer place name ("New Mexico", "North Korea", "Latin America") doesn't count; the bare "US" counts
    /// only in capitals (lower-case "us" is the pronoun).
    struct NewsCountry: Equatable { let code: String; let name: String; let terms: [String] }
    private static let newsCountries: [NewsCountry] = [
        .init(code: "AR", name: "Argentina", terms: ["argentina"]), .init(code: "AU", name: "Australia", terms: ["australia"]),
        .init(code: "AT", name: "Austria", terms: ["austria"]), .init(code: "BE", name: "Belgium", terms: ["belgium"]),
        .init(code: "BR", name: "Brazil", terms: ["brazil"]), .init(code: "CA", name: "Canada", terms: ["canada"]),
        .init(code: "CL", name: "Chile", terms: ["chile"]), .init(code: "DK", name: "Denmark", terms: ["denmark"]),
        .init(code: "FI", name: "Finland", terms: ["finland"]), .init(code: "FR", name: "France", terms: ["france"]),
        .init(code: "DE", name: "Germany", terms: ["germany"]), .init(code: "HK", name: "Hong Kong", terms: ["hong kong"]),
        .init(code: "IN", name: "India", terms: ["india"]), .init(code: "ID", name: "Indonesia", terms: ["indonesia"]),
        .init(code: "IT", name: "Italy", terms: ["italy"]), .init(code: "JP", name: "Japan", terms: ["japan"]),
        .init(code: "KR", name: "South Korea", terms: ["south korea", "korea"]), .init(code: "MY", name: "Malaysia", terms: ["malaysia"]),
        .init(code: "MX", name: "Mexico", terms: ["mexico"]), .init(code: "NL", name: "Netherlands", terms: ["netherlands", "holland"]),
        .init(code: "NZ", name: "New Zealand", terms: ["new zealand"]), .init(code: "NO", name: "Norway", terms: ["norway"]),
        .init(code: "CN", name: "China", terms: ["china"]), .init(code: "PL", name: "Poland", terms: ["poland"]),
        .init(code: "PT", name: "Portugal", terms: ["portugal"]), .init(code: "PH", name: "Philippines", terms: ["philippines"]),
        .init(code: "RU", name: "Russia", terms: ["russia"]), .init(code: "SA", name: "Saudi Arabia", terms: ["saudi arabia"]),
        .init(code: "ZA", name: "South Africa", terms: ["south africa"]), .init(code: "ES", name: "Spain", terms: ["spain"]),
        .init(code: "SE", name: "Sweden", terms: ["sweden"]), .init(code: "CH", name: "Switzerland", terms: ["switzerland"]),
        .init(code: "TW", name: "Taiwan", terms: ["taiwan"]), .init(code: "TR", name: "Turkey", terms: ["turkey", "türkiye", "turkiye"]),
        .init(code: "GB", name: "United Kingdom", terms: ["united kingdom", "uk", "britain", "great britain", "england"]),
        .init(code: "US", name: "United States", terms: ["united states", "usa", "us", "america"])]
    /// A word right before / after a country name that makes it a different place or thing.
    private static let notPreceded: [String: Set<String>] = ["mexico": ["new"], "england": ["new"], "korea": ["north"],
                                                              "america": ["south", "latin", "central", "north"], "guinea": ["new"]]
    private static let notFollowed: [String: Set<String>] = ["turkey": ["dinner", "recipe", "recipes", "sandwich", "breast", "day"],
                                                              "china": ["plate", "plates", "cabinet", "set"], "chile": ["pepper", "peppers", "powder", "sauce"]]
    /// The country a news question names, or nil.
    static func newsCountry(_ q: String) -> NewsCountry? {
        let raw = q.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let words = raw.map { $0.lowercased() }
        let terms = newsCountries.flatMap { c in c.terms.map { (term: $0, country: c) } }
            .sorted { $0.term.count > $1.term.count }   // "south korea" before "korea", "great britain" before "britain"
        for i in words.indices {
            for t in terms where genuine(words, i, t.term) {
                if t.term == "us", raw[i] != "US" { continue }
                return t.country
            }
        }
        return nil
    }
    private static func genuine(_ words: [String], _ i: Int, _ term: String) -> Bool {
        let parts = term.split(separator: " ").map(String.init)
        guard i + parts.count <= words.count, Array(words[i..<i + parts.count]) == parts else { return false }
        if i > 0, notPreceded[parts[0]]?.contains(words[i - 1]) == true { return false }
        let after = i + parts.count
        if after < words.count, notFollowed[parts.last!]?.contains(words[after]) == true { return false }
        return true
    }
    /// A result that names the country ONLY inside a longer place name ("New Mexico" for Mexico) is about somewhere
    /// else — dropped even when Brave's country filter let it through.
    static func isFalseFriend(_ text: String, for country: NewsCountry) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        var lookalike = false
        for i in words.indices {
            for term in country.terms where term != "us" {
                let parts = term.split(separator: " ").map(String.init)
                guard i + parts.count <= words.count, Array(words[i..<i + parts.count]) == parts else { continue }
                if genuine(words, i, term) { return false }
                lookalike = true
            }
        }
        return lookalike
    }

    // MARK: - Dates

    /// Brave gives `page_age` (ISO, "2026-06-24T10:12:00") and/or `age` ("June 24, 2026", "3 days ago").
    static func parsePublished(pageAge: String?, age: String?, now: Date = Date()) -> Date? {
        if let p = pageAge, p.count >= 10 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")   // the day as written, in the reader's calendar
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(p.prefix(10))) { return d }
        }
        guard let a = age?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
        for fmt in ["MMMM d, yyyy", "MMM d, yyyy", "d MMMM yyyy", "d MMM yyyy", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = fmt
            if let d = f.date(from: a) { return d }
        }
        let rel = try! NSRegularExpression(pattern: #"^(\d+|an?)\s+(minute|hour|day|week|month|year)s?\s+ago$"#, options: .caseInsensitive)
        if let m = rel.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)),
           let nR = Range(m.range(at: 1), in: a), let uR = Range(m.range(at: 2), in: a) {
            let n = Int(a[nR]) ?? 1
            let unit: Calendar.Component = switch a[uR].lowercased() {
            case "minute": .minute
            case "hour": .hour
            case "day": .day
            case "week": .weekOfYear
            case "month": .month
            default: .year
            }
            return Calendar.current.date(byAdding: unit, value: -n, to: now)
        }
        return nil
    }

    /// Whole calendar days from `d` to `now` (0 = today).
    static func daysOld(_ d: Date, now: Date) -> Int {
        let c = Calendar.current
        return c.dateComponents([.day], from: c.startOfDay(for: d), to: c.startOfDay(for: now)).day ?? 0
    }

    static func dayString(_ d: Date) -> String {   // live-29 (B5): AppleWebGrounding dates its packet the same way
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }

    /// The tool message for one `web_search`: today's date, then each source numbered GLOBALLY across the turn with its
    /// date and its passages. live-33: no computed-fact notes (fresh / section page / "no article from today") — the date
    /// is stated, and the rerank decides what is relevant.
    static func packet(_ links: [ToolLink], start: Int, now: Date) -> String {
        "Today is \(dayString(now)).\n\n" + links.enumerated().map { i, l in
            let date = WikipediaGrounding.isPassage(l) ? WikipediaGrounding.editedLine(l.published, now: now)
                : l.published.map { "Published \(dayString($0))." } ?? ""
            return ["[\(start + i + 1)] \(l.title)", l.url, date, l.snippet ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The tool message for a `fetch_url` of a numbered result.
    static func fetchedPage(index: Int?, title: String?, url: String, text: String) -> String {
        if let index, let title { return "Page text of [\(index)] \(title) (\(url)):\n\n\(text)" }
        return "Page text of \(url):\n\n\(text)"
    }

    // MARK: - URLs

    static let urlBody = #"(?:https?://|www\.)[^\s<>()\[\]{}"'`]+"#
    static let bareURLRegex = try! NSRegularExpression(pattern: urlBody, options: .caseInsensitive)

    /// Every URL in `text` (bare or a markdown link's target), trailing punctuation trimmed.
    static func urls(in text: String) -> [String] {
        let ns = text as NSString
        return bareURLRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            trimURL(ns.substring(with: $0.range))
        }
    }

    static func trimURL(_ u: String) -> String {
        var s = u
        while let last = s.last, ".,;:!?*_".contains(last) { s.removeLast() }
        return s
    }

    /// Scheme, `www.`, fragment and a trailing slash don't distinguish two URLs; case only matters in the path.
    static func normalize(_ url: String) -> String {
        var s = trimURL(url.trimmingCharacters(in: .whitespacesAndNewlines))
        if let r = s.range(of: "#") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) { s.removeSubrange(r) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        let slash = s.firstIndex(of: "/") ?? s.endIndex
        s = s[..<slash].lowercased() + s[slash...]
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// ★ The answer-side half of web grounding — a STREAMING, append-only filter in front of the citation numberer, so
/// a stripped URL or a removed source list is never shown and then taken away (the same prefix invariant as
/// `CitationNumberer`). What it removes:
///   1. any URL (bare, `<url>`, or a markdown link's target) not in `allowed`; a markdown link keeps its text, and a
///      label in front of a removed URL ("Source:", "Read more at", "(…)") goes with it;
///   2. a source list the model writes itself: a "Sources" / "References" / "Further reading" / "Learn more" heading
///      or "Sources: …" line and the list lines after it, and lines that START with a citation marker
///      ("- [3] Reuters — world news"). The app's own source list is built from the cited results.
/// Held back while undecided (bounded): the start of a line that could still become such a heading or list line,
/// an unterminated URL / markdown link / label, and trailing whitespace.
struct WebAnswerFilter {
    private var allowed: Set<String>
    private var pending = ""
    private enum LineState { case undecided, normal, sourcesLine }
    private var line: LineState = .undecided
    private var inSources = false
    private var lastOut: Character?

    init(allowed: [String] = []) { self.allowed = Set(allowed.map(WebGrounding.normalize)) }

    /// Results arrive mid-turn (each search step): widen the allow-list before the step's answer streams.
    mutating func allow(_ urls: [String]) { allowed.formUnion(urls.map(WebGrounding.normalize)) }

    func isAllowed(_ url: String) -> Bool {
        let n = WebGrounding.normalize(url)
        if allowed.contains(n) { return true }
        if let q = n.firstIndex(of: "?"), allowed.contains(String(n[..<q])) { return true }
        return false
    }

    mutating func feed(_ s: String) -> String { pending += s; return drain(final: false) }
    mutating func finish() -> String { drain(final: true) }

    /// One-shot (commit paths that don't stream).
    static func apply(_ text: String, allowed: [String]) -> String {
        var f = WebAnswerFilter(allowed: allowed)
        return f.feed(text) + f.finish()
    }

    // MARK: lines

    private mutating func drain(final: Bool) -> String {
        var out = ""
        while !pending.isEmpty {
            if let nl = pending.firstIndex(of: "\n") {
                let l = String(pending[..<nl])
                pending.removeSubrange(...nl)
                if let kept = completeLine(l) { out += emit(kept + "\n") }
                line = .undecided
                continue
            }
            if final {
                let l = pending; pending = ""
                if let kept = completeLine(l) { out += emit(kept) }
                line = .undecided
                break
            }
            if !block.isEmpty, block.count > 1500 { out += emit(block); block = "" }   // bounded hold
            out += emit(partial())
            break
        }
        if final { block = "" }   // a source-title run that ends the answer is the model's own source list
        return out
    }

    private mutating func emit(_ s: String) -> String {
        for c in s.suffix(2) { prevOut = lastOut; lastOut = c }
        return s
    }
    private var prevOut: Character?

    private static let headingWords = ["sources", "source", "references", "reference", "citations", "further reading",
                                       "learn more", "read more", "more information", "bibliography", "links"]
    private static func plain(_ l: String) -> String {
        var s = l.replacingOccurrences(of: #"[*_]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s#>]+"#, with: "", options: .regularExpression)
        return s.lowercased()
    }
    private static let wordAlt = headingWords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    private static let headingAlone = try! NSRegularExpression(pattern: "^(?:\(wordAlt))\\s*:?\\s*$")
    private static let headingInline = try! NSRegularExpression(pattern: "^(?:\(wordAlt))\\s*:\\s*\\S")
    private static let markerLine = try! NSRegularExpression(pattern: #"^\s*(?:[-*•+]\s*|\d{1,2}[.)]\s*)?\[\s*\d{1,2}\s*\]"#)
    /// A line so far that is only a bullet / number and maybe the start of a marker ("- ", "2.", "- [", "[1") — undecided.
    private static let markerLineStart = try! NSRegularExpression(pattern: #"^\s*(?:[-*•+]\s*|\d{1,2}[.)]?\s*)?(?:\[\s*\d{0,2}\s*\]?)?\s*$"#)
    private static let listLine = try! NSRegularExpression(pattern: #"^\s*(?:[-*•+]|\d{1,2}[.)])\s+"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A citation-led line that carries a URL — a source entry wherever it appears.
    private static func isURLSourceLine(_ l: String) -> Bool {
        matches(markerLine, l) && !WebGrounding.urls(in: l).isEmpty
    }
    /// A citation-led line that reads like a source TITLE ("[3] Reuters — World", "[1]", "[1] [2]"), not a sentence
    /// about the source ("[1] does not mention a Bolex."). Dropped only as part of a run that ENDS the answer.
    private static func isTitleSourceLine(_ l: String) -> Bool {
        guard let m = markerLine.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) else { return false }
        var rest = (l as NSString).substring(from: m.range.upperBound)
        rest = rest.replacingOccurrences(of: #"^(?:\s*,?\s*\[\s*\d{1,2}\s*\])*[\s:\-–—]*"#, with: "", options: .regularExpression)
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return true }
        if let c = rest.first, c.isLowercase { return false }
        if rest.count > 160 || rest.range(of: #"[.!?]\s+\S"#, options: .regularExpression) != nil { return false }
        return true
    }
    /// Title-like source lines (and blank lines between them) held until the answer either ENDS (→ dropped: the
    /// model's own source list) or continues with prose (→ released unchanged).
    private var block = ""

    /// The line to emit, or nil when it is dropped (a source heading / list line).
    private mutating func completeLine(_ l: String) -> String? {
        switch line {
        case .sourcesLine:   // "Sources: …" on one line — only that line goes
            return nil
        case .normal:
            return scrub(l, wholeLine: false)
        case .undecided:
            let p = Self.plain(l)
            if inSources {
                if p.trimmingCharacters(in: .whitespaces).isEmpty || Self.matches(Self.listLine, l)
                    || Self.matches(Self.headingAlone, p) || Self.matches(Self.headingInline, p)
                    || Self.matches(Self.markerLine, l) || !WebGrounding.urls(in: l).isEmpty {
                    return nil
                }
                inSources = false
                // prose after the list: keep it a separate paragraph
                let gap = lastOut == nil || (lastOut == "\n" && prevOut == "\n") ? "" : (lastOut == "\n" ? "\n" : "\n\n")
                return gap + scrub(l, wholeLine: true)
            }
            if Self.matches(Self.headingAlone, p) {
                inSources = true
                block = ""
                return nil
            }
            if Self.matches(Self.headingInline, p) { return nil }
            if Self.isURLSourceLine(l) { return nil }
            if Self.isTitleSourceLine(l) { block += scrub(l, wholeLine: true) + "\n"; return nil }
            if p.trimmingCharacters(in: .whitespaces).isEmpty, !block.isEmpty { block += "\n"; return nil }
            let held = block; block = ""
            return held + scrub(l, wholeLine: true)
        }
    }

    private mutating func partial() -> String {
        if line == .undecided {
            if inSources { return "" }
            let p = Self.plain(pending)
            if pending.count > 200 { line = .normal }
            else if Self.matches(Self.headingInline, p) { line = .sourcesLine; return "" }
            else if p.trimmingCharacters(in: .whitespaces).isEmpty
                        || Self.headingWords.contains(where: { $0.hasPrefix(p) || Self.matches(Self.headingAlone, p) })
                        || Self.matches(Self.markerLineStart, pending)
                        || (Self.matches(Self.markerLine, pending) && pending.count <= 160) {
                return ""   // could still become a heading or a source-list line
            } else {
                line = .normal
            }
        }
        if line == .sourcesLine { return "" }
        // prose continues after held source-title lines → they were part of the answer: release them first
        let held = block; block = ""
        let ns = pending as NSString
        var cut = ns.length
        for re in Self.holdRegexes {
            if let m = re.firstMatch(in: pending, range: NSRange(location: 0, length: ns.length)), ns.length - m.range.location <= 400 {
                cut = min(cut, m.range.location)
            }
        }
        // a held fragment takes the whitespace before it, so a removal and its surrounding spaces settle together
        while cut > 0, let u = UnicodeScalar(ns.character(at: cut - 1)), CharacterSet.whitespaces.contains(u) { cut -= 1 }
        // a trailing word that may still become a label's first word ("Rea" → "Read more at …")
        if let r = pending.range(of: #"\b[A-Za-z]{1,9}\z"#, options: .regularExpression) {
            let w = pending[r].lowercased()
            if Self.labelStarters.contains(where: { $0.hasPrefix(w) }) { cut = min(cut, NSRange(r, in: pending).location) }
        }
        // never cut inside a markdown link or a (labelled) URL — they are scrubbed whole
        for re in [Self.mdLinkLoose, Self.labelledURL] {
            for m in re.matches(in: pending, range: NSRange(location: 0, length: ns.length))
            where m.range.location < cut && cut < m.range.upperBound { cut = m.range.location }
        }
        while cut > 0, let u = UnicodeScalar(ns.character(at: cut - 1)), CharacterSet.whitespaces.contains(u) { cut -= 1 }
        guard cut > 0 else { return held }
        let head = ns.substring(to: cut)
        pending = ns.substring(from: cut)
        return held + scrub(head, wholeLine: false)
    }

    // MARK: scrub

    private static let label = #"(?:sources?|via|see|link|read more|learn more|more information|more info|find out more|available)(?:\s+(?:at|on|here))?"#
    private static let holdRegexes: [NSRegularExpression] = [
        // an unterminated URL (or one just closed by ")"), with the label / open paren in front of it
        try! NSRegularExpression(pattern: #"(?:\(\s*)?(?:\b"# + label + #"\s*:?\s*)?<?(?:https?://|www\.)[^\s<>()\[\]{}"'`]*>?\)?\z"#, options: .caseInsensitive),
        // a label being written ("Read more", "Source:", "available at") can still be completed by a URL
        try! NSRegularExpression(pattern: #"\b(?:read|learn|find|more|available|see|via|sources?|link)\b(?:[ \t]+[\w:]{0,12}){0,3}[ \t]*\z"#, options: .caseInsensitive),
        // a URL scheme still arriving
        try! NSRegularExpression(pattern: #"(?:\(\s*)?(?:\b"# + label + #"\s*:?\s*)?<?\b(?:h|ht|htt|http|https|https?:|https?:/|w|ww|www)\z"#, options: .caseInsensitive),
        // a label that may be followed by a URL
        try! NSRegularExpression(pattern: #"(?:\(\s*)?\b"# + label + #"\s*:?\s*\z"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"[(<]\s*\z"#),
        // an open markdown link: `[text`, `[text]`, `[text](url`
        try! NSRegularExpression(pattern: #"\[[^\]\n]{0,300}\z"#),
        try! NSRegularExpression(pattern: #"\[[^\]\n]{1,300}\]\(?[^)\s]*\z"#),
        try! NSRegularExpression(pattern: #"[ \t]+\z"#),
    ]
    private static let labelStarters = ["read", "learn", "find", "more", "available", "see", "via", "source", "sources", "link"]
    private static let mdLinkLoose = try! NSRegularExpression(pattern: #"\[[^\]\n]{1,300}\]\([^)\n]*\)?"#)
    private static let mdLink = try! NSRegularExpression(
        pattern: #"\[([^\]\n]{1,300})\]\(\s*<?("# + WebGrounding.urlBody + #")>?\s*\)"#, options: .caseInsensitive)
    private static let labelledURL = try! NSRegularExpression(
        pattern: #"(\(\s*)?(?:\b"# + label + #"\s*:?\s*)?<?("# + WebGrounding.urlBody + #")>?(\s*\))?"#, options: .caseInsensitive)

    private mutating func scrub(_ seg: String, wholeLine: Bool) -> String {
        guard seg.range(of: #"https?://|www\."#, options: [.regularExpression, .caseInsensitive]) != nil else { return seg }
        var s = seg as NSString
        // 1. markdown links: an allowed target stays; otherwise keep the link text (unless it is itself a URL).
        var keepRanges: [NSRange] = []
        for m in Self.mdLink.matches(in: s as String, range: NSRange(location: 0, length: s.length)).reversed() {
            let url = s.substring(with: m.range(at: 2))
            if isAllowed(url) { keepRanges.append(m.range); continue }
            let text = s.substring(with: m.range(at: 1))
            let rep = WebGrounding.urls(in: text).isEmpty ? text : ""
            s = s.replacingCharacters(in: m.range, with: rep) as NSString
            keepRanges = keepRanges.map { NSRange(location: $0.location + (rep as NSString).length - m.range.length, length: $0.length) }
        }
        // allowed markdown links (recomputed on the rewritten string) are left alone by step 2
        let kept = Self.mdLink.matches(in: s as String, range: NSRange(location: 0, length: s.length))
            .filter { isAllowed(s.substring(with: $0.range(at: 2))) }.map(\.range)
        // 2. bare URLs, with the label and parens that announce them
        for m in Self.labelledURL.matches(in: s as String, range: NSRange(location: 0, length: s.length)).reversed() {
            if kept.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            let raw = s.substring(with: m.range(at: 2))
            let url = WebGrounding.trimURL(raw)
            if isAllowed(url) { continue }
            var r = m.range
            // an open paren in the match needs its close: if the URL's closing paren wasn't matched, keep the "("
            if m.range(at: 1).location != NSNotFound, m.range(at: 3).location == NSNotFound {
                r = NSRange(location: m.range(at: 1).upperBound, length: r.upperBound - m.range(at: 1).upperBound)
            }
            // trailing punctuation that belonged to the URL's sentence stays (the trim above)
            let trail = (raw as NSString).length - (url as NSString).length
            if trail > 0, m.range(at: 3).location == NSNotFound { r.length -= trail }
            s = s.replacingCharacters(in: r, with: "") as NSString
        }
        var out = s as String
        out = out.replacingOccurrences(of: #"\(\s*\)|\[\s*\]|<\s*>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<=\S)[ \t]{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[ \t]+(?=[.,;:!?])"#, with: "", options: .regularExpression)
        // a removal that leaves a doubled sentence end ("fish.." / "fish. .")
        out = out.replacingOccurrences(of: #"([.!?])\s*[.,;:](?=\s|$)"#, with: "$1", options: .regularExpression)
        if let first = out.first, ".,;:".contains(first), let prev = lastOut, ".!?".contains(prev) { out.removeFirst() }
        // a whole line that was only a link / label is now only punctuation → empty it
        if wholeLine, out.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;:-–—•*_()")).isEmpty,
           !seg.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return out
    }
}

#if DEBUG
/// `-WebGroundingSelfTest` (Simulator; PASS/FAIL). The load-bearing checks: a URL no tool returned never appears
/// (at ANY chunk boundary, chunked whole / by word / by character), the streamed text is always a prefix of the
/// committed text, a model-written source list never reaches the numberer, and fresh results rank first. Each
/// group carries a CONTROL (the unfiltered text must contain what the filter removes — the check has teeth).
enum WebGroundingSelfTest {
    @MainActor static func run() -> String {
        var fails: [String] = [], ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            ran += 1
            if !ok { fails.append("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        func chunkings(_ s: String) -> [[String]] {
            [[s], s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element },
             s.map { String($0) }, stride(from: 0, to: s.count, by: 7).map { i in String(Array(s)[i..<min(i + 7, s.count)]) }]
        }
        /// Streams every chunking; checks the prefix invariant + `forbidden` never shown; returns the committed text.
        func filter(_ name: String, _ text: String, allowed: [String] = [], forbidden: [String] = []) -> String {
            var outs: [String] = []
            for (k, ch) in chunkings(text).enumerated() {
                var f = WebAnswerFilter(allowed: allowed)
                var shown = ""
                var snapshots: [String] = []
                for c in ch { shown += f.feed(c); snapshots.append(shown) }
                shown += f.finish()
                let final = shown.replacingOccurrences(of: #"\s+\z"#, with: "", options: .regularExpression)
                let bad = snapshots.first { !final.hasPrefix($0.replacingOccurrences(of: #"\s+\z"#, with: "", options: .regularExpression)) }
                check("\(name)#\(k) prefix-invariant", bad == nil, "shown «\(bad ?? "")» ⊄ final «\(final)»")
                for f in forbidden { check("\(name)#\(k) never shows \(f)", !snapshots.contains { $0.contains(f) } && !final.contains(f), final) }
                outs.append(final)
            }
            check("\(name) deterministic across chunkings", Set(outs).count == 1, "\(Set(outs))")
            return outs[0]
        }

        // 1. T's case 1 — a General answer that didn't search ends with invented sources.
        let natgeo = "Oarfish can grow longer than 8 metres and live in the deep ocean.\n\n**Sources:**\n- National Geographic: https://www.nationalgeographic.com/animals/fish/facts/oarfish\n- Science: https://www.science.org/content/article/oarfish-deep-sea"
        check("control: the raw answer carries the invented URLs", natgeo.contains("nationalgeographic.com"))
        let r1 = filter("natgeo", natgeo, forbidden: ["nationalgeographic", "science.org", "Sources", "National Geographic"])
        check("natgeo text", r1 == "Oarfish can grow longer than 8 metres and live in the deep ocean.", r1)

        // 2. inline URL: kept when a tool returned it, stripped (with its parens) when not.
        let inline = "The oarfish belongs to the family Regalecidae (https://en.wikipedia.org/wiki/Oarfish). It is rarely seen."
        let r2a = filter("inline-allowed", inline, allowed: ["https://en.wikipedia.org/wiki/Oarfish"])
        check("inline allowed kept", r2a == inline, r2a)
        let r2b = filter("inline-stripped", inline, forbidden: ["wikipedia"])
        check("inline stripped", r2b == "The oarfish belongs to the family Regalecidae. It is rarely seen.", r2b)

        // 3. markdown links keep their text; a labelled URL goes with its label.
        let md = "See [the 2019 study](https://fake.example/study) for details. Read more at https://fake.example/more."
        let r3 = filter("markdown", md, forbidden: ["fake.example", "Read more"])
        check("markdown text", r3 == "See the 2019 study for details.", r3)
        let r3b = filter("markdown-allowed", md, allowed: ["fake.example/study"], forbidden: ["fake.example/more"])
        check("markdown allowed", r3b == "See [the 2019 study](https://fake.example/study) for details.", r3b)

        // 4. T's case 3 — the model's own source list (out of order, an uncited source) never reaches the numberer.
        let list = "Floods hit the north [2] and markets rallied [1].\n\nSources:\n[3] Reuters — World\n[1] AP News\n[2] BBC"
        let r4 = filter("model-sources", list, allowed: [], forbidden: ["Reuters", "Sources"])
        check("model-sources text", r4 == "Floods hit the north [2] and markets rallied [1].", r4)
        let headless = "Floods hit the north [2].\n\n- [3] Reuters — world news\n- [1] AP News, https://apnews.com/hub/world"
        let r4b = filter("marker-lines", headless, forbidden: ["Reuters", "apnews"])
        check("marker-lines text", r4b == "Floods hit the north [2].", r4b)

        // 5. prose that merely starts with a heading word is left alone; prose after a source list comes back.
        let prose = "Sources say the mayor resigned on Monday [1].\n\nReferences:\n- [1] Local Times\n\nThat is all I found."
        let r5 = filter("prose", prose, forbidden: ["Local Times"])
        check("prose text", r5 == "Sources say the mayor resigned on Monday [1].\n\nThat is all I found.", r5)

        // 5b. a heading-less source-title run ENDING the answer goes; the same lines followed by prose stay; a
        //     sentence that starts with a marker stays.
        let tail = "Floods hit the north [2] and markets rallied [1].\n\n[3] Reuters — World\n[1] AP News"
        let r5b = filter("title-run-at-end", tail, forbidden: ["Reuters"])
        check("title-run-at-end text", r5b == "Floods hit the north [2] and markets rallied [1].", r5b)
        let mid = "Two outlets covered it:\n- [1] Reuters — World\n- [2] AP News\n\nBoth say the floods hit the north [1]."
        check("title-run then prose kept", filter("title-run-mid", mid) == mid)
        let sentence = "Nothing matched.\n\n[1] does not mention a Bolex."
        check("marker sentence kept", filter("marker-sentence", sentence) == sentence)
        let inlineSrc = "Two values are high:\n- Cholesterol 241 [1]\n  *Source: the lab report*\n- LDL 171 [1]"
        let r5c = filter("inline-source", inlineSrc)
        check("inline source line goes, the list stays", r5c == "Two values are high:\n- Cholesterol 241 [1]\n- LDL 171 [1]", r5c)
        let bullets = "The pattern:\n- [1][2][3] show the *origin* of it.\n- [4] shows its expression."
        check("marker bullets kept", filter("marker-bullets", bullets) == bullets)

        // 6. nothing to filter → byte-identical (lists, markers, markdown untouched).
        let clean = "Three things:\n\n1. **Rayleigh scattering** [1]\n2. Blue light scatters more [2]\n\n- a list item\n- another"
        check("clean passthrough", filter("clean", clean) == clean)

        // 7. URL helpers
        check("normalize", WebGrounding.normalize("https://WWW.Example.com/Path/?q=1#x") == "example.com/Path/?q=1", WebGrounding.normalize("https://WWW.Example.com/Path/?q=1#x"))
        var f7 = WebAnswerFilter(allowed: ["https://example.com/a"])
        check("query variant allowed", f7.isAllowed("http://example.com/a?utm=x"))
        f7.allow(["https://b.example/x"])
        check("allow widens", f7.isAllowed("b.example/x/"))

        // 8. dates + ranking (T's case 2: a June story under "today's news")
        let now = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00Z")!
        let june = WebGrounding.parsePublished(pageAge: "2026-06-24T09:00:00", age: nil, now: now)
        check("page_age parsed", june.map { WebGrounding.daysOld($0, now: now) } == 106, "\(String(describing: june))")
        check("age text parsed", WebGrounding.parsePublished(pageAge: nil, age: "June 24, 2026", now: now) != nil)
        check("relative age parsed", WebGrounding.parsePublished(pageAge: nil, age: "3 days ago", now: now).map { WebGrounding.daysOld($0, now: now) } == 3)
        let stale = ToolLink(title: "Mexico: Reuters world", url: "https://reuters.example/world/americas/mexico-floods-june-24", snippet: "June story", published: june)
        let hub = ToolLink(title: "Mexico news | Reuters", url: "https://reuters.example/world/mexico/", snippet: "Latest headlines")
        let pk = WebGrounding.packet([stale, hub], start: 3, now: now)
        check("packet: today's date", pk.hasPrefix("Today is 8 October 2026."), pk)
        check("packet: the date stated, global numbering", pk.contains("[4] Mexico: Reuters world\nhttps://reuters.example/world/americas/mexico-floods-june-24\nPublished 24 June 2026.\nJune story"), pk)
        check("packet: no computed-fact notes", !pk.contains("COMPUTED FACT") && !pk.contains("date unknown") && pk.contains("[5] Mexico news | Reuters\nhttps://reuters.example/world/mexico/\nLatest headlines"), pk)

        // 9. question shape
        for (q, want) in [("What family does the oarfish belong to?", true), ("Who wrote Pride and Prejudice?", true),
                          ("When was Antarctica first sighted?", true), ("Explain in two sentences why the sky is blue.", true),
                          ("What is 17 × 23?", false), ("What did I write about Mara?", false), ("Write a haiku about rain", false),
                          ("Should I learn Swift or Kotlin?", false), ("hello", false), ("Is the colossal squid bigger than the giant squid?", true)] {
            check("factual: \(q)", WebGrounding.isFactualQuestion(q) == want)
        }
        check("news keywords: Mexico", WebGrounding.newsKeywords("What's the top news in Mexico today?") == ["mexico"], "\(WebGrounding.newsKeywords("What's the top news in Mexico today?"))")
        check("news keywords: world", WebGrounding.newsKeywords("What are the top world news stories today?") == ["world"])
        check("news keywords: telescope", WebGrounding.newsKeywords("What's the latest news about the Lakeview Observatory telescope?") == ["lakeview", "observatory", "telescope"])
        check("factual: pep talk is not", !WebGrounding.isFactualQuestion("Write a two-line pep talk for a Monday."))
        check("factual: give me a pep talk is not", !WebGrounding.isFactualQuestion("Give me a pep talk, I have a big day"))

        // 10. CH (T 2026-10-09) — the country a news question names → Brave's `country` code.
        for (q, want) in [("What's the top news in Mexico today?", "MX"), ("Latest news from New Mexico", nil),
                          ("What's happening in South Korea today?", "KR"), ("North Korea latest news", nil),
                          ("Top news in the US today", "US"), ("Can you tell us the latest news?", nil),
                          ("What's the latest UK news?", "GB"), ("Latest Latin America news", nil),
                          ("Breaking news in Turkey", "TR"), ("Latest turkey recipe news", nil),
                          ("What are the top world news stories today?", nil), ("News from New Zealand today", "NZ")] {
            check("news country: \(q)", WebGrounding.newsCountry(q)?.code == want, "\(WebGrounding.newsCountry(q)?.code ?? "nil")")
        }
        // 11. live-29 (B3) — T (Tavily): "Who is the current president of the United States" went to the NEWS topic
        // (midterm articles), and the answer that searched showed the training-data line.
        for (q, want) in [("Who is the current president of the United States", false), ("Who is the current president?", false),
                          ("What's the current population of Chicago?", false), ("Who is the prime minister of Canada right now?", false),
                          ("What's the latest iPhone?", false), ("What's the top news in Mexico today?", true),
                          ("What are the headlines this morning?", true), ("Latest news on the Lakeview Observatory", true),
                          ("What happened in Turkey yesterday?", true), ("Breaking news in Turkey", true)] {
            check("news-shaped: \(q)", WebGrounding.isNewsQuestion(q) == want)
        }
        let pres = "Who is the current president of the United States?"
        let cited = WebGrounding.answerNote(question: pres, searchRan: true, resultCount: 3, citedCount: 2, rateLimited: false)
        let uncited = WebGrounding.answerNote(question: pres, searchRan: true, resultCount: 3, citedCount: 0, rateLimited: false)
        let empty = WebGrounding.answerNote(question: pres, searchRan: true, resultCount: 0, citedCount: 0, rateLimited: false)
        let none = WebGrounding.answerNote(question: pres, searchRan: false, resultCount: 0, citedCount: 0, rateLimited: false)
        check("searched + cited → no line", cited == nil)
        check("searched, nothing cited → 'didn't confirm', never training data", uncited?.unconfirmed == true && uncited?.dated == false
              && uncited?.text == WebGrounding.searchUnconfirmedNote, uncited?.text ?? "nil")
        check("searched, no results → 'didn't confirm', never training data", empty?.unconfirmed == true && empty?.dated == false,
              empty?.text ?? "nil")
        check("no search → the dated line, as before", none?.dated == true && none?.text == WebGrounding.datedKnowledgeNote, none?.text ?? "nil")
        for (raw, want) in [("#### Tags\nThe 47th president took office in January.", "Tags The 47th president took office in January."),
                            ("## Who is the president? | Encyclopedia", "Who is the president? | Encyclopedia"),
                            ("**Joe** — *served* 2021–2025 [details](https://example.com)", "Joe — served 2021–2025 details"),
                            ("Plain snippet &amp; more", "Plain snippet & more")] {
            let got = WebGrounding.cleanResultText(raw)
            check("result text has no markdown: \(raw.prefix(20))", got == want, got)
        }
        let mx = WebGrounding.newsCountry("Top news in Mexico")!
        check("false friend: New Mexico only", WebGrounding.isFalseFriend("Two pipeline fires in New Mexico Tuesday", for: mx))
        check("false friend: Mexico itself", !WebGrounding.isFalseFriend("Deadly riot at a prison in Mexico's Sinaloa state", for: mx))
        check("false friend: both", !WebGrounding.isFalseFriend("New Mexico and Mexico sign a water deal", for: mx))
        check("false friend: no mention", !WebGrounding.isFalseFriend("Puerto Vallarta placed under hurricane watch", for: mx))

        // 11. CH (T 2026-10-09) — the live tool status line.
        check("status: search", ChatSession.toolStatus(AgentTools.webSearch, ["query": "x"]) == "Searching the web…")
        check("status: read", ChatSession.toolStatus(AgentTools.fetchURL, ["url": "https://www.example.org/wiki/Oarfish"]) == "Reading example.org…",
              ChatSession.toolStatus(AgentTools.fetchURL, ["url": "https://www.example.org/wiki/Oarfish"]) ?? "nil")

        // 12. live-27 (3) — current-state requests, make / list / table included, are searched when search is on; the
        // no-key notice keeps its own narrow cues (a presidents table still answers without a key).
        for (q, want) in [("Make a table of US presidents and whether each is living", true),
                          ("Who is the current prime minister of Japan?", true),
                          ("List the latest phones from the big three makers", true),
                          ("Is the Lakeview Observatory telescope still the largest in the state?", true),
                          ("What does a dozen eggs cost now?", true),
                          ("Which teams are in the league this year?", true),
                          ("Make a table of the planets with their distance from the sun", false),
                          ("Write a short poem about the sea", false),
                          ("What caused the fall of the Western Roman Empire?", false),
                          ("How do I make a simple tomato sauce?", false),
                          ("Explain how a heat pump works", false),
                          ("Is the colossal squid bigger than the giant squid?", false)] {
            check("current-state: \(q)", WebGrounding.asksCurrentState(q) == want)
        }
        check("no-key notice stays narrow (the presidents table answers)",
              !LibrarianState.looksLikeSearchIntent("Make a table of US presidents and whether each is living"))
        let tool = LibrarianState.toolChatBase(today: "Sunday, October 18, 2026")
        check("tool prompt keeps today's date", tool.contains("Today's real date is Sunday, October 18, 2026"))
        check("tool prompt no longer forbids a cutoff", !tool.lowercased().contains("knowledge cutoff") || !tool.contains("Do NOT claim"), tool)
        check("tool prompt: changing facts as of the training data, offer a search", tool.contains("as of my training data")
              && tool.contains("who holds an office") && tool.lowercased().contains("offer to search"))
        check("tool prompt: never 'as of <today>' without this turn's search result", tool.contains("Never write \"as of"))
        // live-28 (A5) — "your information" read as the USER's (T: "based on your entries and the latest data"): the line
        // says whose knowledge is dated, and General never mentions the user's information.
        check("general prompt (Apple + Host without a key): the dated-knowledge line says what YOU know may be out of date",
              LibrarianState.generalPromptBase.contains("If a fact may have changed recently, say that what you know may be out of date.")
              && !LibrarianState.generalPromptBase.contains("your information"))
        // live-27 (3) — the gauntlet's DK1 (search off, qwen3:4b): the one line was ignored ("As of now (June 2024)", no
        // caveat). The Host without a key gets the full dated paragraph (Apple keeps the one plain line), and the app says
        // it under any current-state answer no search backs.
        let hostNoKey = LibrarianState.hostGeneralPromptBase
        check("host prompt without a key dates its knowledge", hostNoKey.contains("as of my training data")
              && hostNoKey.contains("who holds an office") && hostNoKey.contains("Never present such a fact as current"), hostNoKey)
        check("apple keeps the one plain line", !LibrarianState.generalPromptBase.contains("DATED KNOWLEDGE"))
        check("ungrounded current-state answer → the dated note",
              WebGrounding.ungroundedNote(for: "Make a table of US presidents and whether each is living") == WebGrounding.datedKnowledgeNote
              && WebGrounding.ungroundedNote(for: "Who wrote Pride and Prejudice?") == WebGrounding.generalKnowledgeNote
              && WebGrounding.ungroundedNote(for: "Write a two-line pep talk for a Monday.") == nil)

        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(ran - fails.count)/\(ran)\n  " + fails.joined(separator: "\n  ")
    }
}
#endif

#if DEBUG
/// live-31 (3) — `-HostWebSelfTest`: the Host path's current-state rule, pure parts plus both providers' failure signal
/// (against a closed port). RED: `-HostWebLive30 YES` (live-30's rule). The send itself is checked on the stub stack
/// (`scripts/runaway/run.sh`, `WebSearchAnswerUI`).
enum HostWebSelfTest {
    static func run() async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        func cs(_ q: String) -> Bool { WebGrounding.asksCurrentState(q) }
        // Current state: deaths and recent years count; a question about the user or a request to write doesn't.
        row("a-list-of-people-and-how-they-died", cs("List the members of the Beatles and how each of them died"))
        row("leaders-who-died-since-a-recent-year", cs("Which world leaders have died since 2024?"))
        row("a-recent-year", cs("Who won the 2025 Tour de France?"))
        row("an-office-still-counts", cs("Make a table of the US presidents, their parties and their causes of death"))
        row("not-about-the-user", !cs("My grandfather died last year, how do I write a eulogy?"))
        row("not-a-request-to-write", !cs("Write a poem about death"))
        row("not-an-old-fact", !cs("Who wrote Pride and Prejudice?") && !cs("What happened in 1066?"))
        // The plan: a current-state question is searched; a real follow-up to a searched answer is searched again.
        let first = WebGrounding.hostPrefetch("Make a table of the US presidents, their parties and their causes of death",
                                              searchIntent: false, lastAnswerSearched: false)
        row("T's-shape-is-searched-up-front", first.prefetch == "search", first.prefetch)
        let follow = WebGrounding.hostPrefetch("And which of them was the most recent to go?", searchIntent: false, lastAnswerSearched: true)
        row("a-follow-up-to-a-searched-answer-is-searched", follow.prefetch == "search" && follow.followUp, "\(follow)")
        let thanks = WebGrounding.hostPrefetch("thanks!", searchIntent: false, lastAnswerSearched: true)
        row("thanks-isn't-searched", thanks.prefetch == "none", thanks.prefetch)
        // Social / video hosts out (live-33: the rerank picks the passages, no top-five cut).
        let links = [ToolLink(title: "Clip", url: "https://www.youtube.com/watch?v=1", snippet: "a"),
                     ToolLink(title: "Post", url: "https://www.instagram.com/p/1", snippet: "b")]
            + (1...6).map { ToolLink(title: "Result \($0)", url: "https://example.org/\($0)", snippet: "s\($0)") }
        let kept = WebGrounding.hostLinks(links)
        row("social-hosts-out", kept.count == 6 && !kept.contains { AppleWebQuery.isSocial($0.url) }, kept.map(\.url).joined(separator: " "))
        // The turn: the app's search, labelled, the question last; the clause says whose search it was.
        let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
        let turn = WebGrounding.appSearchTurn(query: "US presidents party cause of death 2026", question: "Make a table…",
                                              links: Array(kept.prefix(2)), now: now)
        row("results-labelled-as-the-app's-search", turn.hasPrefix("Web results the app found today (20 October 2026) for \"US presidents party cause of death 2026\":")
            && turn.contains("[1] Result 1") && turn.hasSuffix("Question: Make a table…") && WebGrounding.appSearchClause.contains("not from the user"),
            String(turn.prefix(80)))
        // No search ran (a provider that didn't answer): the training-data line, never "didn't confirm".
        let d = UserDefaults.standard
        let priorBase = d.string(forKey: "WebSearchBaseURL")
        d.set("http://127.0.0.1:1", forKey: "WebSearchBaseURL")
        let brave = await BraveSearchToolExecutor(apiKey: "stub").execute(name: AgentTools.webSearch, arguments: ["query": "Which world leaders have died since 2024?"])
        let tavily = await TavilySearchToolExecutor(apiKey: "stub").execute(name: AgentTools.webSearch, arguments: ["query": "Which world leaders have died since 2024?"])
        if let priorBase { d.set(priorBase, forKey: "WebSearchBaseURL") } else { d.removeObject(forKey: "WebSearchBaseURL") }
        row("brave-unreachable-is-a-failure", brave.failed && brave.links.isEmpty, brave.textForModel)
        row("tavily-unreachable-is-a-failure", tavily.failed && tavily.links.isEmpty, tavily.textForModel)
        let note = WebGrounding.answerNote(question: "Which world leaders have died since 2024?", searchRan: false, resultCount: 0,
                                           citedCount: 0, rateLimited: false)
        row("no-search-means-the-training-data-line", note?.dated == true, note?.text ?? "nil")
        let passed = rows.filter { $0.1 }.count
        let lines = rows.map { "\($0.1 ? "ok  " : "BAD ") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined(separator: "\n")
        return "\(passed == rows.count ? "PASS" : "FAIL") — \(passed)/\(rows.count)\n\(lines)"
    }
}
#endif
