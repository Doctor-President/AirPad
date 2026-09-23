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
    /// Build K / AJ4 — when a store is supplied, the picker rows gain swipe-to-delete
    /// and long-press-rename (the SAME `deleteTagInUserRoom` / `renameTagInUserRoom`
    /// the Settings → Tags list uses), so the entry-side Add Tag sheet has CRUD parity.
    /// nil (the canvas batch bar) → the plain add-only picker, unchanged.
    var store: CorpusStore? = nil
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
                    store: store,
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
    /// When set, rows gain delete/rename (see `TagPickerButton.store`). Read LIVE for
    /// the row source so a delete/rename reflects in the list immediately.
    var store: CorpusStore? = nil
    let onPickExisting: (String) -> Void
    let onRequestCreate: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    // AJ4 CRUD state (only reachable when `store != nil`), mirroring Settings → Tags.
    @State private var tagPendingDelete: Tag? = nil
    @State private var tagRenaming: Tag? = nil
    @State private var tagRenameText = ""

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vocabulary source: LIVE `store.tags` when a store is present (so CRUD reflects
    /// at once), else the passed snapshot (canvas batch bar).
    private var source: [Tag] { store?.tags ?? tags }

    private var available: [Tag] {
        let base = source.filter { !excludeNames.contains($0.name) }
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
                            tagRow(tag)
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
            // AJ4 — delete/rename reuse the SAME room-sealed store methods as Settings;
            // wording matches so the two surfaces read identically. Inert when store == nil
            // (the state never gets set without CRUD rows).
            .confirmationDialog(deleteTitle(tagPendingDelete),
                                isPresented: Binding(get: { tagPendingDelete != nil },
                                                     set: { if !$0 { tagPendingDelete = nil } }),
                                titleVisibility: .visible, presenting: tagPendingDelete) { tag in
                Button("Remove", role: .destructive) {
                    if let store { Task { await store.deleteTagInUserRoom(tag) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { tag in
                if tag.isCanvasAnchor { Text("Its territory on the Map will dissolve.") }
            }
            .alert("Rename tag", isPresented: Binding(get: { tagRenaming != nil },
                                                      set: { if !$0 { tagRenaming = nil } })) {
                TextField("Tag name", text: $tagRenameText).autocorrectionDisabled()
                Button("Rename") {
                    if let store, let t = tagRenaming { Task { await store.renameTagInUserRoom(t, to: tagRenameText) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Renames it on your entries and keeps its colour. The Sample Library keeps the old name.")
            }
        }
    }

    /// One tag row. With a store, it carries swipe-delete + long-press rename/delete
    /// (the entry-side parity with Settings → Tags); without one, it's add-only.
    @ViewBuilder
    private func tagRow(_ tag: Tag) -> some View {
        let button = Button {
            onPickExisting(tag.name)
            dismiss()
        } label: {
            Text(tag.name).foregroundStyle(AppearancePalette.ink)
        }
        if store != nil {
            button
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { tagPendingDelete = tag } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button { tagRenaming = tag; tagRenameText = tag.name } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { tagPendingDelete = tag } label: { Label("Delete", systemImage: "trash") }
                }
        } else {
            button
        }
    }

    /// Delete-confirmation title names the cost (the user-room count), matching Settings.
    private func deleteTitle(_ tag: Tag?) -> String {
        guard let tag else { return "Remove tag?" }
        let n = store?.userNodeCount(forTag: tag.name) ?? 0
        return "Remove \u{201C}\(tag.name)\u{201D} from \(n) \(n == 1 ? "entry" : "entries")?"
    }
}
