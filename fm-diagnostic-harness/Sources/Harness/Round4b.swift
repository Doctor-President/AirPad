import Foundation
import NaturalLanguage

// MARK: - Round 4b — Two interventions on the Round 4 substrate
//
// Round 4 surfaced a mean-pool-bias artifact: NLContextualEmbedding mean-pooled
// vectors all sit on a strong shared direction, so cosine similarity collapses
// into the 0.76–0.96 band and dynamic range is worse than NLEmbedding.
//
// This round tries two cheap interventions on the SAME texts and SAME model:
//
//  (a) Mean-centering — load Round 4's mean-pooled vectors, subtract the
//      per-corpus mean (computed separately per channel: content, summary,
//      folksonomy), then recompute cosines. Removes the global bias.
//
//  (b) First-token (CLS-style) — re-run NLContextualEmbedding on each text and
//      take the FIRST token vector instead of the mean. The first subword token
//      after tokenization tends to act as a sentence summary in BERT-family
//      models. No new model is loaded; same NLContextualEmbedding instance.
//
// No FM calls. No new models.

// MARK: - Decode Round 4 envelope

struct Round4ReadRecord: Decodable {
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

struct Round4ReadEnvelope: Decodable {
    let embedder: String
    let dimension: Int
    let records: [Round4ReadRecord]
}

// MARK: - Vector ops

func vSub(_ a: [Double], _ b: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: a.count)
    for i in 0..<a.count { out[i] = a[i] - b[i] }
    return out
}

func vMean(_ vs: [[Double]]) -> [Double]? {
    guard let first = vs.first else { return nil }
    var sum = [Double](repeating: 0, count: first.count)
    for v in vs { for i in 0..<v.count { sum[i] += v[i] } }
    let inv = 1.0 / Double(vs.count)
    return sum.map { $0 * inv }
}

// MARK: - First-token extractor

@available(macOS 14.0, iOS 17.0, *)
func firstTokenVector(_ embedding: NLContextualEmbedding, text: String) -> [Double]? {
    guard !text.isEmpty else { return nil }
    do {
        let result = try embedding.embeddingResult(for: text, language: .english)
        let dim = embedding.dimension
        var first: [Double]? = nil
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            // Take the first token's vector; truncate / pad to declared dim.
            var v = [Double](repeating: 0, count: dim)
            for i in 0..<min(dim, vec.count) { v[i] = vec[i] }
            first = v
            return false  // stop after first token
        }
        return first
    } catch {
        print("ERROR firstTokenVector for text='\(text.prefix(60))…': \(error)")
        return nil
    }
}

// MARK: - Runner

@available(macOS 14.0, iOS 17.0, *)
func runRound4b() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")

    print("=== FM Tagging Diagnostic Harness — Round 4b (centering + first-token) ===")

    // 1. Load Round 4 envelope (mean-pooled vectors).
    let envelope: Round4ReadEnvelope
    do {
        let data = try Data(contentsOf: outDir.appendingPathComponent("embeddings-round4.json"))
        envelope = try JSONDecoder().decode(Round4ReadEnvelope.self, from: data)
    } catch {
        print("ERROR loading embeddings-round4.json: \(error)")
        return
    }
    print("Loaded Round 4 envelope: embedder=\(envelope.embedder) dim=\(envelope.dimension) records=\(envelope.records.count)")

    // 2. Load Round 3 embeddings (for the comparison columns).
    let r3List: [Round3Record]
    do {
        r3List = try loadRound3Embeddings(outDir.appendingPathComponent("embeddings.json"))
    } catch {
        print("ERROR loading Round 3 embeddings.json: \(error)")
        return
    }

    // 3. Bring NLContextualEmbedding back up for the first-token pass.
    guard let embedding = NLContextualEmbedding(language: .english) else {
        print("ERROR: NLContextualEmbedding init failed.")
        return
    }
    let ok = await ensureAssetsAndLoad(embedding)
    guard ok else { print("ERROR: NLContextualEmbedding load failed."); return }
    print("NLContextualEmbedding loaded for first-token pass (assets cached from Round 4).")

    // 4. We need the original `content` text for first-token re-embedding.
    //    The Round 4 envelope stored `contentChars` but not the truncated string,
    //    so re-extract from the corpus using the same seed-42 path.
    let nodes: [Node]
    do { nodes = try loadCorpus(rootURL: corpusRoot) }
    catch { print("ERROR loading corpus: \(error)"); return }
    let sample = sampleEligible(nodes, k: 20, seed: 42)
    var contentByID: [String: String] = [:]
    for (n, c) in sample { contentByID[n.id] = truncate800(c) }

    // 5. Iterate records in envelope order so all four matrices share indexing.
    let records = envelope.records
    let n = records.count
    let ids = records.map { $0.nodeID }
    let titles = records.map { $0.title }
    let abstainedID = "E7BCE684-7DFF-4225-B15A-E0DDFEB1BF54"

    // (a) Mean-centered vectors — subtract per-channel corpus mean.
    func centeredChannel(_ picker: (Round4ReadRecord) -> [Double]?) -> [[Double]?] {
        let raws: [[Double]?] = records.map(picker)
        let present = raws.compactMap { $0 }
        guard let mean = vMean(present) else { return raws }
        return raws.map { v in v.map { vSub($0, mean) } }
    }
    let centeredContent = centeredChannel { $0.content }
    let centeredSummary = centeredChannel { $0.summary }
    let centeredFolk = centeredChannel { $0.folksonomy }

    // (b) First-token vectors — re-run embeddingResult per text, take token 0.
    var firstContent: [[Double]?] = Array(repeating: nil, count: n)
    var firstSummary: [[Double]?] = Array(repeating: nil, count: n)
    var firstFolk: [[Double]?] = Array(repeating: nil, count: n)
    for i in 0..<n {
        let r = records[i]
        if let txt = contentByID[r.nodeID] {
            firstContent[i] = firstTokenVector(embedding, text: txt)
        }
        if r.nodeID != abstainedID {
            if !r.summaryText.isEmpty {
                firstSummary[i] = firstTokenVector(embedding, text: r.summaryText)
            }
            if !r.folksonomyPhrase.isEmpty {
                firstFolk[i] = firstTokenVector(embedding, text: r.folksonomyPhrase)
            }
        }
        let cFlag = firstContent[i] == nil ? "·" : "C"
        let sFlag = firstSummary[i] == nil ? "·" : "S"
        let fFlag = firstFolk[i] == nil ? "·" : "F"
        print("  first-token [\(i+1)/\(n)] \(String(r.nodeID.prefix(8))) \(cFlag)\(sFlag)\(fFlag)")
    }

    // 6. Build matrices for: R3, R4-mean (already in envelope), R4b-mc, R4b-ft.
    func buildMatrix(_ vecs: [[Double]?]) -> [[Double?]] {
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            guard let a = vecs[i] else { continue }
            for j in 0..<n {
                if i == j { m[i][j] = 1.0; continue }
                guard let b = vecs[j] else { continue }
                m[i][j] = cosine(a, b)
            }
        }
        return m
    }

    // R4 (mean-pool) — straight from envelope.
    let r4ContentVecs: [[Double]?] = records.map { $0.content }
    let r4SummaryVecs: [[Double]?] = records.map { $0.summary }
    let r4FolkVecs: [[Double]?] = records.map { $0.folksonomy }
    let mContentR4 = buildMatrix(r4ContentVecs)
    let mSummaryR4 = buildMatrix(r4SummaryVecs)
    let mFolkR4 = buildMatrix(r4FolkVecs)

    // R4b mean-centered.
    let mContentMC = buildMatrix(centeredContent)
    let mSummaryMC = buildMatrix(centeredSummary)
    let mFolkMC = buildMatrix(centeredFolk)

    // R4b first-token.
    let mContentFT = buildMatrix(firstContent)
    let mSummaryFT = buildMatrix(firstSummary)
    let mFolkFT = buildMatrix(firstFolk)

    // R3 — align by ID and rebuild matrices.
    let r3ByID = Dictionary(uniqueKeysWithValues: r3List.map { ($0.nodeID, $0) })
    let r3Aligned: [Round3Record?] = ids.map { r3ByID[$0] }
    let r3ContentVecs: [[Double]?] = r3Aligned.map { $0?.content }
    let r3SummaryVecs: [[Double]?] = r3Aligned.map { $0?.summary }
    let r3FolkVecs: [[Double]?] = r3Aligned.map { $0?.folksonomy }
    let mContentR3 = buildMatrix(r3ContentVecs)
    let mSummaryR3 = buildMatrix(r3SummaryVecs)
    let mFolkR3 = buildMatrix(r3FolkVecs)

    // Blend matrices (avg of summary + folksonomy where both defined).
    func blend(_ a: [[Double?]], _ b: [[Double?]]) -> [[Double?]] {
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                if i == j { m[i][j] = 1.0; continue }
                if let s = a[i][j], let f = b[i][j] { m[i][j] = (s + f) / 2.0 }
            }
        }
        return m
    }
    let mBlendR3 = blend(mSummaryR3, mFolkR3)
    let mBlendR4 = blend(mSummaryR4, mFolkR4)
    let mBlendMC = blend(mSummaryMC, mFolkMC)
    let mBlendFT = blend(mSummaryFT, mFolkFT)

    // 7. Aggregate stats per matrix.
    func pairs(_ m: [[Double?]]) -> [(i: Int, j: Int, score: Double)] { r4Pairs(m) }
    func avg(_ ps: [(i: Int, j: Int, score: Double)]) -> Double { r4Avg(ps) }
    func minmax(_ ps: [(i: Int, j: Int, score: Double)]) -> (Double, Double) {
        guard !ps.isEmpty else { return (0, 0) }
        var lo = ps[0].score, hi = ps[0].score
        for p in ps { if p.score < lo { lo = p.score }; if p.score > hi { hi = p.score } }
        return (lo, hi)
    }

    // 8. Per-node top-3 neighbors per matrix (M_blend across all four paths).
    func neighbors(_ m: [[Double?]]) -> [[Neighbor]] {
        (0..<n).map { i in r4TopK(scores: m[i], titles: titles, ids: ids, selfIdx: i, k: 3) }
    }
    let nbBlendR3 = neighbors(mBlendR3)
    let nbBlendR4 = neighbors(mBlendR4)
    let nbBlendMC = neighbors(mBlendMC)
    let nbBlendFT = neighbors(mBlendFT)

    // 9. Render summary-round4b.md.
    var lines: [String] = []
    lines.append("# FM Tagging Diagnostic — Round 4b (mean-centering + first-token)")
    lines.append("")
    lines.append("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    lines.append("- Substrate: same NLContextualEmbedding(.english) Round 4 used. dim=\(embedding.dimension), modelIdentifier=`\(embedding.modelIdentifier)` rev=\(embedding.revision).")
    lines.append("- (a) Mean-centered: per-channel corpus mean subtracted from each vector before cosine. Channels are independent (content / summary / folksonomy each get their own mean).")
    lines.append("- (b) First-token: re-ran `embeddingResult(for:language:)` and took the first subword token's vector instead of mean-pooling. Same model, same texts.")
    lines.append("- Sample size: \(n) (seed=42, regenerated to match Rounds 1–4)")
    lines.append("- E7BCE684 — A5 guardrail violation; summary & folksonomy still skipped, content embedding present in all paths.")
    lines.append("")

    // Section 1 — Aggregate cosine comparison
    lines.append("## Section 1 — Aggregate cosine across four paths")
    lines.append("")
    lines.append("Average / min / max over defined pairs per matrix.")
    lines.append("")
    lines.append("| matrix | R3 NLEmbedding | R4 mean-pool | R4b mean-centered | R4b first-token |")
    lines.append("|---|---|---|---|---|")
    func formatStats(_ ps: [(i: Int, j: Int, score: Double)]) -> String {
        let a = avg(ps); let mm = minmax(ps)
        return String(format: "%.4f (min %.4f, max %.4f)", a, mm.0, mm.1)
    }
    func row3(_ name: String, _ a: [[Double?]], _ b: [[Double?]], _ c: [[Double?]], _ d: [[Double?]]) {
        lines.append("| \(name) | \(formatStats(pairs(a))) | \(formatStats(pairs(b))) | \(formatStats(pairs(c))) | \(formatStats(pairs(d))) |")
    }
    row3("M_content", mContentR3, mContentR4, mContentMC, mContentFT)
    row3("M_summary", mSummaryR3, mSummaryR4, mSummaryMC, mSummaryFT)
    row3("M_folksonomy", mFolkR3, mFolkR4, mFolkMC, mFolkFT)
    row3("M_blend", mBlendR3, mBlendR4, mBlendMC, mBlendFT)
    lines.append("")
    lines.append("Spread (max − min) per M_blend path:")
    let spreads: [(String, [[Double?]])] = [
        ("R3 NLEmbedding", mBlendR3),
        ("R4 mean-pool", mBlendR4),
        ("R4b mean-centered", mBlendMC),
        ("R4b first-token", mBlendFT),
    ]
    for (name, m) in spreads {
        let mm = minmax(pairs(m))
        lines.append("- \(name): \(String(format: "%.4f", mm.1 - mm.0))")
    }
    lines.append("")

    // Section 1b — strongest / weakest pairs per intervention (M_blend only, to keep the file scannable).
    func renderTopBottom(_ name: String, _ m: [[Double?]]) {
        let ps = pairs(m).sorted { $0.score > $1.score }
        lines.append("### \(name) — 5 strongest M_blend pairs")
        lines.append("")
        for p in ps.prefix(5) {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
        lines.append("### \(name) — 5 weakest M_blend pairs")
        lines.append("")
        for p in ps.suffix(5).reversed() {
            let a = String(ids[p.i].prefix(8))
            let b = String(ids[p.j].prefix(8))
            lines.append("- \(String(format: "%.4f", p.score)) — \(a) (\(titles[p.i])) ↔ \(b) (\(titles[p.j]))")
        }
        lines.append("")
    }
    renderTopBottom("R4b mean-centered", mBlendMC)
    renderTopBottom("R4b first-token", mBlendFT)

    // Section 2 — Per-node M_blend top-3 across all four paths.
    lines.append("## Section 2 — Per-node M_blend top-3 across all four paths")
    lines.append("")
    func renderList(_ nb: [Neighbor]) -> String {
        if nb.isEmpty { return "_(none — embedding missing)_" }
        return nb.map { "\(String($0.nodeID.prefix(8))) \($0.title) — \(String(format: "%.4f", $0.score))" }.joined(separator: "; ")
    }
    for i in 0..<n {
        let r = records[i]
        let short = String(r.nodeID.prefix(8))
        lines.append("### \(short) — \(r.title)")
        lines.append("")
        if let note = r.note { lines.append("- note: \(note)") }
        lines.append("- R3 NLEmbedding:    \(renderList(nbBlendR3[i]))")
        lines.append("- R4 mean-pool:      \(renderList(nbBlendR4[i]))")
        lines.append("- R4b mean-centered: \(renderList(nbBlendMC[i]))")
        lines.append("- R4b first-token:   \(renderList(nbBlendFT[i]))")
        // Diff R4b-mc top-3 set vs R3
        let r3Set = Set(nbBlendR3[i].map { $0.nodeID })
        let mcSet = Set(nbBlendMC[i].map { $0.nodeID })
        let ftSet = Set(nbBlendFT[i].map { $0.nodeID })
        if !r3Set.isEmpty {
            let mcMatch = r3Set.intersection(mcSet).count
            let ftMatch = r3Set.intersection(ftSet).count
            lines.append("- top-3 set agreement with R3: mean-centered=\(mcMatch)/\(r3Set.count), first-token=\(ftMatch)/\(r3Set.count)")
        }
        lines.append("")
    }

    // Section 3 — Flagged groupings table (across all four paths).
    lines.append("## Section 3 — Flagged groupings: M_blend across all paths")
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
    lines.append("| pair | R3 | R4 mean-pool | R4b mean-centered | R4b first-token |")
    lines.append("|---|---|---|---|---|")
    let lookups: [(String, String, String)] = [
        ("18C0ADA0", "DF6B5E4B", "Stress Router ↔ Zoom Clustering"),
        ("18C0ADA0", "56C645B8", "Stress Router ↔ Topographic Canvas"),
        ("DF6B5E4B", "56C645B8", "Zoom Clustering ↔ Topographic Canvas"),
        ("9C8F8D6F", "6215BD85", "Hate Faces ↔ Mask Dynamics"),
        ("0A0DB1DA", "948C90CD", "Hole to China ↔ Lights Out"),
    ]
    for (a, b, label) in lookups {
        lines.append("| \(label) | \(fmt(cellPair(a, b, mBlendR3))) | \(fmt(cellPair(a, b, mBlendR4))) | \(fmt(cellPair(a, b, mBlendMC))) | \(fmt(cellPair(a, b, mBlendFT))) |")
    }
    if let vfIdx = indexOfPrefix("0638A25E") {
        func topNeighborStr(_ nb: [[Neighbor]]) -> String {
            guard let n0 = nb[vfIdx].first else { return "—" }
            return "\(String(n0.nodeID.prefix(8))) — \(String(format: "%.4f", n0.score))"
        }
        lines.append("| Vertical Farming nearest neighbor | \(topNeighborStr(nbBlendR3)) | \(topNeighborStr(nbBlendR4)) | \(topNeighborStr(nbBlendMC)) | \(topNeighborStr(nbBlendFT)) |")
    }
    lines.append("")

    // Section 4 — Tomato Recipe outlier check, both new paths.
    lines.append("## Section 4 — Tomato Recipe outlier check across both interventions")
    lines.append("")
    func outlierBlock(_ label: String, _ m: [[Double?]], _ nbList: [[Neighbor]]) {
        guard let ti = indexOfPrefix("7735A62F") else {
            lines.append("Tomato Recipe (7735A62F) not in sample.")
            return
        }
        var rowPairs: [(other: Int, score: Double)] = []
        for j in 0..<n {
            if j == ti { continue }
            if let s = m[ti][j] { rowPairs.append((j, s)) }
        }
        rowPairs.sort { $0.score > $1.score }
        lines.append("### \(label)")
        lines.append("")
        lines.append("- 3 strongest blend partners:")
        for p in rowPairs.prefix(3) {
            lines.append("    - \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) (\(titles[p.other]))")
        }
        lines.append("- 5 weakest blend partners:")
        for p in rowPairs.suffix(5).reversed() {
            lines.append("    - \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) (\(titles[p.other]))")
        }
        var appearances = 0
        for i in 0..<n {
            if i == ti { continue }
            if nbList[i].contains(where: { $0.nodeID == ids[ti] }) { appearances += 1 }
        }
        lines.append("- Tomato Recipe appears in \(appearances) other node's top-3 blend neighbor list.")
        lines.append("")
    }
    outlierBlock("R4b mean-centered", mBlendMC, nbBlendMC)
    outlierBlock("R4b first-token", mBlendFT, nbBlendFT)

    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.data(using: .utf8)!.write(to: outDir.appendingPathComponent("summary-round4b.md"))
        print("Wrote summary-round4b.md.")
    } catch {
        print("ERROR writing summary-round4b.md: \(error)")
    }
}
