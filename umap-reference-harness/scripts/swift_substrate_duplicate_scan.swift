#!/usr/bin/env swift
// Pre-Stage-4b diagnostic — scan the real corpus for byte-identical centered
// substrate vectors on any of the three channels (summary / folksonomy /
// content). Read-only; no AirPad mutation.
//
// Verified-against-source assumptions (see AirPad/Services/SubstrateService.swift
// and AirPad/Models/Node.swift):
//   • Channel vectors on Node are `summaryEmbedding`, `folksonomyEmbedding`,
//     `contextualContentEmbedding`, serialized under JSON keys
//     `summary_embedding`, `folksonomy_embedding`, `contextual_content_embedding`.
//   • Per-channel corpus mean is computed by `SubstrateService.mean(of:)`:
//     accumulate in Double, divide by Double(n), cast back to Float. Means
//     are cached on SubstrateService (`summaryMean` / `folksonomyMean` /
//     `contentMean`), recomputed from all nodes carrying that channel.
//   • Read-time centering inside `centeredCosine` subtracts the cached mean
//     element-wise in Double space: `Double(v[i]) - Double(mean[i])`.
//
// Storage layout (verified against iCloudDriveService.swift):
//   AirPad stores ONE node per file — `nodes/<id>/node.json` under the iCloud
//   Documents root. There is no single `nodes.json` aggregate. This script
//   walks the per-node directories.
//
// Run from the harness root:
//   xcrun --sdk macosx swift scripts/swift_substrate_duplicate_scan.swift

import Foundation

// ===========================================================================
// MARK: - Locate the corpus
// ===========================================================================

let nodesRoot: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents/nodes",
                                isDirectory: true)
}()

guard FileManager.default.fileExists(atPath: nodesRoot.path) else {
    FileHandle.standardError.write(Data("error: nodes directory not found at \(nodesRoot.path)\n".utf8))
    exit(1)
}

let nodeDirs: [URL] = {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: nodesRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: .skipsHiddenFiles
    )) ?? []
    return contents.filter { url in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}()

// ===========================================================================
// MARK: - Minimal per-node decoder
// ===========================================================================

struct NodeEmbeddings: Decodable {
    let id: String
    let summaryEmbedding: [Float]?
    let folksonomyEmbedding: [Float]?
    let contextualContentEmbedding: [Float]?

    enum CodingKeys: String, CodingKey {
        case id
        case summaryEmbedding = "summary_embedding"
        case folksonomyEmbedding = "folksonomy_embedding"
        case contextualContentEmbedding = "contextual_content_embedding"
    }
}

let decoder = JSONDecoder()

var nodes: [NodeEmbeddings] = []
nodes.reserveCapacity(nodeDirs.count)
var readErrors: [(dir: String, error: String)] = []

for dir in nodeDirs {
    let file = dir.appendingPathComponent("node.json")
    guard FileManager.default.fileExists(atPath: file.path) else { continue }
    do {
        let data = try Data(contentsOf: file)
        let node = try decoder.decode(NodeEmbeddings.self, from: data)
        nodes.append(node)
    } catch {
        readErrors.append((dir.lastPathComponent, String(describing: error)))
    }
}

// ===========================================================================
// MARK: - Mean + centering (mirrors SubstrateService.mean / centeredCosine)
// ===========================================================================

func corpusMean(_ vecs: [[Float]]) -> [Float]? {
    guard let first = vecs.first, !first.isEmpty else { return nil }
    let dim = first.count
    var sum = [Double](repeating: 0, count: dim)
    var n = 0
    for v in vecs where v.count == dim {
        for i in 0..<dim { sum[i] += Double(v[i]) }
        n += 1
    }
    guard n > 0 else { return nil }
    let inv = 1.0 / Double(n)
    return sum.map { Float($0 * inv) }
}

/// Per-element: Float(Double(v[i]) - Double(mean[i])). Mirrors the read-time
/// centering done inside `centeredCosine` before the dot product, materialized
/// as [Float] so we can compare element-wise for bit-equality.
func center(_ v: [Float], mean: [Float]) -> [Float] {
    precondition(v.count == mean.count)
    var out = [Float](repeating: 0, count: v.count)
    for i in 0..<v.count {
        out[i] = Float(Double(v[i]) - Double(mean[i]))
    }
    return out
}

/// Byte-identical grouping key: bit pattern of every Float, as [UInt32]. Two
/// vectors collide iff every element compares equal under Float bit-equality.
func bitKey(_ v: [Float]) -> [UInt32] {
    v.map { $0.bitPattern }
}

// ===========================================================================
// MARK: - Per-channel scan
// ===========================================================================

struct ChannelInput {
    let name: String
    let collect: (NodeEmbeddings) -> [Float]?
}

let channels: [ChannelInput] = [
    .init(name: "summary",     collect: { $0.summaryEmbedding }),
    .init(name: "folksonomy",  collect: { $0.folksonomyEmbedding }),
    .init(name: "content",     collect: { $0.contextualContentEmbedding }),
]

struct DuplicateGroup {
    let size: Int
    let nodeIDs: [String]
}

struct ChannelReport {
    let name: String
    let totalNodes: Int
    let dim: Int
    let duplicateGroups: [DuplicateGroup]
    var duplicateGroupCount: Int { duplicateGroups.count }
    var duplicatedNodeCount: Int { duplicateGroups.reduce(0) { $0 + $1.size } }
}

func scan(_ ch: ChannelInput) -> ChannelReport {
    var ids: [String] = []
    var vecs: [[Float]] = []
    for n in nodes {
        guard let v = ch.collect(n), !v.isEmpty else { continue }
        ids.append(n.id)
        vecs.append(v)
    }
    let dim = vecs.first?.count ?? 0

    guard let mean = corpusMean(vecs) else {
        return ChannelReport(name: ch.name, totalNodes: 0, dim: 0, duplicateGroups: [])
    }

    var buckets: [[UInt32]: [String]] = [:]
    buckets.reserveCapacity(vecs.count)
    for (id, v) in zip(ids, vecs) where v.count == mean.count {
        let key = bitKey(center(v, mean: mean))
        buckets[key, default: []].append(id)
    }

    let dupGroups = buckets.values
        .filter { $0.count >= 2 }
        .map { ids -> DuplicateGroup in
            DuplicateGroup(size: ids.count, nodeIDs: ids.sorted())
        }
        .sorted { a, b in
            if a.size != b.size { return a.size > b.size }
            return (a.nodeIDs.first ?? "") < (b.nodeIDs.first ?? "")
        }

    return ChannelReport(
        name: ch.name,
        totalNodes: ids.count,
        dim: dim,
        duplicateGroups: dupGroups
    )
}

let reports = channels.map { scan($0) }

// ===========================================================================
// MARK: - Console summary
// ===========================================================================

print("substrate duplicate scan")
print("  corpus root: \(nodesRoot.path)")
print("  node dirs scanned: \(nodeDirs.count)")
print("  node.json decoded: \(nodes.count)")
if !readErrors.isEmpty {
    print("  decode errors: \(readErrors.count)")
    for e in readErrors.prefix(5) {
        print("    \(e.dir): \(e.error)")
    }
}
print("")

for r in reports {
    print("channel: \(r.name)")
    print("  nodes carrying channel: \(r.totalNodes) (dim=\(r.dim))")
    print("  duplicate groups: \(r.duplicateGroupCount) (nodes in duplicate groups: \(r.duplicatedNodeCount))")
    if r.duplicateGroups.isEmpty {
        print("  -> no byte-identical centered vectors")
    } else {
        for (i, g) in r.duplicateGroups.enumerated() {
            print("  group \(i + 1) (size=\(g.size)):")
            for id in g.nodeIDs { print("    \(id)") }
        }
    }
    print("")
}

// ===========================================================================
// MARK: - JSON report
// ===========================================================================

struct DuplicateGroupJSON: Encodable {
    let size: Int
    let node_ids: [String]
}

struct ChannelReportJSON: Encodable {
    let name: String
    let nodes_with_channel: Int
    let dim: Int
    let duplicate_group_count: Int
    let duplicated_node_count: Int
    let duplicate_groups: [DuplicateGroupJSON]
}

struct ReadErrorJSON: Encodable {
    let dir: String
    let error: String
}

struct ReportJSON: Encodable {
    let generated_at: String
    let corpus_root: String
    let node_dirs_scanned: Int
    let node_json_decoded: Int
    let read_errors: [ReadErrorJSON]
    let channels: [ChannelReportJSON]
}

let now = Date()
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime]
let generatedAt = iso.string(from: now)

let tsFmt = DateFormatter()
tsFmt.dateFormat = "yyyyMMdd-HHmmss"
tsFmt.locale = Locale(identifier: "en_US_POSIX")
tsFmt.timeZone = TimeZone.current
let stamp = tsFmt.string(from: now)

let payload = ReportJSON(
    generated_at: generatedAt,
    corpus_root: nodesRoot.path,
    node_dirs_scanned: nodeDirs.count,
    node_json_decoded: nodes.count,
    read_errors: readErrors.map { ReadErrorJSON(dir: $0.dir, error: $0.error) },
    channels: reports.map { r in
        ChannelReportJSON(
            name: r.name,
            nodes_with_channel: r.totalNodes,
            dim: r.dim,
            duplicate_group_count: r.duplicateGroupCount,
            duplicated_node_count: r.duplicatedNodeCount,
            duplicate_groups: r.duplicateGroups.map {
                DuplicateGroupJSON(size: $0.size, node_ids: $0.nodeIDs)
            }
        )
    }
)

let resultsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("results", isDirectory: true)
try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)

let outURL = resultsDir.appendingPathComponent("substrate_duplicate_scan_\(stamp).json")

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(payload)
try data.write(to: outURL, options: .atomic)

print("wrote: \(outURL.path)")
