import SwiftUI

/// Mac batch B1f — the quiet two-device UI on an entry (minimal; the Companion may restyle):
/// - "Catching up…" while iCloud is still bringing this entry's newest version (edits are held meanwhile);
/// - "Also edited on your Mac · Restore" when a merge kept another version of something here.
/// Draws nothing otherwise, so an entry without either looks exactly as before.
struct EntrySyncNotes: View {
    @Environment(CorpusStore.self) private var store
    let nodeID: String

    var body: some View {
        let catching = store.catchingUp.contains(nodeID)
        let note = store.versionNotes[nodeID]
        if catching || note != nil {
            VStack(alignment: .leading, spacing: 8) {
                if catching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Catching up…")
                    }
                    .accessibilityIdentifier("entry.catchingUp")
                }
                if let note {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(note.note)
                        Text("·").foregroundStyle(AppearancePalette.ink.opacity(0.35))
                        Button("Restore") {
                            Task { await store.restoreVersion(nodeID: nodeID, versionID: note.id) }
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("entry.versionNote.restore")
                        Spacer(minLength: 0)
                        Button {
                            Task { await store.dismissVersionNote(nodeID: nodeID) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .accessibilityIdentifier("entry.versionNote")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(AppearancePalette.ink.opacity(0.62))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }
}

/// "Versions" (entry menu): what two-device merges kept, newest first, one tap to restore.
struct EntryVersionsSheet: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let nodeID: String
    @State private var versions: [EntryVersion] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && versions.isEmpty {
                    Text("No other versions. When this entry is edited on two devices at once, the version that didn't win is kept here.")
                        .font(.system(size: 14))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                }
                ForEach(versions) { v in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(v.label).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if v.state == "restored" {
                                Text("Restored").font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                            } else {
                                Button("Restore") {
                                    Task {
                                        await store.restoreVersion(nodeID: nodeID, versionID: v.id)
                                        await reload()
                                    }
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("versions.restore")
                            }
                        }
                        Text((v.from.isEmpty ? "Another device" : "Your \(v.from)") + " · " + v.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        if !v.preview.isEmpty {
                            Text(v.preview).font(.system(size: 14)).lineLimit(3)
                                .foregroundStyle(AppearancePalette.ink.opacity(0.8))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await reload() }
    }

    private func reload() async {
        versions = await store.versions(nodeID: nodeID)
        loaded = true
    }
}
