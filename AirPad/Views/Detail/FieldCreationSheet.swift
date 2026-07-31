import SwiftUI

/// Stage 5.2 — the field creation sheet, opened from the Detail-view "+" flyout's
/// "More…". Three COLLAPSIBLE sections expanding IN PLACE (no pushed screen):
///   1. User-Created — the user's own definitions, ordered most-recently-used,
///      HIDDEN ENTIRELY when empty (first run shows two rows, not one dead one).
///   2. Presets      — the shipped (displayName, kind) pairs, curated order.
///   3. New Field     — build your own; preview lists the twelve kinds.
/// Each header carries a dense preview line so the user can aim before tapping.
/// The sheet REMEMBERS the last section opened and reopens it.
///
/// Tapping an existing field or a preset ATTACHES THE EXISTING DEFINITION
/// (reuse by id, never a duplicate). Reads `fieldDefinitions` off the
/// `@Observable` store (per-property tracking — deliberately NOT an
/// `@ObservedObject`, which would invalidate the whole detail view on publish).
struct FieldCreationSheet: View {

    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Section: String { case userCreated, presets, newField }

    /// Remembered across sheet opens. Empty = nothing remembered (first run).
    @AppStorage("fieldSheet.lastSection") private var lastSectionRaw: String = ""
    @State private var expanded: Section?

    /// User definitions, most-recently-used first (nil lastUsed sorts last).
    private var userDefinitions: [FieldDefinition] {
        store.fieldDefinitions.sorted {
            ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if !userDefinitions.isEmpty {
                        sectionView(
                            .userCreated,
                            title: "User-Created",
                            preview: userDefinitions.map(\.displayName)
                        ) {
                            ForEach(userDefinitions) { def in
                                fieldRow(title: def.displayName, kind: def.kind) {
                                    attach { await store.attachField(definitionID: def.id, toNodeID: nodeID) }
                                }
                            }
                        }
                    }

                    sectionView(
                        .presets,
                        title: "Presets",
                        preview: FieldPreset.seeded.map(\.displayName)
                    ) {
                        ForEach(FieldPreset.seeded) { preset in
                            fieldRow(title: preset.displayName, kind: preset.kind) {
                                attach {
                                    let def = await store.resolvePreset(preset)
                                    await store.attachField(definitionID: def.id, toNodeID: nodeID)
                                }
                            }
                        }
                    }

                    sectionView(
                        .newField,
                        title: "New Field",
                        preview: FieldKind.allCases.map(\.pickerName)
                    ) {
                        NewFieldForm { displayName, kind, config in
                            attach {
                                let def = await store.createFieldDefinition(displayName: displayName, kind: kind, config: config)
                                await store.attachField(definitionID: def.id, toNodeID: nodeID)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Reopen the remembered section — but never User-Created if it's
            // hidden (empty). First run has nothing remembered → all collapsed.
            if let remembered = Section(rawValue: lastSectionRaw),
               remembered != .userCreated || !userDefinitions.isEmpty {
                expanded = remembered
            }
        }
    }

    // MARK: - Section chrome

    @ViewBuilder
    private func sectionView<Content: View>(
        _ id: Section,
        title: String,
        preview: [String],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    if expanded == id {
                        expanded = nil
                    } else {
                        expanded = id
                        lastSectionRaw = id.rawValue   // remember only on OPEN
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AppearancePalette.ink)
                        Text(preview.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        .rotationEffect(.degrees(expanded == id ? 0 : -90))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if expanded == id {
                content()
                    .padding(.bottom, 12)
            }

            Divider()
        }
    }

    private func fieldRow(title: String, kind: FieldKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(AppearancePalette.ink)
                Spacer(minLength: 8)
                Text(kind.pickerName)
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    /// Run a store attach, then dismiss. The store is @MainActor so the whole
    /// closure runs on the main actor and `dismiss()` is safe after the await.
    private func attach(_ work: @escaping () async -> Void) {
        Task {
            await work()
            dismiss()
        }
    }
}

// MARK: - New Field form

/// Stage 5.2 — the build-your-own form inside the "New Field" section: a name,
/// a kind chosen from the twelve, and the kind-specific config. Sensible
/// defaults only (TASTE — T's eye decides on device). "Create & Add" mints the
/// definition and attaches it in one step.
private struct NewFieldForm: View {

    /// (displayName, kind, config) — the caller creates + attaches.
    var onCreate: (String, FieldKind, FieldConfig) -> Void

    @State private var name = ""
    @State private var kind: FieldKind = .number
    @State private var dimension: MeasurementDimension = .volume
    @State private var ratingScale = 5
    @State private var ratingStyle: RatingStyle = .stars
    @State private var rangeEnabled = false
    @State private var dateHasTime = false
    @State private var vocabValues: [VocabularyValue] = []
    @State private var newVocabLabel = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Field name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Kind")
                    .font(.subheadline)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                Spacer()
                Picker("Kind", selection: $kind) {
                    ForEach(FieldKind.allCases, id: \.self) { k in
                        Text(k.pickerName).tag(k)
                    }
                }
                .pickerStyle(.menu)
            }

            if let note = kind.pickerNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }

            configControls

            Button {
                onCreate(trimmedName, kind, buildConfig())
            } label: {
                Text("Create & Add").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding(.top, 4)
        .onChange(of: ratingScale) { _, newValue in
            if newValue > 5 { ratingStyle = .numeric }   // stars stop working past 5
        }
    }

    @ViewBuilder
    private var configControls: some View {
        switch kind {
        case .measurement:
            labeledPicker("Measures", selection: $dimension, options: MeasurementDimension.allCases) { $0.rawValue.capitalized }
            Toggle("Allow a range (e.g. 2–3)", isOn: $rangeEnabled)
        case .number, .duration, .money:
            Toggle("Allow a range (e.g. 4–6)", isOn: $rangeEnabled)
        case .rating:
            labeledPicker("Scale", selection: $ratingScale, options: [5, 10, 100]) { "\($0)" }
            labeledPicker("Style", selection: $ratingStyle, options: [RatingStyle.stars, .numeric]) { $0 == .stars ? "Stars" : "Numeric" }
                .disabled(ratingScale > 5)
        case .vocabulary:
            vocabularyEditor
        case .date:
            Toggle("Include time", isOn: $dateHasTime)
        case .location, .text, .boolean, .url, .nodeReference:
            EmptyView()
        }
    }

    private func labeledPicker<T: Hashable>(
        _ label: String,
        selection: Binding<T>,
        options: [T],
        _ title: @escaping (T) -> String
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppearancePalette.ink.opacity(0.6))
            Spacer()
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { opt in Text(title(opt)).tag(opt) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var vocabularyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a value", text: $newVocabLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addVocabValue)
                Button("Add", action: addVocabValue)
                    .disabled(newVocabLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !vocabValues.isEmpty {
                Text(vocabValues.map(\.label).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addVocabValue() {
        let label = newVocabLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        vocabValues.append(VocabularyValue(label: label))
        newVocabLabel = ""
    }

    private func buildConfig() -> FieldConfig {
        switch kind {
        case .measurement:
            return FieldConfig(dimension: dimension, rangeEnabled: rangeEnabled)
        case .number, .duration, .money:
            return FieldConfig(rangeEnabled: rangeEnabled)
        case .rating:
            return FieldConfig(ratingScale: ratingScale, ratingStyle: ratingScale > 5 ? .numeric : ratingStyle)
        case .vocabulary:
            return FieldConfig(vocabularyValues: vocabValues)
        case .date:
            return FieldConfig(dateHasTime: dateHasTime)
        case .location, .text, .boolean, .url, .nodeReference:
            return FieldConfig()
        }
    }
}
