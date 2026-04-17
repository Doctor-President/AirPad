import SwiftUI

/// Create a new tag or edit an existing one. Pass `existing: nil` to create.
struct TagEditorSheet: View {

    let existing: Tag?
    var onCreated: ((String) -> Void)? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorHex: String
    @State private var showDeleteConfirmation = false

    private let colorPresets: [String] = [
        "#FF6B35", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#00C7BE", "#32ADE6", "#007AFF",
        "#5856D6", "#AF52DE", "#FF2D55", "#A2845E",
        "#636366", "#8E8E93", "#FFFFFF", "#000000"
    ]

    init(existing: Tag?, onCreated: ((String) -> Void)? = nil) {
        self.existing = existing
        self.onCreated = onCreated
        _name     = State(initialValue: existing?.name ?? "")
        _colorHex = State(initialValue: existing?.colorHex ?? "#8E8E93")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nameSection
                    colorSection
                    if existing != nil { deleteSection }
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(existing == nil ? "New Tag" : "Edit Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(name.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.25) : .white)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
        .confirmationDialog(
            "Delete \"\(existing?.name ?? "")\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Tag", role: .destructive) {
                if let tag = existing {
                    Task { await store.deleteTag(id: tag.id) }
                }
                dismiss()
            }
        } message: {
            Text("Nodes with this tag will keep the name but lose its color.")
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Name")
            TextField("Tag name", text: $name)
                .font(.body)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(12)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .autocorrectionDisabled()
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Color")
                Spacer()
                // Preview pill
                Text(name.isEmpty ? "Tag" : name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background((Color(hex: colorHex) ?? .gray).opacity(0.35))
                    .overlay(Capsule().stroke(Color(hex: colorHex) ?? .gray, lineWidth: 1))
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 0.12), value: colorHex)
            }

            let columns = Array(repeating: GridItem(.flexible()), count: 8)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(colorPresets, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .gray)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle().stroke(
                                colorHex == hex ? Color.white : Color.clear,
                                lineWidth: 2.5
                            )
                        )
                        .onTapGesture { colorHex = hex }
                }
            }
        }
    }

    private var deleteSection: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete tag")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.red.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.red.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.35))
            .textCase(.uppercase)
            .tracking(0.6)
    }

    // MARK: - Save

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            if let existing {
                var updated = existing
                updated.name     = trimmed
                updated.colorHex = colorHex
                await store.updateTag(updated)
            } else {
                let tag = Tag(
                    id: UUID(),
                    name: trimmed,
                    colorHex: colorHex,
                    createdAt: Date(),
                    useCount: 0
                )
                await store.addTag(tag)
                onCreated?(trimmed)
            }
            dismiss()
        }
    }
}
