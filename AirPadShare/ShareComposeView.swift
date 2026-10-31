import SwiftUI
import LocalAuthentication

/// 1.1-C (C1) — the share sheet's state. The extension stages the shared items first (`stageForCompose`), then the
/// person picks a title, an optional note and where it goes.
@MainActor @Observable
final class ShareComposeModel {
    enum Destination: Hashable { case new, existing }

    let recordID = UUID().uuidString
    var loading = true
    var items: [NodeItem] = []
    var prefilledTitle = ""
    var title = ""
    var note = ""
    var destination: Destination = .new
    var target: ShareIndex.Entry?
    var query = ""
    var saved = false

    /// Face ID / passcode passed in this sheet (the Require Face ID gate, or "Show private").
    private(set) var unlocked = false
    private(set) var authenticating = false
    var authMessage: String?
    let requireFaceID = ShareShared.requireFaceID
    let index = ShareIndex.load()
    /// The phone can authenticate (a passcode is set). With the lock on and no way to unlock, only New entry is offered.
    let canAuthenticate: Bool = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)

    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    /// "Existing entry" is offered: there are entries to pick, and (with the lock on) a way to unlock.
    var existingOffered: Bool { !(index?.entries.isEmpty ?? true) && (!requireFaceID || canAuthenticate) }
    var hasPrivate: Bool { index?.entries.contains(where: \.isPrivate) ?? false }
    var showsList: Bool { destination == .existing && (!requireFaceID || unlocked) }
    var list: [ShareIndex.Entry] { Array((index?.visible(query: query, showPrivate: unlocked) ?? []).prefix(query.isEmpty ? 30 : 200)) }
    var canSave: Bool { !loading && (destination == .new || target != nil) }

    func choose(_ d: Destination) {
        destination = d
        authMessage = nil
        if d == .existing && requireFaceID && !unlocked { Task { await authenticate(reason: "Add to an existing entry") } }
        if d == .new { target = nil }
    }

    func authenticate(reason: String) async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            if requireFaceID { destination = .new; authMessage = "Face ID isn't available. Saving as a new entry." }
            return
        }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { unlocked = true } else if requireFaceID && destination == .existing {
            destination = .new
            authMessage = "Not unlocked. Saving as a new entry."
        }
    }
}

struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $model.title, axis: .vertical)
                        .focused($titleFocused)
                        .accessibilityIdentifier("share.title")
                    TextField("Note (optional)", text: $model.note, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("share.note")
                } footer: {
                    if model.loading { HStack(spacing: 6) { ProgressView(); Text("Reading what you shared…") } }
                    else { Text(summary) }
                }

                Section("Save to") {
                    if model.existingOffered {
                        Picker("Save to", selection: Binding(get: { model.destination }, set: { model.choose($0) })) {
                            Text("New entry").tag(ShareComposeModel.Destination.new)
                            Text("Existing entry").tag(ShareComposeModel.Destination.existing)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("share.destination")
                    } else {
                        Text("New entry")
                    }
                    if let m = model.authMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    if model.destination == .existing && model.requireFaceID && !model.unlocked && model.authenticating {
                        HStack(spacing: 6) { ProgressView(); Text("Unlocking…").foregroundStyle(.secondary) }
                    }
                }

                if model.showsList {
                    Section {
                        TextField("Search entries", text: $model.query)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("share.search")
                        ForEach(model.list) { e in
                            Button { model.target = e } label: {
                                HStack {
                                    Text(e.title).lineLimit(2).foregroundStyle(.primary)
                                    Spacer()
                                    if model.target?.id == e.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityIdentifier("share.entry")
                        }
                        if model.list.isEmpty { Text("No entries match.").foregroundStyle(.secondary) }
                        if model.hasPrivate && !model.unlocked {
                            Button("Show private") { Task { await model.authenticate(reason: "Show private entries") } }
                                .accessibilityIdentifier("share.showPrivate")
                        }
                    } header: { Text(model.query.isEmpty ? "Recent" : "Entries") }
                }
            }
            .navigationTitle(model.saved ? "Saved" : "AirPad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.onCancel() }.accessibilityIdentifier("share.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.onSave() }
                        .fontWeight(.semibold)
                        .disabled(!model.canSave || model.saved)
                        .accessibilityIdentifier("share.save")
                }
            }
        }
    }

    private var summary: String {
        let n = model.items.count
        guard n > 0 else { return "Nothing to save from this share." }
        let kinds = Set(model.items.map(\.type))
        if n == 1, let k = kinds.first {
            switch k {
            case .link: return "A link. AirPad reads the page when it next opens."
            case .imageVideo, .image: return "A photo."
            case .video: return "A video."
            case .audio: return "A recording."
            case .document: return "A file."
            default: return "Text."
            }
        }
        return "\(n) items, saved together."
    }
}
