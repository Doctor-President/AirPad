#if DEBUG
import Foundation
import CryptoKit

/// Brief CI (CI-2) — headless self-test for `ComputedFacts` (`-ComputedFactsSelfTest`, run in the Simulator;
/// prints PASS/FAIL per case). Covers design §9: every §2.5 negative + positive parser case, the approved flag
/// rules (↑/↓, Critical/CRIT, no `*`, A only beside H/L), the age table + edge days, relative windows, both
/// phrase matchers (incl. the Companion regression questions), the typed-fields line, and determinism.
/// Fixture text is SYNTHETIC (same layout as a real lab printout, invented values) — no user data.
enum ComputedFactsSelfTest {

    static let labTable = """
    Performing Lab:General Hospital, 12 Main Street, Springfield, IL
    BLOOD UREA
    NITROGEN
    15 6-20 MG/DL N
    SODIUM 137 135-145
    MMOL/L
    N
    POTASSIUM 4.4 3.5-5.2 MMOL/L N
    ALBUMIN 5.0 3.4-5.0 GM/DL N
    CHOLESTEROL 213 <200 MG/DL H
    HDL 43 >40 MG/DL N
    LDL, CALCULATED 153 <130 MG/DL H
    ESTIMATED GLOMERULAR
    FILTRATION RATE
    85 >=60
    mL/min/1.73m*2
    N
    TESTOSTERONE, PERCENTAGE FREE
    2.4 1.6-2.9 % N Performed By: Some Lab
    """

    @MainActor static func run() -> String {
        var fails: [String] = []
        var ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            ran += 1
            if !ok { fails.append("\(name)\(detail().isEmpty ? "" : " — " + detail())") }
        }

        // ── §2.5 positives: the synthetic lab table
        let rows = ComputedFacts.rangeRows(in: labTable)
        check("P-rowcount", rows.count == 9, "\(rows.count) rows: \(rows.map(\.name))")
        func row(_ n: String) -> ComputedFacts.RangeRow? { rows.first { $0.name == n } }
        check("P-two-line-name", row("BLOOD UREA NITROGEN")?.value == "15", rows.map(\.name).joined(separator: " | "))
        check("P-wrapped-unit-flag", row("SODIUM")?.unit == "MMOL/L" && row("SODIUM")?.flagToken == "N")
        check("P-at-upper", row("ALBUMIN")?.status == .atUpper)
        check("P-above-H", row("CHOLESTEROL")?.status == .above && row("CHOLESTEROL")?.isOutOfRange == true)
        check("P-lower-bound", row("HDL")?.status == .within)
        check("P-ge", row("ESTIMATED GLOMERULAR FILTRATION RATE")?.status == .within && row("ESTIMATED GLOMERULAR FILTRATION RATE")?.unit == "mL/min/1.73m*2")
        check("P-percent", row("TESTOSTERONE, PERCENTAGE FREE")?.unit == "%" && row("TESTOSTERONE, PERCENTAGE FREE")?.flagToken == "N")
        check("P-no-address-name", !rows.contains { $0.name.contains("IL") && $0.name.contains("Springfield") })
        check("P-line-albumin", ComputedFacts.rangeLine(row("ALBUMIN")!) == "- ALBUMIN 5.0 GM/DL: reference 3.4-5.0 — within the range, equal to its upper limit (5.0).",
              ComputedFacts.rangeLine(row("ALBUMIN")!))
        check("P-line-chol", ComputedFacts.rangeLine(row("CHOLESTEROL")!) == "- CHOLESTEROL 213 MG/DL: reference <200 — ABOVE the range (the entry flags it H).",
              ComputedFacts.rangeLine(row("CHOLESTEROL")!))

        // ── §2.5 negatives: each on its own (and inside prose) must yield NO row
        let negatives = [
            "Serves 4–6",
            "- 2-3 serrano peppers (stemmed)",
            "Cardio Activity: 15,000–22,000 steps/day",
            "Body Fat %: Estimated 14–16%",
            "Order date: 05/05/2026",
            "Reviewed date:05/13/2026 10:43:22 AM",
            "2026-05-05",
            "Visit 2026 05-12",
            "840 South Wood Street, Chicago, IL 60612",
            "Ride time: ~30-40 min to Kreuzberg",
            "Simmer for 5-7 minutes",
            "Training Frequency: 4–6 days per week",
            "Result 17.6",
            "Testosterone 250 mg/week (split into 2 injections)",
            "The reading came back as 12 10-20 mg which surprised me.",
        ]
        for n in negatives {
            let r = ComputedFacts.rangeRows(in: n)
            check("N: \(n)", r.isEmpty, r.map { "\($0.name) \($0.value) \($0.rangeText)" }.joined(separator: "; "))
        }
        let prose = negatives.joined(separator: "\n")
        check("N-all-together", ComputedFacts.rangeRows(in: prose).isEmpty, "\(ComputedFacts.rangeRows(in: prose).map(\.name))")

        // ── flags (Companion Q5): ↑/↓ and Critical/CRIT are flags; * is not; A only beside H/L
        let arrows = ComputedFacts.rangeRows(in: "IRON 210 60-170 ug/dL ↑\nFERRITIN 8 12-150 ng/mL ↓")
        check("F-arrows", arrows.count == 2 && arrows[0].flag == .high && arrows[1].flag == .low && arrows.allSatisfy(\.isOutOfRange))
        let crit = ComputedFacts.rangeRows(in: "POTASSIUM 6.9 3.5-5.2 MMOL/L CRIT\nSODIUM 120 135-145 MMOL/L Critical")
        check("F-critical", crit.count == 2 && crit.allSatisfy { $0.flag == .critical } && crit.allSatisfy(\.isOutOfRange))
        let star = ComputedFacts.rangeRows(in: "GLUCOSE 99 70-110 MG/DL *\nCALCIUM 9.5 8.6-10.6 MG/DL *")
        check("F-star-not-flag", star.count == 2 && star.allSatisfy { $0.flagToken == nil })
        let aWithHL = ComputedFacts.rangeRows(in: "WBC 13.1 4.0-11.0 K/uL H\nRBC MORPH 1 0-0.5 /hpf A")
        check("F-A-with-HL", aWithHL.count == 2 && aWithHL[1].flag == .abnormal && !aWithHL[1].isOutOfRange && aWithHL[1].isFlaggedOnly)
        let aAlone = ComputedFacts.rangeRows(in: "CURRENT 3 1-2 mA A\nVOLTAGE 9 1-12 V A")
        check("F-A-alone-not-flag", aAlone.count == 2 && aAlone.allSatisfy { $0.flag == nil })
        let disagree = ComputedFacts.rangeRows(in: "GLUCOSE 99 70-110 MG/DL H\nCALCIUM 9.5 8.6-10.6 MG/DL N")
        check("F-disagree-quotes-flag", disagree.first?.disagrees == true
              && ComputedFacts.rangeLine(disagree[0]) == "- GLUCOSE 99 MG/DL: reference 70-110 — the entry flags it H.",
              disagree.first.map(ComputedFacts.rangeLine) ?? "")

        // ── ages (design §3): start-of-day calendar days, fixed time zone for the test
        let cal = ComputedFacts.calendar(TimeZone(identifier: "America/Chicago")!)
        func d(_ s: String, _ h: Int = 12, _ m: Int = 0) -> Date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: "\(s) \(String(format: "%02d:%02d", h, m))")!
        }
        let today = d("2026-10-05")
        let ages: [(String, String?, Int?)] = [
            ("2026-10-05", "today", 0), ("2026-10-04", "yesterday", 1), ("2026-09-22", "13 days ago", 13),
            ("2026-09-21", "2 weeks ago", 14), ("2026-08-07", "8 weeks ago", 59), ("2025-11-18", "10 months ago", 321),
            ("2025-10-05", "1 year ago", 365), ("2024-06-01", "2 years and 4 months ago", 856), ("2026-10-06", nil, nil),
        ]
        for (s, want, days) in ages {
            let got = ComputedFacts.ageWords(created: d(s), today: today, calendar: cal)
            let gd = ComputedFacts.ageDays(created: d(s), today: today, calendar: cal)
            check("D-age \(s)", got == want && gd == days, "\(got ?? "nil") / \(gd.map(String.init) ?? "nil")")
        }
        check("D-23:50→00:10", ComputedFacts.ageDays(created: d("2026-10-04", 23, 50), today: d("2026-10-05", 0, 10), calendar: cal) == 1)
        check("D-leap", ComputedFacts.ageDays(created: d("2024-02-29"), today: d("2024-03-01"), calendar: cal) == 1)
        check("D-today-line", ComputedFacts.todayLine(today, calendar: cal) == "Today is Monday, 5 October 2026.", ComputedFacts.todayLine(today, calendar: cal))

        // ── windows
        let lm = ComputedFacts.relativeWindow(question: "What did I write last month?", today: today, calendar: cal)
        check("W-last-month", lm?.label == "September 2026" && ComputedFacts.dayString(lm!.start, calendar: cal) == "2026-09-01"
              && ComputedFacts.dayString(lm!.end, calendar: cal) == "2026-09-30", "\(String(describing: lm))")
        let tw = ComputedFacts.relativeWindow(question: "anything this week?", today: today, calendar: cal)
        check("W-this-week-iso", tw.map { ComputedFacts.dayString($0.start, calendar: cal) } == "2026-10-05", "\(String(describing: tw))")
        let p7 = ComputedFacts.relativeWindow(question: "what did I note in the past 7 days", today: today, calendar: cal)
        check("W-past-7", p7.map { ComputedFacts.dayString($0.start, calendar: cal) } == "2026-09-29")
        check("W-none-lately", ComputedFacts.relativeWindow(question: "Why have I felt low lately?", today: today, calendar: cal) == nil)

        // ── phrase matchers (Companion Q2 + Q3)
        for q in ["Which of my lab values are out of range?", "Is my HDL in the normal range?", "Are any of my test results high?",
                  "Which levels are elevated?", "What's the reference range for my LDL?"] {
            check("R+ \(q)", ComputedFacts.looksLikeRangeQuestion(q))
        }
        for q in ["What were the high points of my year?", "Why have I felt low lately?", "How would you describe my thoughts on technology?",
                  "What do my lab test results reveal?", "Is anything abnormal about my writing lately?"] {
            check("R- \(q)", !ComputedFacts.looksLikeRangeQuestion(q))
        }
        for q in ["How many of my entries mention Mara?", "Did I ever write about beekeeping?", "What's my oldest entry about Mara?",
                  "What's the longest entry in my library?", "What exactly did I say about the Bolex being dandori?", "Have I ever mentioned Paris?"] {
            check("L+ \(q)", ComputedFacts.looksLikeWholeLibraryQuestion(q))
        }
        for q in ["What did I write about my Bolex H16?", "What did I write about the new cock ring I bought?"] {
            check("L- read-q \(q)", !ComputedFacts.looksLikeWholeLibraryQuestion(q) && ComputedFacts.packetAnswers(question: q, entries: [], calendar: ComputedFacts.calendar()).isEmpty)
        }
        check("L+ anything", ComputedFacts.looksLikeWholeLibraryQuestion("Did I write anything about beekeeping?"))
        for q in ["What do I think about everything?", "Whatever happened with the sculpture?", "What connections do you find between my ideas?",
                  "What do my lab test results reveal?", "However you read it, what's the gist?", "Is my HDL in the normal range?"] {
            check("L- \(q)", !ComputedFacts.looksLikeWholeLibraryQuestion(q))
        }

        // ── the section: determinism + content + allowance
        let entries = [
            ComputedFacts.PacketEntry(number: 2, nodeID: "B", title: "Fourteen years", created: d("2026-06-20"), readText: nil),
            ComputedFacts.PacketEntry(number: 1, nodeID: "A", title: "Lab report", created: d("2026-07-07"), readText: labTable),
            ComputedFacts.PacketEntry(number: 3, nodeID: "B", title: "Fourteen years", created: d("2026-06-20"), readText: nil),
        ]
        func section(_ q: String, _ allowance: Int = 3_600) -> String? {
            ComputedFacts.build(.init(today: today, calendar: cal, question: q, entries: entries, scopeTotal: 434,
                                      scopeNoun: "library", allowanceChars: allowance))
        }
        let s1 = section("Which of my lab values are out of range?"), s2 = section("Which of my lab values are out of range?")
        let h1 = s1.map { SHA256.hash(data: Data($0.utf8)).description }, h2 = s2.map { SHA256.hash(data: Data($0.utf8)).description }
        check("S-deterministic", s1 != nil && h1 == h2)
        // T 2026-10-06: "N of M" ONLY on whole-library questions — absent on a single-entry read, present on a count/rank/absence question.
        check("S-no-N-of-M-on-read-q", s1?.contains("You are seeing") == false, s1 ?? "nil")
        let sWhole = section("How many of my entries mention my lab report?")
        check("S-scope-N-of-M-whole-library", sWhole?.contains("You are seeing 2 of the 434 entries in this library") == true, sWhole ?? "nil")
        check("S-no-N-of-M-on-synthesis", section("What connections do you find between my ideas?")?.contains("You are seeing") == false)
        check("S-no-limit-on-range-q", s1?.contains("You cannot count") == false)
        check("S-summary", s1?.contains("Out of range in [1], among the 9 values above: CHOLESTEROL 213 (H), LDL, CALCULATED 153 (H). The other 7 are within their ranges.") == true,
              s1?.components(separatedBy: "\n").first { $0.hasPrefix("Out of range") } ?? "missing")
        check("S-no-dates-on-range-q", s1?.contains("Dates:") == false, s1 ?? "nil")
        let sTime = section("How has my thinking about AirPad changed over time?")
        check("S-dates-on-temporal-q", sTime?.contains("[2] Fourteen years — written 2026-06-20, 3 months ago (107 days).") == true, sTime ?? "nil")
        check("S-no-dates-on-synthesis", section("What connections do you find between my ideas?")?.contains("Dates:") == false)
        for q in ["How has my thinking about AirPad changed over time?", "How did my view evolve?", "What have I written recently?",
                  "What did I note since June?", "When did I start the sculpture?", "What came before the Bolex?", "Anything new lately?"] {
            check("T+ \(q)", ComputedFacts.looksLikeTemporalQuestion(q))
        }
        for q in ["What connections do you find between my ideas?", "Which of my lab values are out of range?", "What am I circling around without saying it directly?"] {
            check("T- \(q)", !ComputedFacts.looksLikeTemporalQuestion(q))
        }
        let sCount = section("How many of my entries mention Mara?")
        check("S-limit-sentence", sCount?.contains("You cannot count, rank (oldest, newest, longest) or prove that something is absent") == true)
        let sWin = section("What did I write last month?")
        check("S-window-none", sWin?.contains("\"Last month\" = September 2026 (2026-09-01 to 2026-09-30). None of the entries shown fall in it — the library may have others from then.") == true,
              sWin ?? "nil")
        let tight = section("Which of my lab values are out of range?", 700)
        check("S-allowance-keeps-floor", tight.map { $0.count <= 700 && $0.contains("Today is") && $0.contains("Out of range in [1]") } == true,
              tight ?? "nil")

        // ── CI-2 ruling 1: key terms + packet-level computed answers
        let kt: [(String, [String])] = [
            ("How many of my entries mention Mara?", ["Mara"]), ("How many of my entries mention my Bolex?", ["Bolex"]),
            ("What's my oldest entry about Mara?", ["Mara"]), ("What's the longest entry in my library?", []),
            ("Did I ever write about Richard Dawkins?", ["Richard Dawkins"]), ("Did I ever write about beekeeping?", ["beekeeping"]),
            ("What exactly did I say about the Bolex being dandori?", ["Bolex", "dandori"]),
        ]
        for (q, want) in kt { check("K \(q)", ComputedFacts.keyTerms(q) == want, "\(ComputedFacts.keyTerms(q))") }
        var shownEntries = [
            ComputedFacts.PacketEntry(number: 1, nodeID: "M1", title: "Mara", created: d("2025-11-22"), readText: nil),
            ComputedFacts.PacketEntry(number: 2, nodeID: "D1", title: "dandori", created: d("2026-01-24"), readText: nil),
            ComputedFacts.PacketEntry(number: 3, nodeID: "L1", title: "Deep dive", created: d("2026-06-16"), readText: nil),
        ]
        shownEntries[0].shownText = "Mara\nShe alphabetises her spice rack."; shownEntries[0].words = 40
        shownEntries[1].shownText = "dandori\nThe art of sequencing a task well."; shownEntries[1].words = 120
        shownEntries[2].shownText = "Deep dive\nThat concept comes from Richard Dawkins."; shownEntries[2].words = 4000
        func ans(_ q: String) -> [String] { ComputedFacts.packetAnswers(question: q, entries: shownEntries, calendar: cal) }
        func line(_ q: String) -> String { ans(q).dropFirst().first ?? "" }   // [0] = the "start your answer with" lead
        check("A-lead", ans("How many of my entries mention Mara?").first?.hasPrefix("This is a whole-library question") == true)
        check("A-count", line("How many of my entries mention Mara?") == "Answer: \u{201C}Of the 3 entries I can see, 1 mentions \u{201C}Mara\u{201D} ([1]) — I can't see your whole library, so there may be more.\u{201D}", line("How many of my entries mention Mara?"))
        check("A-count-none", line("How many of my entries mention my Bolex?") == "Answer: \u{201C}None of the 3 entries I can see mention \u{201C}Bolex\u{201D} — I can't see your whole library, so I can't rule it out.\u{201D}", line("How many of my entries mention my Bolex?"))
        let one = [shownEntries[0]]
        let oneLine = ComputedFacts.packetAnswers(question: "How many of my entries mention Mara?", entries: one, calendar: cal).dropFirst().first ?? ""
        check("A-singular", oneLine.contains("Of the one entry I can see, 1 mentions") && !oneLine.contains("1 entries"), oneLine)
        let oneNone = ComputedFacts.packetAnswers(question: "Did I ever write about beekeeping?", entries: one, calendar: cal).dropFirst().first ?? ""
        check("A-singular-none", oneNone.hasPrefix("Answer: \u{201C}The one entry I can see doesn't mention \u{201C}beekeeping\u{201D} — but I can't see your whole library, so I can't rule it out."), oneNone)
        check("A-oldest", line("What's my oldest entry about Mara?").hasPrefix("Answer: \u{201C}Of the entries I can see that mention \u{201C}Mara\u{201D}, the oldest is [1] Mara (2025-11-22)"), line("What's my oldest entry about Mara?"))
        check("A-longest", line("What's the longest entry in my library?").hasPrefix("Answer: \u{201C}Of the entries I can see, the longest is [3] Deep dive (about 4000 words)"), line("What's the longest entry in my library?"))
        check("A-present", line("Did I ever write about Richard Dawkins?") == "Answer: \u{201C}Yes — of the 3 entries I can see, [3] mentions \u{201C}Richard Dawkins\u{201D}.\u{201D}", line("Did I ever write about Richard Dawkins?"))
        check("A-absent-partial", line("What exactly did I say about the Bolex being dandori?").hasPrefix("Answer: \u{201C}None of the 3 entries I can see mention all of \u{201C}Bolex\u{201D} and \u{201C}dandori\u{201D} ([2] mentions \u{201C}dandori\u{201D} only) — but I can't see your whole library, so I can't rule it out."),
              line("What exactly did I say about the Bolex being dandori?"))
        check("A-no-time-terms", ComputedFacts.keyTerms("What did I write last month?").isEmpty && ans("What did I write last month?").isEmpty, "\(ComputedFacts.keyTerms("What did I write last month?"))")
        check("A-none-for-ordinary", ans("What connections do you find between my ideas?").isEmpty && ans("Which of my lab values are out of range?").isEmpty)

        // ── typed fields line (every kind, via the shared field fixture)
        if #available(iOS 17.0, *) {
            let defs = FieldValueSelfTest.fixtureDefinitions()
            let node = FieldValueSelfTest.fixtureNode(defs: defs)
            let line = ComputedFacts.fieldsLine(items: node.items, definition: { id in defs.first { $0.id == id } },
                                                resolveNodeTitle: { _ in "Charmander" })
            check("T-fields-line", line?.hasPrefix("Fields: Serves: 4–6") == true && line?.contains("Cook time: ") == true
                  && line?.contains("Type: Fire") == true, line ?? "nil")
            let missingDef = ComputedFacts.fieldsLine(items: node.items, definition: { _ in nil }, resolveNodeTitle: { _ in nil })
            check("T-missing-definition-omitted", missingDef == nil || missingDef?.contains("def-") == false, missingDef ?? "nil")
        }

        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(ran - fails.count)/\(ran)\n  " + fails.joined(separator: "\n  ")
    }
}
#endif
