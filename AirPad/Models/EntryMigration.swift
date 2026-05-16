import Foundation

/// Stage 3.1a — per-node lazy migration to the entry-primitive schema.
///
/// Mutates the node in place, populating the four entry-primitive fields
/// (`displayName`, `isExpanded`, `updatedAt`, `specializedType`) on every
/// item and bumping `entrySchemaVersion` to 1. Returns `true` if migration
/// actually ran (caller should persist), `false` if the node was already at
/// the current entry schema version (no-op).
///
/// Idempotent: running twice on the same node produces the same result as
/// running once. Lossless: every existing item field (id, type, createdAt,
/// content, file, description, transcript, durationSeconds, url, title,
/// preview) is preserved verbatim — migration only *adds* values to nil
/// fields, never overwrites populated ones.
///
/// Per-node, lazy, on first open under 3.1a — never bulk-walks the corpus.
/// The caller is `CorpusStore.ensureEntrySchema(forNodeID:)`, invoked from
/// `NodeDetailView.onAppear`. Nodes the user never opens stay at version 0
/// on disk until their first open under this build.
@discardableResult
func migrateEntrySchemaIfNeeded(_ node: inout Node) -> Bool {
    guard node.entrySchemaVersion < 1 else { return false }

    // Sequential numbering scoped per-node, per-type. First item of a given
    // type gets the bare default ("Voice"); subsequent items get ordinals
    // ("Voice 2", "Voice 3", …). Gaps after deletion are accepted —
    // stable identity over tidy sequences.
    var counters: [NodeItemType: Int] = [:]
    for i in node.items.indices {
        let t = node.items[i].type
        let n = (counters[t] ?? 0) + 1
        counters[t] = n

        // Only populate fields that are absent. A user who renamed an item
        // under a hypothetical earlier 3.1a build (or any future scenario
        // where displayName arrives populated) is respected.
        if node.items[i].displayName == nil {
            let base = t.defaultDisplayName
            node.items[i].displayName = (n == 1) ? base : "\(base) \(n)"
        }
        if node.items[i].isExpanded == nil {
            node.items[i].isExpanded = true
        }
        if node.items[i].updatedAt == nil {
            // Legacy items have no `updatedAt`; fall back to `createdAt`
            // so the field is always populated post-migration.
            node.items[i].updatedAt = node.items[i].createdAt
        }
        // `specializedType` stays nil — no specialized types in 3.1a.
    }

    node.entrySchemaVersion = 1
    return true
}
