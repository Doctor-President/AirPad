import SwiftUI

// MARK: - CardLinkTile
// Compact read-only mirror of LinkGalleryTile, sized for the card body
// strip (~200pt × 64pt). Renders cached OG image / favicon / title /
// siteName only — no menu, no tap-to-open, no OGMetadataService fetch.
// The whole card owns the tap; the detail view's gallery owns the
// fetch/snapshot/write paths.

struct CardLinkTile: View {
    let linkItem: LinkItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var thumbImage: UIImage? = nil

    // Appearance-aware ink: dark = shipped warm-cream (byte-identical), light =
    // AppearancePalette.ink so chip text reads on parchment (was cream in both →
    // illegible in light). Mirrors the NodeCardView row-title fix.
    private static let inkTitle = AppearancePalette.cardCreamInk(0.95)
    private static let inkMeta  = AppearancePalette.cardCreamInk(0.55)

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
                if let site = linkItem.siteName, !site.isEmpty {
                    Text(site)
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
        .task(id: "\(linkItem.imageFile ?? "")|\(linkItem.faviconFile ?? "")") {
            await loadCachedImage()
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08))
            if let img = thumbImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "link")
                    .font(.system(size: 16))
                    .foregroundColor(Self.inkMeta)
            }
        }
    }

    private var displayTitle: String {
        if let t = linkItem.title, !t.isEmpty { return t }
        return linkItem.url
    }

    // Prefer the OG image; fall back to favicon. Cached only — never
    // triggers OGMetadataService. If neither resolves, the SF Symbol
    // fallback in `thumb` keeps the slot occupied.
    private func loadCachedImage() async {
        thumbImage = nil
        var url: URL? = nil
        if linkItem.imageFile != nil {
            url = await store.resolveLinkItemImageURL(linkItem, nodeID: nodeID)
        }
        if url == nil, linkItem.faviconFile != nil {
            url = await store.resolveLinkItemFaviconURL(linkItem, nodeID: nodeID)
        }
        guard let url else { return }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let decoded { thumbImage = decoded }
    }
}
