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
    static func chunk(_ text: String, maxChars: Int = 300) -> [String] {
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
        return chunks
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
