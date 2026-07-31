import Foundation

/// Stage 5.1 — the typed value payload for a `.field` `NodeItem`, one case per
/// `FieldKind`. Generalizes the shipped `Rating` precedent (a typed nested
/// value on the item, NOT a serialized string in `content`) across the twelve
/// kinds. An enum-with-associated-values keeps each kind's shape coherent — a
/// `date` value cannot accidentally hold a currency — where a flat 20-field
/// struct could not. Codable is synthesized and round-trips through
/// `JSONEncoder.airPad`, asserted by `FieldValueSelfTest`.
enum FieldPayload: Codable, Equatable {
    /// bare scalar — issue #, reps, serves, difficulty, vintage, page count.
    case number(Decimal)
    /// canonical amount + its unit; the dimension is fixed on the definition.
    case measurement(amount: Decimal, unit: String)
    /// canonical seconds; display flexes ("45 min", "1 hr 15").
    case duration(seconds: Double)
    /// a date; `hasTime` is a flag on the value, not a separate kind.
    case date(Date, hasTime: Bool)
    /// decimal amount + ISO currency code (FX floats — not folded into measurement).
    case money(amount: Decimal, currencyCode: String)
    /// rating value; scale + display style live on the definition.
    case rating(Int)
    /// place name + optional coordinate.
    case location(name: String, latitude: Double?, longitude: Double?)
    /// free string.
    case text(String)
    /// ★ references vocabulary VALUE IDs (`VocabularyValue.id`), never label
    /// text — the amendment that makes the list union-mergeable and rename-safe.
    case vocabulary(valueIDs: [String])
    /// true/false — Owned · Graded · Foil · Read.
    case boolean(Bool)
    /// a URL string (stored as String to survive edge URLs, like `LinkItem.url`).
    case url(String)
    /// pointer to another node by its stable id.
    case nodeReference(nodeID: String)
}

/// Stage 5.1 — a node's reference to a corpus-level `FieldDefinition` plus its
/// value. The node holds only `{ definitionID, value }`; the definition owns
/// kind + display name + config. Attached to a `.field` `NodeItem` via
/// `NodeItem.field`, the same schema-foresight pattern as `NodeItem.rating`.
struct FieldValue: Codable, Equatable {
    /// Stable ID of the `FieldDefinition` this value belongs to. Never the
    /// display name — a rename must not orphan it.
    var definitionID: String
    /// The value. ★ NULLABLE: nil = "field present, unfilled" — a distinct
    /// state from "no such field" (the absence of the `.field` item entirely).
    /// A template batch-applied to 200 nodes is mostly nil on day one; the
    /// empty slots must still render.
    var value: FieldPayload?
    /// Range second value — the optional upper bound for the four scalar kinds
    /// (`number`/`duration`/`measurement`/`money`) when the definition enables
    /// ranges. A property of the VALUE, not a separate kind; the same case as
    /// `value` (both `.number`, both `.duration`, …). nil = not a range.
    var upperValue: FieldPayload?

    init(definitionID: String, value: FieldPayload? = nil, upperValue: FieldPayload? = nil) {
        self.definitionID = definitionID
        self.value = value
        self.upperValue = upperValue
    }

    enum CodingKeys: String, CodingKey {
        case definitionID = "definition_id"
        case value
        case upperValue = "upper_value"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        definitionID = try c.decode(String.self, forKey: .definitionID)
        value        = try c.decodeIfPresent(FieldPayload.self, forKey: .value)
        upperValue   = try c.decodeIfPresent(FieldPayload.self, forKey: .upperValue)
    }
}
