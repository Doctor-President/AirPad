import Foundation

/// Stage 5.2 — a shipped `(display name, kind)` preset. ★ Presets are DATA, not
/// a code path: `makeDefinition()` produces an ORDINARY `FieldDefinition` with a
/// fresh UUID, indistinguishable afterward from one the user built by hand.
/// Reuse-by-id lives in the store (`resolvePreset` = find-or-create), so tapping
/// the same preset twice attaches the SAME definition, never a duplicate — the
/// same de-dup-at-entry principle as `vocabulary`.
struct FieldPreset: Identifiable, Equatable {
    /// Stable id of the PRESET (for list/preview identity) — NOT the id of any
    /// definition it instantiates.
    let id: String
    let displayName: String
    let kind: FieldKind
    let config: FieldConfig

    func makeDefinition() -> FieldDefinition {
        FieldDefinition(displayName: displayName, kind: kind, config: config)
    }
}

extension FieldPreset {
    /// Curated seed order (workstream § FIELD CREATION — THE SHEET). A small
    /// set: the point is a fast start, not a catalog.
    static let seeded: [FieldPreset] = [
        FieldPreset(id: "preset.cookTime", displayName: "Cook time", kind: .duration, config: FieldConfig()),
        FieldPreset(id: "preset.serves",   displayName: "Serves",    kind: .number,   config: FieldConfig(rangeEnabled: true)),
        FieldPreset(id: "preset.price",    displayName: "Price",     kind: .money,    config: FieldConfig()),
        FieldPreset(id: "preset.rating",   displayName: "Rating",    kind: .rating,   config: FieldConfig(ratingScale: 5, ratingStyle: .stars)),
        FieldPreset(id: "preset.when",     displayName: "When",      kind: .date,     config: FieldConfig()),
        FieldPreset(id: "preset.source",   displayName: "Source",    kind: .url,      config: FieldConfig()),
    ]
}
