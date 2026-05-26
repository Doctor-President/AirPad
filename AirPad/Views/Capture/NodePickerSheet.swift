import SwiftUI

struct NodePickerSheet: View {
    let onSelect: (Node) -> Void
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    /// Empty query → first 20 by recency (existing behavior). Non-empty →
    /// substring match across title/summary/tags, preserving store order
    /// (which is recency-sorted). Match cap of 100 keeps the list bounded.
    private var displayedNodes: [Node] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(store.nodes.prefix(20))
        }
        let q = trimmed.lowercased()
        return store.nodes.filter { node in
            node.title.lowercased().contains(q)
                || node.summary.lowercased().contains(q)
                || node.tags.contains(where: { $0.lowercased().contains(q) })
        }
        .prefix(100)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if displayedNodes.isEmpty {
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedNodes) { node in
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
                                    Text(node.createdAt, style: .relative)
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
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Add to Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search nodes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
