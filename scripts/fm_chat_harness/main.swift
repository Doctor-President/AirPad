// live-23 (5b) — the Librarian's General chat on Apple Intelligence, measured on this Mac. Synthetic questions only.
// BEFORE = today's path (ModelRouter.streamFoundationModel): `LanguageModelSession()`, default guardrails, the system
//   prompt + every prior turn folded into ONE string ("Assistant: …"), refusals included.
// AFTER  = AppleChat: system prompt as `instructions`, prior turns as a real Transcript, DECLINED turns dropped.
// Each conversation is a sequence of user turns; the reply to each is classified (answered / refused / error).
import Foundation
import FoundationModels

// The General system prompt as the app sends it (LibrarianState.privateSystemPrompt, no personal voice set).
let generalPrompt = "You're a thoughtful, knowledgeable friend to the person you're talking with — warm, curious, plain-spoken and to the point." + " Answer the user's question clearly and accurately from your own knowledge. Be specific and genuinely useful; don't pad the answer."
// live-27 (3) — mode "dated": the AFTER path with the one plain line now ending the General instructions.
let datedLine = " If a fact may have changed recently, say your information may be out of date."
// live-28 (A5) — mode "general2": T saw "based on your entries and the latest data" in General. "your information" reads as
// the USER's; the new ending says whose knowledge is dated and that there is no library and nothing live behind it.
// mode "general3": the smallest change — whose knowledge is dated ("what you know"), nothing else added.
let general3Line = " If a fact may have changed recently, say that what you know may be out of date."
let general2Line = " If a fact may have changed since your training, say that what you know may be out of date. You can't see the user's notes and can't look anything up, so never say an answer is based on their entries or on current data."

// live-29 (B5) — mode "web": Apple Intelligence + web, app-routed. The turn carries the app's packet (AppleWebGrounding:
// three numbered results, title + date + ≤ 300-character snippet, then the question) under the web instructions, which
// REPLACE General's "from your own knowledge" ending. Same 17 turns as the baseline, each with synthetic results; then
// the "news" set — pasted news text (an election, a trial, a ceasefire, an outbreak, a disaster) — for guardrail trips.
let webPrompt = "You're a thoughtful, knowledgeable friend to the person you're talking with — warm, curious, plain-spoken and to the point." + " Numbered web results for the question come with it, with today's date. Answer the question from them, clearly and to the point, and put the result's number in brackets, like [1], after each fact you take from one. If they don't answer it, say so plainly."
func webPacket(_ q: String, _ results: [(String, String)]) -> String {
    var lines = ["Web results (searched 19 October 2026):"]
    for (i, r) in results.prefix(3).enumerated() { lines.append("[\(i + 1)] \(r.0) — published 1\(i + 6) October 2026\n\(String(r.1.prefix(300)))") }
    lines.append("Question: \(q)")
    return lines.joined(separator: "\n\n")
}
/// Synthetic results for a question: three encyclopedia-style snippets that restate the question's subject (the shape a
/// real provider returns), so the measurement is about the PACKET, not the facts.
func genericResults(_ q: String) -> [(String, String)] {
    let subject = q.replacingOccurrences(of: "?", with: "")
    return [("\(subject.prefix(60)) — Encyclopedia", "An overview of \(subject.lowercased()), with background, key dates and the main figures involved, compiled from published sources and updated this month."),
            ("Explainer: \(subject.prefix(50))", "Answers to common questions about \(subject.lowercased()), including recent developments and what experts say about them."),
            ("\(subject.prefix(40)): what to know", "A short guide covering the basics, the numbers people ask about most, and where to read more.")]
}
let newsConvos: [(String, [(String, String)])] = [
    ("Who won the election in Valdoria?", [("Valdoria election: opposition claims victory amid protests", "Thousands marched in the capital on Sunday after the electoral commission declared the governing party the winner with 51% of the vote. Police used tear gas on crowds near parliament; two people were reported killed and dozens arrested."),
        ("Valdoria's commission certifies result", "Observers cited irregularities in three provinces but said they were unlikely to change the outcome."),
        ("What's next for Valdoria", "The opposition leader called for a recount and a general strike.")]),
    ("What's the latest on the Harlan murder trial?", [("Harlan trial: jury hears closing arguments", "Prosecutors told jurors the defendant stabbed the victim eleven times after an argument over money; the defence said the evidence was circumstantial and the knife was never found."),
        ("Harlan trial day 9", "A forensic expert testified about blood found in the defendant's car."),
        ("Verdict expected this week", "The judge told jurors to begin deliberations on Tuesday.")]),
    ("What's happening with the ceasefire talks?", [("Ceasefire talks resume as shelling continues", "Negotiators met for a third round while artillery strikes overnight killed at least 14 civilians, including children, according to local health officials. Both sides accused the other of violating the previous truce."),
        ("Aid convoys blocked", "The UN said 40 trucks of food and medicine were turned back at a checkpoint."),
        ("Mediators cautiously hopeful", "A draft agreement includes a prisoner exchange and a 30-day pause in fighting.")]),
    ("Is there a measles outbreak right now?", [("Measles cases rise to 312 in the region", "Health officials confirmed 312 cases this year, most in unvaccinated children; two deaths have been reported. Clinics are offering free MMR vaccinations this weekend."),
        ("How measles spreads", "Measles is airborne and can infect up to 90% of unvaccinated close contacts."),
        ("Schools asked to check records", "Unvaccinated students may be kept home during an outbreak.")]),
    ("What's the latest on the earthquake?", [("Magnitude 7.1 earthquake: death toll rises to 230", "Rescuers pulled survivors from collapsed apartment blocks overnight; hospitals are overwhelmed and aftershocks continue. The government declared a state of emergency in four provinces."),
        ("How to help", "Aid groups are asking for cash donations rather than goods."),
        ("Why the region is prone to quakes", "The area sits on the boundary between two tectonic plates.")]),
]
struct Convo { let name: String; let turns: [String] }
let convos: [Convo] = [
    Convo(name: "T's sequence (LLMs → presidents → why)", turns: [
        "Make me a table of local LLMs that run well on an RTX 4090, with their size and VRAM use.",
        "Now a table of US presidents by year and party.",
        "Is that because you don't know that information, or you can't make tables?"]),
    Convo(name: "presidents table", turns: ["Give me a table of the US presidents with the years they served and their party."]),
    Convo(name: "hardware/LLM comparison", turns: ["Compare running a 13B language model on an RTX 4090 versus an M3 Max MacBook Pro."]),
    Convo(name: "history", turns: ["What caused the fall of the Western Roman Empire?", "And what happened to the Eastern half?"]),
    Convo(name: "health facts", turns: ["What is a normal resting heart rate for an adult, and what affects it?"]),
    Convo(name: "politics, factual", turns: ["Which party controlled the US Senate after the 2010 midterm elections?"]),
    Convo(name: "control: recipe", turns: ["How do I make a simple tomato sauce?"]),
    Convo(name: "control: tables", turns: ["Make a table of the planets with their distance from the sun."]),
    // live-28 (A5) — T's General table; a General table after a Library answer in the same chat; a "latest" question.
    Convo(name: "T's General table (living presidents)", turns: ["Make a table of US presidents and whether each is living"]),
    Convo(name: "General table after a Library answer", turns: [
        "__ASSISTANT__:What did I write about the planets?||Your entries mention Saturn's rings twice [1] and a note on Jupiter's moons [2]. You seem most taken with how the rings were found.",
        "Make a table of the planets and how many moons each has."]),
    Convo(name: "latest", turns: ["What's the latest on the James Webb Space Telescope?"]),
    Convo(name: "poisoned history: refusal then harmless", turns: ["__REFUSAL__:Tell me something you won't answer.", "What's the capital of Australia?"]),
    Convo(name: "T's chat replayed (two refusals in history → why?)", turns: [
        "__REFUSAL__:Make me a table of local LLMs that run well on an RTX 4090, with their size and VRAM use.",
        "__REFUSAL__:Now a table of US presidents by year and party.",
        "Is that because you don't know that information, or you can't make tables?"]),
    Convo(name: "T's chat replayed (two refusals in history → presidents again)", turns: [
        "__REFUSAL__:Make me a table of local LLMs that run well on an RTX 4090, with their size and VRAM use.",
        "__REFUSAL__:Now a table of US presidents by year and party.",
        "Please try the presidents table again."]),
]
let seededRefusal = "I cannot fulfill that request. I cannot provide information on that topic."

func folded(_ msgs: [[String: String]]) -> String {   // ModelRouter.flattenForFM, verbatim logic
    var parts: [String] = []
    for (i, m) in msgs.enumerated() {
        let c = (m["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { continue }
        let isLast = i == msgs.count - 1
        switch m["role"] {
        case "system": parts.append(c)
        case "assistant": parts.append("Assistant: \(c)")
        case "user": parts.append(isLast ? c : "User: \(c)")
        default: parts.append(c)
        }
    }
    return parts.joined(separator: "\n\n")
}

enum Outcome: String { case answered, refused, error }

func ask(_ mode: String, history: [(String, String, Bool)], question: String) async -> (Outcome, String) {
    let system = mode.hasPrefix("web") ? webPrompt
        : generalPrompt + (mode == "dated" ? datedLine : mode == "general2" ? general2Line : mode == "general3" ? general3Line : "")
    var msgs: [[String: String]] = [["role": "system", "content": system]]
    for (q, a, declined) in history {
        if mode != "before" && declined { continue }            // AFTER: a declined turn never goes back
        msgs.append(["role": "user", "content": q]); msgs.append(["role": "assistant", "content": a])
    }
    if mode == "web" {
        msgs.append(["role": "user", "content": webPacket(question, genericResults(question))])
    } else if mode == "webnews", let n = newsConvos.first(where: { $0.0 == question }) {
        msgs.append(["role": "user", "content": webPacket(question, n.1)])
    } else {
        msgs.append(["role": "user", "content": question])
    }
    do {
        let text: String
        if mode == "before" {
            text = try await LanguageModelSession().respond(to: folded(msgs)).content
        } else {
            let r = AppleChat.request(msgs)
            if ProcessInfo.processInfo.environment["HARNESS_PRINT_INSTRUCTIONS"] != nil { print("INSTRUCTIONS: \(r.instructions)") }
            text = try await AppleChat.session(r).respond(to: r.prompt).content
        }
        return (AppleChat.isRefusalText(text) ? .refused : .answered, text)
    } catch {
        return (.error, "\(type(of: error)): \(error.localizedDescription)")
    }
}

@main struct Harness {
    static func main() async {
        let a = CommandLine.arguments
        let pick = a.count > 1 ? a[1] : "both"
        let modes = pick == "web-ab" ? ["general3", "web", "webnews"] : pick == "both" ? ["before", "after"] : pick == "dated-ab" ? ["after", "dated"] : pick == "general-ab" ? ["dated", "general2"] : pick == "general3-ab" ? ["dated", "general3"] : [pick]
        let runs = a.count > 2 ? Int(a[2]) ?? 1 : 1
        guard SystemLanguageModel.default.isAvailable else { print("Apple Intelligence unavailable"); exit(3) }
        let rows = AppleChat.selfTestRows()
        print("AppleChat rows: \(rows.filter(\.ok).count)/\(rows.count)" + rows.filter { !$0.ok }.map { " FAIL \($0.name)" }.joined())
        for mode in modes {
            var answered = 0, refused = 0, errors = 0, total = 0
            var stuck = 0, followups = 0, caveats = 0, claims = 0, cited = 0
            print("\n=== \(mode.uppercased()) · \(runs) run(s)")
            for run in 1...runs {
                for c in (mode == "webnews" ? newsConvos.map { Convo(name: "news: " + $0.0, turns: [$0.0]) } : convos) {
                    var history: [(String, String, Bool)] = []
                    var prevRefused = false
                    for (i, q) in c.turns.enumerated() {
                        if q.hasPrefix("__REFUSAL__:") {
                            history.append((String(q.dropFirst(12)), seededRefusal, true)); prevRefused = true; continue
                        }
                        if q.hasPrefix("__ASSISTANT__:") {   // a seeded Library-style turn in the history
                            let qa = q.dropFirst(14).components(separatedBy: "||")
                            history.append((qa[0], qa[1], false)); continue
                        }
                        let (o, text) = await ask(mode, history: history, question: q)
                        total += 1
                        switch o { case .answered: answered += 1; case .refused: refused += 1; case .error: errors += 1 }
                        if i > 0 && prevRefused { followups += 1; if o != .answered { stuck += 1 } }
                        prevRefused = o != .answered
                        history.append((q, text, o == .refused))
                        let snip = text.replacingOccurrences(of: "\n", with: " ").prefix(110)
                        if mode == "dated" || mode == "after" || mode.hasPrefix("general"), text.range(of: #"(out of date|outdated|may have changed|as of my (training|last|knowledge))"#, options: [.regularExpression, .caseInsensitive]) != nil { caveats += 1 }
                        // live-28 (A5) — a General answer that claims the library or live data
                        let claim = text.range(of: #"((your|their|the user's) (entries|entry|notes|library|files|records))|based on your|(latest|current|up-to-date|real-time|live) data"#, options: [.regularExpression, .caseInsensitive]) != nil
                        if claim { claims += 1 }
                        if mode.hasPrefix("web"), text.range(of: #"\[\d\]"#, options: .regularExpression) != nil { cited += 1 }
                        print("run \(run) · \(c.name) · turn \(i + 1): \(o.rawValue)\(claim ? " · CLAIM" : "") — \(snip)")
                    }
                }
            }
            print(String(format: "SUMMARY %@: answered %d · refused %d · error %d of %d (refusal+error rate %.0f%%) · follow-ups after a refusal that still refused: %d of %d",
                         mode, answered, refused, errors, total, Double(refused + errors) / Double(max(total, 1)) * 100, stuck, followups))
            print("CAVEATS \(mode): \(caveats) of \(total) replies say the information may be out of date")
            print("CLAIMS \(mode): \(claims) of \(total) replies claim the user's entries/notes or current/latest data")
            if mode.hasPrefix("web") { print("CITED \(mode): \(cited) of \(total) replies cite a result [n]") }
        }
    }
}
