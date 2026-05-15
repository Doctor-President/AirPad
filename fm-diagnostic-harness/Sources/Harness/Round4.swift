import Foundation
import NaturalLanguage

// MARK: - Round 4 — Stronger Embedder Probe
//
// Re-runs Round 3 using NLContextualEmbedding (macOS 14+ transformer-based
// contextual embedder, Apple-trained) in place of NLEmbedding.sentenceEmbedding
// (the older static word/sentence embedding used in Round 3). Asset is
// downloaded on first use via requestEmbeddingAssets.
//
// Per-token vectors are mean-pooled to produce a sentence embedding. Same
// folksonomy / summary / content treatment as Round 3.
//
// Brief recommended all-MiniLM-L6-v2 CoreML, but explicitly allowed the
// faster-to-integrate option. NLContextualEmbedding ships in the framework
// and avoids a CoreML conversion + WordPiece tokenizer integration; surfaced
// to T in the report. If T wants MiniLM specifically, swap-out is local to
// `runRound4`.

// MARK: - Persisted record shape

struct Round4EmbeddingRecord: Encodable {
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

struct Round4Envelope: Encodable {
    let embedder: String
    let dimension: Int
    let records: [Round4EmbeddingRecord]
}

// MARK: - Round 3 reader

/// Decode the Round 3 embeddings.json record shape so Round 4 can compute the
/// Round 3 M_blend nearest-neighbor list without re-running anything.
struct Round3Record: Decodable {
    let nodeID: String
    let title: String
    let content: [Double]?
    let summary: [Double]?
    let folksonomy: [Double]?
}

func loadRound3Embeddings(_ url: URL) throws -> [Round3Record] {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([Round3Record].self, from: data)
}

// MARK: - Mean-pool

@available(macOS 14.0, iOS 17.0, *)
func meanPooled(_ embedding: NLContextualEmbedding, text: String) -> [Double]? {
    guard !text.isEmpty else { return nil }
    do {
        let result = try embedding.embeddingResult(for: text, language: .english)
        let dim = embedding.dimension
        var sum = [Double](repeating: 0, count: dim)
        var tokens = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            for i in 0..<min(dim, vec.count) { sum[i] += vec[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else {
            print("WARN: zero tokens for text '\(text.prefix(60))…'")
            return nil
        }
        let inv = 1.0 / Double(tokens)
        return sum.map { $0 * inv }
    } catch {
        print("ERROR embeddingResult for text='\(text.prefix(60))…': \(error)")
        return nil
    }
}

// MARK: - Asset bootstrap

@available(macOS 14.0, iOS 17.0, *)
func ensureAssetsAndLoad(_ embedding: NLContextualEmbedding) async -> Bool {
    if !embedding.hasAvailableAssets {
        print("Requesting NLContextualEmbedding assets (first-run download)…")
        do {
            let result = try await embedding.requestAssets()
            print("Asset request result: \(result.rawValue) (0=available, 1=notAvailable, 2=error)")
        } catch {
            print("Asset request error: \(error)")
        }
    }
    do {
        try embedding.load()
        return true
    } catch {
        print("ERROR loading NLContextualEmbedding: \(error)")
        return false
    }
}

// MARK: - Matrix utilities (shared shape with Round 3)

func r4Pairs(_ m: [[Double?]]) -> [(i: Int, j: Int, score: Double)] {
    var out: [(Int, Int, Double)] = []
    let n = m.count
    for i in 0..<n {
        for j in (i+1)..<n {
            if let s = m[i][j] { out.append((i, j, s)) }
        }
    }
    return out
}

func r4Avg(_ ps: [(i: Int, j: Int, score: Double)]) -> Double {
    ps.isEmpty ? 0 : ps.reduce(0) { $0 + $1.score } / Double(ps.count)
}

func r4TopK(scores: [Double?], titles: [String], ids: [String], selfIdx: Int, k: Int) -> [Neighbor] {
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

@available(macOS 14.0, iOS 17.0, *)
func runRound4() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")

    print("=== FM Tagging Diagnostic Harness — Round 4 (Stronger Embedder Probe) ===")
    print("Corpus root: \(corpusRoot.path)")

    // 1. Bring up the new embedder.
    guard let embedding = NLContextualEmbedding(language: .english) else {
        print("ERROR: NLContextualEmbedding(language: .english) returned nil. Aborting.")
        return
    }
    print("NLContextualEmbedding initialized — modelIdentifier=\(embedding.modelIdentifier) revision=\(embedding.revision) dim=\(embedding.dimension) maxLen=\(embedding.maximumSequenceLength)")
    let ok = await ensureAssetsAndLoad(embedding)
    guard ok else {
        print("ERROR: NLContextualEmbedding assets/load failed. Aborting.")
        return
    }
    print("NLContextualEmbedding loaded.")

    // 2. Cached A4 / A5 inputs (no FM calls).
    let a4Map: [String: CachedRow]
    let a5Map: [String: CachedRow]
    do {
        a4Map = try loadCachedRows(outDir.appendingPathComponent("results-A4.json"))
        a5Map = try loadCachedRows(outDir.appendingPathComponent("results-A5.json"))
    } catch {
        print("ERROR loading cached A4/A5: \(error)")
        return
    }
    print("Cached rows: A4=\(a4Map.count), A5=\(a5Map.count)")

    // 3. Re-build seed-42 sample.
    let nodes: [Node]
    do {
        nodes = try loadCorpus(rootURL: corpusRoot)
    } catch {
        print("ERROR loading corpus: \(error)")
        return
    }
    let sample = sampleEligible(nodes, k: 20, seed: 42)
    print("Sampled \(sample.count) nodes (seed=42).")

    // 4. Embed.
    let abstainedID = "E7BCE684-7DFF-4225-B15A-E0DDFEB1BF54"
    var records: [Round4EmbeddingRecord] = []

    for (node, content) in sample {
        let id = node.id
        let truncated = truncate800(content)
        let title = node.title ?? a5Map[id]?.title ?? a4Map[id]?.title ?? "(no title)"
        let folksonomy = a4Map[id]?.fmRawTags ?? []
        let folkPhrase = folksonomy.joined(separator: ", ")
        let summaryText = a5Map[id]?.fmSummary ?? ""

        let contentVec = meanPooled(embedding, text: truncated)
        var summaryVec: [Double]? = nil
        var folkVec: [Double]? = nil
        var note: String? = nil

        if id == abstainedID {
            note = "A5 hit guardrailViolation; summary and folksonomy embeddings skipped per brief."
        } else {
            if !summaryText.isEmpty {
                summaryVec = meanPooled(embedding, text: summaryText)
            } else {
                note = (note ?? "") + "summary missing or empty in A5 cache. "
            }
            if !folkPhrase.isEmpty {
                folkVec = meanPooled(embedding, text: folkPhrase)
            } else {
                note = (note ?? "") + "folksonomy missing or empty in A4 cache. "
            }
        }

        records.append(Round4EmbeddingRecord(
            nodeID: id, title: title,
            contentChars: truncated.count,
            folksonomyPhrase: folkPhrase, summaryText: summaryText,
            content: contentVec, summary: summaryVec, folksonomy: folkVec,
            note: note
        ))

        let cFlag = contentVec == nil ? "·" : "C"
        let sFlag = summaryVec == nil ? "·" : "S"
        let fFlag = folkVec == nil ? "·" : "F"
        print("  [\(records.count)/\(sample.count)] \(String(id.prefix(8))) \(cFlag)\(sFlag)\(fFlag) \(title)")
    }

    // 5. Write embeddings-round4.json.
    let envelope = Round4Envelope(
        embedder: "NLContextualEmbedding(language: .english) [\(embedding.modelIdentifier) rev=\(embedding.revision)]",
        dimension: embedding.dimension,
        records: records
    )
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(envelope)
        try data.write(to: outDir.appendingPathComponent("embeddings-round4.json"))
        print("Wrote embeddings-round4.json (\(data.count) bytes).")
    } catch {
        print("ERROR writing embeddings-round4.json: \(error)")
        return
    }

    // 6. Round 4 matrices.
    let n = records.count
    let ids = records.map { $0.nodeID }
    let titles = records.map { $0.title }

    func buildMatrix(_ picker: (Round4EmbeddingRecord) -> [Double]?) -> [[Double?]] {
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

    let mContentV2 = buildMatrix { $0.content }
    let mSummaryV2 = buildMatrix { $0.summary }
    let mFolkV2 = buildMatrix { $0.folksonomy }
    var mBlendV2 = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
    for i in 0..<n {
        for j in 0..<n {
            if i == j { mBlendV2[i][j] = 1.0; continue }
            if let s = mSummaryV2[i][j], let f = mFolkV2[i][j] {
                mBlendV2[i][j] = (s + f) / 2.0
            }
        }
    }

    func neighbors(_ m: [[Double?]]) -> [[Neighbor]] {
        (0..<n).map { i in r4TopK(scores: m[i], titles: titles, ids: ids, selfIdx: i, k: 3) }
    }
    let nbBlendV2 = neighbors(mBlendV2)

    let pContentV2 = r4Pairs(mContentV2)
    let pSummaryV2 = r4Pairs(mSummaryV2)
    let pFolkV2 = r4Pairs(mFolkV2)
    let pBlendV2 = r4Pairs(mBlendV2)

    // 7. Reconstruct Round 3 matrices from embeddings.json so the comparison
    //    is honest (same indexing, same code path) — no parsing summary-round3.md.
    let r3URL = outDir.appendingPathComponent("embeddings.json")
    let r3List: [Round3Record]
    do {
        r3List = try loadRound3Embeddings(r3URL)
    } catch {
        print("ERROR loading Round 3 embeddings.json: \(error)")
        return
    }
    let r3ByID = Dictionary(uniqueKeysWithValues: r3List.map { ($0.nodeID, $0) })
    // Align to the same ID order as Round 4's `records` so indices match.
    var r3Aligned: [Round3Record?] = []
    for r in records { r3Aligned.append(r3ByID[r.nodeID]) }

    func buildR3Matrix(_ picker: (Round3Record) -> [Double]?) -> [[Double?]] {
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            guard let ri = r3Aligned[i], let a = picker(ri) else { continue }
            for j in 0..<n {
                if i == j { m[i][j] = 1.0; continue }
                guard let rj = r3Aligned[j], let b = picker(rj) else { continue }
                m[i][j] = cosine(a, b)
            }
        }
        return m
    }
    let mContentR3 = buildR3Matrix { $0.content }
    let mSummaryR3 = buildR3Matrix { $0.summary }
    let mFolkR3 = buildR3Matrix { $0.folksonomy }
    var mBlendR3 = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
    for i in 0..<n {
        for j in 0..<n {
            if i == j { mBlendR3[i][j] = 1.0; continue }
            if let s = mSummaryR3[i][j], let f = mFolkR3[i][j] {
                mBlendR3[i][j] = (s + f) / 2.0
            }
        }
    }
    let nbBlendR3 = neighbors(mBlendR3)
    let pContentR3 = r4Pairs(mContentR3)
    let pSummaryR3 = r4Pairs(mSummaryR3)
    let pFolkR3 = r4Pairs(mFolkR3)
    let pBlendR3 = r4Pairs(mBlendR3)

    // 8. Render summary-round4.md.
    var lines: [String] = []
    lines.append("# FM Tagging Diagnostic — Round 4 (Stronger Embedder Probe)")
    lines.append("")
    lines.append("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("- Round 3 embedder: NLEmbedding.sentenceEmbedding(.english) — static (GloVe-style), 512-dim")
    lines.append("- Round 4 embedder: NLContextualEmbedding(.english) — Apple transformer, contextual; mean-pooled per-token vectors. modelIdentifier=`\(embedding.modelIdentifier)` revision=\(embedding.revision) dim=\(embedding.dimension) maxSequenceLength=\(embedding.maximumSequenceLength)")
    lines.append("- Embedder selection note: brief recommended all-MiniLM-L6-v2 CoreML; chose NLContextualEmbedding because it is Apple-native, requires no CoreML conversion or WordPiece tokenizer integration, and ships under the same NaturalLanguage framework as Round 3's baseline. MiniLM-L6 / all-mpnet-base-v2 remain available as a follow-up if the data warrants.")
    lines.append("- Sample size: \(n) (seed=42, regenerated to match Rounds 1–3)")
    lines.append("- Sources: results-A4.json (`fmRawTags`), results-A5.json (`fmSummary`), embeddings.json (Round 3 vectors for side-by-side)")
    lines.append("- E7BCE684 (Creative Storytelling and Technology) — A5 hit guardrailViolation; summary & folksonomy embeddings skipped, content only.")
    lines.append("")

    // Section 1 — aggregate
    lines.append("## Section 1 — Aggregate cosine comparison")
    lines.append("")
    lines.append("| matrix | Round 3 (NLEmbedding) | Round 4 (NLContextualEmbedding) | delta |")
    lines.append("|---|---|---|---|")
    func row(_ name: String, _ a: Double, _ b: Double) {
        let d = b - a
        lines.append("| \(name) | \(String(format: "%.4f", a)) | \(String(format: "%.4f", b)) | \(String(format: "%+.4f", d)) |")
    }
    row("M_content avg cosine", r4Avg(pContentR3), r4Avg(pContentV2))
    row("M_summary avg cosine", r4Avg(pSummaryR3), r4Avg(pSummaryV2))
    row("M_folksonomy avg cosine", r4Avg(pFolkR3), r4Avg(pFolkV2))
    row("M_blend avg cosine", r4Avg(pBlendR3), r4Avg(pBlendV2))
    lines.append("")

    // Strongest / weakest pairs per Round 4 matrix (data, not interpretation)
    func renderPairs(_ name: String, _ ps: [(i: Int, j: Int, score: Double)]) {
        let sorted = ps.sorted { $0.score > $1.score }
        lines.append("### \(name) — 5 strongest pairs (Round 4)")
        lines.append("")
        for p in sorted.prefix(5) {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
        lines.append("### \(name) — 5 weakest pairs (Round 4)")
        lines.append("")
        for p in sorted.suffix(5).reversed() {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
    }
    renderPairs("M_content_v2", pContentV2)
    renderPairs("M_summary_v2", pSummaryV2)
    renderPairs("M_folksonomy_v2", pFolkV2)
    renderPairs("M_blend_v2", pBlendV2)

    // Section 2 — per-node M_blend nearest-neighbor diff
    lines.append("## Section 2 — Per-node M_blend nearest-neighbor diff (Round 3 vs Round 4)")
    lines.append("")
    func renderList(_ nb: [Neighbor]) -> String {
        if nb.isEmpty { return "_(none — embedding missing)_" }
        return nb.map { "\(String($0.nodeID.prefix(8))) \($0.title) — \(String(format: "%.4f", $0.score))" }.joined(separator: "; ")
    }
    for i in 0..<n {
        let r = records[i]
        let short = String(r.nodeID.prefix(8))
        let r3 = nbBlendR3[i]
        let r4 = nbBlendV2[i]
        let r3Set = Set(r3.map { $0.nodeID })
        let r4Set = Set(r4.map { $0.nodeID })
        let same = r3Set == r4Set
        let orderSame = r3.map { $0.nodeID } == r4.map { $0.nodeID }
        let changedTag: String
        if same && orderSame { changedTag = "**identical**" }
        else if same { changedTag = "**same set, different order**" }
        else { changedTag = "**changed** (added: \(r4Set.subtracting(r3Set).map{String($0.prefix(8))}.sorted().joined(separator: ", ")); removed: \(r3Set.subtracting(r4Set).map{String($0.prefix(8))}.sorted().joined(separator: ", ")))" }
        lines.append("### \(short) — \(r.title)")
        lines.append("")
        if let note = r.note { lines.append("- note: \(note)") }
        lines.append("- Round 3 M_blend: \(renderList(r3))")
        lines.append("- Round 4 M_blend: \(renderList(r4))")
        lines.append("- diff: \(changedTag)")
        lines.append("")
    }

    // Section 3 — flagged groupings comparison
    lines.append("## Section 3 — Flagged groupings: Round 3 vs Round 4 M_blend")
    lines.append("")
    func indexOfPrefix(_ p: String) -> Int? {
        for i in 0..<n { if ids[i].hasPrefix(p) { return i } }
        return nil
    }
    func cellPair(_ aPrefix: String, _ bPrefix: String, _ m: [[Double?]]) -> Double? {
        guard let i = indexOfPrefix(aPrefix), let j = indexOfPrefix(bPrefix), let s = m[i][j] else { return nil }
        return s
    }
    func fmt(_ d: Double?) -> String { d.map { String(format: "%.4f", $0) } ?? "—" }
    func dlt(_ a: Double?, _ b: Double?) -> String {
        guard let a = a, let b = b else { return "—" }
        return String(format: "%+.4f", b - a)
    }
    lines.append("| pair | Round 3 M_blend | Round 4 M_blend | delta |")
    lines.append("|---|---|---|---|")
    let lookups: [(String, String, String)] = [
        ("18C0ADA0", "DF6B5E4B", "Stress Router ↔ Zoom Clustering"),
        ("18C0ADA0", "56C645B8", "Stress Router ↔ Topographic Canvas"),
        ("DF6B5E4B", "56C645B8", "Zoom Clustering ↔ Topographic Canvas"),
        ("9C8F8D6F", "6215BD85", "Hate Faces ↔ Mask Dynamics"),
        ("0A0DB1DA", "948C90CD", "Hole to China ↔ Lights Out"),
    ]
    for (a, b, label) in lookups {
        let r3v = cellPair(a, b, mBlendR3)
        let r4v = cellPair(a, b, mBlendV2)
        lines.append("| \(label) | \(fmt(r3v)) | \(fmt(r4v)) | \(dlt(r3v, r4v)) |")
    }
    // Vertical Farming nearest neighbor on each side
    if let vfIdx = indexOfPrefix("0638A25E") {
        let r3Top = nbBlendR3[vfIdx].first
        let r4Top = nbBlendV2[vfIdx].first
        let r3s = r3Top.map { "\(String($0.nodeID.prefix(8))) \($0.title) — \(String(format: "%.4f", $0.score))" } ?? "—"
        let r4s = r4Top.map { "\(String($0.nodeID.prefix(8))) \($0.title) — \(String(format: "%.4f", $0.score))" } ?? "—"
        let dl: String
        if let a = r3Top?.score, let b = r4Top?.score { dl = String(format: "%+.4f", b - a) } else { dl = "—" }
        lines.append("| Vertical Farming nearest neighbor | \(r3s) | \(r4s) | \(dl) |")
    }
    lines.append("")

    // Section 4 — Tomato Recipe outlier check
    lines.append("## Section 4 — Tomato Recipe outlier check (Round 4 M_blend)")
    lines.append("")
    if let ti = indexOfPrefix("7735A62F") {
        // Collect all defined pairs that include Tomato Recipe.
        var rowPairs: [(other: Int, score: Double)] = []
        for j in 0..<n {
            if j == ti { continue }
            if let s = mBlendV2[ti][j] { rowPairs.append((j, s)) }
        }
        rowPairs.sort { $0.score > $1.score }
        lines.append("- 3 strongest blend partners:")
        for p in rowPairs.prefix(3) {
            lines.append("    - \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) (\(titles[p.other]))")
        }
        lines.append("- 5 weakest blend partners:")
        for p in rowPairs.suffix(5).reversed() {
            lines.append("    - \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) (\(titles[p.other]))")
        }
        // Also: how often does Tomato Recipe appear in any other node's top-3 blend list?
        var appearances = 0
        for i in 0..<n {
            if i == ti { continue }
            if nbBlendV2[i].contains(where: { $0.nodeID == ids[ti] }) { appearances += 1 }
        }
        lines.append("- Tomato Recipe appears in \(appearances) other node's top-3 blend neighbor list.")
    } else {
        lines.append("Tomato Recipe (7735A62F) not found in sample.")
    }
    lines.append("")

    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.data(using: .utf8)!.write(to: outDir.appendingPathComponent("summary-round4.md"))
        print("Wrote summary-round4.md.")
    } catch {
        print("ERROR writing summary-round4.md: \(error)")
    }
}
