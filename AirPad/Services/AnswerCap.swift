import Foundation

/// live-28 (1) — every answer is capped, so a model that loops can't hold the Mac and leave the phone waiting
/// (gauntlet DK1: qwen3:4b generated for 10.6 minutes on a presidents table; at temperature 0 it repeats one row until
/// it's stopped). Three caps, any of which stops the answer and keeps what arrived plus one honest line:
/// - `maxTokens` → `options.num_predict` on the Host request, sized to the route. Ollama enforces it on the Mac, so
///   it bounds the Mac's work even when the phone has gone (the Host keeps generating a held answer after a drop).
/// - `RunawayGuard` — the same substantial line, or the same long phrase, coming back again and again.
/// - `wallClockSeconds` — the whole turn.
enum AnswerCap {
    enum Route: String, Sendable { case general, library, table }

    /// Why an answer stopped early. Saved with the answer (`ChatSession.Message.stopped`).
    enum Stop: String, Codable, Sendable { case tooLong, user }

    static let tooLongLine = "Stopped: the answer ran too long"
    static let userLine = "Stopped"
    static func line(for stop: Stop) -> String { stop == .tooLong ? tooLongLine : userLine }

    /// A table request gets the big budget: a 46-row table is ~1,300 tokens, so 4,096 finishes it with room to spare.
    static func route(question: String, library: Bool) -> Route {
        if question.range(of: #"\b(tables?|tabulate|spreadsheet|chart|grid|lists?|each|every|all)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil { return .table }
        return library ? .library : .general
    }

    /// The answer budget in tokens (`options.num_predict`). Generous: a capped answer is a failure, so the cap sits
    /// well above what a real answer needs (Library syntheses run ~300–1,000 tokens). A thought process counts
    /// against `num_predict` too, so Thinking on adds its own 4,096.
    static func maxTokens(_ route: Route, think: Bool) -> Int? {
        let answer: Int
        switch route {
        case .general, .library: answer = 3072
        case .table: answer = 4096
        }
        return answer + (think ? 4096 : 0)
    }

    /// The whole turn, from send to the last token. DEBUG `-AnswerWallClockSec <n>` shortens it for the stub rows.
    static var wallClockSeconds: TimeInterval {
        #if DEBUG
        let v = UserDefaults.standard.double(forKey: "AnswerWallClockSec")
        if v > 0 { return v }
        #endif
        return 300
    }
}

/// Watches an answer as it streams and says when it has started looping. Two signals, both verbatim:
/// - a substantial line (≥ 20 non-space characters, not a table rule or a code fence) seen a 3rd time, or 6 lines that
///   repeat an earlier one (a model "correcting" its table by writing it out again);
/// - a 12-word phrase made of real words (≥ 5 distinct words of 3+ letters) seen a 4th time (a loop with no line
///   breaks). A legit table repeats short cells ("| No | No |"), never whole rows.
struct RunawayGuard {
    private(set) var fired = false
    private var line = ""
    private var lineCounts: [String: Int] = [:]
    private var repeatedLines = 0
    /// The last counted line, so a table's header row can be taken back when its `|---|` rule arrives: several tables
    /// may share a header (a labs summary, one per panel), and a header is never content.
    private var lastCounted: (key: String, wasRepeat: Bool)?
    private var word = ""
    private var window: [String] = []
    private var phraseCounts: [String: Int] = [:]

    /// Feed the next streamed piece. Returns true once the answer is looping (and stays true).
    mutating func feed(_ delta: String) -> Bool {
        guard !fired else { return true }
        for ch in delta {
            if ch.isNewline { endLine() } else { line.append(ch) }
            if ch.isWhitespace { endWord() } else { word.append(ch) }
            if fired { return true }
        }
        return fired
    }

    private mutating func endLine() {
        let key = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        line = ""
        let ink = key.filter { !$0.isWhitespace }
        if ink.count >= 3, ink.allSatisfy({ "|-:".contains($0) }) {
            // A table rule: the line before it was the header — take it back.
            if let last = lastCounted, last.key.hasPrefix("|") {
                lineCounts[last.key, default: 1] -= 1
                if last.wasRepeat { repeatedLines -= 1 }
            }
            lastCounted = nil
            return
        }
        guard !ink.isEmpty else { return }
        guard ink.count >= 20, !ink.hasPrefix("```") else { lastCounted = nil; return }
        let n = (lineCounts[key] ?? 0) + 1
        lineCounts[key] = n
        if n >= 2 { repeatedLines += 1 }
        lastCounted = (key, n >= 2)
        if n >= 3 || repeatedLines >= 6 { fired = true }
    }

    private mutating func endWord() {
        guard !word.isEmpty else { return }
        window.append(word)
        word = ""
        if window.count > 12 { window.removeFirst() }
        guard window.count == 12 else { return }
        let real = Set(window.map { $0.lowercased().filter(\.isLetter) }.filter { $0.count >= 3 })
        guard real.count >= 5 else { return }
        let key = window.joined(separator: " ")
        let n = (phraseCounts[key] ?? 0) + 1
        phraseCounts[key] = n
        if n >= 4 { fired = true }
    }
}

#if DEBUG
/// `-AnswerCapSelfTest` — synthetic answers only. The guard fires on a row loop, a table written out again and a loop
/// with no line breaks; it stays quiet on a 46-row table, a yes/no grid and plain prose, whatever the chunking. The
/// budgets by route, the Host bodies (`options.num_predict`), the `finish_reason: "length"` frame, and the line.
enum AnswerCapSelfTest {
    static func run() -> String {
        var rows: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { rows.append((name, ok)) }

        func feedAll(_ text: String, chunk: Int = 7) -> (fired: Bool, at: Int) {
            var g = RunawayGuard(); var i = text.startIndex; var n = 0
            while i < text.endIndex {
                let j = text.index(i, offsetBy: chunk, limitedBy: text.endIndex) ?? text.endIndex
                n += text.distance(from: i, to: j)
                if g.feed(String(text[i..<j])) { return (true, n) }
                i = j
            }
            return (false, n)
        }

        // A synthetic 46-row table (invented names), one name twice with different terms, as a real list has.
        let header = "As of my training data, here is the list:\n\n| # | Mayor | Term | Living? |\n|---|-------|------|---------|\n"
        var table = header
        for k in 1...46 {
            let name = k == 24 ? "Ada Pellworth" : (k == 22 ? "Ada Pellworth" : "Mayor \(["Corin", "Odile", "Pim", "Rasmus", "Tove", "Ulla"][k % 6]) \(k)")
            table += "| \(k) | \(name) | \(1789 + 4 * k)–\(1793 + 4 * k) | \(k > 40 ? "Yes" : "No") |\n"
        }
        table += "\nThe last six are living as of my training data.\n"
        let legit = feedAll(table)
        check("a 46-row table (a name twice, different terms) doesn't fire", !legit.fired)

        // greedy loop: the same row until the cap (what temperature 0 did)
        let loopRow = "| 23 | Mayor Pim 23 | 1881–1885 | No |\n"
        let firstRows = table.dropFirst(header.count).split(separator: "\n").prefix(15).joined(separator: "\n") + "\n"
        let loop = header + firstRows + String(repeating: loopRow, count: 60)
        let lr = feedAll(loop)
        let thirdCopyEnd = (loop.range(of: loopRow)?.upperBound).map { loop.distance(from: loop.startIndex, to: $0) + 2 * loopRow.count } ?? 0
        check("a row repeated until the cap fires", lr.fired)
        check("… by its 3rd copy (\(lr.at) ≤ \(thirdCopyEnd) chars)", lr.fired && lr.at <= thirdCopyEnd + 8)

        // self-correction loop: the table, "a mistake", the same table again, again…
        let first12 = table.split(separator: "\n", omittingEmptySubsequences: false).prefix(16).joined(separator: "\n")
        let correction = first12 + "\n\nNote: there is a mistake in the table above. Corrected table:\n\n" + first12
            + "\n\nStill wrong — final corrected table:\n\n" + first12
        let cr = feedAll(correction)
        let secondStart = correction.distance(from: correction.startIndex, to: correction.range(of: "Corrected table:")!.upperBound)
        check("a table written out again fires", cr.fired)
        check("… within the second copy (\(cr.at) < \(secondStart + first12.count))", cr.fired && cr.at < secondStart + first12.count)

        // a labs-style answer: three tables under one shared header, one per panel
        var panels = "Here are your results by panel.\n"
        for (k, panel) in ["Blood count", "Metabolic", "Lipids"].enumerated() {
            panels += "\n**\(panel)**\n\n| Test | Value | Reference Range | Status |\n|------|-------|-----------------|--------|\n"
            for r in 1...4 { panels += "| Marker \(k)-\(r) | \(10 + r) | 5–20 | Normal |\n" }
        }
        check("three tables sharing one header row don't fire", !feedAll(panels).fired)

        // a yes/no grid: short repeated cells, every row its own
        var grid = "| Feature | A | B | C | D | E | F |\n|---|---|---|---|---|---|---|\n"
        for k in 1...14 { grid += "| Feature \(k) | No | No | No | No | No | \(k % 3 == 0 ? "Yes" : "No") |\n" }
        check("a yes/no grid doesn't fire", !feedAll(grid).fired)

        // a loop with no line breaks
        let sentence = "I think the answer is that the tide comes in twice a day because the moon pulls on the sea. "
        check("a sentence looping with no line breaks fires", feedAll("Here is my answer. " + String(repeating: sentence, count: 12)).fired)

        // plain prose, varied
        let words = ["tide", "pool", "rock", "anemone", "crab", "kelp", "shore", "wave", "salt", "barnacle", "urchin", "mussel",
                     "starfish", "limpet", "sculpin", "algae", "sand", "foam", "current", "moon"]
        var prose = ""
        for k in 0..<90 {
            prose += "The \(words[k % 20]) near the \(words[(k * 7 + 3) % 20]) shows \(words[(k * 3 + 1) % 20]) in sentence \(k), "
            prose += k % 4 == 3 ? "which matters.\n" : "and then "
        }
        check("plain prose doesn't fire", !feedAll(prose).fired)
        check("chunking doesn't matter (1-char and 64-char feeds agree)",
              feedAll(loop, chunk: 1).fired && feedAll(loop, chunk: 64).fired && !feedAll(table, chunk: 1).fired && !feedAll(table, chunk: 64).fired)

        // budgets by route
        check("the presidents question is a table request",
              AnswerCap.route(question: "Make a table of US presidents and whether each is living", library: false) == .table)
        check("a plain General question is General", AnswerCap.route(question: "What is a tide pool?", library: false) == .general)
        check("a Library turn is Library", AnswerCap.route(question: "What did I write about kelp?", library: true) == .library)
        check("a table request in Library is still a table", AnswerCap.route(question: "Put my coffee entries in a table", library: true) == .table)
        let g = AnswerCap.maxTokens(.general, think: false), l = AnswerCap.maxTokens(.library, think: false)
        let t = AnswerCap.maxTokens(.table, think: false), tt = AnswerCap.maxTokens(.table, think: true)
        check("budgets: General 3072, Library 3072, table 4096 (got \(String(describing: g)), \(String(describing: l)), \(String(describing: t)))",
              g == 3072 && l == 3072 && t == 4096)
        check("Thinking on adds 4096 for the thought process (table → \(String(describing: tt)))", tt == 8192)
        // a 46-row table's size against its budget (≈ 3.2 chars a token, conservative for English + pipes)
        let tableTokens = Int(Double(table.count) / 3.2)
        check("a 46-row table (~\(tableTokens) tokens) is under half the table budget", t.map { tableTokens * 2 < $0 } ?? false)

        // the Host request bodies carry num_predict next to num_ctx
        let msgs: [ModelRouter.WireMessage] = [["role": "system", "content": "s"], ["role": "user", "content": "u"]]
        let hb = ModelRouter.hostChatBody(model: "m", messages: msgs, numCtx: 20480, maxTokens: 4096, think: false, requestID: "r")
        let hopts = hb["options"] as? [String: Any]
        check("Host chat body: options.num_predict 4096 + num_ctx 20480",
              hopts?["num_predict"] as? Int == 4096 && hopts?["num_ctx"] as? Int == 20480 && hb["requestID"] as? String == "r")
        let ab = ModelRouter.hostAgentBody(model: "m", messages: [["role": "user", "content": "u"]], tools: nil, think: false, maxTokens: 3072)
        check("Host search-turn body: options.num_predict 3072", (ab["options"] as? [String: Any])?["num_predict"] as? Int == 3072)

        // the Host's terminal frame: finish_reason "length" (Ollama hit num_predict) reaches the session
        let frames = "data: {\"choices\":[{\"delta\":{\"content\":\"| 1 | A |\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n"
        let parsed = ModelRouter.debugInnerSSE(frames)
        check("finish_reason \"length\" → .finished(\"length\") after the content",
              parsed.count == 2 && { if case .finished("length") = parsed[1] { return true }; return false }())
        let agent = ModelRouter.debugInnerAgentSSE(frames)
        check("… and on the search turn: hitLength", agent.hitLength && agent.content == "| 1 | A |")

        // the stop is saved with the answer and reads as one honest line
        var m = ChatSession.Message(role: .assistant, text: "partial")
        m.stopped = .tooLong
        let back = (try? JSONEncoder().encode(m)).flatMap { try? JSONDecoder().decode(ChatSession.Message.self, from: $0) }
        check("Message.stopped survives a save", back?.stopped == .tooLong)
        check("the line reads \"\(AnswerCap.tooLongLine)\"", AnswerCap.line(for: .tooLong) == "Stopped: the answer ran too long")
        check("the wall-clock turn limit is 300 s", UserDefaults.standard.double(forKey: "AnswerWallClockSec") > 0 || AnswerCap.wallClockSeconds == 300)

        let pass = rows.filter(\.1).count
        return "\(pass == rows.count ? "PASS" : "FAIL") — \(pass)/\(rows.count)\n" + rows.map { "  \($0.1 ? "PASS" : "FAIL")  \($0.0)" }.joined(separator: "\n")
    }
}
#endif
