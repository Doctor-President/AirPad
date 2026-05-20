import SwiftUI
import UIKit

/// Stage 4.5 commit 3 — single OG card for a `LinkItem`, parent-owned-
/// sizing (the parent applies `.frame(width:height:)` and clips). The
/// tile renders four shapes depending on which OG fields are populated:
///   - Image + text: OG image at top, then title/description/siteName.
///   - Text-only: title/description/siteName.
///   - Image-only: OG image fills the tile, no overlay text.
///   - Bare URL: shown when all four OG fields are nil (the tile has
///     either not yet fetched or the page had no OG tags).
///
/// Tap opens the URL via `@Environment(\.openURL)`. The 2026-05-19
/// chrome-tap fix (commit 9c0c180) is preserved: we use
/// `.contentShape(Rectangle()) + .onTapGesture` rather than SwiftUI
/// `Link`, which would broadcast its `.isLink` accessibility hit area
/// across the whole EntryCard and eat chevron/menu/long-press.
///
/// OG-on-demand: when the tile appears with all OG fields nil and a
/// resolvable URL, it fires `OGMetadataService.fetch` and routes the
/// result through `CorpusStore.applyOGFetchToLinkItem`. This mirrors
/// `LinkEntryBody.refetchIfStaleOrMissing`'s shape; unlike the legacy
/// path, LinkItem has no `ogFetchedAt`, so the staleness check
/// degenerates to "any OG field present" — a successful-but-empty-OG
/// page keeps refetching every render. Acceptable tradeoff per the
/// brief (no per-LinkItem fetched-at field; OG fetch is cheap and
/// idempotent at the service layer).
struct LinkGalleryTile: View {

    let linkItem: LinkItem
    let entryID: String
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var ogImage: UIImage? = nil

    private var hasAnyOG: Bool {
        linkItem.title?.isEmpty == false
            || linkItem.description?.isEmpty == false
            || linkItem.siteName?.isEmpty == false
            || linkItem.imageFile?.isEmpty == false
    }

    var body: some View {
        Group {
            if hasAnyOG {
                richBody
            } else {
                bareBody
            }
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { if let url = URL(string: linkItem.url) { openURL(url) } }
        .accessibilityAddTraits(.isLink)
        .onAppear { fetchIfMissing() }
    }

    // MARK: - Bare URL fallback

    private var bareBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "link")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.45))
            Text(linkItem.url)
                .font(.caption)
                .foregroundStyle(.blue)
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }

    // MARK: - Rich body

    private var richBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if linkItem.imageFile != nil {
                imageBlock
            }
            textBlock
                .padding(linkItem.imageFile != nil ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = linkItem.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let description = linkItem.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let siteName = linkItem.siteName, !siteName.isEmpty {
                Text(siteName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    private var imageBlock: some View {
        Group {
            if let img = ogImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 100)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    )
            }
        }
        .task(id: linkItem.imageFile) {
            ogImage = nil
            guard let url = await store.resolveLinkItemImageURL(linkItem, nodeID: nodeID) else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                ogImage = img
            }
        }
    }

    // MARK: - On-demand OG fetch

    private func fetchIfMissing() {
        guard !hasAnyOG, let url = URL(string: linkItem.url) else { return }
        let capturedNodeID = nodeID
        let capturedEntryID = entryID
        let capturedLinkID = linkItem.id
        Task {
            let metadata = await OGMetadataService().fetch(url: url)
            await store.applyOGFetchToLinkItem(
                nodeID: capturedNodeID,
                entryID: capturedEntryID,
                linkItemID: capturedLinkID,
                metadata: metadata
            )
        }
    }
}
