import Foundation

/// The closed set of grid footprints an attribute tile may take in the attributes
/// cell grid (Control Center model — tiles snap to whole cells, columns are 4 units
/// wide). The SIZE SELECTS THE RENDERING: the same attribute renders differently at
/// each size (T, 2026-07-31), so this is a presentation choice made by shape.
///
/// Convention: `<height rows> × <width units>`. Width units come from the closed set
/// {1, 2, 4}; height from {1, 2}.
enum AttributeSizeClass: String, Codable, Equatable, CaseIterable {
    /// 1 × 2 — caption over value, STACKED (the shipped `StackedPairsFlow` treatment).
    case stacked
    /// 1 × 4 — full row: caption LEADING, value TRAILING.
    case row
    /// 2 × 2 — stacked again, rendered LARGER.
    case large
    /// 1 × 1 — a single narrow cell (e.g. a rating). Never used for long text.
    case compact

    /// Grid width in cell units (the grid is 4 units wide).
    var widthUnits: Int {
        switch self {
        case .compact:         return 1
        case .stacked, .large: return 2
        case .row:             return 4
        }
    }

    /// Grid height in rows.
    var heightUnits: Int {
        switch self {
        case .large: return 2
        default:     return 1
        }
    }
}

/// Per-node, per-attribute presentation for the attributes cell grid. Stored ON the
/// atomic `.field` / `.rating` `NodeItem` (deliberately NOT a string-keyed dict on
/// `Node` — the `Node.tagSources` flat-dict lesson, T 2026-08-24: a flat dict is what
/// makes adding typed provenance painful).
///
/// ★ SCHEMA FORESIGHT (T, 2026-08-24): kept a TYPED NESTED STRUCT so a later arc's
/// per-attribute PROVENANCE (SB128 / tag-bound attribute extraction —
/// `attribute_origin`, `extraction_source`, `confidence`) can be added as its own
/// nested typed field, e.g. `var provenance: AttributeProvenance?`, WITHOUT a
/// migration. Those fields are NOT built here — not in the ratified brief, not this
/// arc; this arc ships only `sizeClass`. The shape is the point.
///
/// Additive optional on `NodeItem`; synthesized `Codable` decodes a missing key as
/// nil (`decodeIfPresent` semantics) — no `entrySchemaVersion` bump.
struct AttributeTile: Codable, Equatable {
    /// The tile's grid footprint, which selects its rendering.
    var sizeClass: AttributeSizeClass

    /// ws-attributes-grid P3 — the tile's STORED grid position (the iOS-18 Home Screen
    /// model, T 2026-08-25): position is placed, not derived from array order, so
    /// deliberate empty cells (interior holes) are legitimate composition and a resize
    /// never reshuffles neighbours. Coordinates live in the canonical 4-column space
    /// (see `AttributeGridPosition`). Nil = the position hasn't been authored yet: the
    /// grid DERIVES it from the same first-free-cell pack the pre-P3 layout used, so an
    /// un-arranged node renders identically (lazy migration — the whole node's layout is
    /// frozen into stored positions on its first arrange). Additive optional,
    /// `decodeIfPresent` — no `entrySchemaVersion` bump.
    var position: AttributeGridPosition?

    enum CodingKeys: String, CodingKey {
        case sizeClass = "size_class"
        case position
    }
}

/// A tile's placed position in the attributes cell grid — row (grows unbounded) and
/// column (0..<4, the canonical grid width). Typed (not two bare Ints on `AttributeTile`)
/// so a footprint that runs off the grid can never be represented ambiguously, matching
/// the "typed nested struct" discipline the rest of this schema keeps.
struct AttributeGridPosition: Codable, Equatable {
    /// Row index (0-based, top). Rows grow as needed; there is no ceiling.
    var row: Int
    /// Column index in the 4-wide grid (0...3 for the tile's LEADING cell).
    var col: Int

    enum CodingKeys: String, CodingKey {
        case row, col
    }
}

extension FieldKind {
    /// The CLOSED, PER-KIND set of grid sizes this kind may take (T: "the closed set
    /// of sizes is PER-KIND, not global — otherwise a paragraph can be shrunk into
    /// unreadability"). This is the set the arrange-mode resize handle cycles through;
    /// ordered small → large. CC's sensible sets, surfaced in the sim gate for T's
    /// review — not a re-litigation of the ruled design.
    /// EVERY kind may occupy EVERY size class on EXPLICIT user resize (T, 2026-08-25,
    /// decisions.md ceiling change): the system proposes a sensible DEFAULT
    /// (`defaultSizeClass`), and the human decides the ceiling — restricting the SET is the
    /// system deciding what someone may see for themselves, which cuts against hybrid
    /// authorship. If a value truncates at a chosen size, the user assesses that and picks
    /// another; truncation is rendered as INTENTIONAL (tail ellipsis / degrade-to-fit,
    /// never a glyph clipped mid-stroke). The "attributes are scannable, not prose"
    /// PRINCIPLE still governs DEFAULTS + rendering (text still DEFAULTS to `.row`; text
    /// `.large` is still the growable block) — it is not a ceiling on user choice.
    /// Ordered small → large for the arrange-mode resize cycle.
    var supportedSizeClasses: [AttributeSizeClass] {
        [.compact, .stacked, .row, .large]
    }

    /// Migration + creation default (T's ratified defaults: existing stacked pairs →
    /// 1×2 `.stacked`; long text → full-row `.row`). Guaranteed to be a member of
    /// `supportedSizeClasses`.
    var defaultSizeClass: AttributeSizeClass {
        self == .text ? .row : .stacked
    }
}
