import Foundation

/// Block-level embedding record for the query bar's two-stage retrieval.
/// Stage 1 narrows by node (existing `Node.contextualContentEmbedding`);
/// Stage 2 ranks blocks within candidate nodes by cosine over `embedding`.
///
/// Derived data — never source of truth. Regenerable from `Node.items` via
/// `BlockChunker`. The sidecar (`nodes/<nodeID>/blocks.json`) is rebuilt on
/// `sourceHash` mismatch or `embedderVersion` bump.
struct NodeBlock: Codable, Equatable {
    /// Stable across rebuilds. Survives even when chunk position shifts,
    /// so future jump-to-block UX can keep deep links valid through edits.
    let blockID: String

    /// Parent `NodeItem.id`. Lets the chunker scope rebuilds to a single
    /// item when only one item's content changed.
    let itemID: String

    /// Position within the item's chunked output. Display/order signal —
    /// rebuild matching uses `(itemID, sourceHash)`, not chunkIndex, so an
    /// inserted paragraph mid-item doesn't invalidate trailing blocks.
    let chunkIndex: Int

    /// Raw chunk text. Stored alongside the embedding because the Mistral
    /// re-ranker (Stage 2 of two-stage retrieval) reasons over text, not
    /// vectors — keeping it here avoids a second round-trip to re-chunk.
    let text: String

    /// `NLContextualEmbedding(.english)` mean-pooled, dim 512. Mutable so
    /// rebuild can replace in place without struct re-creation.
    var embedding: [Float]

    /// SHA-256 of `text`. Invalidation signal: rebuild compares this against
    /// freshly chunked text to decide whether to re-embed or reuse.
    let sourceHash: String

    /// `BlockEmbeddingService.currentEmbedderVersion` at write time. Any
    /// change to embedder, chunker, or pooling shape bumps the constant so
    /// stale blocks are detectable on next rebuild.
    let embedderVersion: Int

    /// UTF-16 offset into the item's source text. Stored as
    /// `location`/`length` (not `Range<Int>`) because Swift `String`
    /// indexing isn't `Int`-based and TextKit / `NSAttributedString` —
    /// where jump-to-block will live — speaks `NSRange` natively.
    let charLocation: Int
    let charLength: Int

    var charRange: NSRange { NSRange(location: charLocation, length: charLength) }

    enum CodingKeys: String, CodingKey {
        case text, embedding
        case blockID = "block_id"
        case itemID = "item_id"
        case chunkIndex = "chunk_index"
        case sourceHash = "source_hash"
        case embedderVersion = "embedder_version"
        case charLocation = "char_location"
        case charLength = "char_length"
    }
}

/// Sidecar root for a single node's block embeddings. One file per node at
/// `nodes/<nodeID>/blocks.json`, inside the node's own directory so
/// `iCloudDriveService.deleteNode` (which removes the whole directory)
/// cleans the sidecar without a separate delete path.
struct NodeBlockIndex: Codable, Equatable {
    let nodeID: String
    var blocks: [NodeBlock]

    enum CodingKeys: String, CodingKey {
        case blocks
        case nodeID = "node_id"
    }
}
