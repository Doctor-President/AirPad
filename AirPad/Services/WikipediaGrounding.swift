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
/// live-33 — the articles are SOURCES for the rerank (`WebEvidence`), not a passage the app picks with word rules: one
/// request for the top three articles' leads (plus each infobox's holder / date fields and its last-edit date) for the
/// app's query; the passages that answer it by meaning go to the model, dated by the article's last edit. Wikidata was
/// measured in live-32 and left out (the same fact as the infobox; the current holder's claim carries its term's END date).
///
/// Etiquette (Wikimedia's API policy): the User-Agent names the app and its project page; one request per
/// turn; answers cached for ten minutes. Only the query goes to Wikimedia, exactly as it goes to the search provider.
enum WikipediaGrounding {

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

    // MARK: - Pure parts

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

    static func articleURL(_ title: String) -> String {
        let t = title.replacingOccurrences(of: " ", with: "_")
        return "https://en.wikipedia.org/wiki/" + (t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? t)
    }

    /// The packet line for a Wikipedia source: when it was last edited.
    static func editedLine(_ d: Date?, now: Date) -> String {
        guard let d else { return "Wikipedia article (last edit date unknown)." }
        return "Wikipedia article, last edited \(WebGrounding.dayString(d))."
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
    nonisolated(unsafe) private static var cache: [String: (at: Date, sources: [WebEvidence.Source])] = [:]

    /// live-33 — the articles for the app's query (the same query the search provider gets, without the freshness year):
    /// ONE request (`generator=search`, the top three articles' leads, their infoboxes' wikitext and last-edit dates). Each
    /// becomes a source for the rerank: its infobox facts, then its lead. No word rules pick the article — the rerank keeps
    /// whatever passages answer (the literal "last 10 US presidents" finds "The Last of Us" first; its passages don't).
    static func sources(query: String) async -> [WebEvidence.Source] {
        guard isOn else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let hit = cached(q) { return hit }
        let s = await fetch(query: q)
        store(q, s)
        return s
    }
    private static func cached(_ k: String) -> [WebEvidence.Source]? {
        cacheLock.withLock { cache[k].flatMap { Date().timeIntervalSince($0.at) < 600 ? $0.sources : nil } }
    }
    private static func store(_ k: String, _ s: [WebEvidence.Source]) {
        cacheLock.withLock { cache[k] = (Date(), s); if cache.count > 50 { cache.removeAll() } }
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

    static let articles = 3

    private static func fetch(query: String) async -> [WebEvidence.Source] {
        guard let r = await get(["action": "query", "generator": "search", "gsrsearch": query, "gsrlimit": "\(articles)",
                                 "prop": "extracts|revisions|pageprops", "exintro": "1", "explaintext": "1", "exlimit": "\(articles)",
                                 "rvprop": "timestamp|content", "rvslots": "main", "rvsection": "0", "ppprop": "disambiguation",
                                 "redirects": "1"]),
              let pages = (r["query"] as? [String: Any])?["pages"] as? [[String: Any]] else { return [] }
        return pages.sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }.compactMap { page in
            guard (page["pageprops"] as? [String: Any])?["disambiguation"] == nil,
                  let title = page["title"] as? String, let extract = page["extract"] as? String, !extract.isEmpty else { return nil }
            let rev = (page["revisions"] as? [[String: Any]])?.first
            let wikitext = ((rev?["slots"] as? [String: Any])?["main"] as? [String: Any])?["content"] as? String ?? ""
            let edited = (rev?["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let facts = infoboxFacts(wikitext)
            let text = (facts.isEmpty ? "" : facts.joined(separator: ". ") + ".\n") + extract
            return WebEvidence.Source(title: title, url: articleURL(title), published: edited, wikipedia: true, text: text)
        }
    }
}
