import SwiftUI
import AVKit

/// Stage 3.1a commit (b) — body slot for `.video` entries. Renders inside
/// an `EntryCard`. Same lazy file-URL pattern as `ImageEntryBody`; once
/// resolved we hand it to `VideoPlayer(AVPlayer)`.
struct VideoEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var imageURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = imageURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(Image(systemName: "video").foregroundStyle(.white.opacity(0.3)))
                    .onAppear { loadImageURL() }
            }
            if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }
        }
    }

    private func loadImageURL() {
        Task {
            imageURL = await store.itemFileURL(for: item, nodeID: nodeID)
        }
    }
}
