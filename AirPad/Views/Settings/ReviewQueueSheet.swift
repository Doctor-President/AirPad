import SwiftUI

struct ReviewQueueSheet: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.reviewQueue.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Review Queue")
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
        }
        .presentationDetents([.large])
        .presentationBackground(.black)
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(store.reviewQueue) { block in
                    ReviewBlockRow(block: block)
                }
            } header: {
                Text("\(store.reviewQueue.count) idea\(store.reviewQueue.count == 1 ? "" : "s") waiting")
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
            Text("Queue is clear")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct ReviewBlockRow: View {

    let block: RejectedBlock
    @Environment(CorpusStore.self) private var store
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                reasonBadge
                Text(block.text)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.promoteRejectedBlock(block) }
                } label: {
                    Text("Add as node")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button(role: .destructive) {
                    store.removeFromReviewQueue(id: block.id)
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

                Text(block.rejectedAt, style: .relative)
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
        Text(block.reason == .heuristic ? "fragment" : "incomplete")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(block.reason == .heuristic ? Color.orange : Color.yellow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((block.reason == .heuristic ? Color.orange : Color.yellow).opacity(0.15))
            .clipShape(Capsule())
    }
}
