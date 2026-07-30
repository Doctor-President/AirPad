import SwiftUI

/// Add-a-tag affordance with SEARCH, for duplicate-prevention: a hyper-descriptive
/// tagger must be able to find an existing near-duplicate before creating a new tag
/// (`architecture/tags-as-user-affordance.md` §1). Replaces the old flat `Menu`
/// (a menu can't host a search field). ONE component for every surface — detail
/// view, QuikCapture, and the canvas batch action — so the behaviour can't drift.
///
/// `excludeNames` filters the vocabulary: pass a single node's already-applied tag
/// names, or an empty set for batch (idempotency is enforced at apply-time, so
/// showing all tags is correct there).
///
/// The call site keeps its existing `onPickExisting` / `onAddNew` closures — this
/// only swaps the `Menu` wrapper for a searchable sheet. Creating a new tag still
/// routes through `onAddNew` (the existing name+colour editor); it fires from the
/// picker sheet's `onDismiss` so the two sheets never overlap.
struct TagPickerButton<Label: View>: View {

    let tags: [Tag]
    let excludeNames: Set<String>
    let onPickExisting: (String) -> Void
    let onAddNew: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var showing = false
    @State private var pendingCreate = false

    var body: some View {
        Button { showing = true } label: { label() }
            .sheet(isPresented: $showing, onDismiss: {
                // Present the create-tag editor only AFTER this picker is fully
                // dismissed — presenting it while the picker sheet is still up
                // drops the second presentation (sheet-over-sheet).
                if pendingCreate {
                    pendingCreate = false
                    onAddNew()
                }
            }) {
                TagPickerSheet(
                    tags: tags,
                    excludeNames: excludeNames,
                    onPickExisting: onPickExisting,
                    onRequestCreate: { pendingCreate = true }
                )
            }
    }
}

/// The searchable picker body. Typing filters the vocabulary (case-insensitive
/// contains); tapping an existing tag applies it. "New tag…" defers to the caller's
/// create flow via `onRequestCreate` (see `TagPickerButton`).
struct TagPickerSheet: View {

    let tags: [Tag]
    let excludeNames: Set<String>
    let onPickExisting: (String) -> Void
    let onRequestCreate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var available: [Tag] {
        let base = tags.filter { !excludeNames.contains($0.name) }
        guard !trimmed.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onRequestCreate()
                    dismiss()
                } label: {
                    Label("New tag…", systemImage: "plus")
                }
                if available.isEmpty {
                    Text(trimmed.isEmpty ? "No tags yet." : "No tag matches \u{201C}\(trimmed)\u{201D}.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(available) { tag in
                            Button {
                                onPickExisting(tag.name)
                                dismiss()
                            } label: {
                                Text(tag.name)
                                    .foregroundStyle(AppearancePalette.ink)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search tags")
            .navigationTitle("Add tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
