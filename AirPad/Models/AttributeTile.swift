import Foundation

/// ws-free-footprint (T, 2026-08-26): the four size classes are RETIRED as the legal
/// SET — a tile may take any width 1–4 × any height 1–4 (`AttributeGridSpan`). This enum
/// SURVIVES only as the DEFAULTS + MIGRATION table: `defaultSizeClass` still PROPOSES a
/// sensible starting shape (the system proposes; the human decides the ceiling), and its
/// `widthUnits`/`heightUnits` map a pre-free stored `size_class` to an explicit span (a
/// free migration — no data change). It no longer LIMITS what the user may choose, and
/// rendering is now derived from the span's shape, not switched on this case.
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
    /// ws-free-footprint — the tile's EXPLICIT grid span (any 1–4 × 1–4). Replaces the
    /// four-value `size_class`; migration from a stored `size_class` is free (its
    /// `widthUnits`/`heightUnits` map to a span). Rendering derives from this shape.
    var span: AttributeGridSpan

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

    init(span: AttributeGridSpan, position: AttributeGridPosition? = nil) {
        self.span = span; self.position = position
    }
    /// Defaults/fixtures/migration convenience — build a span from a size class.
    init(sizeClass: AttributeSizeClass, position: AttributeGridPosition? = nil) {
        self.init(span: AttributeGridSpan(w: sizeClass.widthUnits, h: sizeClass.heightUnits),
                  position: position)
    }

    enum CodingKeys: String, CodingKey {
        case span
        case sizeClass = "size_class"
        case position
    }

    /// FREE migration: decode the explicit `span` if present; else map a pre-free stored
    /// `size_class` through its `widthUnits`/`heightUnits`; else the stacked default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.position = try c.decodeIfPresent(AttributeGridPosition.self, forKey: .position)
        if let span = try c.decodeIfPresent(AttributeGridSpan.self, forKey: .span) {
            self.span = span
        } else if let sc = try c.decodeIfPresent(AttributeSizeClass.self, forKey: .sizeClass) {
            self.span = AttributeGridSpan(w: sc.widthUnits, h: sc.heightUnits)
        } else {
            self.span = AttributeGridSpan(w: 2, h: 1)   // stacked default
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(span, forKey: .span)
        try c.encodeIfPresent(position, forKey: .position)
    }
}

/// A tile's grid span — width in cell units (1…4, the 4-wide grid) and height in rows
/// (1…4). ws-free-footprint retired the four fixed size classes; this is the open set.
/// Typed nested struct (like `AttributeGridPosition`) so the schema keeps its discipline.
struct AttributeGridSpan: Codable, Equatable {
    var w: Int
    var h: Int

    enum CodingKeys: String, CodingKey { case w, h }
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
