import Foundation
import FoundationModels

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

    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
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
            vocabLine = "Tag vocabulary: (empty — create 1 to 3 concise domain-level tag names based on the content. Prefer broad categories over specific descriptors.)"
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
                tags:    Array(r.tags.filter { !$0.isEmpty }.prefix(5)),
                mood:    r.mood.isEmpty ? nil : r.mood,
                domain:  r.domain.isEmpty ? nil : r.domain
            )
        } catch {
            return nil
        }
    }

    /// Generates a short evocative name for a neighborhood from its dominant tags.
    /// Returns nil if the model is unavailable, no tags supplied, or the response is empty.
    func nameNeighborhood(dominantTags: [String], memberCount: Int) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !dominantTags.isEmpty else { return nil }
        let tagList = dominantTags.prefix(5).joined(separator: ", ")
        let prompt = """
        Generate a short, evocative name (2-4 words) for a cluster of \(memberCount) ideas \
        with tags: \(tagList).
        The name should feel like a meaningful category, not a list.
        Respond with ONLY the name, nothing else.
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let name = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        } catch { return nil }
    }

    /// Computes semantic similarity between a new tag and an existing tag vocabulary.
    /// Returns the top-N most similar tags (score > 0.3), or nil if the model is unavailable
    /// or output cannot be parsed. Empty vocabulary returns an empty array.
    func computeTagSimilarity(
        newTag: String,
        existingTags: [String]
    ) async -> [TagRelation]? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !existingTags.isEmpty else { return [] }
        let vocabLine = existingTags.joined(separator: ", ")
        let prompt = """
        Rate the semantic similarity between the tag "\(newTag)" and each of the following tags.
        Return only the top 5 most similar tags with a similarity score from 0.0 to 1.0.
        Only include tags with score > 0.3. If none qualify, return an empty array.
        Tags to compare: \(vocabLine)
        Respond ONLY with a JSON array. Example: [{"tag": "French Cooking", "score": 0.87}]
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([TagRelation].self, from: data) else {
                return nil
            }
            return Array(decoded.filter { $0.score > 0.3 }.sorted { $0.score > $1.score }.prefix(5))
        } catch { return nil }
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
