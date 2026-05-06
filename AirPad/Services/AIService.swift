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

/// Output of `nameNeighborhood` Call A. The description is the load-bearing
/// derived field for SB126 Stage 1 — persisted on the neighborhood entry,
/// embedded for Stage 2's prefilter, and reused as input to Call B.
@available(iOS 26.0, *)
@Generable
struct NeighborhoodCharacterization {
    @Guide(description: "1-2 sentence description of what unifies these ideas. Concrete and specific to the actual content, not generic. Under ~80 tokens.")
    var summary: String
}

/// Output of `nameNeighborhood` Call B. Short evocative label that survives
/// across refreshes once stable.
@available(iOS 26.0, *)
@Generable
struct NeighborhoodNaming {
    @Guide(description: "A 2-4 word name for the cluster. Distinct from the sibling cluster names. No quotes, no punctuation, just the words.")
    var name: String
}

@available(iOS 26.0, *)
@Generable
struct CorpusSummaryResult {
    @Guide(description: "2-3 sentence synthesis of what this corpus is about right now. Second person. Be specific.")
    var summaryText: String

    @Guide(description: "Top 5 recurring themes as short phrases, most frequent first.")
    var dominantThemes: [String]

    @Guide(description: "Tags or themes most active in the last 30 days.")
    var recentDominantTags: [String]

    @Guide(description: "Tags that appear rarely or may be stale.")
    var staleTags: [String]

    @Guide(description: "Approximate count of nodes that don't fit clearly into any cluster.")
    var floaterCount: Int
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

    /// Generates a structured corpus summary from the current index. Returns nil if the
    /// model is unavailable or the call fails. Caller is responsible for assembling the
    /// final `CorpusSummary` (which carries computed counts and floater node IDs).
    func generateCorpusSummary(index: CorpusIndex, nodeCount: Int) async -> CorpusSummaryResult? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let neighborhoodNames = index.neighborhoods.values.map { $0.name }.joined(separator: ", ")
        let topTags = index.tags.values
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(15)
            .map { "\($0.name) (\($0.usageCount))" }
            .joined(separator: ", ")
        let prompt = """
        Analyze this idea corpus:
        - \(nodeCount) total nodes
        - \(index.neighborhoods.count) clusters: \(neighborhoodNames)
        - Top tags: \(topTags)
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: CorpusSummaryResult.self)
            return response.content
        } catch { return nil }
    }

    /// SB126 Stage 1 — Call A. Characterize a neighborhood from its dominant
    /// tags, top co-occurrence pairs, and 8 sampled member excerpts. Returns a
    /// 1-2 sentence description, or nil on model unavailability / failure.
    /// `priorName` and `priorDescription` provide continuity when cluster
    /// identity matched across refreshes (AT21 Jaccard logic).
    func characterizeNeighborhood(
        dominantTags: [String],
        topCoOccurrences: [(pair: String, count: Int)],
        memberExcerpts: [(title: String, snippet: String)],
        priorName: String?,
        priorDescription: String?
    ) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !dominantTags.isEmpty else { return nil }

        let tagLine = dominantTags.prefix(5).joined(separator: ", ")
        let coLine: String
        if topCoOccurrences.isEmpty {
            coLine = "(none)"
        } else {
            coLine = topCoOccurrences.prefix(8).map { "\($0.pair) (\($0.count))" }.joined(separator: ", ")
        }
        let memberLines = memberExcerpts.map { entry -> String in
            let title = entry.title.isEmpty ? "Untitled" : entry.title
            let snip = entry.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            return snip.isEmpty ? "- \(title)" : "- \(title): \(snip)"
        }.joined(separator: "\n")

        var continuity = ""
        if let priorName, let priorDescription, !priorDescription.isEmpty {
            continuity = """

            Previously this cluster was named "\(priorName)" and described as: "\(priorDescription)"
            Refine the description if the cluster's character has shifted; otherwise stay close.
            """
        }

        let prompt = """
        Characterize this cluster of related ideas.

        Dominant tags: \(tagLine)
        Top tag co-occurrences: \(coLine)

        Sample members:
        \(memberLines)\(continuity)

        Write a 1-2 sentence description (under ~80 tokens) capturing what unifies these ideas.
        Be concrete and specific to the actual content; avoid generic filler.
        """
        print("[FM][CharacterizeNeighborhood] prompt chars=\(prompt.count)")
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: NeighborhoodCharacterization.self)
            let summary = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch { return nil }
    }

    /// SB126 Stage 1 — Call B. Name a neighborhood given its description and
    /// the names of sibling neighborhoods. Returns a 2-4 word name, or nil on
    /// failure. `priorName` instructs the model to prefer keeping the prior
    /// label unless the description has shifted meaningfully.
    func nameNeighborhood(
        description: String,
        siblingNames: [String],
        priorName: String?
    ) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        guard !description.isEmpty else { return nil }

        let siblingLine: String
        if siblingNames.isEmpty {
            siblingLine = "(none — this is the only cluster)"
        } else {
            siblingLine = siblingNames.prefix(20).joined(separator: ", ")
        }

        var priorClause = ""
        if let priorName, !priorName.isEmpty {
            priorClause = """

            The prior name for this cluster was "\(priorName)". Prefer to keep it unless the description has meaningfully shifted.
            """
        }

        let prompt = """
        Choose a name for this cluster of ideas.

        Description: \(description)
        Existing sibling cluster names: \(siblingLine)\(priorClause)

        Output a 2-4 word name that's distinct from the sibling names. Output only the name itself.
        """
        print("[FM][NameNeighborhood] prompt chars=\(prompt.count)")
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: NeighborhoodNaming.self)
            let name = response.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
