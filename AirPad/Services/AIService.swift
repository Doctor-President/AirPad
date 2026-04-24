import Foundation
import FoundationModels
import QuartzCore

// MARK: - Structured output types

/// Requires iOS 26.0 — @Generable and its synthesised types (GenerationSchema,
/// GeneratedContent, ConvertibleToGeneratedContent) are all iOS 26.0+.
/// Gating the actor at the same version means the macro expansion is always
/// inside an @available(iOS 26.0, *) context, avoiding beta compiler leakage.
@available(iOS 26.0, *)
@Generable
struct NodeAIResult {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String

    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match.")
    var tags: [String]

    @Guide(description: "Emotional tone — exactly one word from this fixed set: curious, reflective, energized, uncertain, calm, urgent, playful, melancholy.")
    var mood: String

    @Guide(description: "Domain classification — exactly one value from: Recipe, Legal, Medical, Nutrition, Dream, Travel, Work, Learning, Family, Art/Project. Use an empty string if none clearly apply.")
    var domain: String
}

@available(iOS 26.0, *)
@Generable
struct CoherenceCheck {
    @Guide(description: "Is this a complete, standalone idea? Reply with exactly 'Yes' or 'No'.")
    var answer: String
}

// MARK: - Service

/// On-device AI processing for nodes.
/// LanguageModelSession and SystemLanguageModel are iOS 26.0+ — the entire
/// actor is gated accordingly. Callers must use #available(iOS 26.0, *).
/// Gracefully returns nil on unavailable hardware or errors — node saves are NEVER blocked.
@available(iOS 26.0, *)
actor AIService {

    func processNode(_ node: Node, tagVocabulary: [Tag]) async -> NodeAIOutput? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let content = extractContent(from: node)
        guard !content.isEmpty else { return nil }

        let vocabLine: String
        if tagVocabulary.isEmpty {
            vocabLine = "Tag vocabulary: (empty — create new tag names based on the content)"
        } else {
            vocabLine = "Tag vocabulary: " + tagVocabulary.map { $0.name }.joined(separator: ", ")
        }

        let prompt = """
        Analyze this captured idea.
        \(vocabLine)
        Only suggest tags from the vocabulary if they are genuinely relevant to this content. \
        If no existing tags apply, return an empty tag list. Do not force a match.

        Idea:
        \(content)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: NodeAIResult.self)
            let r = response.content
            return NodeAIOutput(
                title:   r.title,
                summary: r.summary,
                tags:    r.tags.filter { !$0.isEmpty },
                mood:    r.mood.isEmpty ? nil : r.mood,
                domain:  r.domain.isEmpty ? nil : r.domain
            )
        } catch {
            return nil
        }
    }

    /// Checks whether a raw text block represents a complete, standalone idea.
    /// Returns true (coherent), false (incoherent), or nil if the model is unavailable.
    /// Callers should treat nil as "pass" — never block import when the model is offline.
    func checkCoherence(_ text: String) async -> Bool? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = "Is this a complete, standalone idea? Yes or No.\n\n\(text)"
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: CoherenceCheck.self)
            return response.content.answer.lowercased().hasPrefix("yes")
        } catch {
            return nil
        }
    }

    // MARK: - Embedding generation (for Über-node clustering)

    /// Latency test proxy: use Foundation Model summarization as a latency benchmark.
    /// Embedding API not yet exposed in iOS 26 beta — this proxy measures similar
    /// on-device inference cost. Returns (totalTime, avgPerText, successCount) or nil.
    @Generable
    struct EmbeddingTestSummary {
        @Guide(description: "Two-word summary of the text")
        var summary: String
    }

    func testFoundationModelLatency(texts: [String]) async -> (total: TimeInterval, average: TimeInterval, successCount: Int)? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let startTime = CACurrentMediaTime()
        var successCount = 0

        for text in texts {
            do {
                let session = LanguageModelSession()
                let _ = try await session.respond(to: "Summarize in 2 words: \(text)", generating: EmbeddingTestSummary.self)
                successCount += 1
            } catch {
                // Skip failures, continue measuring
                continue
            }
        }

        let endTime = CACurrentMediaTime()
        let totalTime = endTime - startTime
        let avgTime = successCount > 0 ? totalTime / Double(successCount) : 0

        return (totalTime, avgTime, successCount)
    }

    // MARK: - Image description (stubbed — vision input added in later session)

    func describeImage(_ imageData: Data) async -> String? {
        return nil
    }

    // MARK: - Content extraction

    private func extractContent(from node: Node) -> String {
        node.items.compactMap { item -> String? in
            switch item.type {
            case .text:              return item.content
            case .audio, .video:     return item.transcript
            case .image, .document:  return item.description
            case .link:              return [item.title, item.preview].compactMap { $0 }.joined(separator: " ")
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - Output type (no availability gate — CorpusStore can reference freely)

struct NodeAIOutput {
    let title:   String
    let summary: String
    let tags:    [String]
    let mood:    String?
    let domain:  String?
}
