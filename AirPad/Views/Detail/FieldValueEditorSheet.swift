import SwiftUI

/// Stage 5.3 — the ONE editor sheet for field values that need input (everything
/// except `boolean` + star-style `rating`, which are direct-manipulation in the
/// cell). One presentation, one dismissal, one save path — every sheet-kind
/// routes through here. ★ Binds the RAW payload, never a display string
/// (landmine 3): `FieldValueFormatter` is display-only. Clear-to-unfilled (a
/// genuinely null value) and remove-field-from-this-note are both reachable here.
///
/// C1 kinds: number · text · url · date · location.
/// C2 kinds: duration · money · measurement · numeric rating · + RANGES on the
/// four scalars. C3 adds vocabulary · nodeReference.
struct FieldValueEditorSheet: View {

    let nodeID: String
    let item: NodeItem
    let definition: FieldDefinition

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Drafts, seeded from the current RAW value / upperValue.
    @State private var text: String          // text · url · location name · number
    @State private var dateValue: Date
    @State private var amount: String        // money · measurement amount
    @State private var currencyCode: String
    @State private var unit: String
    @State private var hours: Int
    @State private var minutes: Int
    @State private var ratingValue: Int      // numeric rating
    // Range (upper value) — the four scalar kinds only.
    @State private var hasRange: Bool
    @State private var upperText: String
    @State private var upperAmount: String
    @State private var upperHours: Int
    @State private var upperMinutes: Int
    // C3
    @State private var selectedValueIDs: Set<String>
    @State private var newVocabLabel: String = ""
    @State private var draftRefID: String?
    @State private var showNodePicker = false

    init(nodeID: String, item: NodeItem, definition: FieldDefinition) {
        self.nodeID = nodeID
        self.item = item
        self.definition = definition
        let v = item.field?.value
        let u = item.field?.upperValue
        _text = State(initialValue: Self.seedText(v))
        _dateValue = State(initialValue: Self.seedDate(v))
        _amount = State(initialValue: Self.seedAmount(v))
        _currencyCode = State(initialValue: Self.seedCurrency(v))
        _unit = State(initialValue: Self.seedUnit(v, definition: definition))
        _hours = State(initialValue: Self.seedHours(v))
        _minutes = State(initialValue: Self.seedMinutes(v))
        _ratingValue = State(initialValue: Self.seedRating(v))
        _hasRange = State(initialValue: u != nil)
        _upperText = State(initialValue: Self.seedText(u))
        _upperAmount = State(initialValue: Self.seedAmount(u))
        _upperHours = State(initialValue: Self.seedHours(u))
        _upperMinutes = State(initialValue: Self.seedMinutes(u))
        _selectedValueIDs = State(initialValue: Self.seedVocabIDs(v))
        _draftRefID = State(initialValue: Self.seedRefID(v))
    }

    private var isScalar: Bool { [.number, .duration, .measurement, .money].contains(definition.kind) }
    private var rangeAvailable: Bool { isScalar && definition.config.rangeEnabled }

    var body: some View {
        NavigationStack {
            Form {
                Section { primaryEditor }
                if rangeAvailable {
                    Section("Range") {
                        Toggle("Add an upper value", isOn: $hasRange)
                        if hasRange { upperEditor }
                    }
                }
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
        .sheet(isPresented: $showNodePicker) {
            // Reuse BacklinkPickerSheet's node search+list via its field-reference
            // `onPick` mode (no backlink connection is created).
            BacklinkPickerSheet(sourceNodeID: nodeID, sourceEntryID: nil, onPick: { id in
                draftRefID = id
            })
        }
    }

    // MARK: - Editors

    @ViewBuilder
    private var primaryEditor: some View {
        switch definition.kind {
        case .number:
            decimalField($text)
        case .text:
            TextField("Value", text: $text, axis: .vertical).lineLimit(1...6)
        case .url:
            TextField("https://…", text: $text)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        case .date:
            DatePicker("Date", selection: $dateValue,
                       displayedComponents: definition.config.dateHasTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.graphical)
        case .location:
            TextField("Place", text: $text)
        case .duration:
            durationFields($hours, $minutes)
        case .money:
            decimalField($amount)
            Picker("Currency", selection: $currencyCode) {
                ForEach(FieldCurrency.options, id: \.self) { Text($0).tag($0) }
            }
        case .measurement:
            decimalField($amount)
            Picker("Unit", selection: $unit) {
                ForEach(definition.config.dimension?.units ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .rating:
            // Reached only for the NUMERIC style; star style is direct-manip in the cell.
            Stepper("\(ratingValue) / \(definition.config.ratingScale ?? 5)", value: $ratingValue,
                    in: 0...(definition.config.ratingScale ?? 5))
        case .vocabulary:
            // Multi-select from the definition's LIVE value list (so a value just
            // added shows immediately), plus add-a-new-value inline.
            ForEach(liveVocabValues) { val in
                Button {
                    if selectedValueIDs.contains(val.id) { selectedValueIDs.remove(val.id) }
                    else { selectedValueIDs.insert(val.id) }
                } label: {
                    HStack {
                        Text(val.label).foregroundStyle(AppearancePalette.ink)
                        Spacer()
                        if selectedValueIDs.contains(val.id) {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
            HStack {
                TextField("Add a value", text: $newVocabLabel).onSubmit(addVocab)
                Button("Add", action: addVocab)
                    .disabled(newVocabLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .nodeReference:
            HStack {
                Text("Node")
                Spacer()
                Text(referencedTitle ?? "None").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Choose a node") { showNodePicker = true }
        case .boolean:
            EmptyView()   // boolean is direct-manip in the cell — never routed here
        }
    }

    private var liveVocabValues: [VocabularyValue] {
        store.fieldDefinition(id: definition.id)?.config.vocabularyValues
            ?? definition.config.vocabularyValues ?? []
    }

    private var referencedTitle: String? {
        guard let id = draftRefID, let node = store.nodes.first(where: { $0.id == id }) else { return nil }
        let t = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    private func addVocab() {
        let label = newVocabLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        Task {
            if let v = await store.addVocabularyValue(definitionID: definition.id, label: label) {
                selectedValueIDs.insert(v.id)
            }
            newVocabLabel = ""
        }
    }

    @ViewBuilder
    private var upperEditor: some View {
        switch definition.kind {
        case .number:      decimalField($upperText)
        case .money:       decimalField($upperAmount)
        case .measurement: decimalField($upperAmount)
        case .duration:    durationFields($upperHours, $upperMinutes)
        default:           EmptyView()
        }
    }

    private func decimalField(_ binding: Binding<String>) -> some View {
        TextField("0", text: binding).keyboardType(.decimalPad)
    }

    private func durationFields(_ h: Binding<Int>, _ m: Binding<Int>) -> some View {
        HStack {
            TextField("hr", value: h, format: .number).keyboardType(.numberPad).frame(width: 60)
            Text("hr").foregroundStyle(.secondary)
            TextField("min", value: m, format: .number).keyboardType(.numberPad).frame(width: 60)
            Text("min").foregroundStyle(.secondary)
        }
    }

    // MARK: - Build payloads (RAW)

    private func buildPayload() -> FieldPayload? {
        switch definition.kind {
        case .number:
            return decimal(text).map { .number($0) }
        case .text:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .text(t)
        case .url:
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : .url(t)   // ★ verbatim
        case .date:
            return .date(dateValue, hasTime: definition.config.dateHasTime)
        case .location:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if case .location(_, let lat, let lon)? = item.field?.value {
                return .location(name: t, latitude: lat, longitude: lon)
            }
            return .location(name: t, latitude: nil, longitude: nil)
        case .duration:
            let secs = Double(max(0, hours) * 3600 + max(0, minutes) * 60)
            return secs == 0 ? nil : .duration(seconds: secs)
        case .money:
            return decimal(amount).map { .money(amount: $0, currencyCode: currencyCode) }
        case .measurement:
            guard let d = decimal(amount) else { return nil }
            return .measurement(amount: d, unit: unit)
        case .rating:
            return .rating(ratingValue)
        case .vocabulary:
            return selectedValueIDs.isEmpty ? nil : .vocabulary(valueIDs: Array(selectedValueIDs))
        case .nodeReference:
            return draftRefID.map { .nodeReference(nodeID: $0) }
        case .boolean:
            return item.field?.value   // boolean is direct-manip — unreachable here
        }
    }

    private func buildUpper() -> FieldPayload? {
        guard hasRange else { return nil }
        switch definition.kind {
        case .number:      return decimal(upperText).map { .number($0) }
        case .money:       return decimal(upperAmount).map { .money(amount: $0, currencyCode: currencyCode) }
        case .measurement: return decimal(upperAmount).map { .measurement(amount: $0, unit: unit) }
        case .duration:
            let secs = Double(max(0, upperHours) * 3600 + max(0, upperMinutes) * 60)
            return secs == 0 ? nil : .duration(seconds: secs)
        default:           return nil
        }
    }

    private func decimal(_ s: String) -> Decimal? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return Decimal(string: t)
    }

    // MARK: - Commit

    private func commitSave() {
        let payload = buildPayload()
        let upper = buildUpper()
        Task {
            await store.setFieldValue(itemID: item.id, nodeID: nodeID, value: payload, upperValue: upper)
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

    private static func seedText(_ p: FieldPayload?) -> String {
        switch p {
        case .number(let d)?:            return "\(d)"
        case .text(let s)?:              return s
        case .url(let s)?:               return s
        case .location(let name, _, _)?: return name
        default:                         return ""
        }
    }
    private static func seedDate(_ p: FieldPayload?) -> Date {
        if case .date(let d, _)? = p { return d }
        return Date()
    }
    private static func seedAmount(_ p: FieldPayload?) -> String {
        switch p {
        case .money(let a, _)?:       return "\(a)"
        case .measurement(let a, _)?: return "\(a)"
        default:                      return ""
        }
    }
    private static func seedCurrency(_ p: FieldPayload?) -> String {
        if case .money(_, let code)? = p { return code }
        return FieldCurrency.localeDefault
    }
    private static func seedUnit(_ p: FieldPayload?, definition: FieldDefinition) -> String {
        if case .measurement(_, let u)? = p { return u }
        return definition.config.dimension?.defaultUnit ?? ""
    }
    private static func seedHours(_ p: FieldPayload?) -> Int {
        if case .duration(let s)? = p { return Int(s) / 3600 }
        return 0
    }
    private static func seedMinutes(_ p: FieldPayload?) -> Int {
        if case .duration(let s)? = p { return (Int(s) % 3600) / 60 }
        return 0
    }
    private static func seedRating(_ p: FieldPayload?) -> Int {
        if case .rating(let v)? = p { return v }
        return 0
    }
    private static func seedVocabIDs(_ p: FieldPayload?) -> Set<String> {
        if case .vocabulary(let ids)? = p { return Set(ids) }
        return []
    }
    private static func seedRefID(_ p: FieldPayload?) -> String? {
        if case .nodeReference(let id)? = p { return id }
        return nil
    }
}
