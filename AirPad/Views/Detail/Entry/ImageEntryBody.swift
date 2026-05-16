import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.image` entries. Renders inside
/// an `EntryCard`. Lazy `imageURL` resolution + rounded placeholder while
/// the file URL loads; description text below if present.
struct ImageEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var imageURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = imageURL {
                AsyncImageFromURL(url: url)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
                    .onAppear { loadImageURL() }
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
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
