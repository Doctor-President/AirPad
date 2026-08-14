import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - SB126 Stage 2 — token instrumentation helper

/// Logs a `[FM][<callSite>] tokens=<n> chars=<m>` line for token-budget
/// visibility. F5b — iOS 26.4 shipped `SystemLanguageModel.tokenCount(for:)`, so
/// this now logs REAL tokens (was a `prompt.count` char proxy with `tokens=-1`).
@available(iOS 26.0, *)
fileprivate func logFMTokens(_ callSite: String, prompt: String) async {
    let tokens = await measureTokens(prompt: prompt)
    let chars = prompt.count
    if tokens >= 0 {
        print("[FM][\(callSite)] tokens=\(tokens) chars=\(chars)")
    } else {
        print("[FM][\(callSite)] tokens=? chars=\(chars)")
    }
}

/// The prompt's real token count via `SystemLanguageModel.tokenCount(for:)`
/// (iOS 26.4+), else -1 on older OSes or if the count throws. Best-effort — a
/// logging/measurement aid, never load-bearing.
@available(iOS 26.0, *)
fileprivate func measureTokens(prompt: String) async -> Int {
    if #available(iOS 26.4, *) {
        return (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
    }
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
    /// SB139 Stage 1 cleanup — carries `FMErrorDetail` so the diagnostic
    /// inspect view can show the raw error type + debugDescription. Pre-call
    /// guard failures (model unavailable, empty content, empty output) reuse
    /// the same envelope with `errorType` set to a sentinel and
    /// `debugDescription` nil.
    case otherError(FMErrorDetail)
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
/// ★ The actor is NO LONGER gated `@available(iOS 26.0, *)`. FoundationModels
/// (LanguageModelSession / SystemLanguageModel / @Generable) is iOS 26.0+, so every
/// FM-only method below carries the annotation INDIVIDUALLY. But `processNode` and
/// `processSubstrate` route through `ModelRouter`, whose `.local` branch (the on-device
/// model) has NO OS floor — only a runtime Metal check — so they must be callable on
/// iOS 18–25, where the local model is the ONLY enrichment path. Gating the whole actor
/// stranded them (GAP 27's shape, at the actor level). Node saves are NEVER blocked.
actor AIService {

    /// GAP 27 (pattern) — does the resolved STRUCTURED provider require Apple FM? The
    /// structured summary/substrate calls route BOTH `.foundationModel` and `.ollama` to the
    /// FM session (`generateNodeSummary`/`generateSubstrate`), so ONLY `.local` bypasses FM.
    /// `processNode` / `processSubstrate` take the `SystemLanguageModel.isAvailable` guard
    /// ONLY when this is true — otherwise an opted-in, ready local model would be wrongly
    /// gated behind FM availability (the GAP 27 defect, found at a second site by T
    /// 2026-08-14: the substrate guard returned `model_unavailable` before the router was
    /// ever consulted).
    private func structuredCallNeedsFoundationModel() async -> Bool {
        if case .local = await ModelRouter.structuredProvider() { return false }
        return true
    }

    /// ws-card-catalog step 1 — capture no longer classifies. This legacy path
    /// produces title + summary only; tags/mood/domain were removed from both the
    /// prompt and the structured result (`NodeAIResult`). Tier-2 tag assignment
    /// moves to a deferred reflection pass (step 5). `tagVocabulary` is retained
    /// for signature stability with the corpus-aware sibling but is no longer read.
    func processNode(_ node: Node, tagVocabulary: [Tag]) async -> NodeAIOutcome {
        // GAP 27 — consult the router BEFORE the FM guard. This call routes through
        // `ModelRouter.generateNodeSummary`, which sends `.local` to the on-device model,
        // so the FM-availability guard applies only when FM is the resolved provider.
        if await structuredCallNeedsFoundationModel() {
            // FM is the resolved provider. The `SystemLanguageModel` reference (iOS 26) is
            // itself availability-guarded so this method compiles on the iOS 18 floor — where
            // the only way here is `.local`, which returns false above and skips this block.
            if #available(iOS 26.0, *) {
                guard SystemLanguageModel.default.isAvailable else { return .failure(.unavailable) }
            } else {
                return .failure(.unavailable)
            }
        }

        let content = extractContent(from: node)
        guard !content.isEmpty else { return .failure(.noContent) }

        let prompt = """
        Analyze this captured idea and produce a concise title and summary.

        Idea:
        \(content)
        """

        if #available(iOS 26.0, *) { await logFMTokens("ProcessNode", prompt: prompt) }
        do {
            // ws-local-model Stage 2 — one of the TWO live capture calls routed through
            // ModelRouter (the other is processSubstrate). Foundation Model (guided generation,
            // unchanged) by default, or the on-device model when the user opted in and it's ready.
            // FM's catchable refusal still arrives via the throw below → nodeFailure → .refused,
            // which the tray renders as LeverRefusalBanner. This is the TITLE+SUMMARY refusal
            // locus, INDEPENDENT of processSubstrate's folksonomy locus.
            let r = try await ModelRouter.generateNodeSummary(prompt: prompt)
            return .success(NodeAIOutput(
                title:   r.title,
                summary: r.summary,
                tags:    [],
                mood:    nil,
                domain:  nil,
                neighborhoodID: nil
            ))
        } catch {
            print("[FM][processNode] FAILURE: \(error)")
            // nodeFailure inspects FM error types (iOS 26). On the floor the throw can only
            // come from the local path (e.g. RouterError.localBadJSON), so carry its message
            // verbatim — the same "show what you're handed" derivation nodeFailure uses.
            if #available(iOS 26.0, *) {
                return .failure(await nodeFailure(from: error, prompt: prompt))
            } else {
                return .failure(.failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    /// SB126 Stage 2 — corpus-aware variant of `processNode`. Receives a
    /// deterministically-prefiltered window of corpus context (top-K neighborhood
    /// digests + top-N tag digests with co-occurrence) alongside the full
    /// vocabulary. Single FM call producing all per-node fields plus the
    /// FM's best-guess neighborhood id. Returns nil on model unavailability or
    /// failure. Callers must NOT block node save on this — same contract as
    /// the legacy `processNode`.
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession + @Generable ProcessNodeResult); DEBUG-dormant.
    func processNodeCorpusAware(
        node: Node,
        neighborhoodDigests: [NeighborhoodDigest],
        tagDigests: [TagDigest],
        fullVocabulary: [String]
    ) async -> NodeAIOutcome {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct. (Dormant: DEBUG-gated flag.)
        guard SystemLanguageModel.default.isAvailable else { return .failure(.unavailable) }

        let raw = extractContent(from: node)
        guard !raw.isEmpty else { return .failure(.noContent) }
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

        await logFMTokens("ProcessNodeCorpusAware", prompt: prompt)
        do {
            // ws-local-model Stage 2 CORRECTION: this DORMANT path (gated on the DEBUG-only
            // `useCorpusAwareTagging`, default false → unreachable in Release) is NO LONGER the
            // one routed through ModelRouter. The lever moves to the two LIVE capture calls —
            // `processNode` (title+summary) and `processSubstrate` (folksonomy) — so it reaches a
            // default user. This path stays on its inline FM call, unchanged from before Stage 2.
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: ProcessNodeResult.self)
            let r = response.content
            let nbhd = r.neighborhoodID.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(NodeAIOutput(
                title:   r.title,
                summary: r.summary,
                tags:    Array(r.tags.filter { !$0.isEmpty }.prefix(5)),
                mood:    r.mood.isEmpty ? nil : r.mood,
                domain:  r.domain.isEmpty ? nil : r.domain,
                neighborhoodID: nbhd.isEmpty ? nil : nbhd
            ))
        } catch {
            print("[FM][processNodeCorpusAware] FAILURE: \(error)")
            return .failure(await nodeFailure(from: error, prompt: prompt))
        }
    }

    /// F4/F5b — turn a thrown FM error into a `NodeAIFailure`. The ONE recognised
    /// case is `GenerationError.exceededContextWindowSize` (plainly distinguishable,
    /// and actionable): carry the real `SystemLanguageModel` token / context
    /// numbers so the tray can explain the SHARED window. Everything else —
    /// refusals (`GenerationError.refusal`; this SDK has NO `LanguageModelError`),
    /// decode failures, etc. — carries the error's OWN description verbatim, the
    /// same derivation the chat surface uses. Do NOT re-add a bucketing classifier.
    @available(iOS 26.0, *)   // FM-only: inspects LanguageModelSession.GenerationError + SystemLanguageModel.
    private func nodeFailure(from error: any Error, prompt: String) async -> NodeAIFailure {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let g = error as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize:
                var tokens = -1
                if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
                    tokens = (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
                }
                return .contextOverflow(promptTokens: tokens,
                                        contextSize: SystemLanguageModel.default.contextSize)
            case .refusal, .guardrailViolation:
                // Same pair processSubstrate routes to `guardrailRefused`. Keep the verbatim
                // message; the distinct case only lets the tray offer the on-device model.
                return .refused(message: message)
            default:
                break
            }
        }
        return .failed(message: message)
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
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession + @Generable CorpusSummaryResult).
    func generateCorpusSummary(
        index: CorpusIndex,
        nodeCount: Int,
        recentCaptureCount: Int
    ) async -> CorpusSummaryResult? {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
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

        await logFMTokens("GenerateCorpusSummary", prompt: prompt)
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
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession + @Generable NeighborhoodCharacterization).
    func characterizeNeighborhood(
        dominantTags: [String],
        topCoOccurrences: [(pair: String, count: Int)],
        memberExcerpts: [(title: String, snippet: String)],
        priorName: String?,
        priorDescription: String?
    ) async -> String? {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
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
        await logFMTokens("CharacterizeNeighborhood", prompt: prompt)
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
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession + @Generable NeighborhoodNaming).
    func nameNeighborhood(
        description: String,
        siblingNames: [String],
        priorName: String?
    ) async -> String? {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
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
        await logFMTokens("NameNeighborhood", prompt: prompt)
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
    /// Item 2 — the note's dominant language as an ENGLISH display name ("English",
    /// "Spanish", "Chinese"), or nil when detection isn't confident. Used ONLY to pin the
    /// LOCAL model's substrate output language: Qwen3 is a Chinese-base model and, on a bare
    /// tag list, intermittently returns Chinese folksonomy for an English note (T
    /// device-observed) — which STEP 4 then mints permanently on tap. The prior-art pass
    /// (ws-lever) found NO template/param/grammar knob in mlx-swift/Qwen3, so a system-prompt
    /// line is the only lever; naming the language explicitly (in English, keeping the prompt
    /// all-English) beats "same language as input", which Qwen drifts around. The 0.5 floor
    /// keeps a short/ambiguous note from being forced into the wrong language. FM is untouched.
    private static func substrateResponseLanguage(for text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        if let top = recognizer.languageHypotheses(withMaximum: 1).first?.value, top < 0.5 { return nil }
        // `forIdentifier:` (not `forLanguageCode:`) so script-tagged codes like "zh-Hans"
        // resolve to a real name instead of nil. English locale → an English name.
        return Locale(identifier: "en_US").localizedString(forIdentifier: lang.rawValue)
    }

    func processSubstrate(content: String) async -> SubstrateFMOutcome {
        // GAP 27 (the site T hit) — consult the router BEFORE the FM guard. This call routes
        // through `ModelRouter.generateSubstrate`, which sends `.local` to the on-device
        // model; returning `model_unavailable` here without asking the router meant the local
        // model was never consulted and the tray rendered a refusal that never happened.
        if await structuredCallNeedsFoundationModel() {
            // FM is the resolved provider — availability-guard the SystemLanguageModel
            // reference (iOS 26) so this compiles on the floor, where the only path here is
            // `.local` (returns false above, skips this block).
            if #available(iOS 26.0, *) {
                guard SystemLanguageModel.default.isAvailable else {
                    return .otherError(FMErrorDetail(errorType: "model_unavailable", debugDescription: nil))
                }
            } else {
                return .otherError(FMErrorDetail(errorType: "model_unavailable", debugDescription: nil))
            }
        }
        guard !content.isEmpty else {
            return .otherError(FMErrorDetail(errorType: "empty_content", debugDescription: nil))
        }

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

        // Item 2 — detect the note's OWN language from the raw content (not the
        // instruction-laden prompt) so the LOCAL model can be pinned to it. FM ignores this.
        let responseLanguage = Self.substrateResponseLanguage(for: truncated)

        if #available(iOS 26.0, *) { await logFMTokens("ProcessSubstrate", prompt: prompt) }
        do {
            // ws-local-model Stage 2 — the SECOND live capture call routed through ModelRouter,
            // a SEPARATE refusal locus from processNode. Foundation Model (guided generation,
            // FREE-FORM folksonomy — no vocabulary, by settled decision) by default, or the
            // on-device model when the user opted in and it's ready. The router already trims +
            // filters. A refusal still throws GenerationError up, so the catch below maps it to
            // `.guardrailRefused` → persisted as the node's "guardrail_refused" reason, which is
            // what lets the tray tell a refused-tags node apart from a genuinely-empty one.
            let r = try await ModelRouter.generateSubstrate(prompt: prompt, responseLanguage: responseLanguage)
            if r.summary.isEmpty && r.folksonomy.isEmpty {
                return .otherError(FMErrorDetail(errorType: "empty_output", debugDescription: nil))
            }
            return .ok(summary: r.summary, folksonomy: r.folksonomy)
        } catch {
            // SB139 Stage 1 cleanup: match on the typed enum cases, not on
            // substrings of the stringified error. The `fm_error_detail`
            // diagnostic on the real corpus confirmed two refusal paths:
            //   • `.guardrailViolation` (debugDescription "May contain unsafe content")
            //   • `.refusal`            (debugDescription "May contain sensitive content")
            // Both route to `guardrailRefused`. The case names are the API
            // contract; the debugDescription strings are user-facing UX text
            // Apple may change without notice. Anything else falls through
            // to `fm_error` — reserved for genuine unseen failure modes —
            // and `classifyFMError` captures the type + debugDescription
            // for diagnosis on `Node.fmErrorDetail`.
            // GenerationError is iOS 26; guard the cast so this compiles on the floor (a
            // local-path throw is never a GenerationError, so the floor correctly skips this).
            if #available(iOS 26.0, *), let genErr = error as? LanguageModelSession.GenerationError {
                switch genErr {
                case .refusal, .guardrailViolation:
                    print("[FM][processSubstrate] guardrail refusal: \(error)")
                    return .guardrailRefused
                default:
                    break
                }
            }
            print("[FM][processSubstrate] FAILURE: \(error)")
            return .otherError(classifyFMError(error))
        }
    }

    /// SB139 Stage 1 cleanup — extract a structured `FMErrorDetail` from a
    /// Swift error. Combines `type(of:)` with the case name parsed from the
    /// stringified error (cases of `LanguageModelSession.GenerationError`
    /// like `guardrailViolation` / `refusal` render before the first `(`).
    /// Pulls the first `debugDescription: "..."` if present. String-parsing
    /// approach is intentional: the typed enum's case set may shift across
    /// SDK versions, but `Context.debugDescription` is the public surface
    /// Apple shapes for diagnostics.
    private func classifyFMError(_ error: any Error) -> FMErrorDetail {
        let typeName = "\(type(of: error))"
        let raw = "\(error)"
        var errorType = typeName
        if let parenIdx = raw.firstIndex(of: "(") {
            let head = raw[..<parenIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty,
               head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                errorType = "\(typeName).\(head)"
            }
        }
        var debugDescription: String? = nil
        if let r = raw.range(of: "debugDescription: \"") {
            let after = raw[r.upperBound...]
            if let endQuote = after.firstIndex(of: "\"") {
                debugDescription = String(after[..<endQuote])
            }
        }
        return FMErrorDetail(errorType: errorType, debugDescription: debugDescription)
    }

    /// Cold-start similarity for tags with `usage_count < 5`, where lift values
    /// are not statistically meaningful. Returns top-N most similar existing
    /// tags (score > 0.3), or nil if the model is unavailable or output cannot
    /// be parsed. Empty vocabulary returns an empty array. Per SB126 Stage 3,
    /// the new tag is filtered out of the comparison vocabulary defensively
    /// (AT20 fix) — passing it back to itself produces self-similarity = 1.0
    /// noise.
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession).
    func computeTagSimilarity(
        newTag: String,
        existingTags: [String]
    ) async -> [TagRelation]? {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
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
        await logFMTokens("ComputeTagSimilarity", prompt: prompt)
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
    @available(iOS 26.0, *)   // FM-only (own LanguageModelSession + @Generable CoherenceCheck).
    func checkCoherence(_ text: String) async -> Bool? {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
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
            case .imageVideo:
                // Gallery OCR (substrate) + legacy parent description feed AI
                // content extraction (title/summary/tags), mirroring what
                // BlockChunker feeds the search index. Previously nil — gallery
                // entries contributed nothing to the intelligence layer.
                let ocr = (item.mediaItems ?? [])
                    .compactMap { $0.analysis?.recognizedText }
                    .filter { !$0.isEmpty }
                let desc = (item.description?.isEmpty == false) ? [item.description!] : []
                let parts = desc + ocr
                return parts.isEmpty ? nil : parts.joined(separator: "\n")
            // Stage 4.8 — Rating is an atomic numeric value, not text;
            // contributes nothing to AI content extraction. Stage 5.1 —
            // fields are atomic too; no free text to extract in Stage 1.
            // ws-chat-lane — .chats is a reference (no extraction in V1).
            case .rating, .field, .chats:  return nil
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

// MARK: - THE LEVER — Stage 2 F3 · typed generate outcome

/// Why a node's title/summary generation produced nothing. A bare `nil` used to
/// collapse every reason into one silent failure. Deliberately PLAIN — it carries
/// NO FoundationModels types — so the reason can surface all the way to the tray.
///
/// ★ F4 AMENDED (2026-08-04): do NOT re-classify framework throws into AirPad
/// buckets — CLASSIFICATION is what lost the information. The chat surface shows
/// the framework's own message ("Exceeded model context window size") because it
/// displays what it is handed; the tray now does the same. Only `unavailable` and
/// `noContent` stay typed — those are AirPad's OWN conditions, not the
/// framework's — and everything the session throws renders its own text verbatim.
enum NodeAIFailure: Equatable {
    /// AirPad's own condition — the on-device model isn't available.
    case unavailable
    /// AirPad's own condition — nothing to extract from the node.
    case noContent
    /// The ONE framework case we recognise — `GenerationError.exceededContextWindowSize`.
    /// It is plainly distinguishable (amendment) and actionable, so we carry the
    /// measured numbers and explain the SHARED input+output window in copy: a
    /// prompt that "fits" can still overflow because the reply has nowhere to go.
    /// `promptTokens` / `contextSize` are the real `SystemLanguageModel` numbers
    /// (F5b; -1 if the count was unavailable).
    case contextOverflow(promptTokens: Int, contextSize: Int)
    /// Everything else the session throws — carries the error's OWN description
    /// (same derivation the chat surface uses), shown verbatim. Refusals arrive
    /// here as `GenerationError.refusal` (there is NO separate `LanguageModelError`
    /// type in this SDK); `GenerationError: LocalizedError`, so its text renders.
    case failed(message: String)
    /// ws-local-model Stage 2 — Foundation Model declined (`GenerationError.refusal`
    /// / `.guardrailViolation`, the SAME pair `processSubstrate` routes to
    /// `guardrailRefused`). Still carries the framework's VERBATIM message (no info
    /// lost — this is NOT re-bucketing) so the tray can show it; the distinct case
    /// only adds the product action: offer AirPad's optional on-device model, which
    /// effectively does not refuse. Local's own technical failures do NOT land here.
    case refused(message: String)
}

/// The result of an authorship FM call: the produced fields, or the reason none
/// were produced. Replaces the old `NodeAIOutput?` so the caller can tell WHY a
/// generate came back empty. Node save is still never blocked on this.
enum NodeAIOutcome {
    case success(NodeAIOutput)
    case failure(NodeAIFailure)
}
