import Foundation

/// WHICH SPACE a vector lives in — the embedder that produced it AND the channel (which text it
/// embedded). Two vectors are comparable ONLY when their bases are equal.
///
/// ★ WHY NOT A VERSION INTEGER (the bug this replaces). Until 2026-09-16 both embedders wrote
/// `embeddingVersion = 1`, on different fields: `CardEmbeddingService` meaning "BGE-micro, 384-d"
/// and `SubstrateService` meaning "NLContextualEmbedding, 512-d". No version check could tell them
/// apart — only the DIMENSION could, and only by accident.
///
/// ★★ WHY CHANNEL, NOT JUST EMBEDDER — the trap this type exists for. Once the substrate fields are
/// ALSO BGE-384, dimension stops catching a mix: a card-gist vector and a summary vector are both
/// 384-d BGE, so `cosine` will happily return a number. But they embed DIFFERENT TEXT, so that
/// number is meaningless. Migrating to one embedder REMOVES the accidental guard that dimension was
/// providing; the channel is what replaces it. This is why comparing bases is not optional polish.
struct VectorBasis: RawRepresentable, Codable, Hashable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(embedder: String, channel: String) { self.rawValue = "\(embedder)/\(channel)" }

    /// The producing model, e.g. `bge-micro-384`.
    var embedder: String { rawValue.split(separator: "/").first.map(String.init) ?? rawValue }
    /// Which text was embedded, e.g. `card-gist`. Distinct channels are NOT comparable.
    var channel: String { rawValue.split(separator: "/").dropFirst().joined(separator: "/") }
    var description: String { rawValue }

    // MARK: - Embedders

    static let bgeMicro384 = "bge-micro-384"
    static let nlContextual512 = "nl-contextual-512"

    // MARK: - Channels

    static let cardGistChannel = "card-gist"
    static let summaryChannel = "summary"
    static let folksonomyChannel = "folksonomy"
    static let contentChannel = "content"
    static let blockChannel = "block"

    // MARK: - Current bases (everything written after the 2026-09-16 migration)

    static let cardGist = VectorBasis(embedder: bgeMicro384, channel: cardGistChannel)
    static let summary = VectorBasis(embedder: bgeMicro384, channel: summaryChannel)
    static let folksonomy = VectorBasis(embedder: bgeMicro384, channel: folksonomyChannel)
    static let content = VectorBasis(embedder: bgeMicro384, channel: contentChannel)
    static let block = VectorBasis(embedder: bgeMicro384, channel: blockChannel)
    /// `substrateVector`'s tail averages summary + folksonomy — a vector in neither channel alone.
    static let substrateBlend = VectorBasis(embedder: bgeMicro384, channel: "substrate-blend")

    /// Infer the basis of a vector stored BEFORE the tag existed. Dimension is the only signal an
    /// untagged vector carries — sufficient only while the two embedders differ in dimension, which
    /// is exactly the window the one-off re-embed closes. Every write after the migration is tagged
    /// explicitly, so this is a read-compatibility shim for un-migrated corpora, not a strategy.
    static func inferred(dimension: Int, channel: String) -> VectorBasis {
        VectorBasis(embedder: dimension == 384 ? bgeMicro384 : nlContextual512, channel: channel)
    }

    /// Resolve a stored-or-absent tag against the vector that carries it.
    static func resolve(_ stored: VectorBasis?, vector: [Float], channel: String) -> VectorBasis {
        stored ?? inferred(dimension: vector.count, channel: channel)
    }
}

/// The outcome of comparing two vectors that must share a basis.
enum BasisCheck {
    case ok
    case mismatch(VectorBasis, VectorBasis)

    static func of(_ a: VectorBasis, _ b: VectorBasis) -> BasisCheck {
        a == b ? .ok : .mismatch(a, b)
    }
}

/// ★ The single refusal point for a basis mismatch. NEVER coerce a mismatch to a neutral value —
/// a 0 reads as "unrelated" and a garbage cosine reads as "related", and both are lies the caller
/// cannot detect. In DEBUG this traps so it is caught in development; in Release it logs loudly,
/// once per distinct pair, and the caller EXCLUDES the item rather than scoring it.
enum VectorBasisGuard {
    private static var reported: Set<String> = []

    /// ★ Same EMBEDDER only — the correct check for RETRIEVAL, where a query vector is deliberately
    /// compared against document vectors. Cross-channel is the point there (that is what search IS),
    /// so demanding an identical channel would break it; mixing two EMBEDDERS still never makes
    /// sense and is what this catches.
    @discardableResult
    static func requireSameEmbedder(_ a: VectorBasis, _ b: VectorBasis, site: String) -> Bool {
        guard a.embedder != b.embedder else { return true }
        let key = "embedder|\(site)|\(a.embedder)|\(b.embedder)"
        if !reported.contains(key) {
            reported.insert(key)
            print("🚨 [VectorBasis] EMBEDDER MISMATCH at \(site): \(a.embedder) vs \(b.embedder) — "
                  + "refusing to compare; the item is EXCLUDED, not scored 0.")
        }
        assertionFailure("[VectorBasis] embedder mismatch at \(site): \(a) vs \(b)")
        return false
    }

    /// Returns true when the two bases match. Logs/asserts and returns false when they do not.
    @discardableResult
    static func require(_ a: VectorBasis, _ b: VectorBasis, site: String) -> Bool {
        guard a != b else { return true }
        let key = "\(site)|\(a.rawValue)|\(b.rawValue)"
        if !reported.contains(key) {
            reported.insert(key)
            print("🚨 [VectorBasis] MISMATCH at \(site): \(a) vs \(b) — refusing to compare. "
                  + "The item is EXCLUDED, not scored 0. This means two embedding spaces met; "
                  + "re-embed or fix the caller. (logged once per distinct pair)")
        }
        assertionFailure("[VectorBasis] mismatch at \(site): \(a) vs \(b)")
        return false
    }
}

/// `flatMap` for an async transform — lets the substrate writer keep its optional-chaining shape
/// now that `embed` is `async` (Optional.flatMap cannot take an async closure).
extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
