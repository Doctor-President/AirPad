import Foundation
import FoundationModels

// MARK: - Structured output type

/// The structured result returned by the Foundation Model for each captured node.
@available(iOS 18.1, *)
@Generable
struct NodeAIResult {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String

    @Guide(description: "Array of 3 to 5 tag names. Use names from the provided vocabulary when they fit. Invent new names only if the vocabulary is empty or none of the existing tags apply.")
    var tags: [String]

    @Guide(description: "Emotional tone — exactly one word from this fixed set: curious, reflective, energized, uncertain, calm, urgent, playful, melancholy.")
    var mood: String

    @Guide(description: "Domain classification — exactly one value from: Recipe, Legal, Medical, Nutrition, Dream, Travel, Work, Learning, Family, Art/Project. Use an empty string if none clearly apply.")
    var domain: String
}

// MARK: - Service

/// On-device AI processing for nodes.
/// Requires iOS 18.1+ / Apple Intelligence-capable device.
/// Gracefully returns nil on unavailable hardware or errors — node saves are NEVER blocked.
@available(iOS 18.1, *)
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

    // MARK: - Image description (stubbed — vision input added in later session)

    func describeImage(_ imageData: Data) async -> String? {
        // Vision input requires a multimodal session.
        // The on-device model supports image analysis; this will be wired in Session 4
        // when the node detail view image enrichment flow is built.
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
