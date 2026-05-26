import SwiftUI

/// Multi-select tag picker presented from the capture overlay's `TagPillRail`
/// "More..." pill (brief: ~/Desktop/Ops/briefs/capture-tag-rail.md). Shows
/// the full tag vocabulary with `.searchable` substring filter; each row
/// is a tappable tag with a checkmark when included in the working draft.
/// Visual language mirrors `NodePickerSheet` (black background, dark nav
/// bar, inset-grouped list, medium/large detents).
///
/// Confirmation model: edits live in a local `draft: Set<String>` seeded
/// from the binding on first appear; "Done" writes draft back, "Cancel"
/// (or swipe-down dismiss) discards. The two-step pattern matches the
/// brief's expectation that selection isn't applied until the user
/// commits — same grammar as `CollectionCreationSheet`.
struct TagSelectionSheet: View {

    @Binding var selectedTagNames: Set<String>

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<String> = []
    @State private var query: String = ""
    @State private var hasHydrated = false

    /// Full vocabulary filtered by query, sorted by `tagLastUsedAt` desc
    /// with name ascending as a stable tiebreaker. Tags without a
    /// timestamp fall to `.distantPast` and group at the tail in
    /// alphabetical order.
    private var displayedTags: [Tag] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [Tag]
        if trimmed.isEmpty {
            filtered = store.tags
        } else {
            let q = trimmed.lowercased()
            filtered = store.tags.filter { $0.name.lowercased().contains(q) }
        }
        return filtered.sorted { a, b in
            let aDate = store.tagLastUsedAt[a.name] ?? .distantPast
            let bDate = store.tagLastUsedAt[b.name] ?? .distantPast
            if aDate == bDate { return a.name < b.name }
            return aDate > bDate
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if displayedTags.isEmpty {
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedTags) { tag in
                        tagRow(tag)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedTagNames = draft
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
        .onAppear {
            guard !hasHydrated else { return }
            draft = selectedTagNames
            hasHydrated = true
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        let isSelected = draft.contains(tag.name)
        return Button {
            if isSelected {
                draft.remove(tag.name)
            } else {
                draft.insert(tag.name)
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: tag.colorHex) ?? .gray)
                    .frame(width: 10, height: 10)
                Text(tag.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}
