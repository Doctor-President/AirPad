import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Round 5 — Full-Corpus Substrate
//
// Scales the Round 4b mean-centered NLContextualEmbedding substrate to the
// full corpus. Generates A4 folksonomy and A5 summary for every node not
// already cached, embeds content/summary/folksonomy, computes mean-centered
// cosine matrices, ranks top-10 neighbors per node per channel, runs
// agglomerative clustering at k=23 over M_blend_centered, and renders
// summary-round5.md.

// MARK: - Cached row read/write (matches Round2ResultRow shape)

struct R5CosineMatch: Codable {
    let folksonomy: String
    let vocab: String
    let score: Double
}

struct R5CacheRow: Codable {
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
    let summaryLatencyMs: Int?
    let cosineMatches: [R5CosineMatch]?
    let error: String?
}

func loadR5Cache(_ url: URL) -> [String: R5CacheRow] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    guard let arr = try? JSONDecoder().decode([R5CacheRow].self, from: data) else {
        print("WARN: failed to decode \(url.lastPathComponent); treating as empty.")
        return [:]
    }
    return Dictionary(uniqueKeysWithValues: arr.map { ($0.nodeID, $0) })
}

func writeR5Cache(_ rows: [R5CacheRow], to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let sorted = rows.sorted { $0.nodeID < $1.nodeID }
    let data = try enc.encode(sorted)
    try data.write(to: url)
}

// MARK: - Persisted output shapes

struct R5EmbeddingRecord: Codable {
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

struct R5EmbeddingEnvelope: Codable {
    let embedder: String
    let dimension: Int
    let recordCount: Int
    let generatedAt: String
    let records: [R5EmbeddingRecord]
}

struct R5SimNeighbor: Codable {
    let nodeID: String
    let title: String
    let score: Double
}

struct R5SimRow: Codable {
    let nodeID: String
    let title: String
    let topContent: [R5SimNeighbor]
    let topSummary: [R5SimNeighbor]
    let topFolksonomy: [R5SimNeighbor]
    let topBlend: [R5SimNeighbor]
}

struct R5ClusterAssignment: Codable {
    let nodeID: String
    let title: String
    let clusterID: Int
}

struct R5ClusterEnvelope: Codable {
    let algorithm: String
    let k: Int
    let assignments: [R5ClusterAssignment]
    let clusterSizes: [String: Int] // keyed by cluster ID as string for stable JSON
}

// MARK: - corpus_index.json reader

struct R5NeighborhoodMember: Decodable {
    let id: String
    let name: String?
    let members: [String]
    enum CodingKeys: String, CodingKey { case id, name, members }
}

struct R5CorpusIndexEnvelope: Decodable {
    let neighborhoods: [String: R5Neighborhood]
}

struct R5Neighborhood: Decodable {
    let id: String?
    let name: String?
    let members: [String]
}

func loadCorpusIndex(_ url: URL) -> [R5Neighborhood] {
    guard let data = try? Data(contentsOf: url) else {
        print("WARN: corpus_index.json missing.")
        return []
    }
    guard let env = try? JSONDecoder().decode(R5CorpusIndexEnvelope.self, from: data) else {
        print("WARN: corpus_index.json decode failed.")
        return []
    }
    return Array(env.neighborhoods.values)
}

// MARK: - Folksonomy/summary generators (no stage 2 — only fmRawTags / fmSummary)

func runA4FolksonomyOnly(content: String) async -> (raw: [String], latencyMs: Int, error: String?) {
    let prompt = buildPromptA4(content: content)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A4Folksonomy.self)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return (response.content.tags, ms, nil)
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ([], ms, "\(type(of: error)): \(error)")
    }
}

// MARK: - Linear algebra helpers

func r5VSub(_ a: [Double], _ b: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: a.count)
    for i in 0..<a.count { out[i] = a[i] - b[i] }
    return out
}

func r5VMean(_ vs: [[Double]]) -> [Double]? {
    guard let first = vs.first else { return nil }
    var sum = [Double](repeating: 0, count: first.count)
    for v in vs { for i in 0..<v.count { sum[i] += v[i] } }
    let inv = 1.0 / Double(vs.count)
    return sum.map { $0 * inv }
}

func r5Norm(_ v: [Double]) -> Double {
    var s = 0.0
    for x in v { s += x * x }
    return s.squareRoot()
}

func r5MaxAbs(_ v: [Double]) -> Double {
    var m = 0.0
    for x in v { let a = abs(x); if a > m { m = a } }
    return m
}

// MARK: - Top-K selection

func r5TopK(_ scores: [Double?], k: Int, selfIdx: Int) -> [(idx: Int, score: Double)] {
    var pairs: [(Int, Double)] = []
    for i in 0..<scores.count {
        if i == selfIdx { continue }
        guard let s = scores[i] else { continue }
        pairs.append((i, s))
    }
    pairs.sort { $0.1 > $1.1 }
    return pairs.prefix(k).map { (idx: $0.0, score: $0.1) }
}

// MARK: - Agglomerative clustering (average linkage, target k clusters)

/// Lance–Williams average-linkage HAC over a pre-computed pairwise *distance*
/// matrix. Distances are 1 - cosine. Stops when `targetK` clusters remain.
/// Returns cluster ID per node (0-indexed, contiguous).
func r5HAC(distance: [[Double]], targetK: Int) -> [Int] {
    let n = distance.count
    var d = distance
    var size = [Int](repeating: 1, count: n)
    var alive = [Bool](repeating: true, count: n)
    var parent = Array(0..<n) // representative cluster for each original index
    var clustersLeft = n

    while clustersLeft > targetK {
        // Find min off-diagonal distance among alive clusters.
        var bestI = -1
        var bestJ = -1
        var bestD = Double.infinity
        for i in 0..<n where alive[i] {
            for j in (i+1)..<n where alive[j] {
                if d[i][j] < bestD {
                    bestD = d[i][j]
                    bestI = i
                    bestJ = j
                }
            }
        }
        if bestI < 0 { break } // safety

        // Merge bestJ into bestI (average linkage).
        let si = size[bestI]
        let sj = size[bestJ]
        let total = si + sj
        for k in 0..<n where alive[k] && k != bestI && k != bestJ {
            let dik = d[bestI][k]
            let djk = d[bestJ][k]
            let merged = (Double(si) * dik + Double(sj) * djk) / Double(total)
            d[bestI][k] = merged
            d[k][bestI] = merged
        }
        size[bestI] = total
        alive[bestJ] = false
        // Update parent map: anyone whose parent is bestJ becomes bestI.
        for k in 0..<n where parent[k] == bestJ { parent[k] = bestI }
        clustersLeft -= 1
    }

    // Renumber surviving clusters to 0..targetK-1.
    var renumber: [Int: Int] = [:]
    var nextID = 0
    var assignment = [Int](repeating: -1, count: n)
    for k in 0..<n {
        let p = parent[k]
        if let id = renumber[p] {
            assignment[k] = id
        } else {
            renumber[p] = nextID
            assignment[k] = nextID
            nextID += 1
        }
    }
    return assignment
}

// MARK: - Cohesion metrics

func r5IntraExtra(matrix m: [[Double?]], memberIdx: Set<Int>, n: Int) -> (intra: Double?, boundary: Double?) {
    var intraSum = 0.0; var intraCnt = 0
    var bndSum = 0.0; var bndCnt = 0
    let mems = Array(memberIdx)
    for a in 0..<mems.count {
        for b in (a+1)..<mems.count {
            if let s = m[mems[a]][mems[b]] { intraSum += s; intraCnt += 1 }
        }
    }
    for i in mems {
        for j in 0..<n {
            if memberIdx.contains(j) || i == j { continue }
            if let s = m[i][j] { bndSum += s; bndCnt += 1 }
        }
    }
    let intra = intraCnt > 0 ? intraSum / Double(intraCnt) : nil
    let boundary = bndCnt > 0 ? bndSum / Double(bndCnt) : nil
    return (intra, boundary)
}

// MARK: - Runner

@available(macOS 14.0, iOS 17.0, *)
func runRound5() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let corpusRoot = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    let outDir = home.appendingPathComponent("Desktop/AirPad/fm-diagnostic-harness")
    let runStart = Date()

    print("=== FM Tagging Diagnostic Harness — Round 5 (Full-Corpus Substrate) ===")
    print("Corpus root: \(corpusRoot.path)")

    // 0. FM availability gate
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }

    // 1. Load corpus + caches
    let nodes: [Node]
    do { nodes = try loadCorpus(rootURL: corpusRoot) }
    catch { print("ERROR loading corpus: \(error)"); return }
    print("Loaded \(nodes.count) nodes from disk.")

    let a4URL = outDir.appendingPathComponent("results-A4.json")
    let a5URL = outDir.appendingPathComponent("results-A5.json")
    var a4Cache = loadR5Cache(a4URL)
    var a5Cache = loadR5Cache(a5URL)
    print("Loaded cache: A4=\(a4Cache.count), A5=\(a5Cache.count)")
    let initialCachedIDs = Set(a4Cache.keys).union(Set(a5Cache.keys))

    // Filter eligible nodes (content >= 20 chars).
    var eligible: [(Node, String)] = []
    var skippedShort = 0
    for n in nodes {
        let c = extractContent(from: n)
        if c.count < 20 { skippedShort += 1; continue }
        eligible.append((n, c))
    }
    eligible.sort { $0.0.id < $1.0.id }
    print("Eligible (>=20 chars): \(eligible.count). Skipped (<20 chars): \(skippedShort).")

    // 2. Stage 1 — generate FM outputs for nodes missing from cache.
    var fmCalls = 0
    var fmRefusals = 0
    var fmErrors = 0
    let stage1Start = Date()
    var newA4Generated = 0
    var newA5Generated = 0

    for (idx, pair) in eligible.enumerated() {
        let (node, content) = pair
        let id = node.id
        let title = node.title ?? "(no title)"

        let needsA4 = a4Cache[id] == nil
        let needsA5 = a5Cache[id] == nil
        if !needsA4 && !needsA5 { continue }

        print("\n[FM \(idx + 1)/\(eligible.count)] \(String(id.prefix(8))) \(title) [content=\(content.count) chars]")

        // A4 — folksonomy stage 1 only.
        if needsA4 {
            let s = Date()
            let r = await runA4FolksonomyOnly(content: content)
            let elapsed = Int(Date().timeIntervalSince(s) * 1000)
            fmCalls += 1
            if let e = r.error {
                fmErrors += 1
                if e.lowercased().contains("guardrail") { fmRefusals += 1 }
                print("  A4 ERROR \(elapsed)ms — \(truncateForLog(e, max: 200))")
            } else {
                print("  A4 ok  \(elapsed)ms folk=\(r.raw)")
            }
            a4Cache[id] = R5CacheRow(
                nodeID: id, title: title, contentTruncated: truncateForLog(content),
                currentTags: node.tags ?? [],
                fmRawTags: r.raw, postFilterTags: [],
                fmTitle: "", fmSummary: "", fmMood: "", fmDomain: "",
                latencyMs: r.latencyMs, summaryLatencyMs: nil,
                cosineMatches: nil, error: r.error
            )
            newA4Generated += 1
        }

        // A5 — production-shape stage 1 only (capture summary).
        if needsA5 {
            let s = Date()
            let r = await runSummaryStage1(content: content, vocabulary: vocabulary)
            let elapsed = Int(Date().timeIntervalSince(s) * 1000)
            fmCalls += 1
            if let e = r.error {
                fmErrors += 1
                if e.lowercased().contains("guardrail") { fmRefusals += 1 }
                print("  A5 ERROR \(elapsed)ms — \(truncateForLog(e, max: 200))")
            } else {
                print("  A5 ok  \(elapsed)ms summary=\"\(truncateForLog(r.summary, max: 100))\"")
            }
            a5Cache[id] = R5CacheRow(
                nodeID: id, title: title, contentTruncated: truncateForLog(content),
                currentTags: node.tags ?? [],
                fmRawTags: [], postFilterTags: [],
                fmTitle: r.title, fmSummary: r.summary, fmMood: r.mood, fmDomain: r.domain,
                latencyMs: r.latencyMs, summaryLatencyMs: r.latencyMs,
                cosineMatches: nil, error: r.error
            )
            newA5Generated += 1
        }

        // Periodic incremental writeback every 25 nodes so a crash doesn't lose
        // an hour of FM time.
        if (newA4Generated + newA5Generated) > 0 && idx % 25 == 0 {
            do {
                try writeR5Cache(Array(a4Cache.values), to: a4URL)
                try writeR5Cache(Array(a5Cache.values), to: a5URL)
                print("  …checkpoint written (A4=\(a4Cache.count), A5=\(a5Cache.count))")
            } catch {
                print("  WARN checkpoint failed: \(error)")
            }
        }
    }

    let stage1Time = Date().timeIntervalSince(stage1Start)
    print("\nStage 1 done: FM calls=\(fmCalls) errors=\(fmErrors) refusals=\(fmRefusals) elapsed=\(Int(stage1Time))s")
    if fmCalls > 0 {
        let refusalRate = Double(fmRefusals) / Double(fmCalls)
        if refusalRate > 0.10 {
            print("⚠️  FM refusal rate \(String(format: "%.1f%%", refusalRate * 100)) exceeds 10% — surfacing per brief.")
        }
        if stage1Time > 90 * 60 {
            print("⚠️  Stage 1 elapsed \(Int(stage1Time))s exceeds 90-minute budget — surfacing per brief.")
        }
    }

    // Final writeback for caches.
    do {
        try writeR5Cache(Array(a4Cache.values), to: a4URL)
        try writeR5Cache(Array(a5Cache.values), to: a5URL)
        print("Wrote results-A4.json (\(a4Cache.count) records), results-A5.json (\(a5Cache.count) records).")
    } catch {
        print("ERROR writing cache files: \(error)")
        return
    }

    // 3. Stage 2 — Embeddings.
    print("\n=== Stage 2 — embeddings ===")
    guard let embedding = NLContextualEmbedding(language: .english) else {
        print("ERROR: NLContextualEmbedding init failed."); return
    }
    let okLoad = await ensureAssetsAndLoad(embedding)
    guard okLoad else { print("ERROR: NLContextualEmbedding load failed."); return }
    print("NLContextualEmbedding loaded: dim=\(embedding.dimension) maxLen=\(embedding.maximumSequenceLength)")

    let stage2Start = Date()
    var embRecords: [R5EmbeddingRecord] = []
    var embedFails = 0
    for (i, pair) in eligible.enumerated() {
        let (node, content) = pair
        let id = node.id
        let title = node.title ?? "(no title)"
        let truncated = truncate800(content)

        let folkTags = a4Cache[id]?.fmRawTags ?? []
        let folkPhrase = folkTags.joined(separator: ", ")
        let summaryText = a5Cache[id]?.fmSummary ?? ""

        var contentVec: [Double]? = nil
        var summaryVec: [Double]? = nil
        var folkVec: [Double]? = nil
        var noteParts: [String] = []

        if !truncated.isEmpty {
            contentVec = meanPooled(embedding, text: truncated)
            if contentVec == nil { embedFails += 1; noteParts.append("content embed nil") }
        } else {
            noteParts.append("empty content")
        }

        if !summaryText.isEmpty {
            summaryVec = meanPooled(embedding, text: summaryText)
            if summaryVec == nil { noteParts.append("summary embed nil") }
        } else {
            noteParts.append("missing/empty A5 summary")
        }

        if !folkPhrase.isEmpty {
            folkVec = meanPooled(embedding, text: folkPhrase)
            if folkVec == nil { noteParts.append("folksonomy embed nil") }
        } else {
            noteParts.append("missing/empty A4 folksonomy")
        }

        embRecords.append(R5EmbeddingRecord(
            nodeID: id, title: title,
            contentChars: truncated.count,
            folksonomyPhrase: folkPhrase, summaryText: summaryText,
            content: contentVec, summary: summaryVec, folksonomy: folkVec,
            note: noteParts.isEmpty ? nil : noteParts.joined(separator: "; ")
        ))

        if (i + 1) % 25 == 0 || i == eligible.count - 1 {
            print("  embed [\(i + 1)/\(eligible.count)] \(String(id.prefix(8)))")
        }
    }
    let stage2Time = Date().timeIntervalSince(stage2Start)
    print("Stage 2 done: records=\(embRecords.count) elapsed=\(String(format: "%.1f", stage2Time))s embed fails=\(embedFails)")

    // Persist envelope.
    let envelope = R5EmbeddingEnvelope(
        embedder: "NLContextualEmbedding(language: .english) [\(embedding.modelIdentifier) rev=\(embedding.revision)]",
        dimension: embedding.dimension,
        recordCount: embRecords.count,
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        records: embRecords
    )
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(envelope)
        try data.write(to: outDir.appendingPathComponent("embeddings-corpus.json"))
        print("Wrote embeddings-corpus.json (\(data.count) bytes).")
    } catch {
        print("ERROR writing embeddings-corpus.json: \(error)")
    }

    // 4. Stage 3 — center, build matrices, top-10 neighbors per node.
    print("\n=== Stage 3 — centered cosine matrices ===")
    let n = embRecords.count
    let ids = embRecords.map { $0.nodeID }
    let titles = embRecords.map { $0.title }
    let idToIdx: [String: Int] = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })

    func centeredVecs(_ picker: (R5EmbeddingRecord) -> [Double]?) -> ([[Double]?], [Double]?) {
        let raws: [[Double]?] = embRecords.map(picker)
        let present = raws.compactMap { $0 }
        guard let mean = r5VMean(present) else { return (raws, nil) }
        return (raws.map { v in v.map { r5VSub($0, mean) } }, mean)
    }
    let (contentC, contentMean) = centeredVecs { $0.content }
    let (summaryC, summaryMean) = centeredVecs { $0.summary }
    let (folkC, folkMean) = centeredVecs { $0.folksonomy }

    // Mean vector sanity stats.
    func meanStats(_ name: String, _ v: [Double]?) {
        guard let v = v else { print("  mean[\(name)]: missing"); return }
        let nrm = r5Norm(v)
        let mx = r5MaxAbs(v)
        print("  mean[\(name)]: dim=\(v.count) norm=\(String(format: "%.4f", nrm)) maxAbs=\(String(format: "%.4f", mx))")
        if nrm > 1e3 || mx > 1e2 {
            print("  ⚠️  mean[\(name)] components extreme — surfacing per brief.")
        }
    }
    meanStats("content", contentMean)
    meanStats("summary", summaryMean)
    meanStats("folksonomy", folkMean)

    func buildMatrix(_ vecs: [[Double]?]) -> [[Double?]] {
        var m = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
        for i in 0..<n {
            guard let a = vecs[i] else { continue }
            for j in i..<n {
                if i == j { m[i][j] = 1.0; continue }
                guard let b = vecs[j] else { continue }
                let c = cosine(a, b)
                m[i][j] = c
                m[j][i] = c
            }
        }
        return m
    }

    let mContent = buildMatrix(contentC)
    let mSummary = buildMatrix(summaryC)
    let mFolk = buildMatrix(folkC)
    var mBlend = Array(repeating: Array<Double?>(repeating: nil, count: n), count: n)
    for i in 0..<n {
        for j in 0..<n {
            if i == j { mBlend[i][j] = 1.0; continue }
            if let s = mSummary[i][j], let f = mFolk[i][j] {
                mBlend[i][j] = (s + f) / 2.0
            }
        }
    }

    // Aggregate stats per matrix.
    func pairs(_ m: [[Double?]]) -> [(i: Int, j: Int, score: Double)] {
        var out: [(Int, Int, Double)] = []
        for i in 0..<n {
            for j in (i+1)..<n {
                if let s = m[i][j] { out.append((i, j, s)) }
            }
        }
        return out
    }
    func aggStats(_ ps: [(i: Int, j: Int, score: Double)]) -> (avg: Double, lo: Double, hi: Double) {
        guard !ps.isEmpty else { return (0, 0, 0) }
        var lo = ps[0].score, hi = ps[0].score, sum = 0.0
        for p in ps { sum += p.score; if p.score < lo { lo = p.score }; if p.score > hi { hi = p.score } }
        return (sum / Double(ps.count), lo, hi)
    }
    let pContent = pairs(mContent)
    let pSummary = pairs(mSummary)
    let pFolk = pairs(mFolk)
    let pBlend = pairs(mBlend)
    let aContent = aggStats(pContent)
    let aSummary = aggStats(pSummary)
    let aFolk = aggStats(pFolk)
    let aBlend = aggStats(pBlend)
    print("  M_content     avg=\(String(format: "%.4f", aContent.avg)) min=\(String(format: "%.4f", aContent.lo)) max=\(String(format: "%.4f", aContent.hi)) spread=\(String(format: "%.4f", aContent.hi - aContent.lo))")
    print("  M_summary     avg=\(String(format: "%.4f", aSummary.avg)) min=\(String(format: "%.4f", aSummary.lo)) max=\(String(format: "%.4f", aSummary.hi)) spread=\(String(format: "%.4f", aSummary.hi - aSummary.lo))")
    print("  M_folksonomy  avg=\(String(format: "%.4f", aFolk.avg)) min=\(String(format: "%.4f", aFolk.lo)) max=\(String(format: "%.4f", aFolk.hi)) spread=\(String(format: "%.4f", aFolk.hi - aFolk.lo))")
    print("  M_blend       avg=\(String(format: "%.4f", aBlend.avg)) min=\(String(format: "%.4f", aBlend.lo)) max=\(String(format: "%.4f", aBlend.hi)) spread=\(String(format: "%.4f", aBlend.hi - aBlend.lo))")

    // Surface degeneracy if all near 0 or all near same value.
    if aBlend.hi - aBlend.lo < 0.01 {
        print("⚠️  M_blend spread <0.01 — degenerate substrate. Surfacing per brief.")
    }

    // Top-10 per channel per node.
    func topKList(_ m: [[Double?]], k: Int) -> [[R5SimNeighbor]] {
        (0..<n).map { i in
            r5TopK(m[i], k: k, selfIdx: i).map { hit in
                R5SimNeighbor(nodeID: ids[hit.idx], title: titles[hit.idx], score: hit.score)
            }
        }
    }
    let nbContent = topKList(mContent, k: 10)
    let nbSummary = topKList(mSummary, k: 10)
    let nbFolk = topKList(mFolk, k: 10)
    let nbBlend = topKList(mBlend, k: 10)

    // Persist corpus-similarity.json.
    var simRows: [R5SimRow] = []
    for i in 0..<n {
        simRows.append(R5SimRow(
            nodeID: ids[i], title: titles[i],
            topContent: nbContent[i], topSummary: nbSummary[i],
            topFolksonomy: nbFolk[i], topBlend: nbBlend[i]
        ))
    }
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(simRows.sorted { $0.nodeID < $1.nodeID })
        try data.write(to: outDir.appendingPathComponent("corpus-similarity.json"))
        print("Wrote corpus-similarity.json (\(data.count) bytes).")
    } catch {
        print("ERROR writing corpus-similarity.json: \(error)")
    }

    // 5. Stage 4 — Agglomerative clustering on M_blend_centered.
    print("\n=== Stage 4 — agglomerative clustering on M_blend_centered ===")
    let targetK = 23
    var distance = Array(repeating: [Double](repeating: 1.0, count: n), count: n)
    var pairsWithBlend = 0
    for i in 0..<n {
        for j in 0..<n {
            if i == j { distance[i][j] = 0; continue }
            if let s = mBlend[i][j] {
                distance[i][j] = max(0.0, 1.0 - s)
                if i < j { pairsWithBlend += 1 }
            } else {
                distance[i][j] = 1.0 // missing-pair fallback (max distance)
            }
        }
    }
    print("  blend-defined pairs: \(pairsWithBlend) of \(n * (n - 1) / 2)")
    let stage4Start = Date()
    let assignment = r5HAC(distance: distance, targetK: targetK)
    let stage4Time = Date().timeIntervalSince(stage4Start)
    print("  HAC complete in \(String(format: "%.1f", stage4Time))s")

    // Cluster sizes.
    var sizeByID: [Int: Int] = [:]
    for c in assignment { sizeByID[c, default: 0] += 1 }
    let sortedSizes = sizeByID.sorted { $0.value > $1.value }
    print("  cluster sizes (sorted): \(sortedSizes.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")

    // Persist corpus-clusters.json.
    var clusterRows: [R5ClusterAssignment] = []
    for i in 0..<n {
        clusterRows.append(R5ClusterAssignment(
            nodeID: ids[i], title: titles[i], clusterID: assignment[i]
        ))
    }
    let clusterEnv = R5ClusterEnvelope(
        algorithm: "agglomerative average-linkage on (1 - cosine(M_blend_centered))",
        k: targetK,
        assignments: clusterRows.sorted { $0.nodeID < $1.nodeID },
        clusterSizes: Dictionary(uniqueKeysWithValues: sizeByID.map { (String($0.key), $0.value) })
    )
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(clusterEnv)
        try data.write(to: outDir.appendingPathComponent("corpus-clusters.json"))
        print("Wrote corpus-clusters.json (\(data.count) bytes).")
    } catch {
        print("ERROR writing corpus-clusters.json: \(error)")
    }

    // 6. Section 3 — neighborhood cohesion.
    let neighborhoods = loadCorpusIndex(corpusRoot.appendingPathComponent("corpus_index.json"))
    print("\n=== Section 3 prep — \(neighborhoods.count) neighborhoods loaded ===")

    struct NbhStat {
        let name: String
        let memberCount: Int
        let intra: Double?
        let boundary: Double?
        let cohesionRatio: Double?
    }
    var nbhStats: [NbhStat] = []
    for nbh in neighborhoods {
        let memberIdx: Set<Int> = Set(nbh.members.compactMap { idToIdx[$0] })
        let stats = r5IntraExtra(matrix: mBlend, memberIdx: memberIdx, n: n)
        let ratio: Double?
        if let i = stats.intra, let b = stats.boundary, b != 0 { ratio = i / b } else { ratio = nil }
        nbhStats.append(NbhStat(
            name: nbh.name ?? "(unnamed)",
            memberCount: nbh.members.count,
            intra: stats.intra,
            boundary: stats.boundary,
            cohesionRatio: ratio
        ))
    }
    nbhStats.sort {
        // Sort by member count desc, then ratio desc, name asc.
        if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
        let a = $0.cohesionRatio ?? -.infinity
        let b = $1.cohesionRatio ?? -.infinity
        if a != b { return a > b }
        return $0.name < $1.name
    }

    // 7. Section 4 — specimen carry-over.
    let specimenIDs: [String] = [
        "C57169F2-6217-430E-BEEB-799B0189BAF1",
        "70A66523-9B31-42A0-9021-8988E09C6A46",
        "0A0DB1DA-B0F0-463D-BF1F-F07DCA0E000C",
        "1E9C4DEF", "42B8C8DB", "3B5584B8", "6215BD85", "18C0ADA0",
        "0638A25E", "DF6B5E4B", "56C645B8", "DDC66F15", "948C90CD",
        "09C7E791", "DEA2B9DB", "9C8F8D6F", "7735A62F", "4B5E9285",
        "FF43DCC8", "E7BCE684"
    ]
    func indexOfPrefix(_ p: String) -> Int? {
        for i in 0..<n { if ids[i].hasPrefix(p.prefix(8)) { return i } }
        return nil
    }

    // 8. Section 6 — Tomato Recipe outlier check.
    let tomatoIdx = indexOfPrefix("7735A62F")
    var tomatoRow: [(other: Int, score: Double)] = []
    if let ti = tomatoIdx {
        for j in 0..<n {
            if j == ti { continue }
            if let s = mBlend[ti][j] { tomatoRow.append((j, s)) }
        }
        tomatoRow.sort { $0.score > $1.score }
    }

    // 9. Render summary-round5.md.
    var L: [String] = []
    func a(_ s: String) { L.append(s) }
    a("# FM Tagging Diagnostic — Round 5 (Full-Corpus Substrate)")
    a("")
    a("- Run date: \(ISO8601DateFormatter().string(from: Date()))")
    a("- Embedder: NLContextualEmbedding(.english) modelIdentifier=`\(embedding.modelIdentifier)` rev=\(embedding.revision) dim=\(embedding.dimension)")
    a("- Method: mean-centering per channel (Round 4b winner). Per-pair blend = average(summary, folksonomy) where both defined.")
    a("- Clustering: agglomerative average-linkage HAC over (1 − cosine(M_blend_centered)), target k=\(targetK).")
    a("- Total run elapsed (incl. FM): \(String(format: "%.1f", Date().timeIntervalSince(runStart)))s")
    a("")

    // -- Section 1
    a("## Section 1 — Setup and stats")
    a("")
    a("- Total nodes loaded from disk: \(nodes.count)")
    a("- Skipped (<20 chars content): \(skippedShort)")
    a("- Eligible nodes embedded: \(eligible.count)")
    a("- Cached A4/A5 at start of run: \(initialCachedIDs.count) (specimens from prior rounds)")
    a("- New A4 generated this run: \(newA4Generated)")
    a("- New A5 generated this run: \(newA5Generated)")
    a("- Total FM calls this run: \(fmCalls)")
    a("- FM errors (any cause): \(fmErrors)")
    a("- FM guardrail refusals: \(fmRefusals)")
    if fmCalls > 0 {
        let rate = Double(fmRefusals) / Double(fmCalls) * 100
        a("- Refusal rate: \(String(format: "%.1f%%", rate))")
    }
    a("- Stage 1 (FM) elapsed: \(String(format: "%.1f", stage1Time))s")
    a("- Stage 2 (embed) elapsed: \(String(format: "%.1f", stage2Time))s")
    a("- Stage 4 (HAC) elapsed: \(String(format: "%.1f", stage4Time))s")
    a("- Embed fails: \(embedFails)")
    a("")
    func meanLine(_ name: String, _ v: [Double]?) -> String {
        guard let v = v else { return "- mean[\(name)]: missing" }
        return "- mean[\(name)]: dim=\(v.count) norm=\(String(format: "%.4f", r5Norm(v))) maxAbs=\(String(format: "%.4f", r5MaxAbs(v)))"
    }
    a(meanLine("content", contentMean))
    a(meanLine("summary", summaryMean))
    a(meanLine("folksonomy", folkMean))
    a("")

    // -- Section 2
    a("## Section 2 — Aggregate similarity (centered)")
    a("")
    a("| matrix | defined pairs | avg | min | max | spread |")
    a("|---|---|---|---|---|---|")
    func row2(_ name: String, _ ps: [(i: Int, j: Int, score: Double)], _ s: (avg: Double, lo: Double, hi: Double)) {
        a("| \(name) | \(ps.count) | \(String(format: "%.4f", s.avg)) | \(String(format: "%.4f", s.lo)) | \(String(format: "%.4f", s.hi)) | \(String(format: "%.4f", s.hi - s.lo)) |")
    }
    row2("M_content_centered", pContent, aContent)
    row2("M_summary_centered", pSummary, aSummary)
    row2("M_folksonomy_centered", pFolk, aFolk)
    row2("M_blend_centered", pBlend, aBlend)
    a("")
    a("### M_blend_centered — 5 strongest pairs corpus-wide")
    a("")
    let blendSorted = pBlend.sorted { $0.score > $1.score }
    for p in blendSorted.prefix(5) {
        a("- \(String(format: "%.4f", p.score)) — \(String(ids[p.i].prefix(8))) (\(titles[p.i])) ↔ \(String(ids[p.j].prefix(8))) (\(titles[p.j]))")
    }
    a("")
    a("### M_blend_centered — 5 weakest pairs corpus-wide")
    a("")
    for p in blendSorted.suffix(5).reversed() {
        a("- \(String(format: "%.4f", p.score)) — \(String(ids[p.i].prefix(8))) (\(titles[p.i])) ↔ \(String(ids[p.j].prefix(8))) (\(titles[p.j]))")
    }
    a("")

    // -- Section 3
    a("## Section 3 — Comparison to existing neighborhoods (M_blend_centered)")
    a("")
    a("Note: corpus_index.json contains \(neighborhoods.count) neighborhoods (not 23 as the brief estimated). Listed by member count desc.")
    a("")
    a("| neighborhood | members | intra | boundary | ratio (intra/boundary) |")
    a("|---|---|---|---|---|")
    func fmtO(_ d: Double?) -> String { d.map { String(format: "%.4f", $0) } ?? "—" }
    for s in nbhStats {
        let nameEsc = s.name.replacingOccurrences(of: "|", with: "\\|")
        a("| \(nameEsc) | \(s.memberCount) | \(fmtO(s.intra)) | \(fmtO(s.boundary)) | \(fmtO(s.cohesionRatio)) |")
    }
    a("")

    // -- Section 4
    a("## Section 4 — Specimen carry-over (top-3 corpus-wide vs Round 4b 20-node sample)")
    a("")
    a("Top-3 nearest-neighbor lists under M_blend_centered, computed against the full corpus. Round 4b's 20-node sample top-3s aren't reproduced inline here — refer to summary-round4b.md Section 2 for side-by-side.")
    a("")
    for spec in specimenIDs {
        guard let i = indexOfPrefix(spec) else {
            a("- \(spec) — not in eligible set")
            continue
        }
        let short = String(ids[i].prefix(8))
        a("### \(short) — \(titles[i])")
        a("")
        let top3 = Array(nbBlend[i].prefix(3))
        if top3.isEmpty {
            a("- (no defined blend neighbors — embedding missing)")
        } else {
            for nb in top3 {
                a("- \(String(format: "%.4f", nb.score)) — \(String(nb.nodeID.prefix(8))) \(nb.title)")
            }
        }
        a("")
    }

    // -- Section 5
    a("## Section 5 — Embedding-derived clusters (HAC, k=\(targetK))")
    a("")
    a("- Number of clusters: \(sortedSizes.count)")
    a("- Size distribution (sorted desc): \(sortedSizes.map { String($0.value) }.joined(separator: ", "))")
    a("- Noise/unclustered: 0 (HAC at fixed k assigns every node)")
    a("")
    a("### Five largest embedding-derived clusters — sample members")
    a("")
    var byCluster: [Int: [Int]] = [:]
    for (i, c) in assignment.enumerated() { byCluster[c, default: []].append(i) }
    let topClusters = byCluster.sorted { $0.value.count > $1.value.count }.prefix(5)
    for (cid, members) in topClusters {
        a("**Cluster \(cid)** (size \(members.count)):")
        for mi in members.prefix(5) {
            a("- \(String(ids[mi].prefix(8))) \(titles[mi])")
        }
        a("")
    }

    // -- Section 6
    a("## Section 6 — Tomato Recipe outlier sanity check")
    a("")
    if let ti = tomatoIdx {
        let title = titles[ti]
        a("Tomato Recipe (`\(String(ids[ti].prefix(8)))` — \(title)) row stats over M_blend_centered:")
        a("")
        // Average M_blend cosine of Tomato vs corpus.
        var tSum = 0.0; var tCnt = 0
        for j in 0..<n {
            if j == ti { continue }
            if let s = mBlend[ti][j] { tSum += s; tCnt += 1 }
        }
        let tAvg = tCnt > 0 ? tSum / Double(tCnt) : 0
        // Rank by node-mean blend score (mean over column j).
        var nodeMean: [(idx: Int, mean: Double)] = []
        for i in 0..<n {
            var s = 0.0; var c = 0
            for j in 0..<n {
                if i == j { continue }
                if let v = mBlend[i][j] { s += v; c += 1 }
            }
            if c > 0 { nodeMean.append((i, s / Double(c))) }
        }
        nodeMean.sort { $0.mean < $1.mean }
        let rank = nodeMean.firstIndex(where: { $0.idx == ti }).map { $0 + 1 } ?? -1
        a("- Tomato Recipe avg M_blend_centered cosine to corpus: \(String(format: "%.4f", tAvg)) (negative ↔ pulls below mean)")
        a("- Distinctness rank (1 = most distinct, lowest mean cosine): \(rank) of \(nodeMean.count)")
        a("")
        a("### 5 strongest M_blend_centered partners")
        a("")
        for p in tomatoRow.prefix(5) {
            a("- \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) \(titles[p.other])")
        }
        a("")
        a("### 5 weakest M_blend_centered partners")
        a("")
        for p in tomatoRow.suffix(5).reversed() {
            a("- \(String(format: "%.4f", p.score)) — \(String(ids[p.other].prefix(8))) \(titles[p.other])")
        }
        a("")
    } else {
        a("Tomato Recipe (7735A62F) not in eligible set.")
    }

    let text = L.joined(separator: "\n") + "\n"
    do {
        try text.data(using: .utf8)!.write(to: outDir.appendingPathComponent("summary-round5.md"))
        print("\nWrote summary-round5.md.")
    } catch {
        print("ERROR writing summary-round5.md: \(error)")
    }

    print("\n=== Round 5 complete in \(String(format: "%.1f", Date().timeIntervalSince(runStart)))s ===")
}
