import Foundation
import NaturalLanguage

// MARK: - Round 3 — Embedding Substrate Probe
//
// Reads cached A4 (folksonomy) + A5 (summary) outputs, regenerates the same
// seed-42 sample of 20 nodes, and produces three NLEmbedding sentence vectors
// per node: content, summary, folksonomy. Computes four pairwise cosine
// matrices (content / summary / folksonomy / blend) and writes
// embeddings.json + summary-round3.md.
//
// No FM calls are issued in this round — the FM-derived strings are pulled
// from the prior rounds' result JSONs and only the embedding model is run.

// MARK: - Read shapes

/// Subset of Round2ResultRow needed for Round 3. Decoded loosely so that any
/// extra columns added later don't break the read.
struct CachedRow: Decodable {
    let nodeID: String
    let title: String
    let fmRawTags: [String]?
    let fmSummary: String?
    let error: String?
}

/// Per-node Round 3 record persisted to embeddings.json.
struct EmbeddingRecord: Encodable {
    let nodeID: String
    let title: String
    let contentChars: Int
    let folksonomyPhrase: String
    let summaryText: String
    let content: [Double]?
    let summary: [Double]?
    let folksonomy: [Double]?
    let note: String?
}

func loadCachedRows(_ url: URL) throws -> [String: CachedRow] {
    let data = try Data(contentsOf: url)
    let arr = try JSONDecoder().decode([CachedRow].self, from: data)
    return Dictionary(uniqueKeysWithValues: arr.map { ($0.nodeID, $0) })
}

// MARK: - Helpers

func truncate800(_ s: String) -> String {
    s.count <= 800 ? s : String(s.prefix(800))
}

/// Top-K (excluding self) given a row of cosines into all nodes.
struct Neighbor {
    let nodeID: String
    let title: String
    let score: Double
}

func topK(scores: [Double?], titles: [String], ids: [String], selfIdx: Int, k: Int) -> [Neighbor] {
    var pairs: [(Int, Double)] = []
    for i in 0..<scores.count {
        if i == selfIdx { continue }
        guard let s = scores[i] else { continue }
        pairs.append((i, s))
    }
    pairs.sort { $0.1 > $1.1 }
    return pairs.prefix(k).map { Neighbor(nodeID: ids[$0.0], title: titles[$0.0], score: $0.1) }
}

// MARK: - Runner

func runRound3() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")

    print("=== FM Tagging Diagnostic Harness — Round 3 (Embedding Substrate Probe) ===")
    print("Corpus root: \(corpusRoot.path)")

    // 1. Embedding model
    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
        print("ERROR: NLEmbedding.sentenceEmbedding(for: .english) returned nil. Aborting.")
        return
    }
    print("NLEmbedding.sentenceEmbedding loaded (dim=\(embedding.dimension)).")

    // 2. Read cached A4 / A5 outputs
    let a4Map: [String: CachedRow]
    let a5Map: [String: CachedRow]
    do {
        a4Map = try loadCachedRows(outDir.appendingPathComponent("results-A4.json"))
        a5Map = try loadCachedRows(outDir.appendingPathComponent("results-A5.json"))
    } catch {
        print("ERROR loading cached A4/A5 results: \(error)")
        return
    }
    print("Cached rows: A4=\(a4Map.count), A5=\(a5Map.count)")

    // 3. Load corpus and rebuild the seed-42 sample to get ground-truth content.
    let nodes: [Node]
    do {
        nodes = try loadCorpus(rootURL: corpusRoot)
    } catch {
        print("ERROR loading corpus: \(error)")
        return
    }
    let sample = sampleEligible(nodes, k: 20, seed: 42)
    print("Sampled \(sample.count) nodes (seed=42).")

    // Sanity: A5 sample IDs should match the corpus sample IDs. If they don't,
    // something has shifted — surface and fall back to A5's IDs as the source
    // of truth so the embeddings still align with the cached folksonomies.
    let sampleIDs = Set(sample.map { $0.0.id })
    let cachedIDs = Set(a5Map.keys)
    if sampleIDs != cachedIDs {
        let missing = cachedIDs.subtracting(sampleIDs)
        let extra = sampleIDs.subtracting(cachedIDs)
        print("WARN: sample-vs-cache mismatch. missing-from-corpus=\(missing) extra-from-corpus=\(extra)")
    }

    // 4. Build per-node records keyed by the order returned by sampleEligible
    // — keeps the matrix axes deterministic across runs.
    let abstainedID = "E7BCE684-7DFF-4225-B15A-E0DDFEB1BF54"

    var records: [EmbeddingRecord] = []

    for (node, content) in sample {
        let id = node.id
        let truncated = truncate800(content)
        let title = node.title ?? a5Map[id]?.title ?? a4Map[id]?.title ?? "(no title)"

        let folksonomy = a4Map[id]?.fmRawTags ?? []
        let folkPhrase = folksonomy.joined(separator: ", ")
        let summaryText = a5Map[id]?.fmSummary ?? ""

        // Content embedding always
        let contentVec = embedding.vector(for: truncated)
        if contentVec == nil {
            print("WARN: content embedding nil for \(id) — string may be empty/unsupported.")
        }

        var summaryVec: [Double]? = nil
        var folkVec: [Double]? = nil
        var note: String? = nil

        if id == abstainedID {
            note = "A5 hit guardrailViolation; summary and folksonomy embeddings skipped per brief."
        } else {
            if !summaryText.isEmpty {
                summaryVec = embedding.vector(for: summaryText)
                if summaryVec == nil {
                    print("WARN: summary embedding nil for \(id).")
                }
            } else {
                note = (note ?? "") + "summary missing or empty in A5 cache. "
            }
            if !folkPhrase.isEmpty {
                folkVec = embedding.vector(for: folkPhrase)
                if folkVec == nil {
                    print("WARN: folksonomy embedding nil for \(id) — phrase=\(folkPhrase)")
                }
            } else {
                note = (note ?? "") + "folksonomy missing or empty in A4 cache. "
            }
        }

        records.append(EmbeddingRecord(
            nodeID: id,
            title: title,
            contentChars: truncated.count,
            folksonomyPhrase: folkPhrase,
            summaryText: summaryText,
            content: contentVec,
            summary: summaryVec,
            folksonomy: folkVec,
            note: note
        ))

        let cFlag = contentVec == nil ? "·" : "C"
        let sFlag = summaryVec == nil ? "·" : "S"
        let fFlag = folkVec == nil ? "·" : "F"
        print("  [\(records.count)/\(sample.count)] \(String(id.prefix(8))) \(cFlag)\(sFlag)\(fFlag) \(title)")
    }

    // 5. Persist embeddings
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(records)
        try data.write(to: outDir.appendingPathComponent("embeddings.json"))
        print("Wrote embeddings.json (\(data.count) bytes).")
    } catch {
        print("ERROR writing embeddings.json: \(error)")
        return
    }

    // 6. Build pairwise cosine matrices.
    let n = records.count
    let ids = records.map { $0.nodeID }
    let titles = records.map { $0.title }

    // Each matrix is [[Double?]] with nil for pairs missing either embedding.
    func buildMatrix(picker: (EmbeddingRecord) -> [Double]?) -> [[Double?]] {
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            guard let a = picker(records[i]) else { continue }
            for j in 0..<n {
                if i == j { m[i][j] = 1.0; continue }
                guard let b = picker(records[j]) else { continue }
                m[i][j] = cosine(a, b)
            }
        }
        return m
    }

    let mContent = buildMatrix { $0.content }
    let mSummary = buildMatrix { $0.summary }
    let mFolk = buildMatrix { $0.folksonomy }

    // Blend = per-pair average of summary and folksonomy when both exist.
    var mBlend = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
    for i in 0..<n {
        for j in 0..<n {
            if i == j { mBlend[i][j] = 1.0; continue }
            if let s = mSummary[i][j], let f = mFolk[i][j] {
                mBlend[i][j] = (s + f) / 2.0
            }
        }
    }

    // 7. Per-node top-3 neighbors per matrix
    func neighbors(_ m: [[Double?]]) -> [[Neighbor]] {
        (0..<n).map { i in topK(scores: m[i], titles: titles, ids: ids, selfIdx: i, k: 3) }
    }

    let nbContent = neighbors(mContent)
    let nbSummary = neighbors(mSummary)
    let nbFolk = neighbors(mFolk)
    let nbBlend = neighbors(mBlend)

    // 8. Aggregate: average cosine across all (i<j) pairs, plus 5 strongest +
    // 5 weakest defined pairs per matrix.
    struct Pair { let i: Int; let j: Int; let score: Double }
    func pairs(_ m: [[Double?]]) -> [Pair] {
        var out: [Pair] = []
        for i in 0..<n {
            for j in (i+1)..<n {
                if let s = m[i][j] { out.append(Pair(i: i, j: j, score: s)) }
            }
        }
        return out
    }
    func avg(_ ps: [Pair]) -> Double {
        ps.isEmpty ? 0 : ps.reduce(0) { $0 + $1.score } / Double(ps.count)
    }

    let pContent = pairs(mContent)
    let pSummary = pairs(mSummary)
    let pFolk = pairs(mFolk)
    let pBlend = pairs(mBlend)

    // 9. Write summary-round3.md
    var lines: [String] = []
    lines.append("# FM Tagging Diagnostic — Round 3 (Embedding Substrate Probe)")
    lines.append("")
    lines.append("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("- Embedding model: NLEmbedding.sentenceEmbedding(.english), dim=\(embedding.dimension)")
    lines.append("- Sample size: \(n) (seed=42, regenerated to match Round 1/2)")
    lines.append("- Sources: results-A4.json (folksonomy `fmRawTags`), results-A5.json (`fmSummary`)")
    lines.append("- Content: extracted from corpus per production `extractContent`, truncated to 800 chars")
    lines.append("- E7BCE684 (Creative Storytelling and Technology) — A5 hit guardrailViolation; summary & folksonomy embeddings skipped per brief, content embedding only.")
    lines.append("")

    // Aggregate
    lines.append("## Aggregate")
    lines.append("")
    lines.append("| matrix | defined pairs | avg cosine |")
    lines.append("|---|---|---|")
    lines.append("| M_content | \(pContent.count) | \(String(format: "%.4f", avg(pContent))) |")
    lines.append("| M_summary | \(pSummary.count) | \(String(format: "%.4f", avg(pSummary))) |")
    lines.append("| M_folksonomy | \(pFolk.count) | \(String(format: "%.4f", avg(pFolk))) |")
    lines.append("| M_blend | \(pBlend.count) | \(String(format: "%.4f", avg(pBlend))) |")
    lines.append("")

    func renderPairs(_ name: String, _ ps: [Pair]) {
        let sorted = ps.sorted { $0.score > $1.score }
        lines.append("### \(name) — 5 strongest pairs")
        lines.append("")
        for p in sorted.prefix(5) {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
        lines.append("### \(name) — 5 weakest pairs")
        lines.append("")
        for p in sorted.suffix(5).reversed() {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
    }

    renderPairs("M_content", pContent)
    renderPairs("M_summary", pSummary)
    renderPairs("M_folksonomy", pFolk)
    renderPairs("M_blend", pBlend)

    // Per-node rendering
    lines.append("## Per-node nearest neighbors (top 3 each)")
    lines.append("")

    // Build a 1-line content gist per node from the truncated content.
    func gist(_ s: String, max: Int = 140) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count <= max ? one : String(one.prefix(max)) + "…"
    }
    let contents: [String] = sample.map { $0.1 }

    func renderNeighborList(_ nb: [Neighbor]) -> String {
        if nb.isEmpty { return "_(none — embedding missing)_" }
        return nb.map { "\(String($0.nodeID.prefix(8))) \($0.title) — \(String(format: "%.4f", $0.score))" }.joined(separator: "; ")
    }

    for i in 0..<n {
        let r = records[i]
        let short = String(r.nodeID.prefix(8))
        lines.append("### \(short) — \(r.title)")
        lines.append("")
        lines.append("- gist: \(gist(contents[i]))")
        if let note = r.note { lines.append("- note: \(note)") }
        lines.append("- M_content: \(renderNeighborList(nbContent[i]))")
        lines.append("- M_summary: \(renderNeighborList(nbSummary[i]))")
        lines.append("- M_folksonomy: \(renderNeighborList(nbFolk[i]))")
        lines.append("- M_blend: \(renderNeighborList(nbBlend[i]))")
        lines.append("")
    }

    // Flagged groupings
    lines.append("## Flagged groupings (per brief)")
    lines.append("")

    let watch: [(String, String)] = [
        ("0638A25E", "Vertical Farming — currently isolated in production corpus"),
        ("3B5584B8", "Middle-earth Morality — folksonomy: LotR / Good vs Evil / Epic Fantasy"),
        ("18C0ADA0", "Stress Testing Router (AirPad design note)"),
        ("DF6B5E4B", "Zoom-Dependent Clustering (AirPad design note)"),
        ("56C645B8", "Topographic Canvas (AirPad design note)"),
        ("0A0DB1DA", "Hole to China (thin-content episode premise)"),
        ("948C90CD", "Lights Out (thin-content episode premise)"),
        ("9C8F8D6F", "Hate Faces TikTok (social/psych self-presentation)"),
        ("6215BD85", "Mask Dynamics (social/psych self-presentation)"),
    ]

    func indexOfPrefix(_ p: String) -> Int? {
        for i in 0..<n { if ids[i].hasPrefix(p) { return i } }
        return nil
    }

    for (prefix, label) in watch {
        guard let i = indexOfPrefix(prefix) else {
            lines.append("- **\(prefix)** \(label) — not in seed-42 sample")
            lines.append("")
            continue
        }
        lines.append("### \(prefix) — \(label)")
        lines.append("")
        if let note = records[i].note { lines.append("- note: \(note)") }
        lines.append("- M_content: \(renderNeighborList(nbContent[i]))")
        lines.append("- M_summary: \(renderNeighborList(nbSummary[i]))")
        lines.append("- M_folksonomy: \(renderNeighborList(nbFolk[i]))")
        lines.append("- M_blend: \(renderNeighborList(nbBlend[i]))")
        lines.append("")
    }

    // Cross-pair table for the AirPad design notes triple + the two-pair
    // groupings — bare cosine values for at-a-glance reading.
    lines.append("## Bilateral cosine — flagged pair/triple lookups")
    lines.append("")
    func cell(_ m: [[Double?]], _ a: String, _ b: String) -> String {
        guard let i = indexOfPrefix(a), let j = indexOfPrefix(b), let s = m[i][j] else { return "—" }
        return String(format: "%.4f", s)
    }
    lines.append("| pair | M_content | M_summary | M_folksonomy | M_blend |")
    lines.append("|---|---|---|---|---|")
    let lookups: [(String, String, String)] = [
        ("18C0ADA0", "DF6B5E4B", "Stress Router ↔ Zoom Clustering"),
        ("18C0ADA0", "56C645B8", "Stress Router ↔ Topographic Canvas"),
        ("DF6B5E4B", "56C645B8", "Zoom Clustering ↔ Topographic Canvas"),
        ("0A0DB1DA", "948C90CD", "Hole to China ↔ Lights Out"),
        ("9C8F8D6F", "6215BD85", "Hate Faces ↔ Mask Dynamics"),
    ]
    for (a, b, label) in lookups {
        lines.append("| \(label) | \(cell(mContent, a, b)) | \(cell(mSummary, a, b)) | \(cell(mFolk, a, b)) | \(cell(mBlend, a, b)) |")
    }
    lines.append("")

    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.data(using: .utf8)!.write(to: outDir.appendingPathComponent("summary-round3.md"))
        print("Wrote summary-round3.md.")
    } catch {
        print("ERROR writing summary-round3.md: \(error)")
    }
}
