import SwiftUI

// MARK: - CardDocumentTile
// Compact read-only mirror of DocumentGalleryTile, sized for the card
// body strip (~200pt × 64pt). Renders cached page-1 thumbnail / title /
// metrics only — no menu, no tap-to-QuickLook, no
// DocumentExtractionService fire-and-forget.

struct CardDocumentTile: View {
    let documentItem: DocumentItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var thumbnail: UIImage? = nil

    private static let inkTitle = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.95)
    private static let inkMeta  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.55)

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundColor(Self.inkTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let metrics = metricsLine {
                    Text(metrics)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 64, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        .task(id: documentItem.thumbnailFile) {
            await loadCachedThumbnail()
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08))
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundColor(Self.inkMeta)
            }
        }
    }

    private var displayTitle: String {
        documentItem.documentTitle ?? documentItem.fileName
    }

    private var metricsLine: String? {
        var parts: [String] = []
        if let pages = documentItem.pageCount, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        if let words = documentItem.wordCount, words > 0 {
            parts.append("\(words) words")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch documentItem.fileType.lowercased() {
        case "pdf":          return "doc.richtext.fill"
        case "html", "htm":  return "globe"
        default:             return "doc.fill"
        }
    }

    private func loadCachedThumbnail() async {
        thumbnail = nil
        guard documentItem.thumbnailFile != nil,
              let url = await store.documentThumbnailFileURL(for: documentItem, nodeID: nodeID) else { return }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let decoded { thumbnail = decoded }
    }
}
