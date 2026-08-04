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
