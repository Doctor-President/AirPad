import Foundation

/// Owns per-node block-level embeddings. Chunks via `BlockChunker`, embeds
/// via `CardEmbeddingService` (BGE-micro-v2, 384-dim, unit-normalized —
/// ws-card-catalog step 3a; was `NLContextualEmbedding` at v1), persists to the
/// per-node sidecar at `nodes/<nodeID>/blocks.json`. Block retrieval scores raw
/// cosine — BGE needs no mean-centering.
///
/// **Lifecycle:** owned by `CorpusStore` alongside `iCloudDriveService` and
/// `LayoutService`. Not a singleton — the storage actor is the only
/// dependency that needs threading through, and `CorpusStore` already holds
/// the canonical instance.
///
/// **Threading:** `@MainActor` to match `CorpusStore`. The actual BGE inference
/// runs off-main on the `CardEmbeddingService` actor; `rebuild` still yields 5ms
/// between embeds so a many-block node's main-actor orchestration stays smooth.
@available(iOS 17.0, *)
@MainActor
final class BlockEmbeddingService {

    /// Bump on any change to chunker shape, embedder identity, or pooling
    /// strategy. `rebuild` ignores cached blocks at older versions so a
    /// version bump is sufficient to force re-embed on the next pass.
    /// v1 = NLContextualEmbedding (512-dim). v2 = BGE-micro-v2 (384-dim,
    /// unit-normalized) via `CardEmbeddingService` — ws-card-catalog step 3a.
    static let currentEmbedderVersion: Int = 2

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
        // ws-card-catalog step 3a — blocks now embed on BGE-micro-v2 (384-dim,
        // unit-normalized) via the shared CardEmbeddingService actor, NOT
        // NLContextualEmbedding. The embedder lazy-loads on first use inside the
        // actor (off the main thread); a nil return means unavailable/failed and
        // the block is skipped, same contract as before.
        let embedder = CardEmbeddingService.shared

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
            guard let vec = await embedder.embed(spec.text), !vec.isEmpty else {
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
    /// embedding, this ranks blocks within the surviving candidates.
    /// Returns matches sorted by cosine similarity descending, capped at
    /// `topK`. Each match carries the block, its parent node ID, and
    /// the score so Ask-mode citation rendering doesn't have to walk
    /// the sidecar again.
    ///
    /// Dimension-mismatched blocks (left over from a prior embedder version
    /// that the rebuild path hasn't caught yet) are silently filtered. Empty
    /// result on embedder unavailability or empty query.
    func findRelevantBlocks(
        query: String,
        candidateNodeIDs: [String],
        topK: Int = 50
    ) async -> [BlockMatch] {
        // ws-card-catalog step 3a — the query embeds on BGE (via
        // CardEmbeddingService) so it lives in the SAME 384-dim space as the
        // re-embedded blocks. BGE is unit-normalized, so scoring is RAW cosine —
        // the NLContextual mean-centering crutch does not carry to BGE.
        guard let qvec = await CardEmbeddingService.shared.embed(query), !qvec.isEmpty else { return [] }
        return await findRelevantBlocks(queryVector: qvec, candidateNodeIDs: candidateNodeIDs, topK: topK)
    }

    /// step 3c — pre-embedded-query variant. The two-tier store funnel embeds the
    /// query once (for the card Stage-1) and passes the vector straight through to
    /// this Stage-2 block pass, so a search does a single BGE inference.
    func findRelevantBlocks(
        queryVector qvec: [Float],
        candidateNodeIDs: [String],
        topK: Int = 50
    ) async -> [BlockMatch] {
        guard !qvec.isEmpty else { return [] }
        // Gather block indices (storage-actor I/O), then score OFF the main actor
        // so the vector pass never blocks typing/drag. The `count == qvec.count`
        // filter in the scorer drops any stale v1 (512-dim) block that a rebuild
        // hasn't caught yet.
        var snapshot: [(nodeID: String, blocks: [NodeBlock])] = []
        for nodeID in candidateNodeIDs {
            do {
                guard let index = try await storage.loadBlockIndex(forNodeID: nodeID) else { continue }
                snapshot.append((nodeID, index.blocks))
            } catch {
                print("[BlockEmbedding] load sidecar error node=\(nodeID): \(error)")
            }
        }
        return await Self.scoreBlocksOffMain(qvec: qvec, snapshot: snapshot, topK: topK)
    }

    /// Off-main-actor block scoring. Runs the raw-cosine pass in a detached task
    /// so the main thread stays free during Librarian typing/drag.
    nonisolated private static func scoreBlocksOffMain(
        qvec: [Float],
        snapshot: [(nodeID: String, blocks: [NodeBlock])],
        topK: Int
    ) async -> [BlockMatch] {
        await Task.detached(priority: .userInitiated) {
            var scored: [BlockMatch] = []
            for (nodeID, blocks) in snapshot {
                for block in blocks where block.embedding.count == qvec.count {
                    scored.append(BlockMatch(
                        block: block,
                        nodeID: nodeID,
                        score: cosine(qvec, block.embedding)
                    ))
                }
            }
            scored.sort { $0.score > $1.score }
            return Array(scored.prefix(topK))
        }.value
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
        // ws-card-catalog step 3a — BGE query embed (same 384-dim space as blocks).
        guard let qvec = await CardEmbeddingService.shared.embed(query), !qvec.isEmpty else { return [] }
        return await findRelevantNodeIDs(queryVector: qvec, candidateNodeIDs: candidateNodeIDs, topK: topK)
    }

    /// step 3c — pre-embedded-query variant (single embed shared with card Stage-1).
    func findRelevantNodeIDs(
        queryVector qvec: [Float],
        candidateNodeIDs: [String],
        topK: Int = 5
    ) async -> [String] {
        guard !qvec.isEmpty else { return [] }
        // Gather then score off the main actor (see findRelevantBlocks).
        var snapshot: [(nodeID: String, blocks: [NodeBlock])] = []
        for nodeID in candidateNodeIDs {
            do {
                guard let index = try await storage.loadBlockIndex(forNodeID: nodeID) else { continue }
                snapshot.append((nodeID, index.blocks))
            } catch {
                print("[BlockEmbedding] load sidecar error node=\(nodeID): \(error)")
            }
        }
        return await Self.scoreNodesOffMain(qvec: qvec, snapshot: snapshot, topK: topK)
    }

    /// Off-main-actor node scoring (best-block per node), raw cosine.
    nonisolated private static func scoreNodesOffMain(
        qvec: [Float],
        snapshot: [(nodeID: String, blocks: [NodeBlock])],
        topK: Int
    ) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var nodeScores: [(nodeID: String, score: Float)] = []
            for (nodeID, blocks) in snapshot {
                var bestScore: Float = -.infinity
                for block in blocks where block.embedding.count == qvec.count {
                    let s = cosine(qvec, block.embedding)
                    if s > bestScore { bestScore = s }
                }
                if bestScore > -.infinity {
                    nodeScores.append((nodeID, bestScore))
                }
            }
            nodeScores.sort { $0.score > $1.score }
            return Array(nodeScores.prefix(topK)).map { $0.nodeID }
        }.value
    }

    // MARK: - Helpers

    private static func reuseKey(itemID: String, sourceHash: String) -> String {
        "\(itemID)|\(sourceHash)"
    }

    /// Raw cosine similarity. Correct for BGE vectors (unit-normalized, so this
    /// is effectively their dot product); no mean-centering — that was an
    /// NLContextualEmbedding-anisotropy crutch and does not apply to BGE
    /// (ws-card-catalog step 3a). `nonisolated` so the scoring pass runs off the
    /// main actor.
    nonisolated private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
