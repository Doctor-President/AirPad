import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - SB126 Stage 2 — token instrumentation helper

/// Logs a `[FM][<callSite>] tokens=<n> chars=<m>` line for token-budget
/// visibility. F5b — iOS 26.4 shipped `SystemLanguageModel.tokenCount(for:)`, so
/// this now logs REAL tokens (was a `prompt.count` char proxy with `tokens=-1`).
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
fileprivate func measureTokens(prompt: String) async -> Int {
    if #available(iOS 26.4, *) {
        return (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
    }
    return -1
}

// MARK: - Structured output types

// live-20 (1) — title + summary, tags, the neighbourhood description + name, the coherence check and the corpus
// summary are plain-String replies under the permissive guardrails (AppleNaming). Guided generation always uses the
// default guardrails, so `@Generable` stays only on the DEBUG-dormant corpus-aware type below.

/// SB126 Stage 2 — output of the corpus-aware `processNode` FM call. Mirrors
/// `NodeAIResult`'s shape (title, summary, tags, mood, domain) so the corpus
/// context can ride alongside the existing per-node fields without splitting
/// the capture path into two FM calls. Adds `neighborhoodID` for the FM's
/// best-guess membership against the prefilter's top-K neighborhood digests.
@Generable
struct ProcessNodeResult {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One or two sentences stating what the note is ABOUT — an impersonal catalogue fragment. Never refer to the note's own author (no 'she', 'he', 'they', 'you', 'the author', 'the writer') and never narrate the author's actions; people the note is about may be named, but the writer is never the subject.")
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

/// The corpus summary (live-20 (1): parsed from a plain-String reply; was `@Generable`).
struct CorpusSummaryResult {
    /// 2-3 sentence synthesis of what this corpus is about right now. Second person.
    var summaryText: String
    /// Top 5 recurring themes as short phrases, most frequent first.
    var dominantThemes: [String]
    /// Tags or themes most active in the last 30 days.
    var recentDominantTags: [String]
    /// Tags that appear rarely or may be stale.
    var staleTags: [String]
    /// Approximate count of nodes that don't fit clearly into any cluster.
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
/// model) has NO OS floor — only a runtime Metal check — so they must be callable on a
/// device with no Apple Intelligence, where the local model is the ONLY enrichment path. Gating the whole actor
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
    func processNode(_ node: Node, tagVocabulary: [Tag], authoredOnly: Bool = false) async -> NodeAIOutcome {
        #if DEBUG
        // Brief BM0 — `-StubAuthorModel` stands in for FM/MLX so the Done → model → write
        // path is testable HEADLESS (FM/Apple Intelligence is absent in the Simulator, which
        // is exactly why BI/BL/BM all passed the sim gate and failed on device). Keeps the
        // real `.noContent` guard so a content-starved link still reproduces faithfully; then
        // returns a deterministic, NON-empty title + summary so the write-back, promote, and
        // gate all run exactly as in production. Launch-arg gated → Release excludes it (#if DEBUG).
        if ProcessInfo.processInfo.arguments.contains("-StubAuthorModel"), !Self.stubAppleDeclines {
            let content = Self.namingSlice(extractContent(from: node, authoredOnly: authoredOnly))
            guard !content.isEmpty else { return .failure(.noContent) }
            PasteProbe.noteNaming(chars: content.count)
            // Arc A — `-StubAuthorLatencyMs <n>`: the device model takes seconds, not 150 ms; a realistic
            // latency is what opens the windows a Done can race.
            let latencyMs = UserDefaults.standard.integer(forKey: "StubAuthorLatencyMs")
            try? await Task.sleep(nanoseconds: UInt64(latencyMs > 0 ? latencyMs : 150) * 1_000_000)
            // ★ Faithfully REPRODUCE the real FM's failure mode: the prompt tells the model to
            // base the TITLE on what the user WROTE, so for a derived-only node (a link / an
            // article with no user prose) it returns an empty title while still summarising the
            // supporting text. `-StubEmptyTitleOnDerived` (default ON for the matrix) mimics that
            // so the "summary fills, title empty" device bug is reproducible headlessly; pass
            // `-StubNonEmptyTitle` to force a title for the wiring-only baseline.
            // live-15 (1) — `-StubEchoInput`: the title and summary are made of the words the naming call was GIVEN, so a
            // test can assert what reached the model. Given less than a summary's worth (the device case: a PDF's 22-char
            // file name), it answers as T's device did — a title reworded from the instructions' example, no summary —
            // through the same example-echo guard as the real path.
            if ProcessInfo.processInfo.arguments.contains("-StubEchoInput") {
                let words = content.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 }
                let r = content.count < 64
                    ? (title: "Purchase of Menus and Wikipedia Articles", summary: "")
                    : (title: words.prefix(5).joined(separator: " "), summary: words.prefix(16).joined(separator: " ") + ".")
                return .success(Self.guardedNaming(title: r.title, summary: r.summary, content: content))
            }
            let (authored, _) = Self.classifyContent(from: node)
            let forceTitle = ProcessInfo.processInfo.arguments.contains("-StubNonEmptyTitle")
            // ★ Brief CF — `-StubBlankTitleAlways` blanks the title even for PROSE, mimicking the
            // corpus-aware FM deferring to an identical-content neighbour (T's duplicate-paste:
            // summary fills, title blanks though the note has prose). Exercises the showing-ghost
            // fallback in `runDupTitleCommitSelfTest`.
            let forceBlank = ProcessInfo.processInfo.arguments.contains("-StubBlankTitleAlways")
            let title = ((authored.isEmpty || forceBlank) && !forceTitle) ? "" : "Stub Title"
            return .success(NodeAIOutput(title: title, summary: "Stub summary.",
                                         tags: [], mood: nil, domain: nil, neighborhoodID: nil))
        }
        #endif
        // GAP 27 — consult the router BEFORE the FM guard. This call routes through
        // `ModelRouter.generateNodeSummary`, which sends `.local` to the on-device model,
        // so the FM-availability guard applies only when FM is the resolved provider.
        if !Self.stubAppleDeclines, await structuredCallNeedsFoundationModel() {
            // FM is the resolved provider: it must be available on this device.
            guard SystemLanguageModel.default.isAvailable else { return .failure(.unavailable) }
        }

        let content = Self.namingSlice(extractContent(from: node, authoredOnly: authoredOnly))
        guard !content.isEmpty else { return .failure(.noContent) }
        #if DEBUG
        PasteProbe.noteNaming(chars: content.count)
        #endif

        let prompt = AppleNaming.namingPrompt(content: content)

        // live-11 (2) — the token count is a log line, not an input: counting it is a model call of its own, and awaiting
        // it held the capture's naming back (longer the longer the note). Off the critical path.
        Task { await logFMTokens("ProcessNode", prompt: prompt) }
        do {
            // ws-local-model Stage 2 — one of the TWO live capture calls routed through
            // ModelRouter (the other is processSubstrate). Apple Intelligence (plain String, permissive
            // guardrails — live-20) by default, or the on-device model when the user opted in and it's ready.
            // FM's catchable refusal still arrives via the throw below → nodeFailure → .refused,
            // which the tray renders as LeverRefusalBanner. This is the TITLE+SUMMARY refusal
            // locus, INDEPENDENT of processSubstrate's folksonomy locus.
            #if DEBUG
            if Self.stubAppleDeclines { throw Self.stubDeclineError() }
            #endif
            let r = try await ModelRouter.generateNodeSummary(prompt: prompt)
            return .success(Self.guardedNaming(title: r.title, summary: r.summary, content: content))
        } catch {
            print("[FM][processNode] FAILURE: \(error)")
            // nodeFailure inspects FM error types (iOS 26). On the floor the throw can only
            // come from the local path (e.g. RouterError.localBadJSON), so carry its message
            // verbatim — the same "show what you're handed" derivation nodeFailure uses.
            let failure = await nodeFailure(from: error, prompt: prompt)
            // Brief CD5 (BP5) — Apple Intelligence REFUSED. If the optional on-device model is
            // INSTALLED (.ready — not necessarily opted in), silently retry with it rather than
            // stranding the capture, and log which model authored. If it isn't installed, or the
            // retry also fails, surface the ORIGINAL refusal (→ LeverRefusalBanner / capture note).
            if case .refused = failure, await Self.localModelReadyForFallback() {
                do {
                    let r = try await Self.nodeSummaryLocalForced(prompt: prompt)
                    print("[FM][processNode] refusal → on-device model authored (title/summary)")
                    var out = Self.guardedNaming(title: r.title, summary: r.summary, content: content)
                    out.namedOnDeviceAfterDecline = true   // live-20 (1) — the Proposals sheet says so in one line
                    return .success(out)
                } catch {
                    print("[FM][processNode] refusal → on-device retry also failed: \(error)")
                }
            }
            return .failure(failure)
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
        fullVocabulary: [String],
        authoredOnly: Bool = false
    ) async -> NodeAIOutcome {
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct. (Dormant: DEBUG-gated flag.)
        guard SystemLanguageModel.default.isAvailable else { return .failure(.unavailable) }

        let raw = extractContent(from: node, authoredOnly: authoredOnly)
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
        - summary: 1-2 sentences capturing the core essence, based primarily on what the user wrote (the "## What you wrote" section when present); text found in images or documents is supporting context.
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
    private func nodeFailure(from error: any Error, prompt: String) async -> NodeAIFailure {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        // live-20 (1) — iOS 27 throws `LanguageModelError`, not `GenerationError`: AppleNaming recognises both. (It
        // used to check `GenerationError` only, so on T's iOS 27 phone a decline read as an error to retry, and the
        // installed on-device model was never asked.)
        if AppleNaming.isContextOverflow(error) {
            var tokens = -1
            if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
                tokens = (try? await SystemLanguageModel.default.tokenCount(for: prompt)) ?? -1
            }
            return .contextOverflow(promptTokens: tokens,
                                    contextSize: SystemLanguageModel.default.contextSize)
        }
        if AppleNaming.isRefusal(error) {
            // Same set processSubstrate routes to `guardrailRefused`. Keep the verbatim message for the log; the
            // distinct case lets the tray say so plainly and offer the on-device model.
            return .refused(message: message)
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
            return try await AppleNaming.ask(instructions: Self.corpusSummaryFormat, prompt: prompt, parse: Self.parseCorpusSummary)
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
            return try await AppleNaming.ask(instructions: Self.plainFieldFormat("a 1-2 sentence description, under about 80 tokens"),
                                             prompt: prompt, parse: { AppleNaming.parseSingle($0, maxChars: AppleNaming.summaryMax) })
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
            return try await AppleNaming.ask(instructions: Self.plainFieldFormat("a 2-4 word name with no quotes and no punctuation"),
                                             prompt: prompt, parse: { AppleNaming.parseSingle($0, maxChars: 40) })
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
        #if DEBUG
        // Brief BM0 — stub the SECOND capture model call too, so a `-StubAuthorModel` pass
        // completes deterministically end-to-end (substrate summary + folksonomy) without FM.
        if ProcessInfo.processInfo.arguments.contains("-StubAuthorModel"), !Self.stubAppleDeclines {
            guard !content.isEmpty else { return .otherError(FMErrorDetail(errorType: "empty_content", debugDescription: nil)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .ok(summary: "Stub substrate summary.", folksonomy: ["stub", "test"])
        }
        #endif
        // GAP 27 (the site T hit) — consult the router BEFORE the FM guard. This call routes
        // through `ModelRouter.generateSubstrate`, which sends `.local` to the on-device
        // model; returning `model_unavailable` here without asking the router meant the local
        // model was never consulted and the tray rendered a refusal that never happened.
        if !Self.stubAppleDeclines, await structuredCallNeedsFoundationModel() {
            // FM is the resolved provider: it must be available on this device.
            guard SystemLanguageModel.default.isAvailable else {
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

        let prompt = AppleNaming.substratePrompt(content: truncated)

        // Item 2 — detect the note's OWN language from the raw content (not the
        // instruction-laden prompt) so the LOCAL model can be pinned to it. FM ignores this.
        let responseLanguage = Self.substrateResponseLanguage(for: truncated)

        // live-11 (2) — the token count is a log line, not an input: counting it is a model call of its own, and awaiting
        // it held the capture's naming back (longer the longer the note). Off the critical path.
        Task { await logFMTokens("ProcessSubstrate", prompt: prompt) }
        do {
            // ws-local-model Stage 2 — the SECOND live capture call routed through ModelRouter,
            // a SEPARATE refusal locus from processNode. Foundation Model (guided generation,
            // FREE-FORM folksonomy — no vocabulary, by settled decision) by default, or the
            // on-device model when the user opted in and it's ready. The router already trims +
            // filters. A refusal still throws GenerationError up, so the catch below maps it to
            // `.guardrailRefused` → persisted as the node's "guardrail_refused" reason, which is
            // what lets the tray tell a refused-tags node apart from a genuinely-empty one.
            #if DEBUG
            if Self.stubAppleDeclines { throw Self.stubDeclineError() }
            #endif
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
            // A local-path throw is never a GenerationError, so it skips this.
            // live-20 (1) — `AppleNaming.isRefusal`: iOS 26's GenerationError pair, iOS 27's LanguageModelError pair, and a
            // plain-String reply that declined in prose.
            if AppleNaming.isRefusal(error) {
                print("[FM][processSubstrate] guardrail refusal: \(error)")
                // Brief CD5 (BP5) — silent retry with the installed on-device model, same gate as
                // processNode. On success the substrate is authored locally; else surface the refusal.
                if await Self.localModelReadyForFallback() {
                    do {
                        let r = try await Self.substrateLocalForced(prompt: prompt, responseLanguage: responseLanguage)
                        if !(r.summary.isEmpty && r.folksonomy.isEmpty) {
                            print("[FM][processSubstrate] refusal → on-device model authored (substrate)")
                            return .ok(summary: r.summary, folksonomy: r.folksonomy)
                        }
                    } catch {
                        print("[FM][processSubstrate] refusal → on-device retry also failed: \(error)")
                    }
                }
                return .guardrailRefused
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
            let session = LanguageModelSession(model: AppleNaming.model)   // live-20 (1) — the user's own tag names
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
        // FM-only (GAP 27 audit): builds its own `LanguageModelSession()` — not routed
        // through ModelRouter — so the FM guard is correct.
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = "Is this a complete, standalone idea? Yes or No.\n\n\(text)"
        do {
            return try await AppleNaming.ask(instructions: Self.plainFieldFormat("exactly Yes or No"), prompt: prompt, parse: { raw in
                let a = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return a.hasPrefix("yes") ? true : a.hasPrefix("no") ? false : nil
            })
        } catch {
            return nil
        }
    }

    // MARK: - Image description (stubbed)

    // iOS 27: Foundation Models image input — the real fix (a model-authored description
    // of the photo). Post-V1. Until then, Brief BK derives searchable text from on-device
    // Vision (OCR + `ImageOCRService.classify` labels) and falls back to a dated title.
    func describeImage(_ imageData: Data) async -> String? {
        return nil
    }

    // MARK: - When Apple declines (live-20 (1))

    /// Is the on-device model installed to name what Apple Intelligence declined? (`.ready` — opted in or not.)
    static func localModelReadyForFallback() async -> Bool {
        #if DEBUG
        if stubAppleDeclines { return UserDefaults.standard.bool(forKey: "StubLocalModelReady") }
        #endif
        return await LocalModelService.shared.state == .ready
    }

    static func nodeSummaryLocalForced(prompt: String) async throws -> NodeSummaryResult {
        #if DEBUG
        if stubAppleDeclines { return NodeSummaryResult(title: "On-device stub title", summary: "On-device stub summary.") }
        #endif
        return try await ModelRouter.nodeSummaryLocalForced(prompt: prompt)
    }

    static func substrateLocalForced(prompt: String, responseLanguage: String?) async throws -> SubstrateResult {
        #if DEBUG
        if stubAppleDeclines { return SubstrateResult(summary: "On-device stub substrate.", folksonomy: ["on-device", "stub"]) }
        #endif
        return try await ModelRouter.substrateLocalForced(prompt: prompt, responseLanguage: responseLanguage)
    }

    /// `-StubAppleDeclines YES` (DEBUG): Apple Intelligence declines every naming + tags call with the error the OS
    /// throws — iOS 27's `LanguageModelError.guardrailViolation` (T's device), iOS 26's `GenerationError` — into the
    /// REAL catch path. `StubLocalModelReady` says whether the on-device model is installed to take over.
    static var stubAppleDeclines: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "StubAppleDeclines")
        #else
        return false
        #endif
    }

    #if DEBUG
    static func stubDeclineError() -> any Error {
        if #available(iOS 27.0, *) {
            return LanguageModelError.guardrailViolation(.init(debugDescription: "stub: Apple Intelligence declined"))
        }
        return LanguageModelSession.GenerationError.guardrailViolation(.init(debugDescription: "stub: Apple Intelligence declined"))
    }
    #endif

    // MARK: - Content extraction

    /// The title + summary instructions (live-20: they live in `AppleNaming`, which the Mac harness compiles).
    static var namingInstructions: String { AppleNaming.namingInstructions }

    /// live-20 (1) — a one-field plain-String reply's format (the neighbourhood description + name, the coherence check).
    static func plainFieldFormat(_ what: String) -> String {
        "You describe groups of a person's private notes, which may cover any subject; describe them plainly and neutrally. Reply with \(what), and nothing else."
    }

    static let corpusSummaryFormat = """
    You describe a person's private notes, which may cover any subject; describe them plainly and neutrally.
    Reply with exactly five lines and nothing else. Line 1 starts with "SUMMARY: " followed by a 2-3 sentence synthesis of what this corpus is about right now, in the second person, specific. Line 2 starts with "THEMES: " followed by the top 5 recurring themes as short phrases, most frequent first, separated by commas. Line 3 starts with "RECENT: " followed by the tags or themes most active in the last 30 days, separated by commas. Line 4 starts with "STALE: " followed by tags that appear rarely or may be stale, separated by commas. Line 5 starts with "FLOATERS: " followed by the approximate number of notes that don't fit clearly into any cluster.
    """

    static func parseCorpusSummary(_ raw: String) -> CorpusSummaryResult? {
        let f = AppleNaming.labelledLines(raw, labels: ["SUMMARY", "THEMES", "RECENT", "STALE", "FLOATERS"])
        let summary = AppleNaming.clean(f["SUMMARY"])
        guard !summary.isEmpty, !AppleNaming.looksLikeDecline(summary) else { return nil }
        func list(_ k: String) -> [String] {
            (f[k] ?? "").split(separator: ",").map { AppleNaming.clean(String($0)) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
        }
        let floaters = Int((f["FLOATERS"] ?? "").filter(\.isNumber)) ?? 0
        return CorpusSummaryResult(summaryText: summary, dominantThemes: Array(list("THEMES").prefix(5)),
                                   recentDominantTags: list("RECENT"), staleTags: list("STALE"), floaterCount: floaters)
    }

    /// What the model's name + summary may keep, checked against the content it was given.
    /// A3 — a name or summary may not bring in the app's own words (T's summary gained "the Librarian", a word the entry
    /// never used). Drop that field; the entry stays unnamed rather than mis-named.
    /// live-15 (1) — echoing the instructions' example means the model didn't name THIS entry: drop BOTH fields.
    static func guardedNaming(title: String, summary: String, content: String) -> NodeAIOutput {
        let echo = exampleEcho(in: title + " " + summary, content: content)
        let titleLeak = AppTermLeak.leaked(in: title, content: content) + echo
        let summaryLeak = AppTermLeak.leaked(in: summary, content: content) + echo
        if !titleLeak.isEmpty || !summaryLeak.isEmpty {
            print("[AI] naming used term(s) absent from the entry — dropped title:\(!titleLeak.isEmpty) summary:\(!summaryLeak.isEmpty) terms=\(titleLeak + summaryLeak)")
        }
        return NodeAIOutput(title: titleLeak.isEmpty ? title : "", summary: summaryLeak.isEmpty ? summary : "",
                            tags: [], mood: nil, domain: nil, neighborhoodID: nil)
    }

    /// live-15 (1) — the instructions' example summary's own words. Given almost nothing to read, the model reworded
    /// that example into a title (T's PDF: "Purchase of Menus and Wikipedia Articles"). A name or summary carrying one
    /// of these words that the entry itself doesn't contain is the example, not the entry: both fields are dropped.
    static let exampleTerms = ["menu", "Wikipedia", "French"]
    static func exampleEcho(in output: String, content: String) -> [String] {
        exampleTerms.filter { output.range(of: $0, options: .caseInsensitive) != nil && content.range(of: $0, options: .caseInsensitive) == nil }
    }

    /// AUTHORED vs DERIVED split — the single source of truth for the distinction,
    /// shared by the weighted content assembly (`extractContent`) and the tray's
    /// provenance signal (`contentProvenance`) so the two can't drift.
    ///   • AUTHORED = text the user typed or dictated (text items, audio/video
    ///     transcripts of their own capture).
    ///   • DERIVED = machine-extracted (image OCR + parent description, image/
    ///     document descriptions, link title/OG preview).
    /// Per-item order is preserved WITHIN each bucket (items are visited in order).
    /// Brief BQ2 — the SINGLE source of truth for "does this text count as content?" Trims
    /// whitespace/newlines and returns nil when nothing remains. A blank scaffold Note (created
    /// `content: ""`, but the RichText editor can leave a stray `\n`/space behind once focused)
    /// must NEVER read as authored content — otherwise a link-only capture stops being
    /// link-dominant and the page-title ghost/fallback is skipped, leaving the title empty (the
    /// bug the store matrices kept missing because they had no scaffold Note). Used by
    /// `classifyContent`, `extractNodeContent` (the content hash), and scaffold detection.
    static func meaningfulText(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func classifyContent(from node: Node) -> (authored: [String], derived: [String]) {
        var authored: [String] = []
        var derived: [String] = []
        for item in node.countedItems {   // Arc B — a verbatim extracted copy counts once
            switch item.type {
            case .text:
                if let c = meaningfulText(item.content) { authored.append(c) }
            case .audio, .video:
                if let t = meaningfulText(item.transcript) { authored.append(t) }
            case .image:
                if let d = meaningfulText(item.description) { derived.append(d) }
            case .document:
                if let d = documentText(item) { derived.append(d) }
            case .link:
                if let s = meaningfulText([item.title, item.preview].compactMap { $0 }.joined(separator: " ")) { derived.append(s) }
            case .imageVideo:
                // Gallery OCR + legacy parent description. This is DERIVED — the
                // 2026-08-17 ranking bug was a mockup's OCR caption outranking four
                // typed items because this text was concatenated ahead of them with
                // no authored/derived weighting.
                let ocr = (item.mediaItems ?? [])
                    .compactMap { $0.analysis?.recognizedText }
                    .filter { !$0.isEmpty }
                // Brief BK — Vision labels are DERIVED search context ("find my beach
                // photos"), capped below authored text. A no-readable-text photo skips the
                // authorship pass entirely (dated title instead), so labels never become the
                // title — they only make the photo findable via the substrate.
                let labels = (item.mediaItems ?? [])
                    .compactMap { $0.analysis?.classificationLabels }
                    .flatMap { $0 }
                let desc = (item.description?.isEmpty == false) ? [item.description!] : []
                var parts = desc + ocr
                if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
                if !parts.isEmpty { derived.append(parts.joined(separator: "\n")) }
            // Rating/field are atomic (no free text); .chats is a reference.
            case .rating, .field, .chats:
                break
            }
        }
        return (authored, derived)
    }

    /// live-15 (1) — a document item's text for naming and the content hash: what was extracted from its file(s), else
    /// its description (the file name). It used to be the description ALWAYS, so an 11-page PDF was named from its
    /// 22-character file name and the model invented the rest.
    static func documentText(_ item: NodeItem) -> String? {
        let extracted = (item.documentItems ?? []).compactMap { meaningfulText($0.extractedText) }
        return extracted.isEmpty ? meaningfulText(item.description) : extracted.joined(separator: "\n")
    }

    /// Whether a node carries each kind of text. Drives the tray's provenance line,
    /// which is shown ONLY when BOTH exist — a "regenerate from your writing only"
    /// affordance is inert (must be hidden) when there is no authored text to fall
    /// back to (the same standard as the Test-connection stub: never offer an action
    /// that cannot succeed).
    static func contentProvenance(for node: Node) -> (hasAuthored: Bool, hasDerived: Bool) {
        let c = classifyContent(from: node)
        return (!c.authored.isEmpty, !c.derived.isEmpty)
    }

    /// live-11 (2) — naming (title + summary) reads at most this many characters: the head of the entry, then " […]".
    /// Same ~800-token budget as the substrate and corpus-aware calls. It was uncapped, so a 20k-character paste sent all
    /// of it to the on-device model (T: the auto-title took ~10 s); a title and a 1–2 sentence summary come from the head.
    static let namingContentCap = 3200
    static func namingSlice(_ s: String) -> String {
        s.count > namingContentCap ? String(s.prefix(namingContentCap)) + " […]" : s
    }

    /// Derived-text budget when authored text is ALSO present (~200-token proxy).
    /// Leaves the bulk of the downstream ~3200-char cap for authored text so an
    /// image-heavy node can't crowd out a few typed items.
    static let derivedContentCap = 800

    /// The node's text for title/summary generation, WEIGHTED: authored text first
    /// under a labelled section, then a labelled derived section that is CAPPED so
    /// it can inform but not override. Ordering + labelling + budget, never a filter.
    ///   • text-only  → authored joined (byte-identical to the pre-split behaviour)
    ///   • image-only → derived carries it unlabelled (byte-identical; the Mewtwo
    ///     card / recipe screenshots keep working — derived is NOT gated out)
    ///   • both       → the two labelled sections, derived capped
    /// `authoredOnly` drops the derived section entirely — used ONLY by the tray's
    /// "regenerate from your writing only" action (a scoped, user-initiated
    /// exclusion, never the default path).
    private func extractContent(from node: Node, authoredOnly: Bool = false) -> String {
        let (authored, derived) = Self.classifyContent(from: node)
        let authoredText = authored.joined(separator: "\n")
        if authoredOnly { return authoredText }
        let derivedText = derived.joined(separator: "\n")
        if derivedText.isEmpty { return authoredText }   // text-only → unchanged
        if authoredText.isEmpty { return derivedText }   // image-only → unchanged
        let cappedDerived = derivedText.count > Self.derivedContentCap
            ? String(derivedText.prefix(Self.derivedContentCap)) + " […]"
            : derivedText
        return """
        ## What you wrote
        \(authoredText)

        ## Text found in images and documents (supporting context)
        \(cappedDerived)
        """
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
    /// live-20 (1) — Apple Intelligence declined and the installed on-device model named it instead.
    var namedOnDeviceAfterDecline: Bool = false
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
    /// (same derivation the chat surface uses), shown verbatim. A refusal is NOT
    /// this case (`.refused` below — iOS 26's `GenerationError` and iOS 27's
    /// `LanguageModelError` alike, via `AppleNaming.isRefusal`).
    case failed(message: String)
    /// ws-local-model Stage 2 — Foundation Model declined (`AppleNaming.isRefusal`: the
    /// refusal / guardrail pair on iOS 26 and 27, or a reply that declined in prose — the SAME set
    /// `processSubstrate` routes to `guardrailRefused`). Still carries the framework's VERBATIM message (no info
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
