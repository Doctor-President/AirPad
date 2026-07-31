import SwiftUI

/// Stage 5.3 — the ONE editor sheet for field values that need input (everything
/// except `boolean` + `rating`, which are direct-manipulation in the cell). One
/// presentation, one dismissal, one save path — every sheet-kind routes through
/// here. ★ Binds the RAW payload, never a display string (landmine 3):
/// `FieldValueFormatter` is display-only. Clear-to-unfilled (a genuinely null
/// value) and remove-field-from-this-note are both reachable here.
///
/// C1 kinds: number · text · url · date · location. C2 adds duration · money ·
/// measurement + ranges; C3 adds vocabulary · nodeReference.
struct FieldValueEditorSheet: View {

    let nodeID: String
    let item: NodeItem
    let definition: FieldDefinition

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Drafts, seeded from the current RAW value. Grown in C2/C3.
    @State private var text: String        // text · url · location name · number
    @State private var dateValue: Date

    init(nodeID: String, item: NodeItem, definition: FieldDefinition) {
        self.nodeID = nodeID
        self.item = item
        self.definition = definition
        let payload = item.field?.value
        _text = State(initialValue: Self.seedText(payload))
        _dateValue = State(initialValue: Self.seedDate(payload))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { editor }
                Section {
                    if item.field?.value != nil {
                        Button("Clear value", role: .destructive) { commitClear() }
                    }
                    Button("Remove field from this note", role: .destructive) { commitRemove() }
                }
            }
            .navigationTitle(definition.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { commitSave() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var editor: some View {
        switch definition.kind {
        case .number:
            TextField("Value", text: $text)
                .keyboardType(.decimalPad)
        case .text:
            TextField("Value", text: $text, axis: .vertical)
                .lineLimit(1...6)
        case .url:
            TextField("https://…", text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .date:
            DatePicker(
                "Date",
                selection: $dateValue,
                displayedComponents: definition.config.dateHasTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.graphical)
        case .location:
            TextField("Place", text: $text)
        default:
            // C2/C3 kinds — their editor lands in a later commit; unreachable in
            // C1 because the cell only routes these five kinds to the sheet.
            Text("Editing for \(definition.kind.pickerName) lands in a later commit.")
                .foregroundStyle(.secondary)
        }
    }

    /// Build the RAW payload from the drafts. Empty input → nil (unfilled).
    private func buildPayload() -> FieldPayload? {
        switch definition.kind {
        case .number:
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let d = Decimal(string: t) else { return nil }
            return .number(d)
        case .text:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .text(t)
        case .url:
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : .url(t)   // ★ verbatim — prettyURL is display only
        case .date:
            return .date(dateValue, hasTime: definition.config.dateHasTime)
        case .location:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            // Preserve any existing coordinate; C1 edits the NAME only.
            if case .location(_, let lat, let lon)? = item.field?.value {
                return .location(name: t, latitude: lat, longitude: lon)
            }
            return .location(name: t, latitude: nil, longitude: nil)
        default:
            return item.field?.value   // unimplemented kinds: leave unchanged
        }
    }

    private func commitSave() {
        let payload = buildPayload()
        Task {
            await store.setFieldValue(itemID: item.id, nodeID: nodeID, value: payload, upperValue: item.field?.upperValue)
            dismiss()
        }
    }

    private func commitClear() {
        Task { await store.clearFieldValue(itemID: item.id, nodeID: nodeID); dismiss() }
    }

    private func commitRemove() {
        Task { await store.removeField(itemID: item.id, nodeID: nodeID); dismiss() }
    }

    // MARK: - Seeds (raw → draft)

    private static func seedText(_ payload: FieldPayload?) -> String {
        switch payload {
        case .number(let d)?:          return "\(d)"
        case .text(let s)?:            return s
        case .url(let s)?:             return s
        case .location(let name, _, _)?: return name
        default:                       return ""
        }
    }

    private static func seedDate(_ payload: FieldPayload?) -> Date {
        if case .date(let d, _)? = payload { return d }
        return Date()
    }
}
