import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.audio` entries. Renders inside
/// an `EntryCard`. The waveform player keeps its own internal chrome since
/// it's a self-contained widget; everything else (title, meta, card
/// background) comes from the card.
///
/// Arc B (T, 2026-10-12) — the transcript is the Voice item's ONE copy of the words, editable in place: it
/// reads at note size in the entry's font, and a tap puts the caret in it (same as a note). The edit commits
/// when the field loses focus; the first edit keeps the recognised text for "Restore original" in the "…" menu.
/// While typing, the words sit in `store.transcriptDrafts`, so a "…" action taken with the keyboard still up
/// (Extract, Append to…, Restore) acts on the edited words; it commits them and the field ends editing.
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

    private var unavailable: Bool { item.transcriptUnavailable == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VoiceWaveformPlayer(item: item, nodeID: nodeID)
            // live-10 (4) — speech is on-device only; when that couldn't transcribe the audio, the transcript area says
            // so in full (a placeholder truncates to one line). It sits behind the field, so a tap still types there.
            ZStack(alignment: .topLeading) {
                if unavailable && draft.isEmpty {
                    Text(OnDeviceSpeech.unavailableMessage)
                        .font(bodyFont.font(size: 17, relativeTo: .body))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("voiceTranscriptUnavailable")
                }
                TextField(unavailable ? "" : "Add a transcript", text: $draft, axis: .vertical)
                    .font(bodyFont.font(size: 17, relativeTo: .body))
                    .foregroundStyle(AppearancePalette.ink)
                    .tint(AppearancePalette.ink)
                    .focused($editing)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("voiceTranscript")
                    .onAppear { draft = item.transcript ?? "" }
                    // An outside change (Restore original, a re-transcription) shows unless the person is mid-edit.
                    .onChange(of: item.transcript) { _, new in
                        if !editing || store.transcriptDrafts[item.id] == nil { draft = new ?? "" }
                    }
                    .onChange(of: draft) { _, text in if editing { store.transcriptDrafts[item.id] = text } }
                    // A "…" action committed the draft: the edit is in; stop editing so focus loss can't write it again.
                    .onChange(of: store.transcriptDrafts[item.id] == nil) { _, taken in if taken && editing { editing = false } }
                    .onChange(of: editing) { _, nowEditing in
                        guard !nowEditing, let text = store.transcriptDrafts.removeValue(forKey: item.id) else { return }
                        Task { await store.updateTranscript(itemID: item.id, nodeID: nodeID, newText: text) }
                    }
            }
        }
    }
}
