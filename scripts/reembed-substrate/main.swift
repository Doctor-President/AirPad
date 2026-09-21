// One-off substrate re-embed — NOT shipped app code.
//
// Re-embeds the three substrate channels (summary / folksonomy / contextual_content) with
// BGE-micro 384-d and tags each with its `VectorBasis`, closing the 512-d NLContextual tail.
//
// ★ WHY A SCRIPT AND NOT A MIGRATION. AirPad has never been released — population is 1. A shipped
// upgrade path would be permanent carrying cost for users who do not exist. T runs this once.
//
// ★ PRIVACY. Prints ONLY aggregates: counts, dimension histograms, elapsed time. It never prints
// node text, titles, tags or any vector. The only strings it handles are JSON keys and node IDs.
//
// ★ PRESERVES UNKNOWN FIELDS. Works on `JSONSerialization` dictionaries, never on a typed model —
// decoding into a struct and re-encoding would silently DROP any field this tool doesn't model.
//
// Idempotent + resumable: a node already carrying all its expected basis tags at the target version
// is skipped, so re-running after an interruption costs only the walk.

import CoreML
import Foundation

// MARK: - Constants (mirror the app)

let kEmbedder = "bge-micro-384"
let kTargetVersion = 2            // SubstrateService.currentEmbeddingVersion
let kMaxEmbedChars = 3200         // SubstrateService.maxEmbedChars
let kSequenceLength = 512         // CardEmbeddingService.sequenceLength
let kThinContentThreshold = 20    // SubstrateService.thinContentThreshold

func basis(_ channel: String) -> String { "\(kEmbedder)/\(channel)" }

// MARK: - Args

var args = Array(CommandLine.arguments.dropFirst())
var dryRun = false
var force = false
args.removeAll { a in
    if a == "--dry-run" { dryRun = true; return true }
    if a == "--force" { force = true; return true }
    return false
}
guard let root = args.first else {
    FileHandle.standardError.write(Data("""
    usage: reembed-substrate <corpus-root> [--dry-run] [--force]
      <corpus-root>  directory containing nodes/<id>/node.json
      --dry-run      report what WOULD change; write nothing, back up nothing
      --force        re-embed even nodes already tagged at the target version

    """.utf8))
    exit(2)
}
let rootURL = URL(fileURLWithPath: root, isDirectory: true)
let nodesURL = rootURL.appendingPathComponent("nodes", isDirectory: true)
guard FileManager.default.fileExists(atPath: nodesURL.path) else {
    FileHandle.standardError.write(Data("no nodes/ under \(root)\n".utf8))
    exit(1)
}

// MARK: - Model

guard let modelURL = findModel() else {
    FileHandle.standardError.write(Data("could not locate a compiled BGEMicro.mlmodelc (see run.sh)\n".utf8))
    exit(1)
}
guard let vocabURL = findVocab(), let tokenizer = WordPieceTokenizer(vocabURL: vocabURL) else {
    FileHandle.standardError.write(Data("could not load vocab.txt\n".utf8))
    exit(1)
}
let config = MLModelConfiguration()
config.computeUnits = .all
guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
    FileHandle.standardError.write(Data("could not load the Core ML model\n".utf8))
    exit(1)
}

func findModel() -> URL? {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for c in [here.appendingPathComponent("BGEMicro.mlmodelc"),
              URL(fileURLWithPath: "/tmp/airpad-reembed/BGEMicro.mlmodelc")]
    where FileManager.default.fileExists(atPath: c.path) { return c }
    return nil
}
func findVocab() -> URL? {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let repo = here.deletingLastPathComponent().deletingLastPathComponent()
    for c in [here.appendingPathComponent("vocab.txt"),
              repo.appendingPathComponent("AirPad/Resources/BGE/vocab.txt")]
    where FileManager.default.fileExists(atPath: c.path) { return c }
    return nil
}

/// Mirrors `CardEmbeddingService.embed` exactly — same tokenizer, same sequence length, same model,
/// so a vector written here is identical to one the app would write for the same text.
func embed(_ text: String) -> [Float]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let capped = trimmed.count > kMaxEmbedChars ? String(trimmed.prefix(kMaxEmbedChars)) : trimmed
    let (ids, mask) = tokenizer.encode(capped, maxLength: kSequenceLength)
    guard let idsArray = int32Array(ids), let maskArray = int32Array(mask),
          let provider = try? MLDictionaryFeatureProvider(dictionary: [
              "input_ids": MLFeatureValue(multiArray: idsArray),
              "attention_mask": MLFeatureValue(multiArray: maskArray),
          ]),
          let out = try? model.prediction(from: provider),
          let emb = out.featureValue(for: "embedding")?.multiArrayValue
    else { return nil }
    var v = [Float](repeating: 0, count: emb.count)
    for i in 0..<emb.count { v[i] = emb[i].floatValue }
    return v
}
func int32Array(_ values: [Int32]) -> MLMultiArray? {
    guard let a = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else { return nil }
    let p = a.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
    for i in 0..<values.count { p[i] = values[i] }
    return a
}

/// Mirrors `CorpusStore.extractNodeContent`.
func extractContent(_ node: [String: Any]) -> String {
    guard let items = node["items"] as? [[String: Any]] else { return "" }
    return items.compactMap { item -> String? in
        switch item["type"] as? String {
        case "text":            return item["content"] as? String
        case "audio", "video":  return item["transcript"] as? String
        case "image", "document": return item["description"] as? String
        case "link":
            return [item["title"] as? String, item["preview"] as? String]
                .compactMap { $0 }.joined(separator: " ")
        default: return nil
        }
    }.filter { !$0.isEmpty }.joined(separator: "\n")
}

// MARK: - Backup

var backupPath = "(dry run — none)"
if !dryRun {
    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let dest = rootURL.deletingLastPathComponent()
        .appendingPathComponent(rootURL.lastPathComponent + ".backup-" + stamp)
    do {
        try FileManager.default.copyItem(at: rootURL, to: dest)
        backupPath = dest.path
    } catch {
        FileHandle.standardError.write(Data("BACKUP FAILED — refusing to write: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Walk

var total = 0, skippedAlready = 0, skippedNoText = 0, changed = 0, failed = 0
var wroteSummary = 0, wroteFolksonomy = 0, wroteContent = 0
var beforeDims: [Int: Int] = [:], afterDims: [Int: Int] = [:]
let started = Date()

let ids = (try? FileManager.default.contentsOfDirectory(atPath: nodesURL.path))?.sorted() ?? []
for nid in ids {
    let file = nodesURL.appendingPathComponent(nid).appendingPathComponent("node.json")
    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          var node = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { continue }
    total += 1

    for key in ["summary_embedding", "folksonomy_embedding", "contextual_content_embedding"] {
        if let v = node[key] as? [Any], !v.isEmpty { beforeDims[v.count, default: 0] += 1 }
    }

    // Done == at the target version AND every vector present carries a basis tag.
    func tagged(_ vec: String, _ tag: String) -> Bool {
        let hasVec = (node[vec] as? [Any])?.isEmpty == false
        return !hasVec || node[tag] != nil
    }
    let alreadyDone = (node["embedding_version"] as? Int) == kTargetVersion
        && tagged("summary_embedding", "summary_embedding_basis")
        && tagged("folksonomy_embedding", "folksonomy_embedding_basis")
        && tagged("contextual_content_embedding", "contextual_content_embedding_basis")
    if alreadyDone && !force {
        skippedAlready += 1
        for key in ["summary_embedding", "folksonomy_embedding", "contextual_content_embedding"] {
            if let v = node[key] as? [Any], !v.isEmpty { afterDims[v.count, default: 0] += 1 }
        }
        continue
    }

    let summaryText = (node["substrate_summary"] as? String) ?? ""
    let folksonomyText = ((node["folksonomy"] as? [String]) ?? []).joined(separator: ", ")
    let contentText = extractContent(node)

    // Thin content keeps its app-side shape: no summary/folksonomy, content only.
    let isThin = contentText.trimmingCharacters(in: .whitespacesAndNewlines).count < kThinContentThreshold

    var touched = false
    /// ★ CLEARS the channel when it cannot be re-embedded. Leaving a stale 512-d vector in place —
    /// because its source text is gone, or the node is thin — would preserve exactly the second
    /// basis this migration exists to remove. An ABSENT vector is honest ("no signal, excluded");
    /// a surviving 512-d one is the bug wearing a different hat.
    func put(_ key: String, _ basisKey: String, _ text: String, _ channel: String) {
        func clear() {
            if node[key] != nil || node[basisKey] != nil { touched = true }
            node.removeValue(forKey: key)
            node.removeValue(forKey: basisKey)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { clear(); return }
        guard let v = embed(text) else { failed += 1; clear(); return }
        node[key] = v
        node[basisKey] = basis(channel)
        touched = true
        switch channel {
        case "summary": wroteSummary += 1
        case "folksonomy": wroteFolksonomy += 1
        default: wroteContent += 1
        }
    }
    if !isThin {
        put("summary_embedding", "summary_embedding_basis", summaryText, "summary")
        put("folksonomy_embedding", "folksonomy_embedding_basis", folksonomyText, "folksonomy")
    } else {
        // Thin content carries no summary/folksonomy in the app either — clear, don't strand.
        put("summary_embedding", "summary_embedding_basis", "", "summary")
        put("folksonomy_embedding", "folksonomy_embedding_basis", "", "folksonomy")
    }
    put("contextual_content_embedding", "contextual_content_embedding_basis", contentText, "content")

    if touched {
        node["embedding_version"] = kTargetVersion
        changed += 1
        if !dryRun {
            guard let out = try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys]),
                  (try? out.write(to: file, options: .atomic)) != nil else {
                FileHandle.standardError.write(Data("write failed for one node — aborting\n".utf8))
                exit(1)
            }
        }
    } else {
        skippedNoText += 1
    }
    for key in ["summary_embedding", "folksonomy_embedding", "contextual_content_embedding"] {
        if let v = node[key] as? [Any], !v.isEmpty { afterDims[v.count, default: 0] += 1 }
    }
    if total % 25 == 0 { FileHandle.standardError.write(Data("  … \(total)/\(ids.count)\n".utf8)) }
}

func hist(_ d: [Int: Int]) -> String {
    d.isEmpty ? "(none)" : d.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
}
print("""

    ===== substrate re-embed \(dryRun ? "(DRY RUN — nothing written)" : "") =====
    corpus                : \(rootURL.path)
    backup                : \(backupPath)
    node.json seen        : \(total)
    re-embedded           : \(changed)
    skipped (already v\(kTargetVersion)) : \(skippedAlready)
    skipped (no text)     : \(skippedNoText)
    embed failures        : \(failed)
    fields written        : summary=\(wroteSummary) folksonomy=\(wroteFolksonomy) content=\(wroteContent)
    dims BEFORE           : \(hist(beforeDims))
    dims AFTER            : \(hist(afterDims))
    elapsed               : \(String(format: "%.1f", Date().timeIntervalSince(started)))s
    ==================================================

    """)
