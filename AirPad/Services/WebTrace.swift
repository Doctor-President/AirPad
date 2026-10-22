import Foundation

#if DEBUG
/// live-32 (1) — DEBUG `-WebTrace YES`: what a General web turn did, as JSON lines in the app's tmp dir
/// (`tmp/webtrace.jsonl`): the classifier's verdict, the query and how it was made, every search / page read with its
/// results as the app received them, and every model step with the exact messages sent, the time to its first token,
/// its reasoning and its content. Milliseconds are from the turn's start. Inert without the switch; never a key.
final class WebTrace: @unchecked Sendable {
    static let shared = WebTrace()
    let on = UserDefaults.standard.bool(forKey: "WebTrace")
    private let lock = NSLock()
    private var turn = 0
    private var start = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("webtrace.jsonl")

    var ms: Int { lock.lock(); defer { lock.unlock() }; return Int(Date().timeIntervalSince(start) * 1000) }

    func beginTurn(_ question: String) {
        guard on else { return }
        lock.lock(); turn += 1; start = Date(); lock.unlock()
        note("turn", ["question": question])
    }

    func note(_ kind: String, _ fields: [String: Any]) {
        guard on else { return }
        var row = fields
        lock.lock()
        row["kind"] = kind; row["turn"] = turn; row["ms"] = Int(Date().timeIntervalSince(start) * 1000)
        lock.unlock()
        guard JSONSerialization.isValidJSONObject(row),
              var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    /// live-33 — the rerank: every passage's source, score and whether the model saw it; the time it took.
    static func rerank(_ r: (links: [ToolLink], scored: [WebEvidence.Scored], ms: Int, sources: [WebEvidence.Source])) -> [String: Any] {
        let sources = r.sources
        return ["ms": r.ms, "floor": WebEvidence.floor, "kept": r.scored.filter(\.kept).count, "passages": r.scored.map { p in
            ["url": sources.indices.contains(p.source) ? sources[p.source].url : "", "score": Double(p.score), "kept": p.kept,
             "text": String(p.text.prefix(160))] as [String: Any]
        }, "links": links(r.links)]
    }
    static func links(_ links: [ToolLink]) -> [[String: Any]] {
        links.map { l in
            ["title": l.title, "url": l.url, "host": URL(string: l.url)?.host ?? "", "snippet": l.snippet ?? "",
             "published": l.published.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        }
    }
}

/// One model step's timing: the first content / reasoning token and how much of each arrived.
final class WebTraceStep: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var firstContentMs: Int?
    private(set) var firstReasoningMs: Int?
    private(set) var reasoningChars = 0
    private(set) var reasoning = ""
    func content() { lock.lock(); if firstContentMs == nil { firstContentMs = WebTrace.shared.ms }; lock.unlock() }
    func reasoning(_ r: String) {
        lock.lock(); if firstReasoningMs == nil { firstReasoningMs = WebTrace.shared.ms }
        reasoningChars += r.count; if reasoning.count < 4000 { reasoning += r }; lock.unlock()
    }
}
#endif
