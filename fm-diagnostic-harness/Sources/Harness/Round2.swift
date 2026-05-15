import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Schema types

/// A3 reuses A2Result's typed-enum schema. A new struct is declared so the
/// macro-synthesized GenerationSchema is unambiguous at the call site.
@Generable
struct A3Result {
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

/// A4 stage-1 — pure folksonomy, no vocabulary list, no constraint.
@Generable
struct A4Folksonomy {
    @Guide(description: "Up to 8 tags that best describe this content. Use whatever words best describe it; you are not constrained to any vocabulary.")
    var tags: [String]
}

/// A5/A6 stage-1 — production-shaped @Generable; only the summary field is
/// consumed downstream. Same Guide strings as production NodeAIResult.
@Generable
struct SummaryFirstStage1 {
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

/// A5 stage-2 — free-form tags from the summary, vocabulary in prompt only.
@Generable
struct A5Stage2 {
    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
    var tags: [String]
}

/// A6 stage-2 — typed enum tags from the summary.
@Generable
struct A6Stage2 {
    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
    var tags: [VocabularyTag]
}

// MARK: - Prompt builders

func buildPromptA3(content: String, vocabulary: [String]) -> String {
    let vocabLine = "Tag vocabulary: " + vocabulary.joined(separator: ", ")
    return """
    Analyze this captured idea.
    \(vocabLine)
    Apply only tags that are clearly supported by the content. If the content is too short, too thin, or doesn't clearly relate to any tag in the vocabulary, return an empty list. Returning zero tags is the correct answer when the content does not support tagging. Do not guess.

    Idea:
    \(content)
    """
}

func buildPromptA4(content: String) -> String {
    """
    Generate the most accurate tags for this content. Use whatever words best describe it.

    Idea:
    \(content)
    """
}

// MARK: - Variant outputs

struct CosineMatch: Encodable {
    let folksonomy: String
    let vocab: String
    let score: Double
}

struct VariantA3Output {
    let title: String
    let summary: String
    let mood: String
    let domain: String
    let rawTags: [String]
    let postFilterTags: [String]
    let latencyMs: Int
    let error: String?
}

struct VariantA4Output {
    let folksonomy: [String]
    let cosineMatches: [CosineMatch]
    let tier1Tags: [String]
    let stage1LatencyMs: Int
    let stage2LatencyMs: Int
    let error: String?
}

struct VariantSummaryStageOutput {
    let title: String
    let summary: String
    let mood: String
    let domain: String
    let latencyMs: Int
    let error: String?
}

struct VariantA5Output {
    let summary: String
    let rawTags: [String]
    let postFilterTags: [String]
    let summaryLatencyMs: Int
    let tagLatencyMs: Int
    let error: String?
}

struct VariantA6Output {
    let summary: String
    let rawTags: [String]
    let postFilterTags: [String]
    let summaryLatencyMs: Int
    let tagLatencyMs: Int
    let error: String?
}

// MARK: - Runners

func runA3(content: String, vocabulary: [String]) async -> VariantA3Output {
    let prompt = buildPromptA3(content: content, vocabulary: vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A3Result.self)
        let r = response.content
        let raw = r.tags.map { $0.rawValue }
        var seen = Set<String>()
        var filtered: [String] = []
        for t in raw where !seen.contains(t) {
            seen.insert(t); filtered.append(t)
            if filtered.count == 5 { break }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return VariantA3Output(
            title: r.title, summary: r.summary, mood: r.mood, domain: r.domain,
            rawTags: raw, postFilterTags: filtered, latencyMs: ms, error: nil
        )
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let err = "\(type(of: error)): \(error)"
        return VariantA3Output(
            title: "", summary: "", mood: "", domain: "",
            rawTags: [], postFilterTags: [], latencyMs: ms, error: err
        )
    }
}

/// Cosine similarity over `[Double]` vectors. NLEmbedding returns `[Double]?`.
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    let denom = (na.squareRoot() * nb.squareRoot())
    return denom == 0 ? 0 : dot / denom
}

/// Round 2 A4 stage 2 — embed each folksonomy tag and each vocabulary tag with
/// `NLEmbedding.sentenceEmbedding(for: .english)`, find the highest-cosine
/// vocab match per folksonomy tag, keep if score > 0.5, dedupe, cap 5.
/// Returns the per-folksonomy match list and the final tier-1 set.
func mapFolksonomyToTier1(_ folk: [String], vocabulary: [String], embedding: NLEmbedding) -> (matches: [CosineMatch], tier1: [String]) {
    let vocabVecs: [(String, [Double])] = vocabulary.compactMap { v in
        guard let vec = embedding.vector(for: v) else { return nil }
        return (v, vec)
    }
    var matches: [CosineMatch] = []
    var seen = Set<String>()
    var tier1: [String] = []
    for f in folk {
        guard let fvec = embedding.vector(for: f) else {
            matches.append(CosineMatch(folksonomy: f, vocab: "", score: 0))
            continue
        }
        var best: (String, Double) = ("", 0)
        for (vname, vvec) in vocabVecs {
            let c = cosine(fvec, vvec)
            if c > best.1 { best = (vname, c) }
        }
        matches.append(CosineMatch(folksonomy: f, vocab: best.0, score: best.1))
        if best.1 > 0.5, !seen.contains(best.0) {
            seen.insert(best.0); tier1.append(best.0)
            if tier1.count == 5 { break }
        }
    }
    return (matches, tier1)
}

func runA4(content: String, vocabulary: [String], embedding: NLEmbedding) async -> VariantA4Output {
    let prompt = buildPromptA4(content: content)
    let s1 = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A4Folksonomy.self)
        let folk = response.content.tags
        let s1ms = Int(Date().timeIntervalSince(s1) * 1000)
        let s2 = Date()
        let (matches, tier1) = mapFolksonomyToTier1(folk, vocabulary: vocabulary, embedding: embedding)
        let s2ms = Int(Date().timeIntervalSince(s2) * 1000)
        return VariantA4Output(
            folksonomy: folk, cosineMatches: matches, tier1Tags: tier1,
            stage1LatencyMs: s1ms, stage2LatencyMs: s2ms, error: nil
        )
    } catch {
        let s1ms = Int(Date().timeIntervalSince(s1) * 1000)
        let err = "\(type(of: error)): \(error)"
        return VariantA4Output(
            folksonomy: [], cosineMatches: [], tier1Tags: [],
            stage1LatencyMs: s1ms, stage2LatencyMs: 0, error: err
        )
    }
}

/// Shared stage-1 summary call for A5/A6. Uses the production prompt + shape;
/// only the summary string is consumed downstream.
func runSummaryStage1(content: String, vocabulary: [String]) async -> VariantSummaryStageOutput {
    let prompt = buildPrompt(content: content, vocabulary: vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: SummaryFirstStage1.self)
        let r = response.content
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return VariantSummaryStageOutput(
            title: r.title, summary: r.summary, mood: r.mood, domain: r.domain,
            latencyMs: ms, error: nil
        )
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let err = "\(type(of: error)): \(error)"
        return VariantSummaryStageOutput(
            title: "", summary: "", mood: "", domain: "",
            latencyMs: ms, error: err
        )
    }
}

func runA5Stage2(summary: String, vocabulary: [String]) async -> (raw: [String], filtered: [String], latencyMs: Int, error: String?) {
    let prompt = buildPrompt(content: summary, vocabulary: vocabulary)
    let vocabSet = Set(vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A5Stage2.self)
        let raw = response.content.tags
        let filtered = Array(raw.filter { !$0.isEmpty && vocabSet.contains($0) }.prefix(5))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return (raw, filtered, ms, nil)
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ([], [], ms, "\(type(of: error)): \(error)")
    }
}

func runA6Stage2(summary: String, vocabulary: [String]) async -> (raw: [String], filtered: [String], latencyMs: Int, error: String?) {
    let prompt = buildPrompt(content: summary, vocabulary: vocabulary)
    let started = Date()
    do {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: A6Stage2.self)
        let raw = response.content.tags.map { $0.rawValue }
        var seen = Set<String>()
        var filtered: [String] = []
        for t in raw where !seen.contains(t) {
            seen.insert(t); filtered.append(t)
            if filtered.count == 5 { break }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return (raw, filtered, ms, nil)
    } catch {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return ([], [], ms, "\(type(of: error)): \(error)")
    }
}

// MARK: - Result rows for Round 2

/// Round 2 results extend the Round 1 ResultRow with optional fields specific
/// to A4 (cosineMatches) and A5/A6 (summaryLatencyMs separately from the
/// total `latencyMs`). Kept in a single struct so each variant's JSON is the
/// same shape as Round 1's plus the relevant extras only when populated.
struct Round2ResultRow: Encodable {
    let nodeID: String
    let title: String
    let contentTruncated: String
    let currentTags: [String]
    let fmRawTags: [String]
    let postFilterTags: [String]
    let fmTitle: String
    let fmSummary: String
    let fmMood: String
    let fmDomain: String
    let latencyMs: Int
    let summaryLatencyMs: Int?
    let cosineMatches: [CosineMatch]?
    let error: String?
}
