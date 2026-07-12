import CoreML
import Foundation

/// ws-card-catalog step 2b — on-device BGE-micro-v2 embedder for catalog cards.
///
/// Lifecycle contract: NEVER loaded on the launch path or synchronously in
/// capture. The 33MB Core ML model + WordPiece vocab are lazy-loaded on the
/// first `embed` call and then kept resident for the process lifetime.
///
/// The model is the spike's `BGEMicro.mlpackage`: mean-pooling and L2
/// normalization are INSIDE the graph, so `embed` returns the final 384-dim
/// unit vector directly. Declared model inputs are `input_ids` + `attention_mask`
/// (int32, length 512); token_type_ids/position_ids are constant-folded in.
actor CardEmbeddingService {
    static let shared = CardEmbeddingService()

    /// Embedder/call-shape version. Persisted on `CatalogCard.embeddingVersion`
    /// so a bump (new model / pooling / call shape) can find stale vectors.
    static let currentEmbeddingVersion = 1

    private let sequenceLength = 512
    private var model: MLModel?
    private var tokenizer: WordPieceTokenizer?
    private var loadFailed = false

    /// Lazy one-time load; retained for process life. Returns false (and latches
    /// `loadFailed`) if the model or vocab can't be loaded — callers treat a nil
    /// embedding as "no vector", never a hard failure.
    private func ensureLoaded() -> Bool {
        if model != nil, tokenizer != nil { return true }
        if loadFailed { return false }
        guard let modelURL = Bundle.main.url(forResource: "BGEMicro", withExtension: "mlmodelc"),
              let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
              let tok = WordPieceTokenizer(vocabURL: vocabURL) else {
            loadFailed = true
            return false
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let loaded = try? MLModel(contentsOf: modelURL, configuration: config) else {
            loadFailed = true
            return false
        }
        model = loaded
        tokenizer = tok
        return true
    }

    /// Embed `text` into a 384-dim unit vector. Returns nil on load failure,
    /// empty input, or a prediction error.
    func embed(_ text: String) async -> [Float]? {
        guard ensureLoaded(), let model, let tokenizer else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let (ids, mask) = tokenizer.encode(text, maxLength: sequenceLength)
        guard let idsArray = makeInt32Array(ids),
              let maskArray = makeInt32Array(mask),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [
                  "input_ids": MLFeatureValue(multiArray: idsArray),
                  "attention_mask": MLFeatureValue(multiArray: maskArray),
              ]),
              let output = try? await model.prediction(from: provider),
              let embedding = output.featureValue(for: "embedding")?.multiArrayValue
        else { return nil }

        var vector = [Float](repeating: 0, count: embedding.count)
        // NSNumber subscript is dtype-agnostic (the model emits float32); 384
        // elements once per embed, so the cost is negligible and it's safe.
        for i in 0..<embedding.count { vector[i] = embedding[i].floatValue }
        return vector
    }

    private func makeInt32Array(_ values: [Int32]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
            return nil
        }
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { ptr[i] = values[i] }
        return array
    }
}
