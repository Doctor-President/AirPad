import SwiftUI

struct TextCaptureSheet: View {

    /// If set, the captured text is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .foregroundStyle(.white)
                .font(.body)
                .padding(.horizontal)
                .navigationTitle("New Idea")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { commit() }
                            .fontWeight(.semibold)
                            .foregroundStyle(trimmed.isEmpty ? .white.opacity(0.3) : .white)
                            .disabled(trimmed.isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
        .onAppear { isFocused = true }
    }

    // MARK: - Helpers

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }

        let title = String(trimmed.prefix(40))
        let now = Date()
        let node = Node(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            title: title,
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [.text(content: trimmed)],
            domain: nil,
            domainConfirmed: false
        )

        // Slight random spread so nodes don't all stack at center
        let position = CGPoint(
            x: Double.random(in: -80...80),
            y: Double.random(in: -80...80)
        )

        Task {
            if let targetID = targetNodeID {
                await store.appendItemToNode(nodeID: targetID, item: .text(content: trimmed))
                await store.processNodeWithAI(nodeID: targetID)
            } else {
                await store.addNode(node, position: position)
                await store.processNodeWithAI(nodeID: node.id)
            }
        }
        dismiss()
    }
}
