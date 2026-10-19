import Foundation

/// live-29 (1) — "What did I write about my Bolex H16?" READS the entries that name it, and the Librarian never tells
/// the user an entry doesn't exist when one in the searched room names it.
///
/// Measured (live-27 gauntlet, qwen3:4b): "What have I written about Baldur's Gate 3?" in the Sample Library routed to
/// SURVEY, and the survey's passages + cards held none of the two entries about the game (they say "BG3", never
/// "Baldur's Gate"; the embedding didn't bridge it). The model was handed twelve unrelated entries and said "You have
/// not written about Baldur's Gate 3 in any entry." Case 11 ("…my Bolex H16?") asked T's OWN room, which has no Bolex
/// entry (the five Bolex entries are the Sample Library's): the honest answer there is "nothing in your notes", and
/// this says where the entries are.
///
/// Two layers, both in code (no question classifier — a phrase matcher, same posture as `looksLikeOwnershipQuestion`):
///   (a) ROUTING — a "what did I write / note / save / say about X" question finds the entries that NAME X (every name
///       term as a whole word, or X's initials: "Baldur's Gate 3" → "BG3") and reads the best one in full, the rest as
///       chips. Many matches → a survey over just those entries.
///   (b) THE ABSENCE GUARD — "nothing found" only when nothing in the room names X. Then the app says so itself (no
///       model call, no unrelated survey to misread). When entries were found, an answer that still asserts absence is
///       replaced by the list of entries found.
extension LibrarianState {

    /// The thing a "what did I write about X" question asks for, or nil. Covers write / note / save / say / jot /
    /// record / put down / keep, in the past, perfect and present ("What have I written about…", "What do I say
    /// about…", "Did I note anything about…", "Anything I saved about…").
    nonisolated static func writtenAboutSubject(_ query: String) -> String? {
        let q = query.replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        let verbs = "write|wrote|written|writing|note|noted|save|saved|say|said|jot|jotted|jot down|jotted down|record|recorded|put down|keep|kept|log|logged|capture|captured"
        let pattern = "(?i)^(?:so |and |ok,? |okay,? )?(?:what|anything|did|have|do|show me what|tell me what)\\b[^?]*?\\bi(?:'ve| have| had)?\\s+(?:ever\\s+|already\\s+|actually\\s+)?(?:\(verbs))\\b(?:\\s+(?:anything|something|down|up))?\\s+(?:about|on|regarding)\\s+(.+?)[\\s?.!]*$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range(at: 1), in: q) else { return nil }
        var subject = String(q[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        // "…about my Bolex H16 so far" / "…in my notes" — the subject ends before a scope tail.
        for tail in [" so far", " lately", " recently", " in my notes", " in my entries", " in my library", " anywhere", " at all", " before"] {
            if subject.lowercased().hasSuffix(tail) { subject = String(subject.dropLast(tail.count)) }
        }
        for lead in ["my ", "the ", "a ", "an ", "our ", "that ", "this "] where subject.lowercased().hasPrefix(lead) {
            subject = String(subject.dropFirst(lead.count))
        }
        subject = subject.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return subject.isEmpty ? nil : subject
    }

    /// One subject lookup: the subject as the user wrote it, its name terms, and its initials.
    struct SubjectLookup: Equatable {
        let subject: String
        /// Lowercased whole-word terms (letters, or letters + digits like "h16"); bare numbers and filler dropped.
        let terms: [String]
        /// The initials of a multi-word NAME plus any number ("Baldur's Gate 3" → "BG3"), matched case-sensitively as
        /// a whole token. Nil when the subject isn't a capitalised multi-word name or the initials are < 3 characters.
        let acronym: String?
        /// True when the subject NAMES something (a capitalised word or a letters+digits token): names are lexical, so
        /// "no entry contains it" is evidence of absence. A common-word subject ("my mornings") isn't — retrieval's
        /// meaning match runs as before.
        let isName: Bool
        /// The name's HEAD word — its first capitalised all-letter word ("Bolex" in "Bolex H16", "Baldur" in "Baldur's
        /// Gate 3"), matched case-sensitively. An entry that names only the head ("The Bolex came Thursday") is a WEAK
        /// match: it's about the thing, without the model number.
        let head: String?

        init?(subject: String) {
            let words = subject.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "/" }).map(String.init)
            let filler: Set<String> = ["my", "the", "a", "an", "our", "of", "on", "in", "for", "with", "and", "to", "it",
                                       "that", "this", "these", "those", "any", "all", "some", "things", "stuff", "about",
                                       "entries", "entry", "notes", "note", "i", "me", "much", "ever", "anything", "everything",
                                       "or", "at", "by", "from", "its", "his", "her", "their", "new", "old"]
            var terms: [String] = []
            var initials = "", digits = "", capitalised = 0, isName = false
            var head: String? = nil
            for w in words {
                let core = Self.core(w)
                guard !core.isEmpty else { continue }
                let hasLetter = core.rangeOfCharacter(from: .letters) != nil
                let hasDigit = core.rangeOfCharacter(from: .decimalDigits) != nil
                if !hasLetter { digits += core; continue }                 // "3" in "Baldur's Gate 3" → initials only
                if hasDigit { isName = true }                              // "H16"
                if core.first?.isUppercase == true {
                    capitalised += 1; initials.append(core.first!); isName = true
                    if head == nil, !hasDigit, core.count >= 3 { head = core }
                }
                let lower = core.lowercased()
                if filler.contains(lower) || (lower.count < 3 && !hasDigit) { continue }
                terms.append(lower)
            }
            guard !terms.isEmpty else { return nil }
            self.subject = subject
            self.terms = terms
            let acr = initials + digits
            self.acronym = (capitalised >= 2 && acr.count >= 3) ? acr : nil
            self.isName = isName
            self.head = (terms.count >= 2) ? head : nil   // a one-word name is already matched in full
        }

        /// A word's core: apostrophe-s and surrounding punctuation dropped ("Baldur's" → "Baldur", "H16?" → "H16").
        static func core(_ w: String) -> String {
            var s = w.replacingOccurrences(of: "\u{2019}", with: "'")
            if s.lowercased().hasSuffix("'s") { s = String(s.dropLast(2)) }
            return s.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }

        /// Whole-word tokens of `text` (letters and digits stay together: "H16", "BG3"), each with a light plural stem.
        static func tokens(_ text: String) -> (lower: Set<String>, raw: Set<String>) {
            var lower = Set<String>(), raw = Set<String>()
            for t in text.replacingOccurrences(of: "\u{2019}", with: "'")
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                let s = String(t); raw.insert(s)
                let l = s.lowercased(); lower.insert(l); lower.insert(stem(l))
            }
            return (lower, raw)
        }

        static func stem(_ w: String) -> String {
            if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        }

        /// Does `text` name the subject? Every term as a whole word (plural-tolerant), or the initials as a token.
        func isNamed(in text: String) -> Bool {
            let t = Self.tokens(text)
            if let acronym, t.raw.contains(acronym) { return true }
            return terms.allSatisfy { t.lower.contains($0) || t.lower.contains(Self.stem($0)) }
        }

        /// A WEAK match: the head word alone, capitalised as in the subject.
        func isWeaklyNamed(in text: String) -> Bool {
            guard let head else { return false }
            return Self.tokens(text).raw.contains(head)
        }
    }

    /// The entries in `nodes` that name the subject, best first: STRONG (every term, or the initials) before WEAK (the
    /// head word alone); inside each, a title that names it, then how many of the entry's passages name it, then the
    /// newest. Reads each entry's own text (blocks; a not-yet-chunked capture's own items and summary).
    static func entriesNaming(_ lookup: SubjectLookup, nodes: [Node], store: CorpusStore) async -> (strong: [String], weak: [String]) {
        var hits: [(id: String, strong: Bool, title: Bool, count: Int, date: Date)] = []
        for node in nodes {
            var texts = await store.entryBlockTexts(nodeID: node.id)
            if texts.isEmpty {
                let itemTexts = node.items.flatMap { [$0.content, $0.transcript, $0.description, $0.title, $0.preview].compactMap { $0 } }
                texts = [node.summary] + itemTexts
            }
            let titleStrong = lookup.isNamed(in: node.title)
            let strongCount = texts.reduce(0) { $0 + (lookup.isNamed(in: $1) ? 1 : 0) }
            if titleStrong || strongCount > 0 {
                hits.append((node.id, true, titleStrong, strongCount, node.createdAt)); continue
            }
            let titleWeak = lookup.isWeaklyNamed(in: node.title)
            let weakCount = texts.reduce(0) { $0 + (lookup.isWeaklyNamed(in: $1) ? 1 : 0) }
            if titleWeak || weakCount > 0 { hits.append((node.id, false, titleWeak, weakCount, node.createdAt)) }
        }
        let ordered = hits.sorted {
            $0.title != $1.title ? $0.title : $0.count != $1.count ? $0.count > $1.count : $0.date > $1.date
        }
        return (ordered.filter(\.strong).map(\.id), ordered.filter { !$0.strong }.map(\.id))
    }

    /// (b) The app's own answer when nothing in the searched room names the subject. Names where the entries are when
    /// the Sample Library holds some (T's own room is searched; the sample is a separate scope).
    nonisolated static func nothingFoundAnswer(subject: String, roomName: String, sampleCount: Int) -> String {
        var s = "I couldn't find anything about \(subject) in \(roomName) — no entry there mentions it."
        if sampleCount > 0 {
            let them = sampleCount == 1 ? "it" : "them"
            s += " The Sample Library has \(sampleCount) \(sampleCount == 1 ? "entry" : "entries") about it — open the Sample Library to ask about \(them)."
        }
        return s
    }

    /// The searched room as the answer names it.
    func lookupRoomName(store: CorpusStore) -> String {
        switch selectedScope {
        case .corpus: return "your notes"
        case .collection(let id):
            if id == NodeCollection.journalID { return "your journal" }
            return "your \(store.collections.first { $0.id == id }?.name ?? "collection") collection"
        case .nodeIDs(let ids): return ids == store.sampleNodeIDs ? "the Sample Library" : "the selected entries"
        }
    }

    /// How many Sample Library entries name the subject when the searched room is the user's own notes and the sample
    /// is kept apart from them (T's case 11). 0 otherwise.
    func sampleEntriesNaming(_ lookup: SubjectLookup, store: CorpusStore) async -> Int {
        guard case .corpus = selectedScope, !store.sampleNodeIDs.isEmpty,
              store.nodes(in: .corpus).count < store.nodes.count else { return 0 }
        let (strong, weak) = await Self.entriesNaming(lookup, nodes: store.nodes(in: .nodeIDs(store.sampleNodeIDs)), store: store)
        return strong.count + weak.count
    }

    /// SL-S2 — "What do my coffee entries keep coming back to?" names a COLLECTION ("Coffee"): the question is about
    /// that collection's entries together → a survey over its members in the searched room, never one entry read in
    /// full (measured: it read *coffee in the chili*, an own note that dominated retrieval). Nil unless "my <name>
    /// entries / notes / collection" names a collection with ≥ 2 entries in the room. Same-named collections pool.
    static func collectionSurveyMembers(_ query: String, store: CorpusStore, roomNodes: [Node]) -> Set<String>? {
        guard let phrase = collectionPhrase(query) else { return nil }
        let name = SubjectLookup.stem(phrase)
        let ids = Set(store.collections.filter { SubjectLookup.stem($0.name.lowercased()) == name }.map(\.id))
        guard !ids.isEmpty else { return nil }
        let members = Set(roomNodes.filter { !ids.isDisjoint(with: $0.collectionIDs) }.map(\.id))
        return members.count >= 2 ? members : nil
    }

    /// The collection a question names as "my <name> entries / notes / collection" (lowercased), or nil. Off with
    /// `-SubjectLookupOff YES`.
    nonisolated static func collectionPhrase(_ query: String) -> String? {
        guard isSubjectLookupEnabled else { return nil }
        let q = query.replacingOccurrences(of: "\u{2019}", with: "'")
        guard let re = try? NSRegularExpression(pattern: "(?i)\\bmy\\s+(?:own\\s+)?([\\p{L}][\\p{L}' -]{1,40}?)\\s+(?:entries|notes|collection|logs?)\\b"),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range(at: 1), in: q) else { return nil }
        return String(q[r]).lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// DEBUG A/B for the gauntlet and the RED rows: `-SubjectLookupOff YES` routes and answers as before live-29 (1).
    nonisolated static var isSubjectLookupEnabled: Bool {
        #if DEBUG
        return !UserDefaults.standard.bool(forKey: "SubjectLookupOff")
        #else
        return true
        #endif
    }

    /// (b) An UNHEDGED absence claim ("you didn't write anything about…", "none of your entries mention…", "Nothing."),
    /// the shapes the gauntlet's B2 grader flags. A qualified one ("didn't write a whole essay on X, but…") isn't.
    nonisolated static func assertsAbsence(_ answer: String) -> Bool {
        let text = answer.replacingOccurrences(of: "\u{2019}", with: "'")
        let absence = try! NSRegularExpression(pattern:
            "(?i)\\byou (?:never|didn't|did not|haven't|have not|hadn't)\\s+(?:\\w+\\s+){0,2}?(?:write|written|wrote|mention(?:ed)?|say|said|note(?:d)?|discuss(?:ed)?|record(?:ed)?|save(?:d)?)\\b"
            + "|\\bthere(?:'s| is| are) no (?:mention|entr|note|record)|\\bnone of (?:your|the) (?:entries|notes|retrieved)\\b[^.\\n]{0,60}\\b(?:mention|discuss|talk|refer|reference)"
            + "|\\bno (?:entries|notes) (?:mention|discuss|talk|refer)|\\bi (?:don't|do not) (?:have|see) any (?:entries|notes)\\b|\\bnot mentioned\\b|^\\s*nothing\\.?\\s*$")
        let qualified = try! NSRegularExpression(pattern:
            "(?i)\\b(?:explicitly|directly|a whole|a dedicated|an entire|specifically|in so many words|per se)\\b|\\byou did (?!not\\b)")
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) where !sentence.trimmingCharacters(in: .whitespaces).isEmpty {
            let r = NSRange(sentence.startIndex..., in: sentence)
            if absence.firstMatch(in: sentence, range: r) != nil, qualified.firstMatch(in: sentence, range: r) == nil { return true }
        }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.lowercased().hasPrefix("nothing.") || head.lowercased() == "nothing"
    }
}

/// (b) Handed to `ChatSession.send` for a subject lookup that FOUND entries: if the answer still asserts absence, the
/// committed answer is the list of what was found instead (the absence never reaches the transcript).
struct AbsenceGuard {
    let subject: String
    /// The found entries as packet citations (their `[n]` in this turn's packet), best first.
    let found: [ChatSession.Message.Citation]

    /// The guard itself: nil when the answer may stand; the replacement when it asserts absence (off with
    /// `-SubjectLookupOff YES`, the pre-live-29 behaviour).
    func apply(to answer: String) -> (text: String, citations: [ChatSession.Message.Citation])? {
        guard LibrarianState.isSubjectLookupEnabled, !found.isEmpty, !answer.isEmpty,
              LibrarianState.assertsAbsence(answer) else { return nil }
        return foundAnswer()
    }

    /// The replacement answer: what was found, each entry cited, numbered from 1 in display order.
    func foundAnswer() -> (text: String, citations: [ChatSession.Message.Citation]) {
        var lines = ["\(found.count == 1 ? "One entry mentions" : "\(found.count) entries mention") \(subject):"]
        var cites: [ChatSession.Message.Citation] = []
        for (i, c) in found.prefix(8).enumerated() {
            let n = i + 1
            let gist = MarkdownPlain.label(c.snippet.replacingOccurrences(of: "read in full · ", with: ""))
            var line = "- *\(c.title)* [\(n)]"
            if !gist.isEmpty {
                line += " — " + String(gist.prefix(140))
                if gist.count > 140 { line += "…" }
            }
            lines.append(line)
            if let id = c.nodeID { cites.append(.init(index: n, nodeID: id, title: c.title, snippet: c.snippet)) }
        }
        return (lines.joined(separator: "\n"), cites)
    }
}

#if DEBUG
/// `-SubjectLookupSelfTest` — live-29 (1): the "what did I write about X" lookup and the absence guard, on synthetic
/// questions, entry texts and answers. With `-SubjectLookupOff YES` it measures the pre-live-29 behaviour (RED).
enum SubjectLookupSelfTest {
    static func run() -> String {
        var fails: [String] = [], n = 0
        func check(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
            n += 1
            if !ok { let g = got(); fails.append("  FAIL  \(name)" + (g.isEmpty ? "" : " — got \(g)")) }
        }
        let on = LibrarianState.isSubjectLookupEnabled
        func route(_ q: String) -> String {
            guard on else { return "normal" }   // before live-29: no lookup — the embedding, dominance and survey decide
            if let s = LibrarianState.writtenAboutSubject(q), LibrarianState.SubjectLookup(subject: s) != nil { return "lookup:" + s }
            if let c = LibrarianState.collectionPhrase(q) { return "collection:" + c }
            return "normal"
        }
        // (a) routing — the question shapes
        let shapes: [(String, String, String)] = [
            ("case 11 → lookup", "What did I write about my Bolex H16?", "lookup:Bolex H16"),
            ("SL-M1a → lookup", "What have I written about Baldur's Gate 3?", "lookup:Baldur's Gate 3"),
            ("note → lookup", "Did I note anything about sourdough?", "lookup:sourdough"),
            ("save + tail → lookup", "What did I save about the Voynich manuscript lately?", "lookup:Voynich manuscript"),
            ("say, curly apostrophe → lookup", "What have I said about Mara\u{2019}s garden?", "lookup:Mara's garden"),
            ("SL-S2 → collection survey", "What do my coffee entries keep coming back to?", "collection:coffee"),
            ("general question stays normal", "What is the capital of France?", "normal"),
            ("lab question stays normal", "What do my lab test results reveal?", "normal"),
            ("synthesis stays normal", "What connections do you find between my ideas?", "normal"),
        ]
        for (name, q, want) in shapes { let got = route(q); check(name, got == want, got) }
        // (a) matching — names, initials, the head word
        if on, let bg3 = LibrarianState.SubjectLookup(subject: "Baldur's Gate 3"),
           let bolex = LibrarianState.SubjectLookup(subject: "Bolex H16"),
           let dough = LibrarianState.SubjectLookup(subject: "sourdough") {
            check("BG3 initials", bg3.acronym == "BG3", bg3.acronym ?? "nil")
            check("BG3 entry named by its initials", bg3.isNamed(in: "I finished BG3 last night. One ending."))
            check("BG3 entry named in full", bg3.isNamed(in: "Forty hours into Baldur's Gate and still reloading"))
            check("not BG3: 'Gate 3 closed'", !bg3.isNamed(in: "Gate 3 closed for the night"))
            check("not BG3: inside another token", !bg3.isNamed(in: "the abg3x code"))
            check("Bolex H16 is a name", bolex.isName && bolex.terms == ["bolex", "h16"], "\(bolex.terms)")
            check("Bolex strong", bolex.isNamed(in: "Bolex H16 — mine. Spring-wound."))
            check("Bolex weak, not strong", !bolex.isNamed(in: "The Bolex came Thursday.") && bolex.isWeaklyNamed(in: "The Bolex came Thursday."))
            check("not Bolex", !bolex.isNamed(in: "A painting of Bimbo") && !bolex.isWeaklyNamed(in: "A painting of Bimbo"))
            check("sourdough isn't a name", !dough.isName)
            check("sourdough plural", dough.isNamed(in: "Two sourdoughs this week"))
        } else {
            check("matching by name / initials (before live-29: none — retrieval only)", false)
        }
        // (b) the absence guard
        let found = [ChatSession.Message.Citation(index: 4, nodeID: "n1", title: "I finished BG3", snippet: "One ending. Didn't look at the others."),
                     ChatSession.Message.Citation(index: 7, nodeID: "n2", title: "BG3 — the first playthrough problem", snippet: "read in full · Forty hours in")]
        let g = AbsenceGuard(subject: "Baldur's Gate 3", found: found)
        let absent = ["So, based on what's in your notes: you didn't write anything about your Bolex H16.",
                      "Nothing.\n\nYou have not written about *Baldur's Gate 3* in any of the entries retrieved.",
                      "I don't have any entries in your library about your Bolex H16. None of the retrieved notes mention a Bolex H16.",
                      "There is no mention of Baldur's Gate 3 in your entries."]
        for (i, a) in absent.enumerated() {
            let r = g.apply(to: a)
            let ok = r != nil && r!.text.contains("[1]") && r!.text.contains("I finished BG3") && r!.citations.map(\.index) == [1, 2]
            check("guard replaces absence #\(i + 1)", ok, r.map { String($0.text.prefix(80)) } ?? "kept: \(a.prefix(60))")
        }
        let fine = ["You finished Baldur's Gate 3 on September 3 [1].",
                    "You didn't explicitly write a whole essay on it, but you did note the reloading [2].",
                    "You kept reloading saves to see what the other options said [1]."]
        for (i, a) in fine.enumerated() { check("guard leaves a real answer #\(i + 1)", g.apply(to: a) == nil) }
        check("no guard without found entries", AbsenceGuard(subject: "x", found: []).apply(to: absent[0]) == nil)
        // (b) nothing found — the app's own line
        let none = LibrarianState.nothingFoundAnswer(subject: "Bolex H16", roomName: "your notes", sampleCount: 5)
        check("nothing-found names the room and the Sample Library", none.contains("in your notes") && none.contains("Sample Library has 5 entries"), none)
        let pass = n - fails.count
        return "\(fails.isEmpty ? "PASS" : "FAIL") — \(pass)/\(n)" + (fails.isEmpty ? "" : "\n" + fails.joined(separator: "\n"))
    }
}
#endif
