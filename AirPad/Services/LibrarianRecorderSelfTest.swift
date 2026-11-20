#if DEBUG
import Foundation

/// `-LibrarianRecorderSelfTest` (with a library loaded, e.g. `-SampleSeedDemo -EmbedCPUOnly`) — sweep 2a.
/// The Librarian recorder keeps IDs, scores, counts and timings and NOTHING of the library's words:
///   • the value rules (UUIDs kept, anything else hashed; labels from a closed character set);
///   • a REAL Library turn (retrieval, packet, `ChatSession.send`; the answer is the DEBUG stub) is recorded, saved,
///     and the saved file is scanned for every entry title, three-word runs of the entry that was sent, and the
///     question — none may appear; the scan's own control (the same scan over the packet text) must find them;
///   • "Include my question" on → the question is in the file, and still no entry text.
enum LibrarianRecorderSelfTest {
    @MainActor static func run(store: CorpusStore) async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let d = UserDefaults.standard
        let priorOn = d.object(forKey: LibrarianRecorder.onKey), priorQ = d.object(forKey: LibrarianRecorder.questionKey)
        let priorStub = d.string(forKey: "StubAnswerModels")
        defer {
            d.set(priorOn, forKey: LibrarianRecorder.onKey); d.set(priorQ, forKey: LibrarianRecorder.questionKey)
            if let priorStub { d.set(priorStub, forKey: "StubAnswerModels") } else { d.removeObject(forKey: "StubAnswerModels") }
        }

        // 1. Value rules.
        let u = UUID().uuidString
        row("a UUID is kept", LibrarianRecorder.safeID(u) == u)
        row("card: / full: prefixes and a numeric suffix are kept", LibrarianRecorder.safeID("card:" + u) == "card:" + u
            && LibrarianRecorder.safeID("full:" + u) == "full:" + u && LibrarianRecorder.safeID(u + "-12") == u + "-12")
        let slug = LibrarianRecorder.safeID("bolex-h16-notes")
        row("a readable ID is hashed", slug.hasPrefix("x") && slug.count == 13 && !slug.contains("bolex"), slug)
        row("a UUID followed by words is hashed", !LibrarianRecorder.safeID(u + "-secret-title").contains("secret"))
        row("a label with a space or over 64 characters is dropped", LibrarianRecorder.safeLabel("My private title") == "?"
            && LibrarianRecorder.safeLabel(String(repeating: "a", count: 65)) == "?")
        row("a route / model label passes", LibrarianRecorder.safeLabel("read(pin)") == "read(pin)" && LibrarianRecorder.safeLabel("qwen3:4b") == "qwen3:4b")

        // 2. A real Library turn with the recorder on, the question NOT included.
        let room = store.nodes(in: .corpus).filter { $0.title.split(separator: " ").count >= 2 }
        var target: Node? = nil, targetText = ""
        for n in room.prefix(60) {
            let t = await store.fullEntryText(nodeID: n.id)
            if t.split(whereSeparator: { $0.isWhitespace }).count >= 30 { target = n; targetText = t; break }
        }
        guard let target else {
            return "[LibrarianRecorderSelfTest] FAIL — 0/1\nFAIL no entry with a two-word title and 30 words of text is loaded (run with -SampleSeedDemo -EmbedCPUOnly)"
        }
        d.set(true, forKey: LibrarianRecorder.onKey)
        d.set(false, forKey: LibrarianRecorder.questionKey)
        d.set("apple", forKey: "StubAnswerModels")
        LibrarianRecorder.shared.reset()
        let question = "What does \"\(target.title)\" say?"
        let librarian = LibrarianState()
        librarian.selectedScope = .corpus
        librarian.corpusAware = true
        let chat = ChatSession()
        await librarian.groundedSend(query: question, store: store, chat: chat)
        let turn = LibrarianRecorder.shared.snapshot().last ?? [:]
        let sent = turn["sent"] as? [[String: Any]] ?? []
        row("the turn was recorded and closed", turn["totalMs"] != nil && turn["mode"] as? String == "library", "keys=\(turn.keys.sorted().joined(separator: ","))")
        row("the named entry was sent (the scan has something to find)", sent.contains { ($0["node"] as? String) == LibrarianRecorder.safeID(target.id) },
            "decision=\(turn["decision"] ?? "?") sent=\(sent.count)")
        row("timings and the answer are recorded", turn["firstTokenMs"] != nil && turn["streamEndMs"] != nil && (turn["answer"] as? [String: Any])?["chars"] != nil)
        row("the question's size is recorded, its words are not", turn["questionChars"] as? Int == question.count && turn["question"] == nil)

        // The scan: every entry title, three-word runs of the sent entry, the question.
        var needles: [String] = store.nodes.map(\.title).filter { $0.count >= 8 || $0.split(separator: " ").count >= 2 }
        let words = targetText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var i = 0
        while i + 3 <= words.count, needles.count < 4_000 { needles.append(words[i..<(i + 3)].joined(separator: " ")); i += 2 }
        needles.append(question)
        needles = needles.map { $0.lowercased() }.filter { $0.count >= 8 }
        func hits(_ text: String) -> Int { let t = text.lowercased(); return needles.filter { t.contains($0) }.count }

        guard let url = LibrarianRecorder.shared.save(reason: "selftest"), let saved = try? String(contentsOf: url, encoding: .utf8) else {
            row("the recording saves", false)
            return report(rows)
        }
        row("the recording saves", saved.contains("\"kind\" : \"librarian\""), url.lastPathComponent)
        let control = hits((librarian.debugLastTurn?.modelText ?? "") + "\n" + question)
        row("control: the same scan finds the entry's words in the packet", control >= 5, "\(control) of \(needles.count) needles")
        let leaked = hits(saved)
        row("the saved file holds none of the library's words and not the question", leaked == 0, "\(leaked) hits, \(saved.count) bytes")

        // 3. "Include my question" on.
        d.set(true, forKey: LibrarianRecorder.questionKey)
        let chat2 = ChatSession()
        await librarian.groundedSend(query: question, store: store, chat: chat2)
        let turn2 = LibrarianRecorder.shared.snapshot().last ?? [:]
        row("with the switch on, the question is recorded", turn2["question"] as? String == question)
        if let url2 = LibrarianRecorder.shared.save(reason: "selftest"), let saved2 = try? String(contentsOf: url2, encoding: .utf8) {
            let titleFree = saved2.replacingOccurrences(of: question, with: "")
            // the question itself names the title; everything else must still be clean
            row("…and still no entry text", hits(titleFree.replacingOccurrences(of: question.replacingOccurrences(of: "\"", with: "\\\""), with: "")) == 0)
            try? FileManager.default.removeItem(at: url2)
        } else { row("…and still no entry text", false, "no file") }
        try? FileManager.default.removeItem(at: url)

        // 4. Off → nothing is kept.
        d.set(false, forKey: LibrarianRecorder.onKey)
        LibrarianRecorder.shared.reset()
        LibRec.begin(); LibRec.set("mode", .token("library")); LibRec.end()
        row("switched off, nothing is recorded", LibrarianRecorder.shared.snapshot().isEmpty || ProcessInfo.processInfo.arguments.contains("-LibrarianRecorder"))
        return report(rows)
    }

    private static func report(_ rows: [(String, Bool, String)]) -> String {
        let pass = rows.filter { $0.1 }.count
        var out = "[LibrarianRecorderSelfTest] \(pass == rows.count ? "PASS" : "FAIL") — \(pass)/\(rows.count)"
        for r in rows { out += "\n\(r.1 ? "PASS" : "FAIL") \(r.0)\(r.2.isEmpty ? "" : " — \(r.2)")" }
        return out
    }
}
#endif
