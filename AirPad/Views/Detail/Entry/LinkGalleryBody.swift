import SwiftUI

/// Stage 4.5 commit 3 — body slot for `.link` entries with
/// `linkItems.count >= 2`. Hosts the chrome strip (the "+" add-link
/// button on the left, `LinkViewModeToggle` on the right) and a tiles
/// area that branches on the resolved view mode. Parallel to
/// `GalleryBody` for the media gallery.
///
/// View-mode contract: `effectiveViewMode` falls back to a count-based
/// default when `linkViewMode` is nil — `appendLinkItem` already writes
/// the default on the first single → multi transition, but a future
/// path that produces a multi-link entry with nil `linkViewMode` would
/// still render predictably here.
///
/// Commit 4 replaces the placeholder grid arm with a proper 2-column
/// uniform-tile grid and adds per-tile "…" menus (Open / Copy / Delete).
/// Until then, grid mode renders a single-column vertical stack of the
/// same tiles so the toggle is visibly functional — the user can see
/// the persisted state flip even though the layout doesn't change shape
/// until the proper grid lands.
struct LinkGalleryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingAppendSheet = false

    private var linkItems: [LinkItem] { item.linkItems ?? [] }

    private var effectiveViewMode: LinkViewMode {
        if let mode = item.linkViewMode { return mode }
        return linkItems.count <= 3 ? .carousel : .grid
    }

    var body: some View {
        // Contract: only reached from EntryCard when linkItems.count >= 2.
        // Belt-and-suspenders: render nothing for degenerate counts so a
        // future bypass of the dispatch can't feed the renderer into a
        // bad state.
        if linkItems.count >= 2 {
            galleryContent
        }
    }

    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            tilesArea

            MediaEntryChrome(
                onAdd: { showingAppendSheet = true },
                accessibilityLabel: "Add link"
            ) {
                LinkViewModeToggle(active: effectiveViewMode) { newMode in
                    Task {
                        await store.setEntryLinkViewMode(
                            itemID: item.id,
                            nodeID: nodeID,
                            viewMode: newMode
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingAppendSheet) {
            LinkAppendSheet { url in
                Task {
                    await store.appendLinkItem(
                        toEntryID: item.id,
                        nodeID: nodeID,
                        url: url
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var tilesArea: some View {
        switch effectiveViewMode {
        case .carousel:
            LinkGalleryCarousel(
                linkItems: linkItems,
                entryID: item.id,
                nodeID: nodeID
            )
        case .grid:
            LinkGalleryGridPlaceholder(
                linkItems: linkItems,
                entryID: item.id,
                nodeID: nodeID
            )
        }
    }
}

/// Stage 4.5 commit 3 — horizontal carousel renderer for the link
/// gallery. Fixed-height tiles (180pt) with a fixed aspect width that
/// reads as a card; snap-to-tile via `.scrollTargetBehavior(.viewAligned)`
/// so the strip rests on a tile leading edge after a flick. `LazyHStack`
/// keeps render cost flat for long lists.
///
/// Width is fixed (not aspect-driven) because OG cards have no inherent
/// aspect ratio — the image is a top crop, not the whole tile. A uniform
/// width gives a calm horizontal rhythm; the bento-style aspect packer
/// the media carousel uses would produce uneven, twitchy widths here.
private struct LinkGalleryCarousel: View {
    let linkItems: [LinkItem]
    let entryID: String
    let nodeID: String

    private static let tileHeight: CGFloat = 180
    private static let tileWidth: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(linkItems) { linkItem in
                    LinkGalleryTile(
                        linkItem: linkItem,
                        entryID: entryID,
                        nodeID: nodeID
                    )
                    .frame(width: Self.tileWidth, height: Self.tileHeight)
                }
            }
            .padding(.horizontal, 2)
            .scrollTargetLayout()
        }
        .frame(height: Self.tileHeight)
        .scrollTargetBehavior(.viewAligned)
    }
}

/// Stage 4.5 commit 3 — grid placeholder. A single-column vertical stack
/// of fixed-height tiles. Commit 4 replaces this with the proper
/// 2-column uniform-tile grid and adds per-tile "…" menus. Kept as a
/// distinct view so the swap in commit 4 is a single import change in
/// `LinkGalleryBody.tilesArea`.
private struct LinkGalleryGridPlaceholder: View {
    let linkItems: [LinkItem]
    let entryID: String
    let nodeID: String

    private static let tileHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 8) {
            ForEach(linkItems) { linkItem in
                LinkGalleryTile(
                    linkItem: linkItem,
                    entryID: entryID,
                    nodeID: nodeID
                )
                .frame(maxWidth: .infinity)
                .frame(height: Self.tileHeight)
            }
        }
    }
}
