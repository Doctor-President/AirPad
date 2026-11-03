import SwiftUI

struct ReviewQueueSheet: View {
    @Environment(\.appBodyFont) private var appFont   // 1.1-A type pass

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
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Review Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(AppearancePalette.bgBase)
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                ForEach(store.reviewQueue) { block in
                    ReviewBlockRow(block: block)
                }
            } header: {
                Text("\(store.reviewQueue.count) \(store.reviewQueue.count == 1 ? "entry" : "entries") waiting")
                    .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
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
                .foregroundStyle(AppearancePalette.ink.opacity(0.2))
            Text("Queue is clear")
                .font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct ReviewBlockRow: View {
    @Environment(\.appBodyFont) private var appFont   // 1.1-A type pass

    let block: RejectedBlock
    @Environment(CorpusStore.self) private var store
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                reasonBadge
                Text(block.text)
                    .font(appFont.font(size: 15, relativeTo: .subheadline))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.promoteRejectedBlock(block) }
                } label: {
                    Text("Add as entry")
                        .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                        .foregroundStyle(AppearancePalette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppearancePalette.ink.opacity(0.12))
                        .clipShape(Capsule())
                }

                Button(role: .destructive) {
                    store.removeFromReviewQueue(id: block.id)
                } label: {
                    Text("Discard")
                        .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                        .foregroundStyle(.red.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Capsule())
                }

                Spacer()

                Text("\(block.rejectedAt, style: .relative) ago")
                    .font(appFont.font(size: 11, relativeTo: .caption2))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.25))
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(AppearancePalette.ink.opacity(0.05))
    }

    private var reasonBadge: some View {
        Text(block.reason == .heuristic ? "fragment" : "incomplete")
            .font(appFont.font(size: 11, weight: .semibold, relativeTo: .caption2))
            .foregroundStyle(block.reason == .heuristic ? Color.orange : Color.yellow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((block.reason == .heuristic ? Color.orange : Color.yellow).opacity(0.15))
            .clipShape(Capsule())
    }
}
