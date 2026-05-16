import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.audio` entries. Renders inside
/// an `EntryCard`. The waveform player keeps its own internal chrome since
/// it's a self-contained widget; everything else (title, meta, card
/// background) comes from the card.
struct VoiceEntryBody: View {

    let item: NodeItem
    let nodeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VoiceWaveformPlayer(item: item, nodeID: nodeID)
            if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12)
            }
        }
    }
}
