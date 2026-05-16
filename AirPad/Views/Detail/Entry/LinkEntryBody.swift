import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.link` entries. Renders inside
/// an `EntryCard`, so no outer padding/background — the card supplies it.
/// Inline rendering only; richer link previews land with AT19.3c web
/// clipping immediately after Stage 3.1.
struct LinkEntryBody: View {

    let item: NodeItem
    let nodeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = item.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let preview = item.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            if let urlString = item.url, let url = URL(string: urlString) {
                Link(urlString, destination: url)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
            }
        }
    }
}
