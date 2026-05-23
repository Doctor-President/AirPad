import SwiftUI

/// Dashboard Stage 4 c4.5 — modal sheet for creating a new user collection.
/// Presented from the QuikCapture pill rail's "New +" affordance; the
/// created collection is handed back via `onCreate` so the rail can pin it
/// as the active selection immediately.
struct CollectionCreationSheet: View {

    /// Called on the main actor with the freshly-created collection after
    /// `store.createCollection` finishes. The caller decides what to do
    /// next — c4.5's only consumer (QuikCaptureView) marks it used so it
    /// jumps to the front of the rail and becomes the active selection.
    let onCreate: (NodeCollection) -> Void

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name: String = ""
    @State private var isCreating: Bool = false

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField("", text: $name, prompt: Text("Collection name").foregroundStyle(.white.opacity(0.35)))
                    .focused($isFocused)
                    .font(.body)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .disabled(isCreating)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { commit() }
                        .fontWeight(.semibold)
                        .foregroundStyle(trimmed.isEmpty ? .white.opacity(0.3) : .white)
                        .disabled(trimmed.isEmpty || isCreating)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
        .onAppear { isFocused = true }
    }

    private func commit() {
        let cleanName = trimmed
        guard !cleanName.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            let collection = await store.createCollection(name: cleanName)
            onCreate(collection)
            dismiss()
        }
    }
}
