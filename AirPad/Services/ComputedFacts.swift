import Foundation

/// Brief CI (CI-2) — the Librarian's COMPUTED FACTS layer: "code computes, the model explains"
/// (`architecture/pre-compute-principle.md`, answer-time extension). Pure, deterministic, local — no FM,
/// no network. Everything here is a function of (packet entries, their dates, the scope size, today, the
/// question); the same inputs give byte-identical output (`deterministic-structure.md`). A fact the code
/// can't parse with confidence is OMITTED, never guessed. Design: `Ops/reports/ci-facts-layer/design.md`.
///
/// Every intent check below is a deterministic PHRASE matcher with word boundaries (T's standing "no
/// question classifier" ruling — same posture as `looksLikeOwnershipQuestion`).
enum ComputedFacts {

    // MARK: - Ranges / flags (design §2)

    /// The entry's own flag on a result row.
    enum Flag: Equatable {
        case high, low, normal, abnormal, critical
    }

    enum Status: Equatable { case below, within, above, atLower, atUpper }

    struct RangeRow: Equatable {
        let name: String          // verbatim (name-only lines above the value are joined with a space)
        let value: String         // verbatim
        let rangeText: String     // verbatim
        let unit: String          // verbatim, may be ""
        let flagToken: String?    // verbatim flag token as the entry wrote it
        let flag: Flag?
        let lower: Decimal?
        let upper: Decimal?
        let offset: Int           // line index — the total order for output

        /// Computed against the stated range (inclusive bounds; equality = AT the limit).
        var status: Status? {
            guard let v = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            if let lo = lower, v < lo { return .below }
            if let up = upper, v > up { return .above }
            if let lo = lower, v == lo { return .atLower }
            if let up = upper, v == up { return .atUpper }
            return .within
        }
        /// The entry's flag and the computed status disagree (e.g. computed within, flag H) → the line
        /// quotes the flag and states NO computed status (the entry wins; the app says nothing of its own).
        var disagrees: Bool {
            guard let f = flag, let s = status else { return false }
            switch f {
            case .high:     return s != .above
            case .low:      return s != .below
            case .normal:   return s == .above || s == .below
            case .abnormal: return false
            case .critical: return s != .above && s != .below
            }
        }
        /// Out of range by the app's own check — never for a row whose flag disagrees, or an "abnormal" (A)
        /// flag, where no direction is computed.
        var isOutOfRange: Bool {
            if disagrees || flag == .abnormal { return false }
            return status == .above || status == .below
        }
        /// The entry flags it, but the app does not classify it (disagreement / abnormal / critical within).
        var isFlaggedOnly: Bool {
            disagrees || flag == .abnormal || (flag == .critical && !isOutOfRange)
        }
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let num = #"\d+(?:\.\d+)?"#
    /// value, whitespace, range — on ONE line. The value is not part of a longer number/date/ID (no
    /// digit, '.', ',', '/', ':' or '-' immediately before it; none of those glued after the range).
    private static let rowRegex: NSRegularExpression = {
        let range = #"(?:\d+(?:\.\d+)?\s*(?:-|–|—|\bto\b)\s*\d+(?:\.\d+)?|(?:<=|>=|≤|≥|<|>)\s*\d+(?:\.\d+)?)"#
        let p = #"(?<![\d.,/:\-~\w])("# + num + #")\s+("# + range + #")(?![\d.,/:])"#
        return try! NSRegularExpression(pattern: p)
    }()

    private static func isFlagToken(_ t: String) -> Flag? {
        switch t {
        case "H", "↑": return .high
        case "L", "↓": return .low
        case "N": return .normal
        case "A": return .abnormal          // accepted only when the same table uses H/L (see `rangeRows`)
        default: break
        }
        switch t.lowercased() {
        case "high": return .high
        case "low": return .low
        case "normal": return .normal
        case "critical", "crit": return .critical
        default: return nil
        }
    }

    private static func isUnitToken(_ t: String) -> Bool {
        guard !t.isEmpty, t.count <= 16, isFlagToken(t) == nil else { return false }
        guard t.rangeOfCharacter(from: .letters) != nil || t.contains("%") || t.contains("µ") else { return false }
        // a unit is not a word of prose: letters + / % * . ^ ² digits only, no trailing ':'
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "/%*.^²³µ·-"))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) } && !t.hasSuffix(":")
    }

    /// A measurement unit (not a word that happens to follow a range): has "/", "%", "^" or a digit, or is a known unit.
    private static let knownUnits: Set<String> = ["mg", "g", "kg", "mcg", "µg", "ug", "ng", "pg", "l", "dl", "ml", "fl", "mmol", "umol",
        "µmol", "nmol", "pmol", "meq", "u", "iu", "mu", "miu", "mm", "cm", "mmhg", "bpm", "sec", "s", "ms", "kpa", "cells", "kcal"]
    private static func isMeasureUnit(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("/") || l.contains("%") || l.contains("^") || l.rangeOfCharacter(from: .decimalDigits) != nil || knownUnits.contains(l)
    }

    /// A line that is only a (part of a) result NAME — no digits (bar a chemistry token like "CO2"), no ':'.
    private static func isNameOnlyLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 60, !t.contains(":") else { return false }
        guard t.rangeOfCharacter(from: .letters) != nil else { return false }
        let words = t.split(separator: " ")
        guard words.count <= 6 else { return false }
        for w in words where w.rangeOfCharacter(from: .decimalDigits) != nil {
            if !(w.count <= 5 && w.uppercased() == w && w.rangeOfCharacter(from: .letters) != nil) { return false }
        }
        // a name line is mostly upper-case (lab tables) or Title Case — never a lowercase prose fragment
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        return Double(upper.count) / Double(max(1, letters.count)) >= 0.5
    }

    private static let monthsAndDays: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// Every confidently-parsed result row in `text`, in source order (design §2.2 confidence rules 1–5).
    static func rangeRows(in text: String) -> [RangeRow] {
        let lines = text.components(separatedBy: "\n")
        var rows: [RangeRow] = []
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.replacingOccurrences(of: "\t", with: " ")
            let ns = line as NSString
            for m in rowRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: m.range(at: 1))
                let rangeText = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                // ── bounds (rule 5: bounded a < b)
                var lower: Decimal? = nil, upper: Decimal? = nil
                let compact = rangeText.replacingOccurrences(of: " ", with: "")
                if let first = compact.first, "<>≤≥".contains(first) {
                    let digits = compact.drop { "<>=≤≥".contains($0) }
                    guard let x = Decimal(string: String(digits), locale: posix) else { continue }
                    if first == "<" || first == "≤" { upper = x } else { lower = x }
                } else {
                    let parts = rangeText.components(separatedBy: CharacterSet(charactersIn: "-–—"))
                        .flatMap { $0.components(separatedBy: " to ") }
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard parts.count == 2, let a = Decimal(string: parts[0], locale: posix),
                          let b = Decimal(string: parts[1], locale: posix), a < b else { continue }
                    lower = a; upper = b
                }
                // ── rule 4: not a date/year-month/time
                if let v = Decimal(string: value, locale: posix), v >= 1900, v <= 2100, !value.contains("."),
                   let lo = lower, let up = upper, lo <= 31, up <= 31 { continue }
                // ── name: text before the value on this line, else ≤2 name-only lines above
                var name = ns.substring(to: m.range(at: 1).location).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—•*# "))
                if name.rangeOfCharacter(from: .letters) == nil {
                    var parts: [String] = []
                    var j = i - 1
                    while j >= 0, j >= i - 2, isNameOnlyLine(lines[j]) {
                        parts.insert(lines[j].trimmingCharacters(in: .whitespaces), at: 0); j -= 1
                    }
                    name = parts.joined(separator: " ")
                }
                let nameWords = name.split(separator: " ")
                let letterCount = name.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                guard letterCount >= 2, nameWords.count <= 8 else { continue }
                if let w = nameWords.last, monthsAndDays.contains(w.lowercased()) { continue }
                // ── trailing unit/flag tokens: the rest of this line, or (when the line ends at the range)
                // up to 2 following lines that are ONLY unit/flag tokens (the lab PDF wraps them).
                var trailing = ns.substring(from: m.range.location + m.range.length)
                    .split(separator: " ").map(String.init)
                if trailing.isEmpty {
                    var k = i + 1
                    while k < lines.count, k <= i + 2 {
                        let toks = lines[k].split(separator: " ").map(String.init)
                        guard !toks.isEmpty, toks.count <= 2,
                              toks.allSatisfy({ isUnitToken($0) || isFlagToken($0) != nil }) else { break }
                        trailing += toks; k += 1
                    }
                }
                var unitToks: [String] = [], flagTok: String? = nil
                for t in trailing.prefix(3) {
                    if flagTok == nil, isFlagToken(t) != nil { flagTok = t; break }
                    if isUnitToken(t), unitToks.count < 2 { unitToks.append(t) } else { break }
                }
                rows.append(RangeRow(name: name, value: value, rangeText: rangeText, unit: unitToks.joined(separator: " "),
                                     flagToken: flagTok, flag: flagTok.flatMap(isFlagToken), lower: lower, upper: upper, offset: i))
            }
        }
        // ── rule 3: a TABLE, not prose — ≥ 2 rows, or every row carries a flag.
        guard rows.count >= 2 || (rows.count == 1 && rows[0].flag != nil) else { return [] }
        // ── rule 6 (Session 3 audit fix, T 2026-10-09): a MEASUREMENT table — at least one row carries a flag or a
        // measurement unit ("mg/dL", "%", "U/L"). "Week 1 2-3 runs / Week 2 3-4 runs" is a plan, not a lab panel.
        guard rows.contains(where: { $0.flagToken != nil || $0.unit.split(separator: " ").contains(where: { isMeasureUnit(String($0)) }) }) else { return [] }
        // "A" means abnormal only when the same table uses H/L flags; otherwise it is not a flag at all.
        let usesHL = rows.contains { [.high, .low].contains($0.flag) && ["H", "L"].contains($0.flagToken ?? "") }
        if !usesHL {
            rows = rows.map { r in
                guard r.flagToken == "A" else { return r }
                return RangeRow(name: r.name, value: r.value, rangeText: r.rangeText, unit: r.unit, flagToken: nil, flag: nil,
                                lower: r.lower, upper: r.upper, offset: r.offset)
            }
        }
        return rows
    }

    /// The bound exactly as the entry wrote it ("5.0", not Decimal's "5").
    static func boundText(_ r: RangeRow, upper: Bool) -> String {
        let t = r.rangeText.replacingOccurrences(of: " ", with: "")
        if let f = t.first, "<>≤≥".contains(f) { return String(t.drop { "<>=≤≥".contains($0) }) }
        let parts = r.rangeText.components(separatedBy: CharacterSet(charactersIn: "-–—")).flatMap { $0.components(separatedBy: " to ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count == 2 ? (upper ? parts[1] : parts[0]) : r.value
    }

    /// One `- NAME value unit: reference R — STATUS (the entry flags it F).` line.
    static func rangeLine(_ r: RangeRow) -> String {
        let head = "- \(r.name) \(r.value)\(r.unit.isEmpty ? "" : " " + r.unit): reference \(r.rangeText)"
        let flagNote = r.flagToken.map { "the entry flags it \($0)" }
        if r.disagrees || r.flag == .abnormal || (r.flag == .critical && r.status != .above && r.status != .below) {
            let word = r.flag == .abnormal ? "the entry flags it abnormal" : (flagNote ?? "")
            return "\(head) — \(word)."
        }
        let st: String
        switch r.status {
        case .above?: st = "ABOVE the range"
        case .below?: st = "BELOW the range"
        case .atUpper?: st = "within the range, equal to its upper limit (\(boundText(r, upper: true)))"
        case .atLower?: st = "within the range, equal to its lower limit (\(boundText(r, upper: false)))"
        case .within?: st = "within the range"
        case nil: return "\(head)."
        }
        let showFlag = r.flag != nil && r.flag != .normal
        return "\(head) — \(st)\(showFlag ? " (\(flagNote!))" : "")."
    }

    // MARK: - Typed fields (design §4)

    /// `Fields: Serves: 4–6 · Cook time: 50 min · Rating: 4/5` — filled values only, in item order, rendered by
    /// `FieldValueFormatter` (what the user sees on the card); a missing definition → omitted, never raw.
    static func fieldsLine(items: [NodeItem], definition: (String) -> FieldDefinition?,
                           resolveNodeTitle: @escaping (String) -> String?) -> String? {
        var parts: [String] = []
        for item in items {
            if item.type == .field, let fv = item.field, let def = definition(fv.definitionID),
               let shown = FieldValueFormatter.display(fv, definition: def, resolveNodeTitle: resolveNodeTitle) {
                parts.append("\(def.displayName): \(shown)")
            } else if item.type == .rating, let r = item.rating {
                parts.append("Rating: \(r.value)/\(r.scale)")
            }
        }
        return parts.isEmpty ? nil : "Fields: " + parts.joined(separator: " · ")
    }

    // MARK: - Dates (design §3)

    static func calendar(_ tz: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; c.locale = posix; return c
    }

    /// Whole calendar days from the entry's day to today's day (start-of-day both sides); nil when the
    /// entry is dated after today (clock skew) — no age line then.
    static func ageDays(created: Date, today: Date, calendar cal: Calendar) -> Int? {
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: created), to: cal.startOfDay(for: today)).day ?? 0
        return d < 0 ? nil : d
    }

    static func ageWords(created: Date, today: Date, calendar cal: Calendar) -> String? {
        guard let d = ageDays(created: created, today: today, calendar: cal) else { return nil }
        switch d {
        case 0: return "today"
        case 1: return "yesterday"
        case 2...13: return "\(d) days ago"
        case 14...59: return "\(d / 7) weeks ago"
        case 60...364:
            let m = max(1, cal.dateComponents([.month], from: cal.startOfDay(for: created), to: cal.startOfDay(for: today)).month ?? 0)
            return m == 1 ? "1 month ago" : "\(m) months ago"
        default:
            let c = cal.dateComponents([.year, .month], from: cal.startOfDay(for: created), to: cal.startOfDay(for: today))
            let y = c.year ?? 1, m = c.month ?? 0
            let ys = y == 1 ? "1 year" : "\(y) years"
            return m >= 1 ? "\(ys) and \(m == 1 ? "1 month" : "\(m) months") ago" : "\(ys) ago"
        }
    }

    static func dayString(_ d: Date, calendar cal: Calendar) -> String {
        let f = DateFormatter(); f.locale = posix; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func todayLine(_ today: Date, calendar cal: Calendar) -> String {
        let f = DateFormatter(); f.locale = posix; f.timeZone = cal.timeZone; f.dateFormat = "EEEE, d MMMM yyyy"
        return "Today is \(f.string(from: today))."
    }

    /// A calendar window named by the question ("last month" → the previous calendar month), or nil.
    struct Window: Equatable { let phrase: String; let label: String; let start: Date; let end: Date }

    static func relativeWindow(question q: String, today: Date, calendar cal: Calendar) -> Window? {
        let s = q.lowercased()
        let day0 = cal.startOfDay(for: today)
        func has(_ p: String) -> Bool { s.range(of: p, options: .regularExpression) != nil }
        let mf = DateFormatter(); mf.locale = posix; mf.timeZone = cal.timeZone; mf.dateFormat = "MMMM yyyy"
        func month(offset: Int, phrase: String) -> Window? {
            guard let anyDay = cal.date(byAdding: .month, value: offset, to: day0),
                  let iv = cal.dateInterval(of: .month, for: anyDay) else { return nil }
            let end = cal.date(byAdding: .day, value: -1, to: iv.end)!
            return Window(phrase: phrase, label: mf.string(from: iv.start), start: iv.start, end: end)
        }
        func week(offset: Int, phrase: String) -> Window? {
            var iso = Calendar(identifier: .iso8601); iso.timeZone = cal.timeZone
            guard let anyDay = cal.date(byAdding: .day, value: 7 * offset, to: day0),
                  let iv = iso.dateInterval(of: .weekOfYear, for: anyDay) else { return nil }
            let end = cal.date(byAdding: .day, value: -1, to: iv.end)!
            return Window(phrase: phrase, label: "the week of \(dayString(iv.start, calendar: cal))", start: iv.start, end: end)
        }
        func year(offset: Int, phrase: String) -> Window? {
            guard let anyDay = cal.date(byAdding: .year, value: offset, to: day0),
                  let iv = cal.dateInterval(of: .year, for: anyDay) else { return nil }
            let end = cal.date(byAdding: .day, value: -1, to: iv.end)!
            let yf = DateFormatter(); yf.locale = posix; yf.timeZone = cal.timeZone; yf.dateFormat = "yyyy"
            return Window(phrase: phrase, label: yf.string(from: iv.start), start: iv.start, end: end)
        }
        if has(#"\blast month\b"#) { return month(offset: -1, phrase: "last month") }
        if has(#"\bthis month\b"#) { return month(offset: 0, phrase: "this month") }
        if has(#"\blast week\b"#) { return week(offset: -1, phrase: "last week") }
        if has(#"\bthis week\b"#) { return week(offset: 0, phrase: "this week") }
        if has(#"\blast year\b"#) { return year(offset: -1, phrase: "last year") }
        if has(#"\bthis year\b"#) { return year(offset: 0, phrase: "this year") }
        if has(#"\byesterday\b"#), let y = cal.date(byAdding: .day, value: -1, to: day0) {
            return Window(phrase: "yesterday", label: dayString(y, calendar: cal), start: y, end: y)
        }
        if let r = s.range(of: #"\b(?:past|last)\s+(\d{1,3})\s+(day|week|month)s?\b"#, options: .regularExpression) {
            let frag = String(s[r])
            let n = Int(frag.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
            let unit: Calendar.Component = frag.contains("week") ? .weekOfYear : (frag.contains("month") ? .month : .day)
            guard n > 0, let back = cal.date(byAdding: unit, value: -n, to: day0),
                  let start = cal.date(byAdding: .day, value: 1, to: back) else { return nil }
            return Window(phrase: frag, label: "\(dayString(start, calendar: cal)) to \(dayString(day0, calendar: cal))", start: start, end: day0)
        }
        return nil
    }

    // MARK: - Phrase matchers (word boundaries throughout)

    private static func matches(_ q: String, _ pattern: String) -> Bool {
        q.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A RANGE question (design §2.6, narrowed by Companion): explicit range phrasing, OR a bare
    /// high/low/elevated/abnormal/flagged only together with a measurement word. "What were the high points
    /// of my year?" / "Why have I felt low lately?" are NOT range questions.
    static func looksLikeRangeQuestion(_ q: String) -> Bool {
        if matches(q, #"\bout of (?:the )?(?:normal |reference )?range\b|\bin (?:the )?(?:normal |reference )?range\b|\bnormal range\b|\breference range\b|\bwithin (?:the )?(?:normal|reference)\b"#) {
            return true
        }
        let bare = matches(q, #"\b(?:high|higher|low|lower|elevated|abnormal|flagged)\b"#)
        let measure = matches(q, #"\b(?:values?|levels?|results?|tests?|readings?|numbers?)\b"#)
        return bare && measure
    }

    /// A TEMPORAL question (CI ruling 2) — per-entry date lines are emitted only for these (and whole-library
    /// questions). Word boundaries throughout.
    static func looksLikeTemporalQuestion(_ q: String) -> Bool {
        let p = [
            #"\bevolv(?:e|ed|es|ing)\b"#, #"\bchang(?:e|ed|es|ing)\b"#, #"\bover time\b"#, #"\blately\b"#, #"\brecently\b"#,
            #"\bsince\b"#, #"\bbefore\b"#, #"\bafter\b"#, #"\bwhen\b"#, #"\bago\b"#, #"\bhow long\b"#,
            #"\b(?:today|yesterday)\b"#, #"\b(?:this|last|past) (?:week|month|year)\b"#, #"\b(?:past|last) \d{1,3} (?:days?|weeks?|months?)\b"#,
            #"\b(?:recent|date|dated)\b"#,
        ]
        return p.contains { matches(q, $0) }
    }

    /// The QUESTION SENTENCE(S) of a turn (T 2026-10-07, ruling 6): the sentences that end in "?", or — when none
    /// does ("Tell me how many entries mention Mara") — the last sentence. A conversational reply carries context
    /// before its question ("…but I almost never go back and reread them. What does that say about me?"); only the
    /// question decides whether the turn is a whole-library question.
    static func questionSentence(_ q: String) -> String {
        let parts = q.replacingOccurrences(of: #"(?<=[.!?])\s+|\n+"#, with: "\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let asked = parts.filter { $0.hasSuffix("?") }
        return asked.isEmpty ? (parts.last ?? "") : asked.joined(separator: " ")
    }

    /// The whole-library FORMS a question takes — ONE derivation, read by the matcher, the computed answers and the
    /// key terms, so they can't disagree (T 2026-10-07, ruling 6: question sentence only, existence forms; the same
    /// for latest/count). A rank word must rank ENTRIES ("my oldest entry", "the last time I…", "when did I last…"),
    /// not modify a topic ("the earliest stages of AirPad"); "count" must count entries ("how many times", "how many
    /// of my entries"), never "does my diet count as…"; presence must be an existence form ("did I ever", "have I
    /// never", "I've never written"), never a bare "never" in a reply.
    enum WholeLibraryForm: Hashable { case count, oldest, newest, longest, shortest, frequency, presence }

    private static let entryNoun = #"(?:entr(?:y|ies)|notes?|things?|items?|ones?|pieces?|documents?|articles?|journal entries)"#
    /// Session 3 audit fix — a RANK word must rank the user's ENTRIES: "my oldest entry", "the first thing I wrote".
    /// "the last few items on my packing list" / "the biggest thing I learned" are topics, not ranks.
    private static let rankNoun = #"(?:entr(?:y|ies)|notes?|documents?|articles?|journal entries|(?:things?|items?|ones?|pieces?)(?: that)? i (?:wrote|'ve written|have written|noted|saved|added|made))"#
    private static let writeVerb = #"\b(?:mention(?:s|ed)?|write|writes|wrote|written|note|noted|say|said|talk(?:ed)?|record(?:ed)?|bring up|brought up)\b"#

    static func wholeLibraryForms(_ q: String) -> Set<WholeLibraryForm> {
        let s = questionSentence(q).replacingOccurrences(of: "\u{2019}", with: "'")
        let rank = { (words: String) in #"\b(?:"# + words + #")\s+(?:\w+\s+){0,2}?"# + rankNoun + #"\b"# }
        var out = Set<WholeLibraryForm>()
        // "how many times" counts mentions only when the question is about writing ("how many times did I mention
        // Paris"), never "how many times a day should I take my meds".
        if matches(s, #"\bhow many\s+(?:\w+\s+){0,3}?"# + entryNoun + #"\b|\bnumber of "# + entryNoun + #"\b|\bcount (?:up |the |my |of )*"# + entryNoun + #"\b"#)
            || (matches(s, #"\bhow many times\b|\bnumber of times\b"#) && matches(s, writeVerb)) {
            out.insert(.count)
        }
        // "When did I last SPEAK to Mom?" asks when something HAPPENED, not which entry is newest — the entry date
        // answered it wrong (SL-D3: "written 2026-05-30" read as the last call; the truth is a typed field). Only
        // questions about WRITING ("when did I last write about Mara?") rank entries by date.
        if matches(s, rank("oldest|earliest|first") + #"|\bfirst time i (?:wrote|mentioned|noted|wrote about)\b|\bwhen did i first (?:write|mention|note|bring up)\b"#) { out.insert(.oldest) }
        if matches(s, rank("newest|latest|most recent|last") + #"|\blast time i (?:wrote|mentioned|noted)\b|\bwhen did i (?:last|most recently) (?:write|mention|note|bring up)\b"#) { out.insert(.newest) }
        if matches(s, rank("longest")) { out.insert(.longest) }
        if matches(s, rank("shortest")) { out.insert(.shortest) }
        if matches(s, #"\b(?:most|least)\s+(?:often|frequent(?:ly)?|common|mentioned|written)\b"#) { out.insert(.frequency) }
        // presence = an EXISTENCE question about writing: "did I ever write about…", "have I mentioned…", "have I
        // written anything about…" — never "why do I never finish projects?".
        if matches(s, #"\b(?:did|have|had|do)\s+i\s+(?:\w+\s+)?(?:ever|never)\s+(?:\w+\s+)?"# + writeVerb
                    + #"|^\s*(?:have|had|did)\s+i\s+(?:ever\s+|already\s+)?(?:written|write|wrote|mentioned|mention|noted|note)\s+(?:about|anything|on|down)\b"#
                    + #"|\bi(?:'ve| have)?\s+never\s+(?:written|wrote|mentioned|noted|said|recorded|saved)\b"#
                    + #"|\bever\s+(?:been\s+)?(?:written|mentioned|noted|recorded)\b"#
                    + #"|\bany (?:entries|notes)\b|\bdid i (?:write|mention|say|note) anything\b|\bwhat exactly did i (?:say|write)\b"#) {
            out.insert(.presence)
        }
        return out
    }

    /// A WHOLE-LIBRARY question (count / rank / oldest-newest / absence / exact quote) → the scope line
    /// gains its limit sentence (design §5). See `wholeLibraryForms`.
    static func looksLikeWholeLibraryQuestion(_ q: String) -> Bool {
        !wholeLibraryForms(q).isEmpty
    }

    // MARK: - Packet-level computed answers (CI-2 ruling 1)

    private static let termStop: Set<String> = Set("""
    a an the of in on at for to from by with about into over and
    or but not no nor so as is are was were be been being am do
    does did done doing have has had having i me my mine myself you your yours
    we our it its this that these those there what whats what's which who whom whose
    when where why how many much number count ever never any some all each every write
    wrote written writing say said saying mention mentions mentioned mentioning note notes entry entries library exactly
    really actually oldest newest latest earliest most least recent first last time longest shortest biggest smallest
    often frequent frequently common anything something thing things one ones tell show find give know think
    today yesterday tomorrow day days week weeks month months year years lately recently ago past this
    next new old bought got made idea ideas take the times item items piece pieces
    should would could might must can will describe decide decided meet met visit visited few talk talked
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// The question's KEY TERMS — deterministic: drop stopwords and intent words; a run of Capitalised words is ONE
    /// phrase ("Richard Dawkins"); possessives stripped ("Bolex's" → "Bolex"); ≤ 3 terms, in question order.
    static func keyTerms(_ q: String) -> [String] {
        let words = q.replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
            .map { w -> String in var w = w; if w.hasSuffix("'s") { w.removeLast(2) }; return w.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
        var terms: [String] = [], run: [String] = []
        func flush() { if !run.isEmpty { terms.append(run.joined(separator: " ")); run = [] } }
        for (i, w) in words.enumerated() {
            let lw = w.lowercased()
            if termStop.contains(lw) || lw.count < 3 { flush(); continue }
            let cap = w.first?.isUppercase == true && i > 0
            if cap { run.append(w) } else { flush(); terms.append(w) }
        }
        flush()
        var seen = Set<String>(), out: [String] = []
        for t in terms where !seen.contains(t.lowercased()) { seen.insert(t.lowercased()); out.append(t) }
        return Array(out.prefix(3))
    }

    /// Does `text` mention `term`? Word-boundary, case-insensitive, plural/possessive tolerant; a phrase needs all
    /// its words.
    static func mentions(_ text: String, _ term: String) -> Bool {
        let stems = Set(text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }.map(stem))
        return term.split(whereSeparator: { $0 == " " || $0 == "-" }).allSatisfy { stems.contains(stem(String($0).lowercased())) }
    }

    /// Session 3 audit fix — a light English stemmer so a key term matches its inflections ("speak" ↔ "spoke",
    /// "meet" ↔ "met", "visits" ↔ "visited"). Deterministic; irregular verbs by table, then suffix rules.
    private static let irregular: [String: String] = [
        "spoke": "speak", "spoken": "speak", "met": "meet", "wrote": "write", "written": "write", "bought": "buy",
        "went": "go", "gone": "go", "took": "take", "taken": "take", "thought": "think", "saw": "see", "seen": "see",
        "ate": "eat", "eaten": "eat", "drank": "drink", "drunk": "drink", "ran": "run", "gave": "give", "given": "give",
        "found": "find", "made": "make", "told": "tell", "said": "say", "came": "come", "got": "get", "gotten": "get",
        "knew": "know", "known": "know", "felt": "feel", "left": "leave", "began": "begin", "begun": "begin",
        "taught": "teach", "caught": "catch", "brought": "bring", "sold": "sell", "kept": "keep", "slept": "sleep",
        "flew": "fly", "flown": "fly", "swam": "swim", "sang": "sing", "sung": "sing", "drove": "drive", "driven": "drive",
        "rode": "ride", "fell": "fall", "fallen": "fall", "won": "win", "lost": "lose", "paid": "pay", "heard": "hear",
        "built": "build", "sent": "send", "spent": "spend", "stood": "stand", "understood": "understand", "met's": "meet",
        "children": "child", "people": "person", "men": "man", "women": "woman", "mice": "mouse", "feet": "foot"]
    static func stem(_ raw: String) -> String {
        var w = raw.lowercased()
        if w.hasSuffix("'s") { w.removeLast(2) }
        w = w.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if let base = irregular[w] { w = base }
        func drop(_ n: Int) { w.removeLast(n) }
        if w.count > 4, w.hasSuffix("ies") { drop(3); w += "y" }
        else if w.count > 5, w.hasSuffix("ing") { drop(3) }
        else if w.count > 4, w.hasSuffix("ed") { drop(2) }
        else if w.count > 4, w.hasSuffix("es"), ["s", "x", "z", "ch", "sh"].contains(where: { w.dropLast(2).hasSuffix($0) }) { drop(2) }
        else if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { drop(1) }
        // doubled final consonant after a suffix ("planned" → "plann" → "plan"); a final silent e ("write" ↔ "writ")
        if w.count > 3, let l = w.last, w.dropLast().last == l, !"aeiouslz".contains(l) { drop(1) }
        if w.count > 3, w.hasSuffix("e") { drop(1) }
        return w
    }

    private static func quoted(_ terms: [String]) -> String {
        let q = terms.map { "\u{201C}\($0)\u{201D}" }
        return q.count <= 1 ? (q.first ?? "") : q.dropLast().joined(separator: ", ") + " and " + q.last!
    }

    /// "the 3 entries" / "the one entry" — CI ruling 1 (no "1 entries").
    private static func seen(_ n: Int) -> String { n == 1 ? "the one entry I can see" : "the \(n) entries I can see" }

    private static func list(_ es: [PacketEntry]) -> String { es.map { "[\($0.number)]" }.joined(separator: ", ") }

    /// Answers the code can give FROM THE PACKET for a whole-library question, phrased so the model can copy them
    /// rather than infer: "Among the 9 entries shown, 1 mentions “Mara”: [1]." Scoped to "the entries shown" — the
    /// library-wide answer is 1.1 (hybrid search). Empty for any other question.
    static func packetAnswers(question q: String, entries: [PacketEntry], calendar cal: Calendar) -> [String] {
        let forms = wholeLibraryForms(q)
        guard !forms.isEmpty else { return [] }
        let terms = keyTerms(questionSentence(q))
        let n = entries.count
        let matched = terms.isEmpty ? entries : entries.filter { e in terms.allSatisfy { mentions(e.shownText, $0) } }
        var out: [String] = []
        let about = terms.isEmpty ? "" : " that mention \(quoted(terms))"
        // T ruling (2026-10-09): NEVER assert absence from a key-term miss — a lexical miss is not evidence that the
        // entries don't say it ("speak" vs "spoke", a typed field, a synonym). Only POSITIVE matches become answers;
        // a miss emits nothing and the model reads the entries itself (the N-of-M line still says it can't see all).
        if forms.contains(.count) && !terms.isEmpty && !matched.isEmpty {
            out.append("Answer: \u{201C}Of \(seen(n)), \(matched.count) \(matched.count == 1 ? "mentions" : "mention") \(quoted(terms)) (\(list(matched))) — I can't see your whole library, so there may be more.\u{201D}")
        }
        let dated = matched.filter { $0.created != nil }.sorted { ($0.created!, $0.number) < ($1.created!, $1.number) }
        if forms.contains(.oldest), let e = dated.first {
            out.append("Answer: \u{201C}Of the entries I can see\(about), the oldest is [\(e.number)] \(e.title) (\(e.ownNote ? "written" : "added") \(dayString(e.created!, calendar: cal))) — I can't see your whole library, so it may not be your oldest.\u{201D}")
        }
        if forms.contains(.newest), let e = dated.last {
            out.append("Answer: \u{201C}Of the entries I can see\(about), the most recent is [\(e.number)] \(e.title) (\(e.ownNote ? "written" : "added") \(dayString(e.created!, calendar: cal))) — I can't see your whole library, so it may not be your latest.\u{201D}")
        }
        let sized = matched.filter { ($0.words ?? 0) > 0 }   // an entry counted at 0 words is unknown, not shortest.sorted { ($0.words!, -$0.number) < ($1.words!, -$1.number) }
        if forms.contains(.longest), let e = sized.last {
            out.append("Answer: \u{201C}Of the entries I can see\(about), the longest is [\(e.number)] \(e.title) (about \(e.words!) words) — I can't see your whole library, so it may not be your longest.\u{201D}")
        }
        if forms.contains(.shortest), let e = sized.first {
            out.append("Answer: \u{201C}Of the entries I can see\(about), the shortest is [\(e.number)] \(e.title) (about \(e.words!) words) — I can't see your whole library, so it may not be your shortest.\u{201D}")
        }
        if forms.contains(.presence) && !terms.isEmpty && out.isEmpty && !matched.isEmpty {
            out.append("Answer: \u{201C}Yes — of \(seen(n)), \(list(matched)) \(matched.count == 1 ? "mentions" : "mention") \(quoted(terms)).\u{201D}")
        }
        if !out.isEmpty {
            out.insert("This is a whole-library question and you can see only part of the library. Start your answer with the sentence below, then add what the entries say:", at: 0)
        }
        return out
    }

    // MARK: - The section (design §1)

    struct PacketEntry: Equatable {
        let number: Int
        let nodeID: String
        let title: String
        let created: Date?
        /// Read-in-full (or PARTIAL) text — ranges are extracted ONLY from these (design §2.1).
        let readText: String?
        /// Everything the model can SEE of this entry in the packet (read text / passages / card title + gist) —
        /// what the computed answers (CI-2 ruling 1) check for the question's key terms.
        var shownText: String = ""
        /// Approximate length of the WHOLE entry in words (for "longest of the entries shown"); nil = unknown.
        var words: Int? = nil
        /// The user WROTE it (a note) — its date is "written"; a saved article / document / image text was "added".
        var ownNote: Bool = true
        /// The read was PARTIAL (best excerpts of a long entry) — a range summary must not claim "none out of range".
        var partial: Bool = false
    }

    struct Input {
        var today: Date
        var calendar: Calendar
        var question: String
        var entries: [PacketEntry]       // every packet candidate (reads, passages, cards); deduped here
        var scopeTotal: Int              // M — entries in the searched scope
        var scopeNoun: String            // "library" | "collection"
        var allowanceChars: Int
        /// Range lines only for a RANGE question or a range-routed read (audit §3: they ran on any read entry).
        var rangeQuestion: Bool = true
    }

    static let header = "COMPUTED FACTS (worked out by the app from the entries above — exact; trust them over your own reading or arithmetic):"

    /// The whole section, or nil when it would carry no fact. Deterministic in its input.
    static func build(_ input: Input) -> String? {
        let cal = input.calendar
        // dedupe by node: the lowest [n] represents it; output order = [n] ascending (unique → total order)
        var seen = Set<String>(); var entries: [PacketEntry] = []
        for e in input.entries.sorted(by: { $0.number < $1.number }) where !seen.contains(e.nodeID) {
            seen.insert(e.nodeID); entries.append(e)
        }
        guard !entries.isEmpty else { return nil }

        // T ruling (2026-10-09): "Today is …" ONLY on a date question. Right before "Question:" it captured a bare
        // "that" ("Which entry says that?" → "none of the entries say that today is Friday…", 2 of 2 deictic follow-ups).
        let window = relativeWindow(question: input.question, today: input.today, calendar: cal)
        let wantDates = looksLikeTemporalQuestion(input.question) || looksLikeWholeLibraryQuestion(input.question)
        var keep: [String] = (wantDates || window != nil) ? [todayLine(input.today, calendar: cal)] : []
        // "N of M" ONLY on whole-library questions (T 2026-10-06): on a single-entry read the models recited it
        // as chatter ("I'm seeing only 1 of 224 entries in your library" — thinking-4B 3/15 on test 3).
        if looksLikeWholeLibraryQuestion(input.question) {
            keep.append("You are seeing \(entries.count) of the \(input.scopeTotal) entries in this \(input.scopeNoun) — the ones most related to the question, not all of them."
                + " You cannot count, rank (oldest, newest, longest) or prove that something is absent across the whole \(input.scopeNoun) from these; if asked, say what these entries show and that it may not be everything.")
        }
        keep += packetAnswers(question: input.question, entries: entries, calendar: cal)
        if let w = window {
            let inside = entries.filter { e in
                guard let c = e.created else { return false }
                let d = cal.startOfDay(for: c)
                return d >= cal.startOfDay(for: w.start) && d <= cal.startOfDay(for: w.end)
            }.map { "[\($0.number)]" }
            let span = w.start == w.end ? dayString(w.start, calendar: cal)
                : "\(dayString(w.start, calendar: cal)) to \(dayString(w.end, calendar: cal))"
            let which = inside.isEmpty ? "None of the entries shown fall in it — the library may have others from then."
                : "Of the entries shown, \(inside.count == 1 ? inside[0] : inside.dropLast().joined(separator: ", ") + " and " + inside.last!) \(inside.count == 1 ? "falls" : "fall") in it; the library may have others from then."
            keep.append("\"\(w.phrase.prefix(1).uppercased() + w.phrase.dropFirst())\" = \(w.label) (\(span)). \(which)")
        }

        // date lines (droppable from the highest [n] down) — CI ruling 2: ONLY on temporal / whole-library questions
        // (on a 12-entry survey they were ~300 prompt tokens ≈ +1 s first token for nothing).
        var dateLines: [String] = []
        for e in entries where wantDates {
            guard let c = e.created, let days = ageDays(created: c, today: input.today, calendar: cal),
                  let words = ageWords(created: c, today: input.today, calendar: cal) else { continue }
            dateLines.append("[\(e.number)] \(e.title) — \(e.ownNote ? "written" : "added to the library") \(dayString(c, calendar: cal)), \(words) (\(days) \(days == 1 ? "day" : "days")).")
        }

        // range groups, per read entry (per-value lines droppable beyond the first 30; summary never dropped)
        var rangeHeads: [String] = [], rangeValueLines: [[String]] = [], summaries: [String] = []
        for e in entries where input.rangeQuestion {
            guard let t = e.readText else { continue }
            let rows = rangeRows(in: t)
            guard !rows.isEmpty else { continue }
            rangeHeads.append("Ranges in [\(e.number)] \(e.title) (\(rows.count) \(rows.count == 1 ? "value" : "values") with a reference range):")
            rangeValueLines.append(rows.map(rangeLine))
            let out = rows.filter(\.isOutOfRange)
            let flaggedOnly = rows.filter(\.isFlaggedOnly)
            var s = "Out of range in [\(e.number)], among the \(rows.count) values above: "
            // a PARTIAL read saw only some rows — "none" would be a claim about rows it never saw (audit §3)
            if out.isEmpty && e.partial {
                summaries.append(s + "none of these — but only part of this entry was included, so other values may be out of range; say so.")
                continue
            }
            s += out.isEmpty ? "none." : out.map { "\($0.name) \($0.value)\($0.flagToken.map { " (\($0))" } ?? "")" }.joined(separator: ", ") + "."
            let within = rows.count - out.count - flaggedOnly.count
            s += " The other \(within) \(within == 1 ? "is" : "are") within \(within == 1 ? "its range" : "their ranges")."
            if !flaggedOnly.isEmpty {
                s += " The entry also flags " + flaggedOnly.map { "\($0.name) \($0.value) (\($0.flagToken ?? ""))" }.joined(separator: ", ") + " — say what the entry says."
            }
            summaries.append(s)
        }

        if keep.isEmpty && dateLines.isEmpty && rangeHeads.isEmpty { return nil }   // nothing to compute → no section
        func render(dates: [String], values: [[String]]) -> String {
            var lines = [header] + keep
            if !dates.isEmpty { lines.append("Dates: " + dates.joined(separator: " ")) }
            for (i, h) in rangeHeads.enumerated() {
                lines.append(h); lines += values[i]; lines.append(summaries[i])
            }
            return lines.joined(separator: "\n")
        }
        var dates = dateLines
        var values = rangeValueLines
        var out = render(dates: dates, values: values)
        // truncation order (design §1.4): 1) per-value lines beyond the first 30 per table; 2) date lines from the
        // highest [n] down; 3) further per-value lines; never: today, scope, window, out-of-range summaries.
        if out.count > input.allowanceChars {
            values = values.map { Array($0.prefix(30)) }
            out = render(dates: dates, values: values)
        }
        while out.count > input.allowanceChars, !dates.isEmpty {
            dates.removeLast(); out = render(dates: dates, values: values)
        }
        while out.count > input.allowanceChars, values.contains(where: { !$0.isEmpty }) {
            if let i = values.lastIndex(where: { !$0.isEmpty }) { values[i].removeLast() }
            out = render(dates: dates, values: values)
        }
        guard out.count <= input.allowanceChars else { return nil }   // even the floor doesn't fit → no section
        return out
    }
}
