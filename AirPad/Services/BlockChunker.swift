import Foundation
import NaturalLanguage
import CryptoKit

/// Output of `BlockChunker.chunk(_:)`. One spec per emitted chunk; `NodeBlock`
/// is built from this by `BlockEmbeddingService` after embedding.
struct BlockChunkSpec: Equatable {
    let itemID: String
    let chunkIndex: Int
    let text: String
    let charLocation: Int
    let charLength: Int
    let sourceHash: String
}

/// Pure, deterministic text → chunk mapper. No I/O, no embedder, no actor
/// state — same input yields the same output every run, which is what makes
/// `(itemID, sourceHash)` a reliable invalidation key for incremental rebuild.
///
/// **Chunking strategy:**
/// 1. Split on line breaks if the source has any (respects user formatting).
/// 2. Sentence-tokenize via `NLTokenizer(.sentence)` when no line breaks exist
///    (unformatted prose, voice transcripts).
/// 3. Merge below-threshold pieces forward so fragments don't drown signal.
/// 4. Sub-split above-threshold pieces at sentence boundaries; accept any
///    sentence still over the cap (mid-sentence splits hurt retrieval more
///    than the embedder's truncation does).
///
/// **Granularity:** `itemID` resolves to the most specific source-of-text
/// record. For `.text`/`.audio` that's `NodeItem.id`. For `.document`/`.link`
/// that's `DocumentItem.id` / `LinkItem.id` — each sub-item carries its own
/// extracted text, so per-sub-item keying lets one stale document inside a
/// multi-doc entry invalidate without poisoning its siblings.
enum BlockChunker {

    /// Default merge floor for prose. Below this, chunks merge with their
    /// next neighbor. 50 chars matches the brief.
    static let minChars: Int = 50

    /// Estimated character cap for ~400 tokens of English (≈4 chars/token).
    /// `BlockEmbeddingService` should narrow this against the embedder's
    /// runtime `maximumSequenceLength` when it knows the value; the chunker
    /// only enforces it as a safety net against pathological inputs.
    static let maxChars: Int = 1600

    /// Voice-transcript merge floor. Stream-of-consciousness prose loses
    /// semantic context below ~600–800 chars; 700 is the midpoint of the
    /// brief's range.
    static let voiceFloorChars: Int = 700

    /// ws-card-catalog step 3a — chunk-quality floor. A block must carry at
    /// least this many real (letter/digit) characters after trimming to be
    /// embedded. Screens out the degenerate blocks that polluted RELATED under
    /// the raw-cosine regime: punctuation/whitespace-only remnants (a bare `"-"`
    /// bullet), and short OG-fragment noise (`"TikTok · nasir"` = 11 real chars).
    /// It also bounds `mergeShort`'s "keep the trailing remnant" rule — a
    /// remnant survives only when it clears this floor.
    static let minRealChars: Int = 12

    /// True when `text` has ≥ `minRealChars` letters/digits. Early-exits.
    static func hasQualitySignal(_ text: String) -> Bool {
        var real = 0
        for ch in text where ch.isLetter || ch.isNumber {
            real += 1
            if real >= minRealChars { return true }
        }
        return false
    }

    /// Walks `node.items` in declaration order and concatenates per-item
    /// chunks. Items with no extractable text contribute nothing — silent
    /// skip rather than empty blocks. Sub-`minRealChars` (junk) blocks are
    /// dropped by the quality gate.
    static func chunk(_ node: Node) -> [BlockChunkSpec] {
        node.items.flatMap { chunk(item: $0) }.filter { hasQualitySignal($0.text) }
    }

    static func chunk(item: NodeItem) -> [BlockChunkSpec] {
        switch item.type {
        case .text:
            return chunkText(item.content ?? "", itemID: item.id, minChars: minChars)

        case .audio:
            return chunkText(item.transcript ?? "", itemID: item.id, minChars: voiceFloorChars)

        case .video:
            // Pre-v2-migration .video items may still carry a transcript.
            // Post-migration converts them to .imageVideo and drops the
            // transcript field, so this branch is for stragglers only.
            return chunkText(item.transcript ?? "", itemID: item.id, minChars: voiceFloorChars)

        case .image:
            // Legacy pre-4.2 single-image entry. FM description (when present)
            // is short — emit as one block, no further splitting.
            return singleBlock(item.description ?? "", itemID: item.id)

        case .imageVideo:
            // Two text sources feed the search index:
            //  • the legacy parent `description` (migrated single-image
            //    breadcrumb / FM description), keyed by the entry id.
            //  • each image's OCR text (`GalleryItem.analysis.recognizedText`),
            //    keyed by the GALLERYITEM id — so re-OCR of one image
            //    invalidates only its own blocks (mirrors per-DocumentItem
            //    keying). This is the wire that makes a screenshot's / receipt's
            //    / whiteboard's text findable.
            var specs = singleBlock(item.description ?? "", itemID: item.id)
            for media in item.mediaItems ?? [] {
                if let text = media.analysis?.recognizedText, !text.isEmpty {
                    specs += chunkText(text, itemID: media.id, minChars: minChars)
                }
            }
            return specs

        case .link:
            if let links = item.linkItems, !links.isEmpty {
                return links.flatMap { chunkLink($0) }
            }
            // Pre-4.5 single-link entry — synthesize from the parent fields.
            return chunkLegacyLink(item: item)

        case .document:
            guard let docs = item.documentItems else { return [] }
            return docs.flatMap { doc -> [BlockChunkSpec] in
                guard let text = doc.extractedText, !text.isEmpty else { return [] }
                return chunkText(text, itemID: doc.id, minChars: minChars)
            }

        case .rating, .field:
            // Stage 4.8 / 5.1 — atomic value, no text contribution in Stage 1.
            return []
        case .chats:
            // ws-chat-lane — a reference entry; no extraction in V1, so pinned
            // chats contribute nothing to the search index.
            return []
        }
    }

    // MARK: - Per-type helpers

    private static func chunkLink(_ link: LinkItem) -> [BlockChunkSpec] {
        if let snap = link.snapshotText, !snap.isEmpty {
            return chunkText(snap, itemID: link.id, minChars: minChars)
        }
        if let summary = ogSummary(title: link.title, description: link.description),
           !summary.isEmpty {
            return singleBlock(summary, itemID: link.id)
        }
        return []
    }

    private static func chunkLegacyLink(item: NodeItem) -> [BlockChunkSpec] {
        guard item.url != nil else { return [] }
        let title = item.ogTitle ?? item.title
        let desc  = item.ogDescription ?? item.preview
        guard let summary = ogSummary(title: title, description: desc),
              !summary.isEmpty else { return [] }
        return singleBlock(summary, itemID: item.id)
    }

    private static func ogSummary(title: String?, description: String?) -> String? {
        let parts = [title, description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " — ")
    }

    // MARK: - Text chunking

    private static func chunkText(
        _ raw: String,
        itemID: String,
        minChars: Int
    ) -> [BlockChunkSpec] {
        let source = raw as NSString
        guard source.length > 0 else { return [] }

        let firstPass: [NSRange] = containsNewline(source)
            ? splitOnNewlines(source)
            : splitOnSentences(raw)

        let merged = mergeShort(firstPass, minChars: minChars)
        let sized  = enforceMax(merged, in: source, raw: raw, maxChars: maxChars)

        var out: [BlockChunkSpec] = []
        var idx = 0
        for range in sized {
            let text = source
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(BlockChunkSpec(
                itemID: itemID,
                chunkIndex: idx,
                text: text,
                charLocation: range.location,
                charLength: range.length,
                sourceHash: sha256Hex(text)
            ))
            idx += 1
        }
        return out
    }

    private static func singleBlock(_ raw: String, itemID: String) -> [BlockChunkSpec] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let source = raw as NSString
        return [BlockChunkSpec(
            itemID: itemID,
            chunkIndex: 0,
            text: trimmed,
            charLocation: 0,
            charLength: source.length,
            sourceHash: sha256Hex(trimmed)
        )]
    }

    // MARK: - Splitters

    private static func containsNewline(_ s: NSString) -> Bool {
        s.range(of: "\n").location != NSNotFound
    }

    private static func splitOnNewlines(_ s: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var loc = 0
        while loc < s.length {
            let remainder = NSRange(location: loc, length: s.length - loc)
            let nl = s.range(of: "\n", options: [], range: remainder)
            let end = (nl.location == NSNotFound) ? s.length : nl.location
            let len = end - loc
            if len > 0 {
                ranges.append(NSRange(location: loc, length: len))
            }
            loc = (nl.location == NSNotFound) ? s.length : nl.location + nl.length
        }
        return ranges
    }

    /// Sentence tokenization speaks Swift `Range<String.Index>`, which we
    /// convert to `NSRange` (UTF-16) for storage parity with `NodeBlock`.
    private static func splitOnSentences(_ raw: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = raw
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: raw.startIndex..<raw.endIndex) { swiftRange, _ in
            let ns = NSRange(swiftRange, in: raw)
            if ns.length > 0 { ranges.append(ns) }
            return true
        }
        return ranges
    }

    // MARK: - Size enforcement

    /// Walks the input and absorbs each below-`minChars` range into the next
    /// one, spanning both. A trailing remnant that never clears the floor is
    /// kept as-is — dropping content loses signal worse than a short block does.
    private static func mergeShort(_ ranges: [NSRange], minChars: Int) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        var out: [NSRange] = []
        var pending: NSRange? = nil
        for r in ranges {
            if let p = pending {
                let merged = NSRange(
                    location: p.location,
                    length: (r.location + r.length) - p.location
                )
                if merged.length >= minChars {
                    out.append(merged)
                    pending = nil
                } else {
                    pending = merged
                }
            } else if r.length < minChars {
                pending = r
            } else {
                out.append(r)
            }
        }
        if let p = pending { out.append(p) }
        return out
    }

    /// For each range over the cap, re-tokenize at sentence boundaries and
    /// greedy-pack sentences into windows that stay under `maxChars`. A
    /// single sentence still over the cap is emitted intact — the embedder
    /// will truncate, but splitting mid-sentence harms retrieval more.
    private static func enforceMax(
        _ ranges: [NSRange],
        in source: NSString,
        raw: String,
        maxChars: Int
    ) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if r.length <= maxChars {
                out.append(r)
                continue
            }
            let sub = source.substring(with: r)
            let subRanges = splitOnSentences(sub)
            if subRanges.isEmpty {
                out.append(r)
                continue
            }
            var packed: [NSRange] = []
            var cur: NSRange? = nil
            for sr in subRanges {
                let absolute = NSRange(
                    location: r.location + sr.location,
                    length: sr.length
                )
                if let c = cur {
                    let combinedLen = (absolute.location + absolute.length) - c.location
                    if combinedLen <= maxChars {
                        cur = NSRange(location: c.location, length: combinedLen)
                    } else {
                        packed.append(c)
                        cur = absolute
                    }
                } else {
                    cur = absolute
                }
            }
            if let c = cur { packed.append(c) }
            out.append(contentsOf: packed)
        }
        return out
    }

    // MARK: - Hash

    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
