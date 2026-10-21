import Foundation

/// live-32 (2) — Wikipedia grounding (T 2026-10-21, handoff §3 item 8 pulled forward). Keyless, so a factual or
/// current-holder question is grounded even with no search key (Apple Intelligence-only users).
///
/// T (TF 202610210043, his server model + Tavily): "a table of the last ten US presidents" searched, but the table
/// stopped at Biden ("president through 2026"); the follow-up dismissed Wikipedia "edited on October 17" as not dated
/// news. Snippets of list pages rarely contain the newest row, and the open web is full of stale pages. The article
/// itself states the settled fact in its lead or infobox ("The incumbent president is Donald Trump, who assumed office
/// on January 20, 2025"; `incumbent = Andy Burnham`, `incumbent_since = 20 July 2026`), with its last-edit date.
///
/// What the app fetches (the MediaWiki Action API, two requests, ~0.5 s, alongside the web search, not after it): a
/// full-text search for the question's subject → the best article's plain-text extract, its lead's wikitext (the
/// infobox) and its last revision's timestamp. The passage is the infobox's holder / date fields, then the lead's
/// sentences that answer (and any later sentence that names a current holder), capped. It goes into the turn as
/// source [1], "last edited <date>", next to the web results. Wikidata (the office's officeholder with a start date)
/// was measured as a check and left out: the same fact as the infobox, two more requests, and the qualifiers need
/// reading with care (the current holder's claim carries an END date — the scheduled end of the term).
///
/// Etiquette (Wikimedia's API policy): the User-Agent names the app and its project page; one search + one read per
/// turn; answers cached for ten minutes. Only the query goes to Wikimedia, exactly as it goes to the search provider.
enum WikipediaGrounding {

    struct Passage: Sendable, Equatable {
        let title: String
        let url: String
        let lastEdited: Date?
        let text: String
    }

    /// DEBUG `-Live31Web YES` — live-31's web turn (the RED baseline for `-HostWebSelfTest` / `-AppleWebSelfTest` and the
    /// stub rows): no Wikipedia, today's-news framing on any "current" question, the first 300 characters of a result,
    /// a correction searched as written, no source filter for current-state questions, the Server model left to think.
    static var live31: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "Live31Web")
        #else
        false
        #endif
    }

    /// Wikipedia runs when web search is on (the same switch: off means nothing leaves the phone).
    static var isOn: Bool {
        #if DEBUG
        // The gauntlet's mock provider serves synthetic facts: real Wikipedia stays out unless asked for (`-WikipediaLive YES`).
        let d = UserDefaults.standard
        if d.bool(forKey: "WebSearchMock"), !d.bool(forKey: "WikipediaLive") { return false }
        // UI tests stay off the real site: on only when the stub stands in (`-WebSearchBaseURL`) or a live run asks.
        if ProcessInfo.processInfo.arguments.contains("-UITestLibrary"), !d.bool(forKey: "WikipediaLive"),
           (d.string(forKey: "WebSearchBaseURL") ?? "").isEmpty, (d.string(forKey: "WikipediaBaseURL") ?? "").isEmpty { return false }
        #endif
        return !live31 && WebSearchBackend.isEnabled
    }

    static let titlePrefix = "Wikipedia: "
    static func isPassage(_ l: ToolLink) -> Bool { l.title.hasPrefix(titlePrefix) }
    static func link(_ p: Passage) -> ToolLink {
        ToolLink(title: titlePrefix + p.title, url: p.url, snippet: p.text, published: p.lastEdited)
    }

    static let passageCap = 1_400

    // MARK: - Pure parts

    /// The subject of a question, for the article search: request words, question words, "current / now / still …",
    /// "the last ten", years and punctuation out ("a table of the last ten US presidents 2026" → "us presidents";
    /// "Is Pope Francis still alive?" → "pope francis").
    static func searchTerms(_ q: String) -> String {
        var t = " " + q.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let patterns = [
            #"^\s*(please\s+)?(make|give|show|create|draw up|put together|build|list|tell)( me| us)?\b"#,
            #"\b(a|an)\s+(table|list|chart|rundown|summary|timeline|overview)\s+of\b"#,
            #"\b(table|list|chart|rundown)\s+of\b"#,
            #"^\s*(who|what|which|when|where|whose|how)('s|\s+(is|are|was|were|did|does|do|has|have|holds?|won))?\b"#,
            #"^\s*(is|are|was|were|did|does|do|has|have)\b"#,
            #"\b(the\s+)?(last|first|top)\s+(\d+|two|three|four|five|six|seven|eight|nine|ten|twelve|twenty)\b"#,
            #"\b(currently|current|right now|nowadays|these days|at the moment|at present|today|now|still|alive|living|incumbent|sitting|latest|newest|most recent|recent|present)\b"#,
            #"\b(19|20)\d{2}\b"#,
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression) }
        t = t.replacingOccurrences(of: #"[^a-z0-9'\- ]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(the|a|an|of|in|and)\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(the|of|and|in)\s*$"#, with: " ", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The article to read: the first search hit that isn't a disambiguation page and shares a word with the subject.
    static func pickTitle(_ hits: [String], terms: String) -> String? {
        let words = Set(terms.split(separator: " ").map { String($0).replacingOccurrences(of: "'s", with: "") }.filter { $0.count >= 3 })
        let ok = hits.filter { !$0.lowercased().contains("(disambiguation)") }
        return ok.first { h in
            let hw = Set(h.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return words.contains { w in hw.contains(w) || hw.contains(w + "s") || hw.contains(String(w.dropLast())) }
        } ?? (words.isEmpty ? ok.first : nil)
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                 "October", "November", "December"]

    /// One infobox value as plain text: links, bold/italics, references, comments and templates out; a date template
    /// as a date ("{{Death date and age|2025|4|21|1936|12|17}}" → "21 April 2025").
    static func plain(_ wiki: String) -> String {
        var s = wiki
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<ref[^>/]*/>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<ref[^>]*>[\s\S]*?</ref>"#, with: "", options: .regularExpression)
        // date templates
        if let re = try? NSRegularExpression(pattern: #"\{\{\s*(?:start|end|death|birth|film)[ _]date(?: and age)?\s*\|(?:\s*(?:df|mf)\s*=\s*\w+\s*\|)?\s*(\d{4})\s*\|\s*(\d{1,2})\s*\|\s*(\d{1,2})[^{}]*\}\}"#, options: .caseInsensitive) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let r = Range(m.range, in: s), let y = Range(m.range(at: 1), in: s), let mo = Range(m.range(at: 2), in: s),
                      let d = Range(m.range(at: 3), in: s), let mi = Int(s[mo]), (1...12).contains(mi), let di = Int(s[d]) else { continue }
                s.replaceSubrange(r, with: "\(di) \(months[mi - 1]) \(s[y])")
            }
        }
        for _ in 0..<3 {   // wrappers keep their content (nested once or twice)
            s = s.replacingOccurrences(of: #"\{\{\s*(?:nowrap|nobr|small|nobold|plainlist|ubl|unbulleted list|hlist|flatlist)\s*\|([^{}]*)\}\}"#,
                                       with: "$1", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"\{\{[^{}]*\}\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[(?:[^\]|]*\|)?([^\]|]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[https?://\S+\s([^\]]*)\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"'{2,}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: ", ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "|", with: ", ")
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;*"))
    }

    /// The infobox fields that name who holds something now or when it changed, as short facts.
    static func infoboxFacts(_ wikitext: String) -> [String] {
        var fields: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: #"^\s*\|\s*([a-z_]+\d?)\s*=\s*(.+)$"#, options: [.anchorsMatchLines, .caseInsensitive]) {
            for m in re.matches(in: wikitext, range: NSRange(wikitext.startIndex..., in: wikitext)) {
                guard let k = Range(m.range(at: 1), in: wikitext), let v = Range(m.range(at: 2), in: wikitext) else { continue }
                let key = wikitext[k].lowercased()
                if fields[key] == nil { fields[key] = plain(String(wikitext[v])) }
            }
        }
        var out: [String] = []
        func val(_ keys: [String]) -> String? { keys.lazy.compactMap { fields[$0] }.first { !$0.isEmpty } }
        if let who = val(["incumbent", "current_holder", "officeholder", "holder"]) {
            let since = val(["incumbentsince", "incumbent_since", "since", "holder_since"])
            out.append("Current holder: \(who)" + (since.map { " (since \($0))" } ?? ""))
        }
        for i in 1...4 {
            if let t = fields["leader_title\(i)"], let n = fields["leader_name\(i)"], !t.isEmpty, !n.isEmpty { out.append("\(t): \(n)") }
        }
        if let d = val(["death_date", "died"]) { out.append("Died: \(d)") }
        if let c = val(["current_champion", "current_champions", "most_recent_champion", "most_recent_champions", "champion", "champions", "winner"]) {
            out.append("Most recent champion: \(c)")
        }
        return out
    }

    /// The lead (the text before the first "== Heading ==") and every later sentence, for the passage.
    static func split(extract: String) -> (lead: String, rest: [String]) {
        let parts = extract.components(separatedBy: "\n==")
        let lead = parts.first ?? ""
        let rest = parts.dropFirst().joined(separator: "\n").components(separatedBy: "\n")
            .filter { !$0.hasPrefix("=") && !$0.hasSuffix("==") }
        return (lead, rest)
    }
    static func sentences(_ s: String) -> [String] {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z"“(])"#) else { return [flat] }
        var out: [String] = []; var start = flat.startIndex
        for m in re.matches(in: flat, range: NSRange(flat.startIndex..., in: flat)) {
            guard let r = Range(m.range, in: flat) else { continue }
            out.append(String(flat[start..<r.lowerBound])); start = r.upperBound
        }
        out.append(String(flat[start...]))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 2 }
    }

    /// A sentence that states the current state of things.
    static func statesCurrent(_ s: String) -> Bool {
        s.range(of: #"\b(incumbent|current(ly)?|since (\d{1,2} )?(january|february|march|april|may|june|july|august|september|october|november|december)? ?\d{4}|as of|took office|assumed office|was sworn in|most recent|latest|died|death|succeeded|won the|defeated)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The passage: the infobox facts, then the lead's sentences (the ones that state the current state first), then any
    /// later sentence that does and shares a word with the subject — capped.
    static func passageText(extract: String, wikitext: String, terms: String, cap: Int = passageCap) -> String {
        let facts = infoboxFacts(wikitext)
        let (lead, rest) = split(extract: extract)
        let ls = sentences(lead)
        let words = terms.split(separator: " ").map(String.init).filter { $0.count >= 4 }
        var picked: [String] = []
        let currentLead = ls.filter(statesCurrent), otherLead = ls.filter { !statesCurrent($0) }
        // the lead's opening sentence (what the subject is), the ones that state the current state, then the rest
        if let first = ls.first { picked.append(first) }
        picked += currentLead.filter { $0 != ls.first }
        let later = rest.flatMap(sentences).filter { s in statesCurrent(s) && words.contains { s.lowercased().contains($0) } }
        picked += later.prefix(3)
        picked += otherLead.filter { $0 != ls.first }
        var text = facts.isEmpty ? "" : facts.joined(separator: ". ") + ". "
        for s in picked {
            if text.count + s.count + 1 > cap { if text.count < cap / 2 { text += String(s.prefix(cap - text.count - 1)) + "…" }; break }
            text += s + " "
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func articleURL(_ title: String) -> String {
        let t = title.replacingOccurrences(of: " ", with: "_")
        return "https://en.wikipedia.org/wiki/" + (t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? t)
    }

    /// The packet line for a Wikipedia passage: when it was last edited, and that a recently edited reference page is
    /// current evidence (T's follow-up: the model dismissed Wikipedia "edited on October 17" as not dated news).
    static func editedLine(_ d: Date?, now: Date) -> String {
        guard let d else { return "Wikipedia article (last edit date unknown)." }
        let n = WebGrounding.daysOld(d, now: now)
        let ago = n < 1 ? "today" : n == 1 ? "yesterday" : "\(n) days before today"
        return "Wikipedia article, last edited \(WebGrounding.dayString(d)) (\(ago)). A reference page edited this recently is current evidence."
    }

    // MARK: - Network

    static var base: String {
        #if DEBUG
        if let b = UserDefaults.standard.string(forKey: "WikipediaBaseURL"), !b.isEmpty { return b }
        // the stub stack's search stand-in stands in for Wikipedia too (never the real site from a stub row)
        if let b = UserDefaults.standard.string(forKey: "WebSearchBaseURL"), !b.isEmpty { return b }
        #endif
        return "https://en.wikipedia.org"
    }
    static var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "AirPad/\(v) (iOS; https://github.com/Doctor-President/AirPad)"
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (at: Date, passage: Passage?)] = [:]

    /// The passage for a question (nil when nothing fits or Wikipedia doesn't answer in time). `query` is the app's
    /// search query when it has one (a follow-up's rewrite names the subject).
    static func passage(question: String, query: String?) async -> Passage? {
        guard isOn else { return nil }
        let terms = searchTerms(query ?? question)
        guard !terms.isEmpty else { return nil }
        if let hit = cached(terms) { return hit.passage }
        let p = await fetch(terms: terms)
        store(terms, p)
        return p
    }
    private static func cached(_ k: String) -> (at: Date, passage: Passage?)? {
        cacheLock.withLock { cache[k].flatMap { Date().timeIntervalSince($0.at) < 600 ? $0 : nil } }
    }
    private static func store(_ k: String, _ p: Passage?) {
        cacheLock.withLock { cache[k] = (Date(), p); if cache.count > 50 { cache.removeAll() } }
    }

    private static func get(_ params: [String: String]) async -> [String: Any]? {
        var c = URLComponents(string: base + "/w/api.php")
        c?.queryItems = (params.merging(["format": "json", "formatversion": "2"]) { a, _ in a }).sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(userAgent, forHTTPHeaderField: "Api-User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func fetch(terms: String) async -> Passage? {
        guard let s = await get(["action": "query", "list": "search", "srsearch": terms, "srlimit": "5", "srprop": ""]),
              let hits = ((s["query"] as? [String: Any])?["search"] as? [[String: Any]])?.compactMap({ $0["title"] as? String }),
              let title = pickTitle(hits, terms: terms) else { return nil }
        guard let r = await get(["action": "query", "prop": "extracts|revisions|pageprops", "titles": title, "redirects": "1",
                                 "explaintext": "1", "exsectionformat": "wiki", "rvprop": "timestamp|content", "rvslots": "main",
                                 "rvsection": "0", "ppprop": "disambiguation"]),
              let page = ((r["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              (page["pageprops"] as? [String: Any])?["disambiguation"] == nil,
              let extract = page["extract"] as? String, !extract.isEmpty else { return nil }
        let rev = (page["revisions"] as? [[String: Any]])?.first
        let wikitext = ((rev?["slots"] as? [String: Any])?["main"] as? [String: Any])?["content"] as? String ?? ""
        let edited = (rev?["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let realTitle = page["title"] as? String ?? title
        let text = passageText(extract: extract, wikitext: wikitext, terms: terms)
        guard text.count >= 80 else { return nil }
        return Passage(title: realTitle, url: articleURL(realTitle), lastEdited: edited, text: text)
    }
}
