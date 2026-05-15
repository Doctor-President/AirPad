import SwiftUI

/// Reusable menu content for adding a tag. Used by the single-node detail
/// view (Phase A) and the batch action surface (Phase B). The label and the
/// `Menu { ... }` wrapper are owned by the call site; this just supplies the
/// items — "+ Add tag…" then a divider, then the available vocabulary.
///
/// `excludeNames` filters the vocabulary list — pass the single node's
/// already-applied tag names to mirror the original behavior, or an empty
/// set for batch (idempotency is enforced at apply-time, so showing all tags
/// is the correct affordance for selecting a tag to add to many).
struct TagPickerMenuContent: View {

    let tags: [Tag]
    let excludeNames: Set<String>
    let onPickExisting: (String) -> Void
    let onAddNew: () -> Void

    var body: some View {
        Button {
            onAddNew()
        } label: {
            Label("Add tag…", systemImage: "plus")
        }

        let available = tags.filter { !excludeNames.contains($0.name) }
        if !available.isEmpty {
            Divider()
            ForEach(available) { tag in
                Button(tag.name) { onPickExisting(tag.name) }
            }
        }
    }
}
