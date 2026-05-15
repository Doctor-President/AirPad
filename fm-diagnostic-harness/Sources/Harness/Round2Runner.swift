import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Round 2 runner

/// Round 2 — runs A3, A4, A5, A6 against the same seed-42 specimen set as
/// Round 1. A1/A2 results are read from disk and merged into summary-round2.md
/// without re-running the FM. Stage-1 summary is shared between A5 and A6 to
/// save FM cycles (~20 calls vs 40); the cache is per-node.
func runRound2() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")

    print("=== FM Tagging Diagnostic Harness — Round 2 ===")
    print("Corpus root: \(corpusRoot.path)")
    print("Vocabulary size: \(vocabulary.count)")

    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }

    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
        print("ERROR: NLEmbedding.sentenceEmbedding(for: .english) returned nil. Aborting.")
        return
    }
    print("NLEmbedding.sentenceEmbedding loaded (dim=\(embedding.dimension)).")

    let nodes: [Node]
    do {
        nodes = try loadCorpus(rootURL: corpusRoot)
    } catch {
        print("ERROR loading corpus: \(error)")
        return
    }
    print("Loaded \(nodes.count) nodes from disk.")

    let sample = sampleEligible(nodes, k: 20, seed: 42)
    print("Sampled \(sample.count) eligible nodes (seed=42, content >= 20 chars).")
    print("[cache] Stage-1 summary will be reused across A5 and A6 per-node.")

    var a3Rows: [Round2ResultRow] = []
    var a4Rows: [Round2ResultRow] = []
    var a5Rows: [Round2ResultRow] = []
    var a6Rows: [Round2ResultRow] = []

    for (idx, pair) in sample.enumerated() {
        let (node, content) = pair
        print("\n[\(idx + 1)/\(sample.count)] \(node.id) — \(node.title ?? "(no title)")")
        print("  content len: \(content.count)")

        // A3 — typed enum + abstention prompt
        print("  A3 (typed enum + abstention)…", terminator: " ")
        fflush(stdout)
        let a3 = await runA3(content: content, vocabulary: vocabulary)
        if let e = a3.error {
            print("ERROR \(a3.latencyMs)ms — \(e)")
        } else {
            print("\(a3.latencyMs)ms tags=\(a3.rawTags)")
        }
        a3Rows.append(Round2ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a3.rawTags,
            postFilterTags: a3.postFilterTags,
            fmTitle: a3.title, fmSummary: a3.summary, fmMood: a3.mood, fmDomain: a3.domain,
            latencyMs: a3.latencyMs,
            summaryLatencyMs: nil,
            cosineMatches: nil,
            error: a3.error
        ))

        // A4 — folksonomy + embedding cosine match
        print("  A4 (folksonomy → cosine match)…", terminator: " ")
        fflush(stdout)
        let a4 = await runA4(content: content, vocabulary: vocabulary, embedding: embedding)
        let a4Total = a4.stage1LatencyMs + a4.stage2LatencyMs
        if let e = a4.error {
            print("ERROR \(a4Total)ms — \(e)")
        } else {
            let topMatches = a4.cosineMatches.prefix(5).map { String(format: "%@→%@(%.2f)", $0.folksonomy, $0.vocab, $0.score) }
            print("fm=\(a4.stage1LatencyMs)ms cos=\(a4.stage2LatencyMs)ms folk=\(a4.folksonomy) tier1=\(a4.tier1Tags)")
            print("    matches: \(topMatches.joined(separator: ", "))")
        }
        a4Rows.append(Round2ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a4.folksonomy,
            postFilterTags: a4.tier1Tags,
            fmTitle: "", fmSummary: "", fmMood: "", fmDomain: "",
            latencyMs: a4Total,
            summaryLatencyMs: a4.stage1LatencyMs,
            cosineMatches: a4.cosineMatches,
            error: a4.error
        ))

        // A5 — summary first, then free-form tags from summary.
        // Stage-1 cached for re-use by A6.
        print("  A5 stage-1 (summary)…", terminator: " ")
        fflush(stdout)
        let s1 = await runSummaryStage1(content: content, vocabulary: vocabulary)
        if let e = s1.error {
            print("ERROR \(s1.latencyMs)ms — \(e)")
        } else {
            print("\(s1.latencyMs)ms summary=\"\(truncateForLog(s1.summary, max: 120))\"")
        }
        // Stage-2 free-form
        var a5: (raw: [String], filtered: [String], latencyMs: Int, error: String?) =
            ([], [], 0, s1.error)
        if s1.error == nil, !s1.summary.isEmpty {
            print("  A5 stage-2 (free-form on summary)…", terminator: " ")
            fflush(stdout)
            a5 = await runA5Stage2(summary: s1.summary, vocabulary: vocabulary)
            if let e = a5.error {
                print("ERROR \(a5.latencyMs)ms — \(e)")
            } else {
                print("\(a5.latencyMs)ms tags=\(a5.raw) → filter=\(a5.filtered)")
            }
        }
        let a5Total = s1.latencyMs + a5.latencyMs
        a5Rows.append(Round2ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a5.raw,
            postFilterTags: a5.filtered,
            fmTitle: s1.title, fmSummary: s1.summary, fmMood: s1.mood, fmDomain: s1.domain,
            latencyMs: a5Total,
            summaryLatencyMs: s1.latencyMs,
            cosineMatches: nil,
            error: s1.error ?? a5.error
        ))

        // A6 — same cached summary, typed-enum tag call.
        var a6: (raw: [String], filtered: [String], latencyMs: Int, error: String?) =
            ([], [], 0, s1.error)
        if s1.error == nil, !s1.summary.isEmpty {
            print("  A6 stage-2 (typed enum on summary)…", terminator: " ")
            fflush(stdout)
            a6 = await runA6Stage2(summary: s1.summary, vocabulary: vocabulary)
            if let e = a6.error {
                print("ERROR \(a6.latencyMs)ms — \(e)")
            } else {
                print("\(a6.latencyMs)ms tags=\(a6.raw)")
            }
        }
        let a6Total = s1.latencyMs + a6.latencyMs
        a6Rows.append(Round2ResultRow(
            nodeID: node.id,
            title: node.title ?? "",
            contentTruncated: truncateForLog(content),
            currentTags: node.tags ?? [],
            fmRawTags: a6.raw,
            postFilterTags: a6.filtered,
            fmTitle: s1.title, fmSummary: s1.summary, fmMood: s1.mood, fmDomain: s1.domain,
            latencyMs: a6Total,
            summaryLatencyMs: s1.latencyMs,
            cosineMatches: nil,
            error: s1.error ?? a6.error
        ))
    }

    do {
        try writeJSONRound2(a3Rows, to: outDir.appendingPathComponent("results-A3.json"))
        try writeJSONRound2(a4Rows, to: outDir.appendingPathComponent("results-A4.json"))
        try writeJSONRound2(a5Rows, to: outDir.appendingPathComponent("results-A5.json"))
        try writeJSONRound2(a6Rows, to: outDir.appendingPathComponent("results-A6.json"))
        try writeRound2Summary(
            a3: a3Rows, a4: a4Rows, a5: a5Rows, a6: a6Rows,
            outURL: outDir.appendingPathComponent("summary-round2.md"),
            seed: 42, outDir: outDir
        )
        print("\nWrote results-A3/A4/A5/A6.json and summary-round2.md to \(outDir.path)")
    } catch {
        print("ERROR writing outputs: \(error)")
    }
}

// MARK: - Output writers

func writeJSONRound2(_ rows: [Round2ResultRow], to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(rows)
    try data.write(to: url)
}

/// Read the Round 1 JSONs and pull the postFilterTags column for the side-by-
/// side comparison. Falls back to "(missing)" if the file isn't there.
func loadRound1PostFilter(_ outDir: URL, name: String) -> [String: [String]] {
    let url = outDir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return [:]
    }
    var out: [String: [String]] = [:]
    for r in arr {
        guard let id = r["nodeID"] as? String else { continue }
        out[id] = (r["postFilterTags"] as? [String]) ?? []
    }
    return out
}

func writeRound2Summary(
    a3: [Round2ResultRow], a4: [Round2ResultRow],
    a5: [Round2ResultRow], a6: [Round2ResultRow],
    outURL: URL, seed: UInt64, outDir: URL
) throws {
    let a1Map = loadRound1PostFilter(outDir, name: "results-A1.json")
    let a2Map = loadRound1PostFilter(outDir, name: "results-A2.json")
    let a3Map = Dictionary(uniqueKeysWithValues: a3.map { ($0.nodeID, $0) })
    let a4Map = Dictionary(uniqueKeysWithValues: a4.map { ($0.nodeID, $0) })
    let a5Map = Dictionary(uniqueKeysWithValues: a5.map { ($0.nodeID, $0) })
    let a6Map = Dictionary(uniqueKeysWithValues: a6.map { ($0.nodeID, $0) })

    var lines: [String] = []
    lines.append("# FM Tagging Diagnostic — Round 2 (A1–A6 side-by-side)")
    lines.append("")
    lines.append("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("- Seed: \(seed)")
    lines.append("- Sample size: \(a3.count)")
    lines.append("- Vocabulary size: \(vocabulary.count)")
    lines.append("- A1, A2 columns sourced from existing results-A1.json / results-A2.json (Round 1 run).")
    lines.append("- A5/A6 stage-1 summary is shared between the two variants (single FM call per node, reused).")
    lines.append("")

    // Aggregate
    func errorCount(_ rows: [Round2ResultRow]) -> Int { rows.filter { $0.error != nil }.count }
    func emptyCount(_ rows: [Round2ResultRow]) -> Int { rows.filter { $0.error == nil && $0.postFilterTags.isEmpty }.count }
    func avgTags(_ rows: [Round2ResultRow]) -> Double {
        let success = rows.filter { $0.error == nil }
        guard !success.isEmpty else { return 0 }
        return Double(success.reduce(0) { $0 + $1.postFilterTags.count }) / Double(success.count)
    }
    func avgLatency(_ rows: [Round2ResultRow]) -> Double {
        let success = rows.filter { $0.error == nil }
        guard !success.isEmpty else { return 0 }
        return Double(success.reduce(0) { $0 + $1.latencyMs }) / Double(success.count)
    }

    lines.append("## Aggregate (A3–A6 only)")
    lines.append("")
    lines.append("| metric | A3 (enum + abstain) | A4 (folksonomy → cosine) | A5 (summary → free-form) | A6 (summary → enum) |")
    lines.append("|---|---|---|---|---|")
    lines.append("| errors | \(errorCount(a3)) | \(errorCount(a4)) | \(errorCount(a5)) | \(errorCount(a6)) |")
    lines.append("| empty post-filter (no error) | \(emptyCount(a3)) | \(emptyCount(a4)) | \(emptyCount(a5)) | \(emptyCount(a6)) |")
    lines.append("| avg post-filter tag count | \(String(format: "%.2f", avgTags(a3))) | \(String(format: "%.2f", avgTags(a4))) | \(String(format: "%.2f", avgTags(a5))) | \(String(format: "%.2f", avgTags(a6))) |")
    lines.append("| avg total latency (ms, success) | \(String(format: "%.0f", avgLatency(a3))) | \(String(format: "%.0f", avgLatency(a4))) | \(String(format: "%.0f", avgLatency(a5))) | \(String(format: "%.0f", avgLatency(a6))) |")
    lines.append("")

    // Per-node side-by-side
    lines.append("## Per-node post-filter tags — A1 → A6")
    lines.append("")
    lines.append("| node | title | A1 | A2 | A3 | A4 (tier-1) | A5 | A6 |")
    lines.append("|---|---|---|---|---|---|---|---|")
    func cell(_ tags: [String]) -> String { tags.isEmpty ? "(empty)" : tags.joined(separator: ", ") }
    for row in a3 {
        let id = row.nodeID
        let short = String(id.prefix(8))
        let titleEsc = row.title.replacingOccurrences(of: "|", with: "\\|")
        let a1c = cell(a1Map[id] ?? [])
        let a2c = cell(a2Map[id] ?? [])
        let a3r = a3Map[id]
        let a4r = a4Map[id]
        let a5r = a5Map[id]
        let a6r = a6Map[id]
        let a3c = (a3r?.error != nil) ? "ERROR" : cell(a3r?.postFilterTags ?? [])
        let a4c = (a4r?.error != nil) ? "ERROR" : cell(a4r?.postFilterTags ?? [])
        let a5c = (a5r?.error != nil) ? "ERROR" : cell(a5r?.postFilterTags ?? [])
        let a6c = (a6r?.error != nil) ? "ERROR" : cell(a6r?.postFilterTags ?? [])
        lines.append("| \(short) | \(titleEsc) | \(a1c) | \(a2c) | \(a3c) | \(a4c) | \(a5c) | \(a6c) |")
    }
    lines.append("")

    // A4 folksonomy raw + cosine map detail
    lines.append("## A4 detail — folksonomy raw, top cosine match per folksonomy tag")
    lines.append("")
    for r in a4 {
        let short = String(r.nodeID.prefix(8))
        if r.error != nil {
            lines.append("- **\(short)** \(r.title): ERROR — \(r.error ?? "")")
            continue
        }
        let folkLine = r.fmRawTags.isEmpty ? "(no folksonomy)" : r.fmRawTags.joined(separator: ", ")
        let matchLine: String
        if let cm = r.cosineMatches, !cm.isEmpty {
            matchLine = cm.map { String(format: "%@→%@(%.2f)", $0.folksonomy, $0.vocab.isEmpty ? "—" : $0.vocab, $0.score) }.joined(separator: ", ")
        } else {
            matchLine = "(no matches)"
        }
        let tier1Line = r.postFilterTags.isEmpty ? "(empty)" : r.postFilterTags.joined(separator: ", ")
        lines.append("- **\(short)** \(r.title)")
        lines.append("    - folksonomy: \(folkLine)")
        lines.append("    - matches: \(matchLine)")
        lines.append("    - tier-1: \(tier1Line)")
    }
    lines.append("")

    // A5/A6 summary text used as substrate
    lines.append("## A5/A6 stage-1 summary text (substrate for A5+A6 stage-2)")
    lines.append("")
    for r in a5 {
        let short = String(r.nodeID.prefix(8))
        if r.error != nil, r.fmSummary.isEmpty {
            lines.append("- **\(short)** \(r.title): ERROR — \(r.error ?? "")")
        } else {
            lines.append("- **\(short)** \(r.title): \(r.fmSummary)")
        }
    }
    lines.append("")

    let text = lines.joined(separator: "\n") + "\n"
    try text.data(using: .utf8)!.write(to: outURL)
}
