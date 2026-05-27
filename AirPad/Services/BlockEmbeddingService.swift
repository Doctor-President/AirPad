import Foundation
import Accelerate

/// Owns per-node block-level embeddings. Chunks via `BlockChunker`, embeds
/// via `SubstrateService.shared.embed` (single shared `NLContextualEmbedding`
/// instance — no second embedder), persists to the per-node sidecar at
/// `nodes/<nodeID>/blocks.json`.
///
/// **Lifecycle:** owned by `CorpusStore` alongside `iCloudDriveService` and
/// `LayoutService`. Not a singleton — the storage actor is the only
/// dependency that needs threading through, and `CorpusStore` already holds
/// the canonical instance.
///
/// **Threading:** `@MainActor` to match `SubstrateService` and `CorpusStore`
/// (and because `NLContextualEmbedding.embed` is itself main-bound). Yields
/// 5ms between embeds inside `rebuild` so a many-block node doesn't stall the
/// UI — same cooperative cadence as `CorpusStore.backfillContentEmbeddings`.
@available(iOS 17.0, *)
@MainActor
final class BlockEmbeddingService {

    /// Bump on any change to chunker shape, embedder identity, or pooling
    /// strategy. `rebuild` ignores cached blocks at older versions so a
    /// version bump is sufficient to force re-embed on the next pass.
    static let currentEmbedderVersion: Int = 1

    /// Window the debounced enqueue waits before firing. Coalesces rapid
    /// edits (e.g., per-keystroke autosave bursts) into a single rebuild.
    /// 300ms is a starting line — calibrate against observed edit cadence
    /// once C4 lands.
    static let debounceNanoseconds: UInt64 = 300_000_000

    /// Yield window between consecutive embeds during a rebuild. Same value
    /// as `backfillContentEmbeddings`, same intent: keep the main thread
    /// responsive without true off-main work (which would require
    /// restructuring `SubstrateService` — out of scope here).
    static let interEmbedYieldNanoseconds: UInt64 = 5_000_000

    private let storage: iCloudDriveService

    /// One in-flight debounce task per nodeID. New enqueue calls cancel the
    /// prior task — last writer wins, so the rebuild always sees the latest
    /// node snapshot.
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    init(storage: iCloudDriveService) {
        self.storage = storage
    }

    // MARK: - Rebuild (write-through path)

    /// Debounced rebuild trigger. Call after any node save; collapses bursts
    /// to one rebuild per `debounceNanoseconds` window. Passes the `Node`
    /// value (not just ID) so the rebuild sees the snapshot captured at
    /// enqueue time — avoids a stale-read race against further mutations.
    func enqueueRebuild(node: Node) {
        let id = node.id
        debounceTasks[id]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }
            await self?.rebuild(node: node)
            self?.debounceTasks[id] = nil
        }
        debounceTasks[id] = task
    }

    /// Synchronous rebuild — chunk, diff against existing sidecar by
    /// `(itemID, sourceHash)`, reuse embeddings on hash match, embed misses,
    /// persist. Idempotent. Reused by C5 backfill.
    ///
    /// Match key is content-only (not chunkIndex) so an inserted paragraph
    /// mid-item shifts positions without invalidating trailing blocks.
    /// Orphans (blocks whose key no longer appears in fresh chunks) are
    /// dropped — the sidecar is regenerated from the new spec list.
    func rebuild(node: Node) async {
        let substrate = SubstrateService.shared
        guard await substrate.ensureLoaded() else {
            print("[BlockEmbedding] embedder unavailable; skipping node=\(node.id)")
            return
        }

        let specs = BlockChunker.chunk(node)

        let existing: NodeBlockIndex?
        do {
            existing = try await storage.loadBlockIndex(forNodeID: node.id)
        } catch {
            print("[BlockEmbedding] load sidecar error node=\(node.id): \(error)")
            existing = nil
        }

        var reuseMap: [String: NodeBlock] = [:]
        for block in existing?.blocks ?? []
        where block.embedderVersion == Self.currentEmbedderVersion {
            reuseMap[Self.reuseKey(itemID: block.itemID, sourceHash: block.sourceHash)] = block
        }

        var rebuilt: [NodeBlock] = []
        rebuilt.reserveCapacity(specs.count)
        var reused = 0
        var embedded = 0
        var skipped = 0

        for spec in specs {
            let key = Self.reuseKey(itemID: spec.itemID, sourceHash: spec.sourceHash)
            if let prior = reuseMap[key] {
                rebuilt.append(NodeBlock(
                    blockID: prior.blockID,
                    itemID: spec.itemID,
                    chunkIndex: spec.chunkIndex,
                    text: spec.text,
                    embedding: prior.embedding,
                    sourceHash: spec.sourceHash,
                    embedderVersion: prior.embedderVersion,
                    charLocation: spec.charLocation,
                    charLength: spec.charLength
                ))
                reused += 1
                continue
            }
            guard let vec = substrate.embed(spec.text), !vec.isEmpty else {
                skipped += 1
                continue
            }
            rebuilt.append(NodeBlock(
                blockID: UUID().uuidString,
                itemID: spec.itemID,
                chunkIndex: spec.chunkIndex,
                text: spec.text,
                embedding: vec,
                sourceHash: spec.sourceHash,
                embedderVersion: Self.currentEmbedderVersion,
                charLocation: spec.charLocation,
                charLength: spec.charLength
            ))
            embedded += 1
            try? await Task.sleep(nanoseconds: Self.interEmbedYieldNanoseconds)
        }

        let index = NodeBlockIndex(nodeID: node.id, blocks: rebuilt)
        do {
            try await storage.saveBlockIndex(index, forNodeID: node.id)
            print("[BlockEmbedding] node=\(node.id) blocks=\(rebuilt.count) reused=\(reused) embedded=\(embedded) skipped=\(skipped)")
        } catch {
            print("[BlockEmbedding] save sidecar error node=\(node.id): \(error)")
        }
    }

    // MARK: - Retrieval

    /// Stage 2 of two-stage retrieval — Stage 1 narrows by node-level
    /// embedding, this ranks blocks within the surviving candidates. Returns
    /// blocks sorted by cosine similarity descending, capped at `topK`.
    ///
    /// Dimension-mismatched blocks (left over from a prior embedder version
    /// that the rebuild path hasn't caught yet) are silently filtered. Empty
    /// result on embedder unavailability or empty query.
    func findRelevantBlocks(
        query: String,
        candidateNodeIDs: [String],
        topK: Int = 50
    ) async -> [NodeBlock] {
        let substrate = SubstrateService.shared
        guard await substrate.ensureLoaded(),
              let qvec = substrate.embed(query),
              !qvec.isEmpty else { return [] }

        var scored: [(block: NodeBlock, score: Float)] = []
        for nodeID in candidateNodeIDs {
            do {
                guard let index = try await storage.loadBlockIndex(forNodeID: nodeID) else { continue }
                for block in index.blocks where block.embedding.count == qvec.count {
                    scored.append((block, Self.cosine(qvec, block.embedding)))
                }
            } catch {
                print("[BlockEmbedding] load sidecar error node=\(nodeID): \(error)")
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK)).map { $0.block }
    }

    /// Navigate-mode retrieval — ranks nodes by their best-scoring block.
    /// Returns node IDs sorted by best-block cosine similarity descending,
    /// capped at `topK`. Nodes with no sidecar or no dimension-matching
    /// blocks are silently dropped; nodes with at least one valid block
    /// are scored even if other blocks are stale.
    ///
    /// Distinct from `findRelevantBlocks` because Navigate cares about
    /// *which nodes* the query lives in, not which blocks. Pull-quote
    /// citation (Ask mode, c5+) is the block-level path.
    func findRelevantNodeIDs(
        query: String,
        candidateNodeIDs: [String],
        topK: Int = 5
    ) async -> [String] {
        let substrate = SubstrateService.shared
        guard await substrate.ensureLoaded(),
              let qvec = substrate.embed(query),
              !qvec.isEmpty else { return [] }

        var nodeScores: [(nodeID: String, score: Float)] = []
        for nodeID in candidateNodeIDs {
            do {
                guard let index = try await storage.loadBlockIndex(forNodeID: nodeID) else { continue }
                var bestScore: Float = -.infinity
                for block in index.blocks where block.embedding.count == qvec.count {
                    let s = Self.cosine(qvec, block.embedding)
                    if s > bestScore { bestScore = s }
                }
                if bestScore > -.infinity {
                    nodeScores.append((nodeID, bestScore))
                }
            } catch {
                print("[BlockEmbedding] load sidecar error node=\(nodeID): \(error)")
            }
        }
        nodeScores.sort { $0.score > $1.score }
        return Array(nodeScores.prefix(topK)).map { $0.nodeID }
    }

    // MARK: - Helpers

    private static func reuseKey(itemID: String, sourceHash: String) -> String {
        "\(itemID)|\(sourceHash)"
    }

    /// Cosine similarity via `Accelerate`. `vDSP_dotpr` for the dot product,
    /// `vDSP_svesq` for the sum-of-squares norms. At 512-dim × 1000 blocks
    /// the full pass is sub-millisecond — ANN indexing (HNSW etc.) would be
    /// premature until corpora reach 10K+ blocks.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "cosine: dimension mismatch")
        let n = vDSP_Length(a.count)
        var dot: Float = 0
        var sumA: Float = 0
        var sumB: Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, n)
                vDSP_svesq(ap.baseAddress!, 1, &sumA, n)
                vDSP_svesq(bp.baseAddress!, 1, &sumB, n)
            }
        }
        let denom = sqrt(sumA * sumB)
        return denom > 0 ? dot / denom : 0
    }
}
