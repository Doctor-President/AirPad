import Foundation

/// Splits a long passage into sentence-sized chunks Kokoro can synthesize one at
/// a time. A full Librarian answer far exceeds Kokoro's ~510-token window, so a
/// single `generateAudio` call would throw `tooManyTokens`; chunking is what makes
/// long read-aloud work. Also lightly strips Markdown so the model doesn't
/// vocalize `**`, `#`, backticks, or link syntax (Kokoro path only — the AVSpeech
/// path is untouched).
enum TextChunker {

    /// `maxChars` is a conservative proxy for the token window (~510 tokens ≈
    /// 400–500 English chars; 300 keeps a safe margin incl. phoneme expansion).
    ///
    /// `firstChunkMaxChars` (nil = same as `maxChars`) caps CHUNK 0 to a smaller
    /// budget so first-audio lands fast: at int8 RTF ~0.55, a 300-char chunk 0 is
    /// ~10 s of synth before any sound, vs ~2 s for ~60 chars. The ORT engine passes
    /// ~60. A first sentence longer than the budget is word-boundary hard-split, so
    /// chunk 0 may be a leading fragment of it; chunks 1+ use `maxChars`.
    static func chunk(_ text: String, maxChars: Int = 300, firstChunkMaxChars: Int? = nil) -> [String] {
        let cleaned = stripMarkdown(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        // 1) Break into sentences on . ! ? and hard newlines (delimiter kept).
        var sentences: [String] = []
        var current = ""
        for ch in cleaned {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }

        // 2) Pack sentences into chunks up to maxChars; hard-split any single
        //    sentence that's over budget (on word boundaries).
        var chunks: [String] = []
        var buf = ""
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            buf = ""
        }
        for s in sentences {
            if s.count > maxChars {
                flush()
                chunks.append(contentsOf: hardSplit(s, maxChars: maxChars))
            } else if buf.count + s.count + 1 > maxChars {
                flush()
                buf = s
            } else {
                buf = buf.isEmpty ? s : buf + " " + s
            }
        }
        flush()
        // Drop letterless fragments (pure numbers/punctuation left after the
        // Markdown strip, e.g. a bare list marker). Misaki can produce an empty
        // phoneme sequence for these, which faults synthesis — and one such chunk
        // is far more likely to appear in a long answer than a short one.
        var result = chunks.filter { $0.rangeOfCharacter(from: .letters) != nil }
        // Peel a small head (≤ firstChunkMaxChars, word boundary) off chunk 0 so
        // first-audio lands fast; the remainder becomes chunk 1. The head depends
        // only on the answer's LEADING words, so a speculative synth of the first
        // sentence produces the SAME head → the speculative cache hits.
        if let cap = firstChunkMaxChars, let first = result.first, first.count > cap {
            let pieces = hardSplit(first, maxChars: cap)
            if pieces.count >= 2 {
                let remainder = pieces.dropFirst().joined(separator: " ")
                result.removeFirst()
                result.insert(remainder, at: 0)
                result.insert(pieces[0], at: 0)
            }
        }
        return result
    }

    /// Split an over-long sentence into ≤ maxChars pieces on word boundaries.
    private static func hardSplit(_ s: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var buf = ""
        for word in s.split(separator: " ") {
            if buf.count + word.count + 1 > maxChars {
                if !buf.isEmpty { out.append(buf) }
                buf = String(word)
            } else {
                buf = buf.isEmpty ? String(word) : buf + " " + String(word)
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    /// Minimal Markdown → plain text so the model reads words, not symbols.
    /// Converts `[label](url)` → `label`, drops emphasis/heading/quote/code
    /// markers and bare URLs. Not a full parser — just enough to keep speech clean.
    private static func stripMarkdown(_ text: String) -> String {
        var t = text
        // [label](url) → label
        t = t.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1",
            options: .regularExpression)
        // bare http(s) URLs → drop
        t = t.replacingOccurrences(
            of: #"https?://\S+"#, with: "",
            options: .regularExpression)
        // emphasis / code / heading / quote / list markers
        for token in ["**", "__", "```", "`", "*", "_", "#", ">", "~~"] {
            t = t.replacingOccurrences(of: token, with: " ")
        }
        // collapse runs of whitespace introduced by the above
        t = t.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ",
            options: .regularExpression)
        return t
    }
}
