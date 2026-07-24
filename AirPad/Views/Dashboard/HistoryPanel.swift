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
                        // Light-mode convergence — pass adaptive ink (RecentNodeRow
                        // defaults to `.white`, which was illegible on the light
                        // panel). Same as RecentsView / NodeListView callers.
                        RecentNodeRow(node: node, timestamp: node.updatedAt,
                                      ink: AppearancePalette.ink)
                            .equatable()
                    }
                    .listRowBackground(AppearancePalette.ink.opacity(0.05))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(AppearancePalette.bgBase)
    }
}
