import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.audio` entries. Renders inside
/// an `EntryCard`. The waveform player keeps its own internal chrome since
/// it's a self-contained widget; everything else (title, meta, card
/// background) comes from the card.
///
/// Arc B (T, 2026-10-12) — the transcript is the Voice item's ONE copy of the words, editable in place: it
/// reads at note size in the entry's font, and a tap puts the caret in it (same as a note). The edit commits
/// when the field loses focus; the first edit keeps the recognised text for "Restore original" in the "…" menu.
struct VoiceEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @AppStorage(EntryBodyFont.defaultStorageKey) private var defaultBodyFontRaw = EntryBodyFont.fallback.rawValue
    @State private var draft = ""
    @FocusState private var editing: Bool

    /// The note face for this entry: its own override, else the app-wide default (as `TextEntryBody` resolves it).
    private var bodyFont: EntryBodyFont {
        store.nodes.first(where: { $0.id == nodeID })?.perEntryBodyFont
            ?? EntryBodyFont(rawValue: defaultBodyFontRaw) ?? .fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VoiceWaveformPlayer(item: item, nodeID: nodeID)
            TextField("Add a transcript", text: $draft, axis: .vertical)
                .font(bodyFont.font(size: 17, relativeTo: .body))
                .foregroundStyle(AppearancePalette.ink)
                .tint(AppearancePalette.ink)
                .focused($editing)
                .padding(.horizontal, 12)
                .accessibilityIdentifier("voiceTranscript")
                .onAppear { draft = item.transcript ?? "" }
                // An outside change (Restore original, a re-transcription) lands while not editing.
                .onChange(of: item.transcript) { _, new in if !editing { draft = new ?? "" } }
                .onChange(of: editing) { _, nowEditing in
                    guard !nowEditing, draft != (item.transcript ?? "") else { return }
                    let text = draft
                    Task { await store.updateTranscript(itemID: item.id, nodeID: nodeID, newText: text) }
                }
        }
    }
}
