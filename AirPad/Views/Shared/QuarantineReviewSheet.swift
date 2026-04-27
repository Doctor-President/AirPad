import SwiftUI

/// Sheet for reviewing quarantined entries.
/// Shows each entry with its reason and provides Rescue/Discard actions.
struct QuarantineReviewSheet: View {

    @Environment(CorpusStore.self) private var store
    @Environment(QuarantineStore.self) private var quarantineStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if quarantineStore.entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Quarantine Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .onChange(of: quarantineStore.entries.count) { _, newCount in
                if newCount == 0 {
                    dismiss()
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.black)
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(quarantineStore.entries, id: \.importedAt) { entry in
                    QuarantineEntryRow(entry: entry)
                }
            } header: {
                Text("\(quarantineStore.entries.count) quarantined \(quarantineStore.entries.count == 1 ? "entry" : "entries")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text("No quarantined entries")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct QuarantineEntryRow: View {

    let entry: BatchParser.QuarantinedEntry
    @Environment(CorpusStore.self) private var store
    @Environment(QuarantineStore.self) private var quarantineStore
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                reasonBadge
                Text(entry.rawText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await rescueEntry() }
                } label: {
                    Text("Rescue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button(role: .destructive) {
                    discardEntry()
                } label: {
                    Text("Discard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(entry.importedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
                + Text(" ago")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.white.opacity(0.05))
    }

    private var reasonBadge: some View {
        Text(entry.reason)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    /// Rescue: creates a Node from rawText and adds it to the corpus.
    /// Does NOT re-run through Router (user override).
    private func rescueEntry() async {
        await store.rescueQuarantinedEntry(entry)
    }

    /// Discard: removes the entry from quarantine storage.
    private func discardEntry() {
        quarantineStore.remove(entry)
        print("[Quarantine] Discarded entry: \(entry.rawText.prefix(50))...")
    }
}
