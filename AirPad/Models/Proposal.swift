import Foundation

/// THE LEVER — Stage 1 (ws-lever.md § STAGE 1; architecture/hybrid-authorship.md
/// § THE LEVER — SETTLED SPEC).
///
/// A model-authored PROPOSAL for one user-owned field — a title, summary, or set
/// of tags the model has composed and the user may accept. The Lever (Stage 2)
/// surfaces these as offers the user pulls; Stage 1 only *records* them, alongside
/// the existing write, so it is invisible until the tray lands.
///
/// ★ Deliberately a typed structure, NOT a bare `String`. Without
/// `sourceEmbedding` the Stage 4 staleness decision — has the node's meaning
/// drifted past a cosine threshold since this text was generated? — is
/// UNCOMPUTABLE, and could not be added later without regenerating every
/// proposal. This is the schema-foresight rule already carried by `TagOrigin`,
/// `HeroCrop`, and `PriorityState`.
///
/// ★ Stage 1 scope is TITLE + SUMMARY ONLY. `.tags` is modeled here so the tag
/// producer (ws-lever.md § THE TAG PRODUCER — its own deferred arc) slots in with
/// no schema change, but nothing produces a `.tags` proposal on the default path
/// yet. BUG 17 therefore does not close in Stage 1.
struct Proposal: Codable, Equatable, Identifiable {
    /// Which user-owned aspect this proposal offers.
    enum Kind: String, Codable {
        case title
        case summary
        case tags
    }

    /// Lifecycle. `fresh` = generated and current. `stale` = the node's meaning
    /// has moved past the drift threshold (Stage 4). `dismissed` = the user
    /// declined it. Stage 1 only ever writes `.fresh`.
    enum State: String, Codable {
        case fresh
        case stale
        case dismissed
    }

    let id: UUID
    var kind: Kind
    var text: String
    var generatedAt: Date
    /// ★ The node's `contextualContentEmbedding` as computed on the SAME
    /// substrate pass that produced `text` (`runSubstratePipeline` writes it;
    /// `FeatureFlags.substrateOnCapture` defaults true, so it is present on the
    /// normal path). Optional ONLY because that substrate call can fail (thin
    /// content / guardrail refusal / embedder error) — never left nil when a
    /// vector exists. Stage 4 compares it to the node's current embedding.
    var sourceEmbedding: [Float]?
    var state: State
    /// Stage 2 F2 — whether the user EXPLICITLY asked for this proposal (tapped
    /// generate) rather than the system offering it. The distinction is
    /// load-bearing at display time: an UNSOLICITED proposal is never surfaced
    /// for a field the user authored (§ C3 — the request model), but a SOLICITED
    /// one always is (consent came from initiating). Defaults false; every
    /// unsolicited path (capture enrichment, scheduleEnrichment, substrate
    /// refires) leaves it false. Additive + decode-tolerant (see init(from:)).
    var solicited: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case generatedAt = "generated_at"
        case sourceEmbedding = "source_embedding"
        case state
        case solicited
    }
}

extension Proposal {
    /// Decode-tolerant (codebase norm): `solicited` is additive, so a proposal
    /// persisted before Stage 2 F2 (no key) decodes as `false` rather than
    /// throwing. The memberwise init and synthesized `encode(to:)` are unchanged.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self,   forKey: .id)
        kind            = try c.decode(Kind.self,   forKey: .kind)
        text            = try c.decode(String.self, forKey: .text)
        generatedAt     = try c.decode(Date.self,   forKey: .generatedAt)
        sourceEmbedding = try c.decodeIfPresent([Float].self, forKey: .sourceEmbedding)
        state           = try c.decode(State.self,  forKey: .state)
        solicited       = try c.decodeIfPresent(Bool.self, forKey: .solicited) ?? false
    }
}

/// THE LEVER — the posture SEAM (ws-lever.md § STAGE 3; hybrid-authorship.md).
/// The three postures are the same authorship rule at three settings: does the
/// system WRITE a model draft, only PROPOSE it, or leave the field alone. It
/// governs APPLICATION to user-visible fields, never substrate COMPUTATION —
/// the substrate keeps running under every posture.
///
/// ★ Stage 1 exposes this as a plain constant (`current`), NOT a setting and NOT
/// a `FeatureFlag`. Stage 3 replaces `current` with a per-aspect stored setting;
/// every call site already reads through it, so Stage 3 is a one-file change, not
/// a code change. Default `.automatic` is what keeps Stage 1 invisible: titles
/// and summaries are still written exactly as they are today.
enum AuthorshipPosture: String, Codable {
    /// The model writes the field directly (today's behaviour, as a choice).
    case automatic
    /// The model only offers; the user pulls the lever to apply. (Stage 2+.)
    case propose
    /// Nothing is ever offered; the lever still works on demand. (Stage 3+.)
    case off

    /// ★ THE SEAM. Stage 3 makes this a per-aspect stored setting. Do not read
    /// the posture from anywhere but `AuthorshipPosture.current`.
    ///
    /// Stage 2 (T's explicit call): flipped `.automatic` → `.propose`. This is
    /// the one-line change the Stage 1 seam was built for, and the real
    /// behaviour change of the stage — blank captures STOP auto-filling; title
    /// and summary wait for the user to pull the lever. `recordProposal` already
    /// withholds the write and records the proposal under `.propose`, so nothing
    /// else in the pipeline changes.
    static let current: AuthorshipPosture = .propose
}

extension Node {
    /// THE LEVER — Stage 1 record-and-decide for ONE authored aspect (title or
    /// summary; the mechanism is kind-generic so `.tags` works the day it has a
    /// producer). Called at the FM write site (`CorpusStore.processNodeWithAI`)
    /// once per aspect.
    ///
    /// - The user-beats-model gate lives HERE (relocated from the two inline
    ///   `titleSource`/`summarySource` checks, unchanged in semantics — so it is
    ///   the single source of truth the self-test exercises): when the user has
    ///   authored the field (`currentSource == .user`) nothing is recorded and
    ///   nothing is written, and it returns `false` — UNLESS `solicited`.
    /// - Otherwise it records a proposal of `kind` carrying `text` +
    ///   `sourceEmbedding`, REPLACING any prior proposal of that same kind (one
    ///   per kind per node — a regeneration replaces, never accumulates). Empty
    ///   text records nothing (there is nothing to offer).
    /// - It returns whether the posture says to WRITE the field now. The field
    ///   write and `.model` stamp stay at the call site (they are field-specific).
    ///   Under the Stage-1 default (`.automatic`) it returns `true` whenever the
    ///   gate passes, so titles/summaries are written EXACTLY as before — the
    ///   proposal record is purely additive. Stage 3 flips the posture and this
    ///   body does not move.
    ///
    /// ★ Stage 2 F2 — `solicited`: the user tapped GENERATE. **CONSENT COMES FROM
    /// INITIATING.** The system never OFFERS to rewrite what the user wrote, but
    /// the user may always ASK it to — so a solicited call bypasses the
    /// user-beats-model gate for PROPOSAL RECORDING ONLY. It NEVER bypasses the
    /// write (the return is still posture-driven; under `.propose` nothing
    /// auto-writes and the field changes only on accept). If unsolicited passes
    /// could reach user-authored fields, THE SENTENCE would be broken — so ONLY
    /// the tray's generate action passes `solicited: true`; every unsolicited path
    /// keeps the gate at full strength.
    ///
    /// - Returns: `true` when the caller should write the field + stamp `.model`.
    mutating func recordProposal(kind: Proposal.Kind,
                                 text: String,
                                 currentSource: TagSource?,
                                 sourceEmbedding: [Float]?,
                                 posture: AuthorshipPosture,
                                 generatedAt: Date,
                                 solicited: Bool = false) -> Bool {
        // User-beats-model. `nil` = legacy / never-processed (FM eligible);
        // `.model` = a prior FM write (FM may refresh); `.user` = locked — UNLESS
        // the user explicitly asked (`solicited`), in which case the gate opens
        // for RECORDING only (never for the write; the return is unchanged).
        let mayRecord = solicited || currentSource == nil || currentSource == .model
        if mayRecord, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var list = proposals ?? []
            list.removeAll { $0.kind == kind }   // one per kind — regeneration replaces
            list.append(Proposal(id: UUID(),
                                 kind: kind,
                                 text: text,
                                 generatedAt: generatedAt,
                                 sourceEmbedding: sourceEmbedding,
                                 state: .fresh,
                                 solicited: solicited))
            proposals = list
        }
        // ★ The WRITE is never bypassed by `solicited`: user-authored fields still
        // never auto-write, and under `.propose` nothing auto-writes at all.
        guard currentSource == nil || currentSource == .model else { return false }
        return posture == .automatic
    }

    /// THE LEVER — the proposal to SURFACE for `kind` in the button + tray, or
    /// nil. A fresh proposal shows unless the field is user-authored AND the
    /// proposal was UNSOLICITED — the system never surfaces an unsolicited
    /// proposal for a field the user wrote (§ C3), but a SOLICITED one always
    /// shows (consent came from initiating). ONE predicate so the button and tray
    /// can't disagree.
    func surfacedProposal(kind: Proposal.Kind) -> Proposal? {
        guard let p = proposals?.first(where: { $0.kind == kind && $0.state == .fresh }) else { return nil }
        let source: TagSource?
        switch kind {
        case .title:   source = titleSource
        case .summary: source = summarySource
        case .tags:    source = nil
        }
        if source == .user && !p.solicited { return nil }
        return p
    }
}
