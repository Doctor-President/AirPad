import Foundation
import FoundationModels

// MARK: - SB126 Stage 2 — token instrumentation helper

/// Logs a `[FM][<callSite>] tokens=<n> chars=<m>` line for token-budget
/// visibility. Apple's FoundationModels SDK does not currently surface a
/// stable public `tokenCount(for:)` method on `LanguageModelSession` (Xcode
/// 26.5 beta + iOS 26.4), so the implementation falls back to `prompt.count`
/// as a chars proxy with `tokens=-1` to mark the gap. When the SDK exposes
/// the API, swap the body of `measureTokens` to call it and the four call
/// sites pick up the real numbers without further changes.
@available(iOS 26.0, *)
fileprivate func logFMTokens(_ callSite: String, prompt: String) {
    let tokens = measureTokens(prompt: prompt)
    let chars = prompt.count
    if tokens >= 0 {
        print("[FM][\(callSite)] tokens=\(tokens) chars=\(chars)")
    } else {
        print("[FM][\(callSite)] tokens=? chars=\(chars)")
    }
}

/// Returns the prompt's token count if the SDK exposes one, else -1.
/// Centralized here so flipping to the real API is a one-line change.
@available(iOS 26.0, *)
fileprivate func measureTokens(prompt: String) -> Int {
    // No public tokenCount(for:) on LanguageModelSession in the current beta.
    // When Apple ships one, replace this body with the real call.
    return -1
}

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

/// SB126 Stage 2 — output of the corpus-aware `processNode` FM call. Mirrors
/// `NodeAIResult`'s shape (title, summary, tags, mood, domain) so the corpus
/// context can ride alongside the existing per-node fields without splitting
/// the capture path into two FM calls. Adds `neighborhoodID` for the FM's
/// best-guess membership against the prefilter's top-K neighborhood digests.
@available(iOS 26.0, *)
@Generable
struct ProcessNodeResult {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String

    @Guide(description: "Up to 5 tags from the supplied vocabulary. Prefer compound or specific tags over single broad ones when both are valid; e.g., a recipe-app idea should be tagged with both 'Recipe' and 'Technology' rather than 'Technology' alone. Return an empty array if the content is too thin to support confident tagging.")
    var tags: [String]

    @Guide(description: "Emotional tone — exactly one word from this fixed set: curious, reflective, energized, uncertain, calm, urgent, playful, melancholy.")
    var mood: String

    @Guide(description: "Domain classification — exactly one value from: Recipe, Legal, Medical, Nutrition, Dream, Travel, Work, Learning, Family, Art/Project. Use an empty string if none clearly apply.")
    var domain: String

    @Guide(description: "If the node clearly belongs to one of the supplied existing neighborhoods, the neighborhood id (uuid) of the best match. Empty string if no clear fit.")
    var neighborhoodID: String
}

/// SB139 Stage 1 — output of the substrate FM call. One prompt, two outputs:
/// `summary` becomes the seed for `summaryEmbedding`; `tags` (folksonomy) is
/// joined comma-space and embedded as `folksonomyEmbedding`. The substrate's
/// summary is intentionally separate from the tag pipeline's `summary` —
/// sharing would defeat the lens separation the substrate is built on.
@available(iOS 26.0, *)
@Generable
struct SubstrateInterpretation {
    @Guide(description: "One to two sentence summary of the idea, capturing what it's about. Specific to the actual content; avoid generic filler.")
    var summary: String

    @Guide(description: "Free-form tags describing this idea. Pick whatever words best capture the content — no fixed vocabulary, no schema list. Aim for 3 to 8 short tags. Concrete nouns and topical phrases work better than abstract single words.")
    var tags: [String]
}

/// SB139 Stage 1 — outcome envelope for the substrate FM call. Models guardrail
/// refusals as a normal outcome (~4% of nodes per harness data) so the caller
/// can record the reason on the node and fall back to the content embedding.
enum SubstrateFMOutcome {
    case ok(summary: String, folksonomy: [String])
    case guardrailRefused
    case otherError(String)
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

// MARK: - Corpus-aware digest types (SB126 Stage 2)

/// Digest of a neighborhood, passed to the corpus-aware `processNode` FM call
/// as part of the prefiltered context window. Built deterministically by
/// `CorpusStore.prefilterNeighborhoods`; consumed by `processNodeCorpusAware`.
struct NeighborhoodDigest {
    let id: String
    let name: String
    let description: String
    let dominantTags: [String]
}

/// Digest of a tag entry, passed to the corpus-aware `processNode` FM call.
/// Built by `CorpusStore.topTagsForProcessNode`. The co-occurrence list helps
/// the FM prefer compound tagging over single broad tags (SB133 specificity).
struct TagDigest {
    let name: String
    let usageCount: Int
    let topCoOccurring: [String]
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

        logFMTokens("ProcessNode", prompt: prompt)
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: NodeAIResult.self)
            let r = response.content
            return NodeAIOutput(
                title:   r.title,
                summary: r.summary,
                tags:    Array(r.tags.filter { !$0.isEmpty }.prefix(5)),
                mood:    r.mood.isEmpty ? nil : r.mood,
                domain:  r.domain.isEmpty ? nil : r.domain,
                neighborhoodID: nil
            )
        } catch {
            print("[FM][processNode] FAILURE: \(error)")
            print("[FM][processNode] Error type: \(type(of: error))")
            print("[FM][processNode] Localized: \(error.localizedDescription)")
            return nil
        }
    }

    /// SB126 Stage 2 — corpus-aware variant of `processNode`. Receives a
    /// deterministically-prefiltered window of corpus context (top-K neighborhood
    /// digests + top-N tag digests with co-occurrence) alongside the full
    /// vocabulary. Single FM call producing all per-node fields plus the
    /// FM's best-guess neighborhood id. Returns nil on model unavailability or
    /// failure. Callers must NOT block node save on this — same contract as
    /// the legacy `processNode`.
    func processNodeCorpusAware(
        node: Node,
        neighborhoodDigests: [NeighborhoodDigest],
        tagDigests: [TagDigest],
        fullVocabulary: [String]
    ) async -> NodeAIOutput? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let raw = extractContent(from: node)
        guard !raw.isEmpty else { return nil }
        // ~4 chars per token proxy; truncate at ~3200 chars (≈800 tokens) so the
        // node-content slice stays inside its allocation in the token budget.
        let content: String
        if raw.count > 3200 {
            content = String(raw.prefix(3200)) + " […]"
        } else {
            content = raw
        }

        let neighborhoodSection: String
        if neighborhoodDigests.isEmpty {
            neighborhoodSection = "(no existing neighborhoods)"
        } else {
            neighborhoodSection = neighborhoodDigests.map { d -> String in
                let desc = d.description.isEmpty ? "(no description)" : d.description
                let tags = d.dominantTags.isEmpty ? "(none)" : d.dominantTags.joined(separator: ", ")
                return """
                id: \(d.id)
                name: \(d.name)
                description: \(desc)
                dominant_tags: [\(tags)]
                """
            }.joined(separator: "\n\n")
        }

        let tagSection: String
        if tagDigests.isEmpty {
            tagSection = "(no tag usage data)"
        } else {
            tagSection = tagDigests.map { d -> String in
                if d.topCoOccurring.isEmpty {
                    return "\(d.name) (used \(d.usageCount)×)"
                } else {
                    return "\(d.name) (used \(d.usageCount)×, often with: \(d.topCoOccurring.joined(separator: ", ")))"
                }
            }.joined(separator: "\n")
        }

        let vocabLine: String
        if fullVocabulary.isEmpty {
            vocabLine = "(empty)"
        } else {
            vocabLine = fullVocabulary.joined(separator: ", ")
        }

        let prompt = """
        You are tagging a captured idea against an existing personal corpus. Use the supplied corpus context to ground your choices.

        Tag-selection rules:
        - Only choose tags from the full vocabulary list. Tags outside the vocabulary are not allowed.
        - Prefer compound or specific tags over single broad ones when both are valid. A recipe-app idea is better tagged ["Recipe", "Technology"] than ["Technology"] alone. Single broad tags like "Technology" or "Work" tagged in isolation make clusters incoherent.
        - If the content is too thin or ambiguous to support confident tagging, return an empty tags array. Do not fabricate.

        Other fields:
        - title: concise, functional, under 60 characters.
        - summary: 1-2 sentences capturing the core essence.
        - mood: exactly one of curious, reflective, energized, uncertain, calm, urgent, playful, melancholy.
        - domain: exactly one of Recipe, Legal, Medical, Nutrition, Dream, Travel, Work, Learning, Family, Art/Project, or empty string if none apply.
        - neighborhoodID: if the idea clearly belongs to one of the existing neighborhoods below, copy that neighborhood's id verbatim. Otherwise empty string.

        ## Node content
        \(content)

        ## Most-relevant existing neighborhoods (top \(neighborhoodDigests.count))
        \(neighborhoodSection)

        ## Most-used tags in the corpus (top \(tagDigests.count), with co-occurrence)
        \(tagSection)

        ## Full tag vocabulary (fallback — pick from any of these)
        \(vocabLine)
        """

        logFMTokens("ProcessNodeCorpusAware", prompt: prompt)
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: ProcessNodeResult.self)
            let r = response.content
            let nbhd = r.neighborhoodID.trimmingCharacters(in: .whitespacesAndNewlines)
            return NodeAIOutput(
                title:   r.title,
                summary: r.summary,
                tags:    Array(r.tags.filter { !$0.isEmpty }.prefix(5)),
                mood:    r.mood.isEmpty ? nil : r.mood,
                domain:  r.domain.isEmpty ? nil : r.domain,
                neighborhoodID: nbhd.isEmpty ? nil : nbhd
            )
        } catch {
            print("[FM][processNodeCorpusAware] FAILURE: \(error)")
            print("[FM][processNodeCorpusAware] Error type: \(type(of: error))")
            print("[FM][processNodeCorpusAware] Localized: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generates a structured corpus summary from the current index. Returns nil if the
    /// model is unavailable or the call fails. Caller is responsible for assembling the
    /// final `CorpusSummary` (which carries computed counts and floater node IDs).
    ///
    /// SB126 Stage 3: input shape upgraded — top-25 neighborhoods by member_count are
    /// passed with their `description` (the Stage 1 derived field), so the FM gets
    /// cohesion signal directly rather than guessing from name strings. Surplus
    /// neighborhoods collapse into an "and N smaller communities" footer.
    /// `recentCaptureCount` is the count of nodes captured in the last 14 days.
    func generateCorpusSummary(
        index: CorpusIndex,
        nodeCount: Int,
        recentCaptureCount: Int
    ) async -> CorpusSummaryResult? {
        guard SystemLanguageModel.default.isAvailable else { return nil }

        let topTags = index.tags.values
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(15)
            .map { "\($0.name) (\($0.usageCount))" }
            .joined(separator: ", ")

        let sortedNeighborhoods = index.neighborhoods.values
            .sorted { $0.memberCount > $1.memberCount }
        let topNeighborhoods = Array(sortedNeighborhoods.prefix(25))
        let remainingCount = max(0, sortedNeighborhoods.count - topNeighborhoods.count)

        let neighborhoodSection: String
        if topNeighborhoods.isEmpty {
            neighborhoodSection = "(no neighborhoods yet)"
        } else {
            var lines = topNeighborhoods.map { entry -> String in
                let desc = entry.description.isEmpty ? "(no description)" : entry.description
                return "- \(entry.name) (\(entry.memberCount) members): \(desc)"
            }
            if remainingCount > 0 {
                lines.append("- and \(remainingCount) smaller communities")
            }
            neighborhoodSection = lines.joined(separator: "\n")
        }

        let prompt = """
        Synthesize what this idea corpus is about right now. Ground every claim in the supplied neighborhoods (each carries a 1-2 sentence description of its content) and tag usage. Reference cluster content, not just names.

        Corpus stats:
        - \(nodeCount) total nodes
        - \(recentCaptureCount) captured in the last 14 days

        Neighborhoods (top by size, with description):
        \(neighborhoodSection)

        Top tags by usage:
        \(topTags)
        """

        logFMTokens("GenerateCorpusSummary", prompt: prompt)
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
        logFMTokens("CharacterizeNeighborhood", prompt: prompt)
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
        logFMTokens("NameNeighborhood", prompt: prompt)
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: NeighborhoodNaming.self)
            let name = response.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        } catch { return nil }
    }

    /// SB139 Stage 1 — substrate FM call. Single prompt produces both the
    /// substrate summary (1-2 sentences) and the free-form folksonomy. The
    /// substrate is intentionally separate from `processNode` /
    /// `processNodeCorpusAware`: the tag pipeline picks from a fixed
    /// vocabulary; the substrate lets the FM interpret content with no
    /// schema constraint, then the resulting text is embedded.
    /// Returns `.guardrailRefused` for the ~4% of nodes Apple's safety layer
    /// rejects so the caller can record the reason and fall back to content.
    func processSubstrate(content: String) async -> SubstrateFMOutcome {
        guard SystemLanguageModel.default.isAvailable else { return .otherError("model_unavailable") }
        guard !content.isEmpty else { return .otherError("empty_content") }

        // Same ~3200-char cap (≈800 token proxy) used by processNodeCorpusAware
        // so the substrate call has a similar input footprint.
        let truncated: String
        if content.count > 3200 {
            truncated = String(content.prefix(3200)) + " […]"
        } else {
            truncated = content
        }

        let prompt = """
        Interpret this captured idea. Two outputs:

        1. summary — 1 to 2 sentences capturing what this idea is actually about. Be concrete and specific to the content; no generic filler. This is the seed for downstream embedding, so accuracy matters more than style.
        2. tags — free-form folksonomy. Pick whatever short tags best describe this idea. No fixed vocabulary; use the words that actually fit. Concrete topical phrases beat abstract single words. 3 to 8 tags.

        Idea:
        \(truncated)
        """

        logFMTokens("ProcessSubstrate", prompt: prompt)
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: SubstrateInterpretation.self)
            let s = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let f = response.content.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if s.isEmpty && f.isEmpty {
                return .otherError("empty_output")
            }
            return .ok(summary: s, folksonomy: f)
        } catch {
            let desc = "\(error)".lowercased()
            // Apple's FoundationModels surfaces guardrail refusals as errors
            // whose stringified form mentions "guardrail" / "safety". Detect
            // those textually since the SDK doesn't expose a typed enum yet.
            if desc.contains("guardrail") || desc.contains("safety") {
                print("[FM][processSubstrate] guardrail refusal: \(error)")
                return .guardrailRefused
            }
            print("[FM][processSubstrate] FAILURE: \(error)")
            return .otherError("\(type(of: error)): \(error.localizedDescription)")
        }
    }

    /// Cold-start similarity for tags with `usage_count < 5`, where lift values
    /// are not statistically meaningful. Returns top-N most similar existing
    /// tags (score > 0.3), or nil if the model is unavailable or output cannot
    /// be parsed. Empty vocabulary returns an empty array. Per SB126 Stage 3,
    /// the new tag is filtered out of the comparison vocabulary defensively
    /// (AT20 fix) — passing it back to itself produces self-similarity = 1.0
    /// noise.
    func computeTagSimilarity(
        newTag: String,
        existingTags: [String]
    ) async -> [TagRelation]? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let filteredVocab = existingTags.filter { $0 != newTag }
        guard !filteredVocab.isEmpty else { return [] }
        let vocabLine = filteredVocab.joined(separator: ", ")
        let prompt = """
        Rate the semantic similarity between the tag "\(newTag)" and each of the following tags.
        Return only the top 5 most similar tags with a similarity score from 0.0 to 1.0.
        Only include tags with score > 0.3. If none qualify, return an empty array.
        Tags to compare: \(vocabLine)
        Respond ONLY with a JSON array. Example: [{"tag": "French Cooking", "score": 0.87}]
        """
        logFMTokens("ComputeTagSimilarity", prompt: prompt)
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
    /// SB126 Stage 2 — set only by the corpus-aware path; always nil from
    /// legacy `processNode`. Stored on the node as metadata; not consumed in
    /// Stage 2 itself.
    let neighborhoodID: String?
}
