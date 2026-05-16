import SwiftUI

/// Sheet-mode text capture surface. Still used by QuikCapture, the canvas
/// "+" fan, the list-view "+" fan, and the empty-canvas placeholder — any
/// path that creates a node from scratch rather than appending to one
/// already open. The in-node "+" → Text path bypasses this sheet entirely
/// and appends inline via `CorpusStore.appendEmptyTextItem`.
///
/// Stage 3.1a fix-up: the editor here is `RichTextEditor`, not the plain
/// SwiftUI `TextEditor` — so the formatting toolbar is available in
/// capture mode too. Writing surfaces everywhere in the app give the user
/// formatting access; capture and workspace shouldn't diverge.
struct TextCaptureSheet: View {

    /// If set, the captured text is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

    /// Optional pre-populated text (e.g. from clipboard).
    var initialText: String = ""

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                RichTextEditor(
                    text: $text,
                    placeholder: "Capture an idea…",
                    autoFocusOnAppear: true
                )
                .padding(.horizontal)
                .padding(.vertical, 12)
                .dismissKeyboardOnTapOutside()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.black)
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
        .onAppear {
            if text.isEmpty { text = initialText }
        }
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
            domainConfirmed: false,
            needsAIProcessing: false
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
