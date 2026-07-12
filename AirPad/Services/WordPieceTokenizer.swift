import Foundation

/// ws-card-catalog step 2b — self-contained uncased BERT WordPiece tokenizer for
/// BGE-micro-v2 (bert-base-uncased vocab, 30522 tokens). NO external dependencies.
///
/// Mirrors HuggingFace `BertTokenizer(do_lower_case=True)`:
///   clean text → lowercase + NFD strip-accents → whitespace split →
///   punctuation split → greedy longest-match-first WordPiece ("##" continuation,
///   `[UNK]` on miss). CJK ideographs are space-isolated as BERT does.
///
/// `encode` returns `input_ids` + `attention_mask` only. The BGEMicro model bakes
/// token_type_ids (all 0) and position_ids (0..<512) in as constants, so they are
/// not model inputs; they are noted here for completeness.
struct WordPieceTokenizer {
    static let clsID: Int32 = 101
    static let sepID: Int32 = 102
    static let padID: Int32 = 0
    static let unkID: Int32 = 100
    static let unkToken = "[UNK]"
    static let maxInputCharsPerWord = 200

    private let vocab: [String: Int32]

    /// Loads `vocab.txt` — one token per line, id == 0-based line index.
    init?(vocabURL: URL) {
        guard let text = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        var v: [String: Int32] = [:]
        var index: Int32 = 0
        text.enumerateLines { line, _ in
            v[line] = index
            index += 1
        }
        guard !v.isEmpty else { return nil }
        self.vocab = v
    }

    // MARK: - Public API

    /// Tokenize `text` into `[CLS] … [SEP]`, pad/truncate to `maxLength`.
    /// Returns int32 ids and a 1/0 attention mask of length `maxLength`.
    func encode(_ text: String, maxLength: Int = 512) -> (inputIds: [Int32], attentionMask: [Int32]) {
        var pieces: [String] = []
        for word in basicTokenize(text) {
            pieces.append(contentsOf: wordPiece(word))
        }
        // Reserve two slots for [CLS] and [SEP].
        if pieces.count > maxLength - 2 {
            pieces = Array(pieces.prefix(maxLength - 2))
        }

        var ids: [Int32] = [Self.clsID]
        for p in pieces { ids.append(vocab[p] ?? Self.unkID) }
        ids.append(Self.sepID)

        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < maxLength {
            let pad = maxLength - ids.count
            ids.append(contentsOf: [Int32](repeating: Self.padID, count: pad))
            mask.append(contentsOf: [Int32](repeating: 0, count: pad))
        }
        return (ids, mask)
    }

    // MARK: - Basic tokenizer (BERT BasicTokenizer, do_lower_case)

    private func basicTokenize(_ text: String) -> [String] {
        let cleaned = tokenizeCJK(cleanText(text))
        var output: [String] = []
        for token in whitespaceSplit(cleaned) {
            let lowered = token.lowercased()
            let stripped = stripAccents(lowered)
            output.append(contentsOf: splitOnPunctuation(stripped))
        }
        return output
    }

    /// Remove null/replacement/control chars; normalize all whitespace to a space.
    private func cleanText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD || isControl(s) { continue }
            out.append(isWhitespace(s) ? " " : s)
        }
        return String(out)
    }

    /// NFD normalize, drop non-spacing marks (accents).
    private func stripAccents(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where s.properties.generalCategory != .nonspacingMark {
            out.append(s)
        }
        return String(out)
    }

    /// Split each punctuation scalar into its own token.
    private func splitOnPunctuation(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isPunctuation(s) {
                if !current.isEmpty { result.append(String(current)); current = String.UnicodeScalarView() }
                result.append(String(Character(s)))
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// Put spaces around CJK ideographs so each becomes its own token.
    private func tokenizeCJK(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isCJK(s) {
                out.append(" ")
                out.append(s)
                out.append(" ")
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    private func whitespaceSplit(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
    }

    // MARK: - WordPiece (greedy longest-match-first)

    private func wordPiece(_ token: String) -> [String] {
        let scalars = Array(token.unicodeScalars)
        if scalars.count > Self.maxInputCharsPerWord { return [Self.unkToken] }

        var subTokens: [String] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var cur: String? = nil
            while start < end {
                var piece = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if vocab[piece] != nil { cur = piece; break }
                end -= 1
            }
            guard let matched = cur else { return [Self.unkToken] }
            subTokens.append(matched)
            start = end
        }
        return subTokens
    }

    // MARK: - Character classes (BERT semantics)

    private func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        if s == " " || s == "\t" || s == "\n" || s == "\r" { return true }
        return s.properties.generalCategory == .spaceSeparator
    }

    private func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    private func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let cp = s.value
        // BERT treats these ASCII ranges as punctuation even when their Unicode
        // category is a Symbol (e.g. $, +, ^, `, |, ~).
        if (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64)
            || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private func isCJK(_ s: Unicode.Scalar) -> Bool {
        let cp = s.value
        return (cp >= 0x4E00 && cp <= 0x9FFF)
            || (cp >= 0x3400 && cp <= 0x4DBF)
            || (cp >= 0x20000 && cp <= 0x2A6DF)
            || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F)
            || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF)
            || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }
}
