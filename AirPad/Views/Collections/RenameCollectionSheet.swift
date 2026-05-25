import SwiftUI

/// Modal sheet for renaming a user collection. Same visual shape and
/// keyboard behavior as `CollectionCreationSheet` — single text field,
/// Cancel + Save toolbar buttons, autofocus on appear. Pre-fills with the
/// current name; Save is disabled when the trimmed input is empty or
/// unchanged from the original.
struct RenameCollectionSheet: View {

    let collectionID: String
    let currentName: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name: String
    @State private var isSaving: Bool = false

    init(collectionID: String, currentName: String) {
        self.collectionID = collectionID
        self.currentName = currentName
        self._name = State(initialValue: currentName)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != currentName
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
                    .disabled(isSaving)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Rename Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .fontWeight(.semibold)
                        .foregroundStyle(canSave ? .white : .white.opacity(0.3))
                        .disabled(!canSave || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard canSave, !isSaving else { return }
        let cleanName = trimmed
        isSaving = true
        Task {
            await store.renameCollection(id: collectionID, to: cleanName)
            dismiss()
        }
    }
}
