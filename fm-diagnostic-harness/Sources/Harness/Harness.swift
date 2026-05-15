import Foundation
import FoundationModels

// MARK: - Seeded RNG

/// SplitMix64 — same shape as the AirPad CorpusStore RNG so behavior is
/// portable if T cross-checks. Seeded with 42 per the brief.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}

// MARK: - Per-node result row

struct ResultRow: Encodable {
    let nodeID: String
    let title: String
    let contentTruncated: String
    let currentTags: [String]
    let fmRawTags: [String]
    let postFilterTags: [String]
    let fmTitle: String
    let fmSummary: String
    let fmMood: String
    let fmDomain: String
    let latencyMs: Int
    let error: String?
}

// MARK: - Helpers

func truncateForLog(_ s: String, max: Int = 200) -> String {
    if s.count <= max { return s }
    return String(s.prefix(max)) + "…"
}

func loadCorpus(rootURL: URL) throws -> [Node] {
    let nodesDir = rootURL.appendingPathComponent("nodes")
    let entries = try FileManager.default.contentsOfDirectory(atPath: nodesDir.path).sorted()
    var nodes: [Node] = []
    for entry in entries {
        let p = nodesDir.appendingPathComponent("\(entry)/node.json")
        guard FileManager.default.fileExists(atPath: p.path) else { continue }
        let data = try Data(contentsOf: p)
        if let node = try? JSONDecoder().decode(Node.self, from: data) {
            nodes.append(node)
        } else {
            print("[loadCorpus] decode failed: \(entry)")
        }
    }
    return nodes
}

func sampleEligible(_ nodes: [Node], k: Int, seed: UInt64) -> [(Node, String)] {
    let eligible: [(Node, String)] = nodes.compactMap { n in
        let c = extractContent(from: n)
        if c.count < 20 { return nil }
        return (n, c)
    }.sorted { $0.0.id < $1.0.id }
    var rng = SeededRNG(seed: seed)
    var arr = eligible
    // Fisher-Yates shuffle in place
    for i in stride(from: arr.count - 1, to: 0, by: -1) {
        let j = Int(rng.next() % UInt64(i + 1))
        arr.swapAt(i, j)
    }
    return Array(arr.prefix(k))
}

// MARK: - Variant runners

struct VariantA1Output {
    let title: String
    let summary: String
    let mood: String
    let domain: String
    let rawTags: [String]
    let postFilterTags: [String]
    let latencyMs: Int
    let error: String?
}

struct VariantA2Output {
    let title: String
    let summary: String
    let mood: String
    let domain: String
    let rawTags: [String]
    let postFilterTags: [String]
    let latencyMs: Int
    let error: String?
}

func runA1(content: String, vocabulary: [String]) async -> VariantA1Output {
    let prompt = buildPrompt(content: content, vocabulary: vocabulary)
    let vocabSet = Set(vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A1Result.self)
        let r = response.content
        let raw = r.tags
        let filtered = Array(raw.filter { !$0.isEmpty && vocabSet.contains($0) }.prefix(5))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return VariantA1Output(
            title: r.title, summary: r.summary, mood: r.mood, domain: r.domain,
            rawTags: raw, postFilterTags: filtered, latencyMs: ms, error: nil
        )
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let err = "\(type(of: error)): \(error)"
        return VariantA1Output(
            title: "", summary: "", mood: "", domain: "",
            rawTags: [], postFilterTags: [], latencyMs: ms, error: err
        )
    }
}

func runA2(content: String, vocabulary: [String]) async -> VariantA2Output {
    let prompt = buildPrompt(content: content, vocabulary: vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A2Result.self)
        let r = response.content
        let raw = r.tags.map { $0.rawValue }
        // For A2, post-filter is by construction equal to raw — every emitted
        // tag is already a valid vocabulary literal. Still apply prefix(5)
        // and dedupe to mirror A1's downstream shape.
        var seen = Set<String>()
        var filtered: [String] = []
        for t in raw where !seen.contains(t) {
            seen.insert(t); filtered.append(t)
            if filtered.count == 5 { break }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return VariantA2Output(
            title: r.title, summary: r.summary, mood: r.mood, domain: r.domain,
            rawTags: raw, postFilterTags: filtered, latencyMs: ms, error: nil
        )
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let err = "\(type(of: error)): \(error)"
        return VariantA2Output(
            title: "", summary: "", mood: "", domain: "",
            rawTags: [], postFilterTags: [], latencyMs: ms, error: err
        )
    }
}

// MARK: - Output writers

func writeJSON(_ rows: [ResultRow], to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(rows)
    try data.write(to: url)
}

// MARK: - Summary

func writeSummary(a1: [ResultRow], a2: [ResultRow], outURL: URL, seed: UInt64) throws {
    func avgTags(_ rows: [ResultRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        let total = rows.reduce(0) { $0 + $1.postFilterTags.count }
        return Double(total) / Double(rows.count)
    }
    func errorCount(_ rows: [ResultRow]) -> Int {
        rows.filter { $0.error != nil }.count
    }
    func emptyTagCount(_ rows: [ResultRow]) -> Int {
        rows.filter { $0.error == nil && $0.postFilterTags.isEmpty }.count
    }
    func avgLatency(_ rows: [ResultRow]) -> Double {
        let success = rows.filter { $0.error == nil }
        guard !success.isEmpty else { return 0 }
        let total = success.reduce(0) { $0 + $1.latencyMs }
        return Double(total) / Double(success.count)
    }

    var lines: [String] = []
    lines.append("# FM Tagging Diagnostic — A1 vs A2")
    lines.append("")
    lines.append("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("- Seed: \(seed)")
    lines.append("- Sample size: \(a1.count)")
    lines.append("- Vocabulary size: \(vocabulary.count)")
    lines.append("")
    lines.append("## Aggregate")
    lines.append("")
    lines.append("| metric | A1 (free-form + post-filter) | A2 (typed enum) |")
    lines.append("|---|---|---|")
    lines.append("| errors | \(errorCount(a1)) | \(errorCount(a2)) |")
    lines.append("| empty-tag results (no error) | \(emptyTagCount(a1)) | \(emptyTagCount(a2)) |")
    lines.append("| avg post-filter tag count | \(String(format: "%.2f", avgTags(a1))) | \(String(format: "%.2f", avgTags(a2))) |")
    lines.append("| avg latency (ms, success only) | \(String(format: "%.0f", avgLatency(a1))) | \(String(format: "%.0f", avgLatency(a2))) |")
    lines.append("")

    // Difference table
    let a1ByID = Dictionary(uniqueKeysWithValues: a1.map { ($0.nodeID, $0) })
    let a2ByID = Dictionary(uniqueKeysWithValues: a2.map { ($0.nodeID, $0) })
    let allIDs = a1.map { $0.nodeID }

    lines.append("## Per-node tag set diffs (post-filter)")
    lines.append("")
    lines.append("| node | title | A1 tags | A2 tags | same? |")
    lines.append("|---|---|---|---|---|")
    for id in allIDs {
        let r1 = a1ByID[id]!
        let r2 = a2ByID[id]!
        let s1 = Set(r1.postFilterTags)
        let s2 = Set(r2.postFilterTags)
        let same = s1 == s2
        let tagStr1 = r1.postFilterTags.isEmpty ? "(empty)" : r1.postFilterTags.joined(separator: ", ")
        let tagStr2 = r2.postFilterTags.isEmpty ? "(empty)" : r2.postFilterTags.joined(separator: ", ")
        let shortID = String(id.prefix(8))
        let titleEsc = r1.title.replacingOccurrences(of: "|", with: "\\|")
        lines.append("| \(shortID) | \(titleEsc) | \(tagStr1) | \(tagStr2) | \(same ? "yes" : "**no**") |")
    }

    // Out-of-vocabulary list — A1 raw tags that did not survive the post-filter.
    lines.append("")
    lines.append("## A1 raw → drop list (out-of-vocabulary tokens emitted by A1)")
    lines.append("")
    var any = false
    for r in a1 {
        let dropped = Set(r.fmRawTags).subtracting(Set(r.postFilterTags)).filter { !$0.isEmpty }
        if !dropped.isEmpty {
            any = true
            lines.append("- \(String(r.nodeID.prefix(8))) \(r.title): \(Array(dropped).sorted().joined(separator: ", "))")
        }
    }
    if !any { lines.append("- (none — every A1 raw tag was in vocabulary)") }

    let text = lines.joined(separator: "\n") + "\n"
    try text.data(using: .utf8)!.write(to: outURL)
}

// MARK: - Main

func runHarness() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")

    print("=== FM Tagging Diagnostic Harness ===")
    print("Corpus root: \(corpusRoot.path)")
    print("Vocabulary size: \(vocabulary.count)")

    // Availability gate — match the production guard so an unavailable model
    // surfaces the same way it would in the app.
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }

    let nodes: [Node]
    do {
        nodes = try loadCorpus(rootURL: corpusRoot)
    } catch {
        print("ERROR loading corpus: \(error)")
        return
    }
    print("Loaded \(nodes.count) nodes from disk.")

    let sample = sampleEligible(nodes, k: 20, seed: 42)
    print("Sampled \(sample.count) eligible nodes (content >= 20 chars).")

    var a1Rows: [ResultRow] = []
    var a2Rows: [ResultRow] = []

    for (idx, pair) in sample.enumerated() {
        let (node, content) = pair
        print("\n[\(idx + 1)/\(sample.count)] \(node.id) — \(node.title ?? "(no title)")")
        print("  content len: \(content.count)")

        // A1
        print("  A1 (free-form)…", terminator: " ")
        fflush(stdout)
        let a1 = await runA1(content: content, vocabulary: vocabulary)
        if let e = a1.error {
            print("ERROR \(a1.latencyMs)ms — \(e)")
        } else {
            print("\(a1.latencyMs)ms tags=\(a1.rawTags) → filter=\(a1.postFilterTags)")
        }

        // A2
        print("  A2 (typed enum)…", terminator: " ")
        fflush(stdout)
        let a2 = await runA2(content: content, vocabulary: vocabulary)
        if let e = a2.error {
            print("ERROR \(a2.latencyMs)ms — \(e)")
        } else {
            print("\(a2.latencyMs)ms tags=\(a2.rawTags)")
        }

        a1Rows.append(ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a1.rawTags,
            postFilterTags: a1.postFilterTags,
            fmTitle: a1.title,
            fmSummary: a1.summary,
            fmMood: a1.mood,
            fmDomain: a1.domain,
            latencyMs: a1.latencyMs,
            error: a1.error
        ))
        a2Rows.append(ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a2.rawTags,
            postFilterTags: a2.postFilterTags,
            fmTitle: a2.title,
            fmSummary: a2.summary,
            fmMood: a2.mood,
            fmDomain: a2.domain,
            latencyMs: a2.latencyMs,
            error: a2.error
        ))
    }

    do {
        try writeJSON(a1Rows, to: outDir.appendingPathComponent("results-A1.json"))
        try writeJSON(a2Rows, to: outDir.appendingPathComponent("results-A2.json"))
        try writeSummary(a1: a1Rows, a2: a2Rows, outURL: outDir.appendingPathComponent("summary.md"), seed: 42)
        print("\nWrote results-A1.json, results-A2.json, summary.md to \(outDir.path)")
    } catch {
        print("ERROR writing outputs: \(error)")
    }
}

@main
struct HarnessMain {
    static func main() async {
        // Line-buffer stdout so progress is visible when piped through `tee`.
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        if args.contains("round5") {
            if #available(macOS 14.0, *) {
                await runRound5()
            } else {
                print("ERROR: round5 requires macOS 14.0+ (NLContextualEmbedding).")
            }
        } else if args.contains("round4b") {
            if #available(macOS 14.0, *) {
                await runRound4b()
            } else {
                print("ERROR: round4b requires macOS 14.0+ (NLContextualEmbedding).")
            }
        } else if args.contains("round4") {
            if #available(macOS 14.0, *) {
                await runRound4()
            } else {
                print("ERROR: round4 requires macOS 14.0+ (NLContextualEmbedding).")
            }
        } else if args.contains("round3") {
            await runRound3()
        } else if args.contains("round2") {
            await runRound2()
        } else {
            await runHarness()
        }
    }
}
