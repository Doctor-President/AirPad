import Foundation

/// ws-card-catalog step 2b — device parity self-test for the full Swift embed
/// path (WordPiece tokenizer + Core ML model) against Python reference vectors.
///
/// The Swift tokenizer is the new risk surface — the viability spike fed
/// pre-tokenized IDs and never exercised it. This test embeds the raw TEXT of
/// each bundled fixture through the real path and checks two things per fixture:
///   1. Swift token IDs match the Python (HuggingFace) IDs exactly.
///   2. cosine(Swift embedding, Python reference embedding) ≥ 0.999.
///
/// Fired on demand from the dev inspect view (mirrors `SubstrateSelfTest`). A
/// token-ID mismatch is a tokenizer bug: it is reported with the diverging text,
/// not patched around.
@available(iOS 17.0, *)
enum CardEmbeddingParityTest {

    private struct Fixture: Decodable {
        let title: String
        let text: String
        let input_ids: [Int32]
        let attention_mask: [Int32]
        let embedding: [Float]
    }

    static func run() async -> String {
        guard let url = Bundle.main.url(forResource: "card_parity_fixture", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let fixtures = try? JSONDecoder().decode([Fixture].self, from: data),
              !fixtures.isEmpty
        else { return "FAIL · card parity fixture missing or unreadable" }

        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
              let tokenizer = WordPieceTokenizer(vocabURL: vocabURL)
        else { return "FAIL · vocab.txt missing — tokenizer could not load" }

        let service = CardEmbeddingService.shared
        var minCosine = 1.0
        var idMismatches: [String] = []
        var embedded = 0

        for f in fixtures {
            let (ids, _) = tokenizer.encode(f.text, maxLength: 512)
            if ids != f.input_ids { idMismatches.append(f.title) }

            guard let vector = await service.embed(f.text) else {
                return "FAIL · embed returned nil for \"\(f.title)\""
            }
            embedded += 1
            minCosine = min(minCosine, cosine(vector, f.embedding))
        }

        let pass = minCosine >= 0.999 && idMismatches.isEmpty
        let idLine = idMismatches.isEmpty ? "token-IDs exact" : "token-ID MISMATCH: \(idMismatches.joined(separator: ", "))"
        return "\(pass ? "OK" : "FAIL") · \(embedded)/\(fixtures.count) embedded · min cos \(String(format: "%.5f", minCosine)) · \(idLine)"
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
