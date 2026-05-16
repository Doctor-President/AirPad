import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.document` entries. Renders inside
/// an `EntryCard`, so no outer padding/background — the card supplies it.
/// Filename derived from the last path component of `item.file`; falls back
/// to "Document" if absent.
struct DocumentEntryBody: View {

    let item: NodeItem
    let nodeID: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file?.components(separatedBy: "/").last ?? "Document")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                if let description = item.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }
}
