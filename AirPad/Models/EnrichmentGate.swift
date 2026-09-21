import Foundation

/// THE ENRICHMENT GATE — the single predicate that decides whether a node still
/// needs FM work, asked identically by the eager pass (`scheduleEnrichment`) and
/// by Done (`TextCaptureSheet`).
///
/// ★ WHY THIS EXISTS AS A PURE TYPE. The gate used to be four lines inlined in
/// `scheduleEnrichment`, and Done didn't ask it at all — Done called
/// `processNodeWithAI` unconditionally. Two call sites, two different questions,
/// one of them wrong. Pulling the predicate out is what makes "Done asks the same
/// question the eager pass asked" a fact rather than an intention. It is pure over
/// its inputs so it is testable without a store, a corpus, or a model.
///
/// ★★ THE DEFECT THIS REPLACES (2026-09-16). The old predicate was
/// `needsAuthorship = title.isEmpty || summary.isEmpty`. Under `AuthorshipPosture
/// .propose` the FM *never writes* those fields — `recordProposal` returns false and
/// the model only RECORDS an offer. So an empty title is the CORRECT resting state,
/// the predicate was stuck true forever, and every typing pause ≥500 ms cost two FM
/// calls for the whole time the user was composing. Emptiness measured the wrong
/// thing. The honest question is the one below: **has this aspect already been
/// offered or accepted, for THIS content?**
enum EnrichmentGate {

    /// What a node still needs. The two halves are governed by different rules and
    /// are deliberately NOT collapsed into one boolean (that collapse is the bug
    /// this type exists to prevent).
    struct Needs: Equatable {
        /// The model has not yet offered — or the user has not accepted — a title
        /// or summary for the node's current content.
        var authorship: Bool
        /// The substrate (summary + folksonomy + the three BGE channels) is missing
        /// or no longer describes the node's current content.
        var substrate: Bool

        var any: Bool { authorship || substrate }
        static let none = Needs(authorship: false, substrate: false)
    }

    /// WHEN the question is being asked. The authorship half is identical at both
    /// moments; the substrate half is not, and the difference is load-bearing.
    enum Moment {
        /// Mid-composition, 500 ms after a text commit. The substrate is asked only
        /// "are you MISSING?" — re-deriving it at every pause is precisely the cost
        /// being cut, and an interim summary has no reader until the note is
        /// committed anyway.
        case composing
        /// The user pressed Done. Now the substrate is asked "are you STALE?", because
        /// this is the text that will be persisted, embedded, and placed on the map.
        /// A summary computed three paragraphs ago must not become the node's meaning.
        case committed
    }

    /// The aspects the default (non-tray) path offers. `.tags` is modelled in
    /// `Proposal.Kind` but has no producer, so it is not asked about here.
    static let authoredAspects: [Proposal.Kind] = [.title, .summary]

    /// - Parameters:
    ///   - proposals: the node's recorded proposals (`Node.proposals`).
    ///   - titleSource: `Node.titleSource` — non-nil means authored or accepted.
    ///   - summarySource: `Node.summarySource`.
    ///   - substrateIsPresent: does the node currently carry a substrate summary
    ///     AND a folksonomy? (Unchanged from the predicate this replaces.)
    ///   - substrateContentHash: the content hash the substrate was last computed
    ///     against (`Node.substrateContentHash`), or nil if it predates the field.
    ///   - contentHash: the node's CURRENT content hash — the same
    ///     `cardContentHash` key the card catalog uses for freshness. Reused rather
    ///     than re-invented so there is exactly one notion of "the content moved".
    static func needs(proposals: [Proposal]?,
                      titleSource: TagSource?,
                      summarySource: TagSource?,
                      substrateIsPresent: Bool,
                      substrateContentHash: String?,
                      contentHash: String,
                      at moment: Moment) -> Needs {

        let authorship = authoredAspects.contains { kind in
            let source: TagSource? = (kind == .title) ? titleSource : summarySource
            return aspectNeedsOffer(kind: kind, source: source,
                                    proposals: proposals, contentHash: contentHash)
        }

        let substrate: Bool
        switch moment {
        case .composing:
            substrate = !substrateIsPresent
        case .committed:
            // Missing, or computed against text the user has since moved past.
            // A nil hash means the substrate predates the field — treat as stale
            // once, which re-derives it and stamps the hash. Self-healing.
            substrate = !substrateIsPresent || substrateContentHash != contentHash
        }

        return Needs(authorship: authorship, substrate: substrate)
    }

    /// Does ONE authored aspect still need the model to offer something?
    ///
    /// ★ Order matters. The source check comes FIRST: a `.user` or `.model` source
    /// means the field is authored or an offer was accepted, and `recordProposal`'s
    /// user-beats-model gate would refuse to touch it anyway — asking about
    /// proposals after that would be asking a question whose answer cannot matter.
    ///
    /// ★ This deliberately does NOT use `Node.surfacedProposal(kind:)`. That
    /// predicate answers a DISPLAY question ("should the tray show this?") and hides
    /// an unsolicited proposal for a user-authored field — which would read here as
    /// "nothing offered, go generate", re-firing the model at exactly the field the
    /// user owns. Display-worthiness and work-needed are different questions.
    ///
    /// ★ Any state counts, not just `.fresh`. A proposal the user DISMISSED is still
    /// an answer the model already gave for this content; regenerating it on the next
    /// keystroke would re-offer what was just declined. Only new content re-opens it.
    private static func aspectNeedsOffer(kind: Proposal.Kind,
                                         source: TagSource?,
                                         proposals: [Proposal]?,
                                         contentHash: String) -> Bool {
        guard source == nil else { return false }
        guard let existing = proposals?.first(where: { $0.kind == kind }) else { return true }
        return existing.sourceContentHash != contentHash
    }
}
