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

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case generatedAt = "generated_at"
        case sourceEmbedding = "source_embedding"
        case state
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
    static let current: AuthorshipPosture = .automatic
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
    ///   nothing is written, and it returns `false`.
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
    /// - Returns: `true` when the caller should write the field + stamp `.model`.
    mutating func recordProposal(kind: Proposal.Kind,
                                 text: String,
                                 currentSource: TagSource?,
                                 sourceEmbedding: [Float]?,
                                 posture: AuthorshipPosture,
                                 generatedAt: Date) -> Bool {
        // User-beats-model. `nil` = legacy / never-processed (FM eligible);
        // `.model` = a prior FM write (FM may refresh); `.user` = locked.
        guard currentSource == nil || currentSource == .model else { return false }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var list = proposals ?? []
            list.removeAll { $0.kind == kind }   // one per kind — regeneration replaces
            list.append(Proposal(id: UUID(),
                                 kind: kind,
                                 text: text,
                                 generatedAt: generatedAt,
                                 sourceEmbedding: sourceEmbedding,
                                 state: .fresh))
            proposals = list
        }
        return posture == .automatic
    }
}
