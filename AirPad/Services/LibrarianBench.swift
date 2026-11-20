#if DEBUG
import Foundation

/// Sweep 2a — THE LIBRARIAN BENCHMARK (DEBUG only): question types × libraries × routes, graded on the delivered
/// answer by `scripts/librarian/bench.py`.
///
///   -LibrarianBench <cases.json>      the cases (chats of turns; `scripts/librarian/benchmark/`)
///   -LibrarianBenchOut <dir>          where `results.json` goes (a Mac path from the Simulator)
///   -LibrarianBenchOnly F1,G2         only these turn ids (their chats run whole up to the last wanted turn)
///   -UITestSeedBenchNotes <notes.json> (with -UITestLibrary) plants the benchmark's invented notes in the scratch library
///
/// Unlike `-LibrarianGauntlet` it reads its cases from the file (one source of truth with the grader) and runs on
/// WHATEVER route is active — Apple Intelligence, the own-server route (`-DebugEndpointURL` / `-DebugEndpointModel`) or
/// a scratch Host (`-DebugHost*`) — through the real `LibrarianState.groundedSend` → `ChatSession.send`. Each turn's
/// row carries the answer, the chips, the Librarian recorder's record (IDs, scores, cut-offs, timings, tokens) and, for
/// the grader's support check, the packet. Titles are written only for the benchmark's own planted notes and the
/// bundled Sample Library — never for a user library (the T-corpus fixture rows are IDs only).
enum LibrarianBench {
    static let plantedPrefix = "BE7C0000-0000-4000-8000-"

    /// Called from the `-UITestLibrary` seeding stage. Written once per scratch (the marker is the last thing written).
    static func seedNotes(_ root: URL) {
        guard let path = UserDefaults.standard.string(forKey: "UITestSeedBenchNotes"), !path.isEmpty else { return }
        let fm = FileManager.default
        let marker = root.appendingPathComponent("bench-notes.done")
        guard !fm.fileExists(atPath: marker.path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notes = obj["notes"] as? [[String: Any]] else {
            print("[LibrarianBench] seed: cannot read \(path)"); return
        }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = TimeZone(identifier: "UTC")
        let iso = ISO8601DateFormatter()
        for (i, n) in notes.enumerated() {
            let id = String(format: "\(plantedPrefix)%012d", i + 1)
            let dir = root.appendingPathComponent("nodes/\(id)")
            try? fm.createDirectory(at: dir.appendingPathComponent("items"), withIntermediateDirectories: true)
            let created = (n["date"] as? String).flatMap { day.date(from: $0) }?.addingTimeInterval(12 * 3600) ?? Date(timeIntervalSince1970: 1_760_000_000)
            let title = n["title"] as? String ?? "", text = n["text"] as? String ?? ""
            var items: [NodeItem] = []
            if (n["kind"] as? String) == "link" {
                let url = n["url"] as? String ?? "https://example.org/\(i)"
                var link = NodeItem(id: id + "-link", type: .link, createdAt: created)
                link.url = url; link.title = title; link.isExpanded = true
                let li: [String: Any] = ["id": id + "-li", "url": url, "title": title, "description": n["summary"] as? String ?? "",
                                         "capturedAt": iso.string(from: created), "captured_at": iso.string(from: created),
                                         "snapshotText": text, "snapshot_text": text,
                                         "snapshotAt": iso.string(from: created), "snapshot_at": iso.string(from: created),
                                         "snapshotWordCount": text.split(separator: " ").count, "snapshot_word_count": text.split(separator: " ").count]
                if let d = try? JSONSerialization.data(withJSONObject: li), let item = try? JSONDecoder.airPad.decode(LinkItem.self, from: d) {
                    link.linkItems = [item]
                } else { print("[LibrarianBench] seed: link item for '\(n["key"] ?? "?")' did not decode") }
                items = [link]
            } else {
                items = [NodeItem(id: id + "-note", type: .text, createdAt: created, content: text,
                                  displayName: nil, isExpanded: true, updatedAt: created)]
            }
            let node = Node(id: id, createdAt: created, updatedAt: created, title: title, summary: n["summary"] as? String ?? "",
                            tags: [], items: items, entrySchemaVersion: 4)
            try? JSONEncoder.airPad.encode(node).write(to: dir.appendingPathComponent("node.json"), options: .atomic)
        }
        // key → id, for the grader (the keys are the benchmark's own).
        let map = Dictionary(uniqueKeysWithValues: notes.enumerated().compactMap { i, n in (n["key"] as? String).map { ($0, String(format: "\(plantedPrefix)%012d", i + 1)) } })
        if let d = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: root.appendingPathComponent("bench-notes.json"), options: .atomic)
        }
        try? Data("\(notes.count)".utf8).write(to: marker, options: .atomic)
        print("[LibrarianBench] seeded \(notes.count) planted notes at \(root.path)")
    }
}

extension CorpusStore {
    func runLibrarianBench() async {
        let d = UserDefaults.standard
        guard let casesPath = d.string(forKey: "LibrarianBench"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: casesPath)),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chats = doc["chats"] as? [[String: Any]] else {
            NSLog("[LibrarianBench] ABORT — pass -LibrarianBench <cases.json>"); NSLog("[LibrarianBench] done"); return
        }
        let outDir = URL(fileURLWithPath: d.string(forKey: "LibrarianBenchOut") ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let only = Set((d.string(forKey: "LibrarianBenchOnly") ?? "").split(separator: ",").map(String.init))

        // The index must be whole before the first question (a freshly seeded library has none).
        let t0 = Date()
        await rebuildBlockIndexNow()
        await backfillCatalog()
        var indexed = 0, carded = 0
        for n in nodes {
            if await blockIndex(forNodeID: n.id) != nil { indexed += 1 }
            if await card(forNodeID: n.id)?.embedding?.isEmpty == false { carded += 1 }
        }
        NSLog("[LibrarianBench] index ready in %.0fs: nodes=%d withBlocks=%d withCardVector=%d", Date().timeIntervalSince(t0), nodes.count, indexed, carded)

        // The recorder is the benchmark's evidence: on for the run, question text off (cases carry it).
        let priorOn = d.object(forKey: LibrarianRecorder.onKey)
        d.set(true, forKey: LibrarianRecorder.onKey)
        defer { d.set(priorOn, forKey: LibrarianRecorder.onKey) }
        LibrarianRecorder.shared.reset()

        let routeName: String
        switch ModelRouter.active {
        case .foundationModel: routeName = "apple"
        case .ollama: routeName = "server"
        case .host: routeName = "host"
        case .local: routeName = "local"
        }
        let librarian = LibrarianState()
        librarian.selectedScope = .corpus
        await librarian.refreshActiveModel()
        NSLog("[LibrarianBench] START route=%@ model=%@ window=%d nodes=%d chats=%d webKey=%@ wikipedia=%@", routeName, librarian.activeModelLabel,
              ModelRouter.contextWindowTokens, nodes.count, chats.count, WebSearchBackend.hasKey ? "yes" : "no", WikipediaGrounding.isOn ? "on" : "off")

        func mayName(_ id: String) -> Bool { id.hasPrefix(LibrarianBench.plantedPrefix) || sampleNodeIDs.contains(id) }
        var rows: [[String: Any]] = []
        for chatSpec in chats {
            let turns = chatSpec["turns"] as? [[String: Any]] ?? []
            if !only.isEmpty, !turns.contains(where: { only.contains($0["id"] as? String ?? "") }) { continue }
            let lastWanted = only.isEmpty ? turns.count - 1 : (turns.lastIndex { only.contains($0["id"] as? String ?? "") } ?? -1)
            let chat = ChatSession()
            librarian.corpusAware = true
            for (ti, turn) in turns.enumerated() where ti <= lastWanted {
                let id = turn["id"] as? String ?? "?"
                let question = turn["question"] as? String ?? ""
                let general = (turn["mode"] as? String) == "general"
                let action = turn["action"] as? String ?? "send"
                librarian.corpusAware = !general
                NSLog("[LibrarianBench] TURN %@ BEGIN (%@, %@)", id, general ? "general" : "library", action)
                let started = Date()
                switch action {
                case "acceptWebOffer": await librarian.acceptWebSearchOffer(store: self, chat: chat)
                case "acceptReadOffer": await librarian.acceptReadInFullOffer(store: self, chat: chat)
                default: await librarian.groundedSend(query: question, store: self, chat: chat)
                }
                let elapsed = Date().timeIntervalSince(started)
                let answerMsg = chat.messages.last
                let answered = answerMsg?.role == .assistant
                let answer = answered ? (answerMsg?.text ?? "") : ""
                let chips: [[String: Any]] = (answered ? (answerMsg?.citations ?? []) : []).map { c in
                    var row: [String: Any] = ["index": c.index, "nodeID": c.nodeID ?? "", "url": c.url ?? ""]
                    if let nid = c.nodeID, mayName(nid) { row["title"] = c.title }
                    return row
                }
                let rec = LibrarianRecorder.shared.snapshot().last ?? [:]
                let plan = general ? nil : librarian.debugLastTurn
                var row: [String: Any] = [
                    "id": id, "chat": chatSpec["id"] as? String ?? "", "mode": general ? "general" : "library", "action": action,
                    "route": routeName, "model": librarian.activeModelLabel, "elapsedSec": (elapsed * 10).rounded() / 10,
                    "answer": answer, "chips": chips, "error": chat.lastError ?? "",
                    "receipt": answerMsg?.readReceipt.map { ChatTranscript.readReceiptText($0) } ?? "",
                    "generalKnowledgeLine": answerMsg?.generalKnowledge == true, "declined": answerMsg?.declined == true,
                    "datedLine": answerMsg?.datedKnowledge == true, "unconfirmedLine": answerMsg?.searchUnconfirmed == true,
                    "provenanceCaption": answerMsg?.provenance?.caption ?? "",
                    "webOffer": librarian.pendingWebSearchOffer != nil, "readOffer": librarian.pendingReadInFullOffer != nil,
                    "record": rec,
                ]
                if let plan, (rec["decision"] as? String) != "none(subject)" {
                    row["planMode"] = plan.mode
                    // The packet, for the grader's "is each citation supported" check. Local file only (build/, ignored).
                    row["packet"] = plan.modelText
                }
                rows.append(row)
                NSLog("[LibrarianBench] TURN %@ END %.1fs decision=%@ chips=%d answerChars=%d%@", id, elapsed,
                      (rec["decision"] as? String) ?? (rec["generalTool"] as? String) ?? "?", chips.count, answer.count,
                      answer.isEmpty ? " EMPTY (\(chat.lastError ?? "no error"))" : "")
                // Written after every turn, so a hang or a kill keeps what ran.
                var names: [String: String] = [:]
                for n in nodes where mayName(n.id) { names[n.id] = n.title }
                let out: [String: Any] = ["cases": casesPath, "route": routeName, "model": librarian.activeModelLabel,
                                          "window": ModelRouter.contextWindowTokens, "nodes": nodes.count,
                                          "webKey": WebSearchBackend.hasKey, "wikipedia": WikipediaGrounding.isOn,
                                          "at": ISO8601DateFormatter().string(from: Date()), "titles": names, "rows": rows]
                if let j = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                    try? j.write(to: outDir.appendingPathComponent("results.json"), options: .atomic)
                }
            }
        }
        NSLog("[LibrarianBench] RESULT %d turns → %@", rows.count, outDir.appendingPathComponent("results.json").path)
        NSLog("[LibrarianBench] done")
    }
}
#endif
