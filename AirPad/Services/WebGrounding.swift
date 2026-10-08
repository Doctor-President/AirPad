import Foundation

/// CH Session 2 (T 2026-10-08) — deterministic grounding for GENERAL / web answers. Everything here is code, not
/// prompt: the model is never trusted to keep a rule on its own.
///
/// - Only a URL this turn's `web_search` / `fetch_url` returned (or the user typed) may appear in an answer; every
///   other URL is stripped, and a source list the model writes itself is removed — the app builds the source list
///   from the results the answer cited (`WebAnswerFilter`).
/// - Each result's age goes into the packet as a computed fact, and on a today/latest question fresh results are
///   ranked first in code (`packet`, `rank`).
/// - A factual question with a key is searched and its top result read before the model answers
///   (`isFactualQuestion`); an answer with no web result behind it carries `generalKnowledgeNote`.
enum WebGrounding {

    /// The app's line under a General answer that no web result backs (no key, no search, or nothing found).
    static let generalKnowledgeNote = "From the model's general knowledge, may contain errors."

    // MARK: - Question shape

    /// A today/latest question: rank fresh results first and state each result's age.
    static func isFreshnessQuestion(_ q: String) -> Bool {
        q.range(of: #"\b(today|tonight|this (morning|afternoon|evening|week)|yesterday|latest|newest|most recent|recent(ly)?|current(ly)?|right now|breaking|news|headlines?)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
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

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }

    static func publishedLine(_ d: Date?, now: Date, freshness: Bool = false) -> String {
        guard let d else {
            return freshness ? "Published: date unknown — this result carries no date (it may be a section or front page, not an article)."
                             : "Published: date unknown."
        }
        let n = daysOld(d, now: now)
        switch n {
        case ..<1: return "Published: today (\(dayString(d)))."
        case 1: return "Published: yesterday (\(dayString(d)))."
        default: return "Published: \(dayString(d)) — \(n) days before today."
        }
    }

    /// Fresh first: dated results newest → oldest, undated last; ties keep the provider's order.
    static func rank(_ links: [ToolLink]) -> [ToolLink] {
        links.enumerated().sorted { a, b in
            switch (a.element.published, b.element.published) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The tool message for one `web_search`: today's date, each result numbered GLOBALLY across the turn with its
    /// publication date as a computed fact, and — on a today/latest question — which results are actually fresh.
    static func packet(_ links: [ToolLink], start: Int, now: Date, freshness: Bool) -> String {
        var out = "Today is \(dayString(now)).\n\n"
        out += links.enumerated().map { i, l in
            "[\(start + i + 1)] \(l.title)\n\(l.url)\n\(publishedLine(l.published, now: now, freshness: freshness))\n\(l.snippet ?? "")"
        }.joined(separator: "\n\n")
        guard freshness else { return out }
        let fresh = links.enumerated().filter { $0.element.published.map { daysOld($0, now: now) <= 1 } ?? false }
            .map { "[\(start + $0.offset + 1)]" }
        if fresh.isEmpty {
            out += "\n\nCOMPUTED FACT: none of these results is from today or yesterday. Say that you found no news from today, and give the date of any story you mention. Never present an older story as today's news."
            // the model once called a 40-day-old result "the latest" with a 3-day-old one above it — say which is newest
            if let newest = links.enumerated().filter({ $0.element.published != nil }).max(by: { $0.element.published! < $1.element.published! }) {
                out += " The newest result is [\(start + newest.offset + 1)], published \(dayString(newest.element.published!))."
            }
        } else {
            out += "\n\nCOMPUTED FACT: only \(fresh.joined(separator: ", ")) \(fresh.count == 1 ? "is" : "are") from today or yesterday. Lead with \(fresh.count == 1 ? "it" : "those"), and give the date of any older story you mention."
        }
        return out
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
    static func run() -> String {
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
        let inlineSrc = "Two values are high:\n- Cholesterol 213 [1]\n  *Source: the lab report*\n- LDL 153 [1]"
        let r5c = filter("inline-source", inlineSrc)
        check("inline source line goes, the list stays", r5c == "Two values are high:\n- Cholesterol 213 [1]\n- LDL 153 [1]", r5c)
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
        let stale = ToolLink(title: "Mexico: Reuters world", url: "https://reuters.example/world/americas/mexico-june", snippet: "June story", published: june)
        let hub = ToolLink(title: "Mexico news | Reuters", url: "https://reuters.example/world/mexico/", snippet: "Latest headlines")
        let fresh = ToolLink(title: "Today in Mexico", url: "https://news.example/mexico-today", snippet: "Today", published: now)
        let ranked = WebGrounding.rank([stale, hub, fresh])
        check("fresh ranked first, undated last", ranked.map(\.url) == [fresh.url, stale.url, hub.url], "\(ranked.map(\.title))")
        let pk = WebGrounding.packet(ranked, start: 0, now: now, freshness: true)
        check("packet: today's date", pk.hasPrefix("Today is 8 October 2026."), pk)
        check("packet: stale age stated", pk.contains("Published: 24 June 2026 — 106 days before today."), pk)
        check("packet: undated flagged", pk.contains("date unknown"), pk)
        check("packet: only [1] fresh", pk.contains("only [1] is from today or yesterday"), pk)
        let pk2 = WebGrounding.packet([stale, hub], start: 3, now: now, freshness: true)
        check("packet: none fresh, global numbering", pk2.contains("[4] Mexico: Reuters world") && pk2.contains("none of these results is from today"), pk2)
        check("packet: names the newest result", pk2.contains("The newest result is [4], published 24 June 2026."), pk2)

        // 9. question shape
        for (q, want) in [("What family does the oarfish belong to?", true), ("Who wrote Pride and Prejudice?", true),
                          ("When was Antarctica first sighted?", true), ("Explain in two sentences why the sky is blue.", true),
                          ("What is 17 × 23?", false), ("What did I write about Mara?", false), ("Write a haiku about rain", false),
                          ("Should I learn Swift or Kotlin?", false), ("hello", false), ("Is the colossal squid bigger than the giant squid?", true)] {
            check("factual: \(q)", WebGrounding.isFactualQuestion(q) == want)
        }
        check("freshness: today's news", WebGrounding.isFreshnessQuestion("What's the top news in Mexico today?"))
        check("freshness: not a fact question", !WebGrounding.isFreshnessQuestion("What family does the oarfish belong to?"))

        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(ran - fails.count)/\(ran)\n  " + fails.joined(separator: "\n  ")
    }
}
#endif
