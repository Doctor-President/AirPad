import Foundation
import FoundationModels

// MARK: - A1: production-shape, free-form string tags

/// A1 mirrors the production `NodeAIResult` exactly — tags is `[String]` with
/// no enum constraint, vocabulary supplied only via the prompt.
@Generable
struct A1Result {
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

// MARK: - A2: hard-typed vocabulary

/// A2 swaps `tags: [String]` for `tags: [VocabularyTag]`. The Generable enum
/// constrains output to the 72-tag vocabulary at the schema level.
@Generable
struct A2Result {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String

    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
    var tags: [VocabularyTag]

    @Guide(description: "Emotional tone — exactly one word from this fixed set: curious, reflective, energized, uncertain, calm, urgent, playful, melancholy.")
    var mood: String

    @Guide(description: "Domain classification — exactly one value from: Recipe, Legal, Medical, Nutrition, Dream, Travel, Work, Learning, Family, Art/Project. Use an empty string if none clearly apply.")
    var domain: String
}

// MARK: - Production prompt builder (verbatim from AIService.processNode)

/// Constructs the prompt verbatim from `AIService.processNode`. Both variants
/// receive the same prompt — only the `@Generable` output type differs.
func buildPrompt(content: String, vocabulary: [String]) -> String {
    let vocabLine: String
    if vocabulary.isEmpty {
        vocabLine = "Tag vocabulary: (empty — create 1 to 3 concise domain-level tag names based on the content. Prefer broad categories over specific descriptors.)"
    } else {
        vocabLine = "Tag vocabulary: " + vocabulary.joined(separator: ", ")
    }
    return """
    Analyze this captured idea.
    \(vocabLine)
    Only suggest tags from the vocabulary if they are genuinely relevant to this content. \
    If no existing tags apply, return an empty tag list. Do not force a match.

    Idea:
    \(content)
    """
}
