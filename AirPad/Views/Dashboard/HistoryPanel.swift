import SwiftUI

/// Dedicated history view — nodes sorted by `updatedAt` descending so
/// recently-edited notes surface first. Distinct from `NodePickerSheet`
/// (which exists for "add content to node" flows): no add-affordance
/// copy, no search, no creation-order timestamps.
struct HistoryPanel: View {
    let onSelect: (Node) -> Void
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var nodesByRecency: [Node] {
        store.nodes.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(nodesByRecency) { node in
                    Button {
                        onSelect(node)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(nodeColor(node))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(node.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                                + Text(" ago")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("History")
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
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
    }

    private func nodeColor(_ node: Node) -> Color {
        guard let tag = node.tags.first,
              let storeTag = store.tags.first(where: { $0.name == tag })
        else { return .gray }
        return Color(hex: storeTag.colorHex) ?? .gray
    }
}
