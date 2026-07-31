import Foundation

/// Stage 5.1 — the closed set of DIMENSIONS a `measurement` field fixes once
/// at creation ("Measurement" → "Volume"). The field then wears that name
/// everywhere; the dimension scopes which units a value may carry.
enum MeasurementDimension: String, Codable, Equatable, CaseIterable {
    case volume
    case weight
    case distance
    case temperature
}

/// Stage 5.1 — how a `rating` field renders. Scale + style live on the
/// DEFINITION (not the value) so two nodes can't disagree about the same
/// field's scale. Stars stop reading past ~5, so a 10/100 scale renders
/// numeric.
enum RatingStyle: String, Codable, Equatable, CaseIterable {
    case stars
    case numeric
}

/// Stage 5.1 — one selectable value in a `vocabulary` field's growing list.
/// ★ Carries a STABLE ID, not just a label. A vocabulary list is a growing
/// list (same shape as `Node.items`); ID-addressing is what lets the single
/// `field_definitions.json` merge union-by-ID under a future merge driver
/// rather than positionally (`ws-corpus-version-control.md`). A node's
/// vocabulary value references these IDs, never the label text — so renaming
/// "Fire" → "Fire type" never orphans the nodes that picked it.
struct VocabularyValue: Codable, Equatable, Identifiable {
    let id: String
    var label: String

    init(id: String = UUID().uuidString, label: String) {
        self.id = id
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case id, label
    }
}

/// Stage 5.1 — kind-specific configuration for a `FieldDefinition`. A TYPED
/// structure, never a string-keyed dict (schema-foresight rule): each kind's
/// extras live in a named, typed field. Every field is optional/defaulted and
/// decoded with `decodeIfPresent`, so a definition written by an older or
/// newer client decodes cleanly. Only the fields relevant to the definition's
/// `kind` are read; the rest stay nil. Coherence with `kind` is guaranteed by
/// construction through `FieldDefinition`'s factories.
struct FieldConfig: Codable, Equatable {
    /// `measurement` — the dimension fixed at creation. nil for other kinds.
    var dimension: MeasurementDimension?
    /// `rating` — upper bound of the scale (5 → stars, 10/100 → numeric).
    var ratingScale: Int?
    /// `rating` — how the value renders.
    var ratingStyle: RatingStyle?
    /// `vocabulary` — the growable, ID-addressed value list.
    var vocabularyValues: [VocabularyValue]?
    /// The four scalar kinds (`number`/`duration`/`measurement`/`money`) —
    /// whether a range (optional second value) is offered. Defaults false.
    var rangeEnabled: Bool

    init(
        dimension: MeasurementDimension? = nil,
        ratingScale: Int? = nil,
        ratingStyle: RatingStyle? = nil,
        vocabularyValues: [VocabularyValue]? = nil,
        rangeEnabled: Bool = false
    ) {
        self.dimension = dimension
        self.ratingScale = ratingScale
        self.ratingStyle = ratingStyle
        self.vocabularyValues = vocabularyValues
        self.rangeEnabled = rangeEnabled
    }

    enum CodingKeys: String, CodingKey {
        case dimension
        case ratingScale = "rating_scale"
        case ratingStyle = "rating_style"
        case vocabularyValues = "vocabulary_values"
        case rangeEnabled = "range_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dimension        = try c.decodeIfPresent(MeasurementDimension.self, forKey: .dimension)
        ratingScale      = try c.decodeIfPresent(Int.self, forKey: .ratingScale)
        ratingStyle      = try c.decodeIfPresent(RatingStyle.self, forKey: .ratingStyle)
        vocabularyValues = try c.decodeIfPresent([VocabularyValue].self, forKey: .vocabularyValues)
        rangeEnabled     = try c.decodeIfPresent(Bool.self, forKey: .rangeEnabled) ?? false
    }
}

/// Stage 5.1 — a CORPUS-LEVEL field definition. Nodes reference it by stable
/// ID and hold only `{ definitionID, value }` (see `FieldValue`); the
/// definition owns everything the system reasons about — kind, the
/// user-editable display name, and the kind-specific config. Persisted in the
/// single top-level `field_definitions.json` (modeled on `collections.json`);
/// a rename here follows to every node that references it.
struct FieldDefinition: Codable, Equatable, Identifiable {
    /// Stable identity. A rename changes `displayName`, never this.
    let id: String
    /// User-owned, freely editable. Never used as an identifier
    /// (`typed-fields-with-display-names.md`).
    var displayName: String
    /// System-owned, stable. The thing the system sorts/filters/aggregates by.
    let kind: FieldKind
    /// Kind-specific extras. Coherent with `kind` by construction.
    var config: FieldConfig
    /// Stage 5.2 — most-recently-used timestamp, driving the sheet's
    /// User-Created ordering. Additive optional; nil on Stage 1 definitions,
    /// decodes clean. Bumped on create and on every attach (the accepted cost:
    /// each attach writes `field_definitions.json` — see the store).
    var lastUsedAt: Date?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        kind: FieldKind,
        config: FieldConfig = FieldConfig(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.config = config
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case kind
        case config
        case lastUsedAt = "last_used_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind        = try c.decode(FieldKind.self, forKey: .kind)
        config      = try c.decodeIfPresent(FieldConfig.self, forKey: .config) ?? FieldConfig()
        lastUsedAt  = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// Stage 5.1 — the on-disk shape of `field_definitions.json`. Wraps the
/// definitions in a versioned envelope (mirrors `canvas_layout.json` /
/// `corpus_index.json`, which carry a `version: Int`) so a future format
/// change to the config shapes has a migration anchor. An absent file is the
/// normal first-run state (no definitions yet) — the loader returns nil and
/// nothing is seeded or written.
struct FieldDefinitionStore: Codable, Equatable {
    var version: Int
    var definitions: [FieldDefinition]

    static let currentVersion = 1

    init(
        version: Int = FieldDefinitionStore.currentVersion,
        definitions: [FieldDefinition] = []
    ) {
        self.version = version
        self.definitions = definitions
    }

    enum CodingKeys: String, CodingKey {
        case version, definitions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version     = try c.decodeIfPresent(Int.self, forKey: .version) ?? FieldDefinitionStore.currentVersion
        definitions = try c.decodeIfPresent([FieldDefinition].self, forKey: .definitions) ?? []
    }
}
