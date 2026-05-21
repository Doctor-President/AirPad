import SwiftUI

/// Stage 4.6 commit 3 — body slot for `.document` entries with
/// `documentItems.count >= 2`. Hosts a tiles area (carousel or grid)
/// and a chrome strip with a "+" button (which presents
/// `DocumentPickerView` and routes the result to
/// `CorpusStore.appendDocumentItems(toEntryID:...)`). Parallel to
/// `LinkGalleryBody` for the link gallery and `GalleryBody` for media.
///
/// Stage 4.6 commit 4 — chrome trailing slot now hosts
/// `DocumentViewModeToggle`, and `tilesArea` branches on
/// `effectiveViewMode` between `DocumentGalleryCarousel` and
/// `DocumentGalleryGrid`. View-mode contract mirrors `LinkGalleryBody`:
/// `effectiveViewMode` falls back to a count-based default (≤3 →
/// carousel, ≥4 → grid) when `documentViewMode` is nil.
/// `appendDocumentItems` already writes the default at the single →
/// multi transition, but the fallback keeps a hypothetical
/// nil-`documentViewMode` multi-doc entry rendering predictably.
struct DocumentGalleryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingAppendPicker = false

    private var documentItems: [DocumentItem] { item.documentItems ?? [] }

    private var effectiveViewMode: DocumentViewMode {
        if let mode = item.documentViewMode { return mode }
        return documentItems.count <= 3 ? .carousel : .grid
    }

    var body: some View {
        // Contract: only reached from EntryCard when documentItems.count >= 2.
        // Belt-and-suspenders: render nothing for degenerate counts so a
        // future dispatch bypass can't feed the renderer bad state.
        if documentItems.count >= 2 {
            galleryContent
        }
    }

    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            tilesArea

            MediaEntryChrome(
                onAdd: { showingAppendPicker = true },
                accessibilityLabel: "Add document"
            ) {
                DocumentViewModeToggle(active: effectiveViewMode) { newMode in
                    Task {
                        await store.setEntryDocumentViewMode(
                            itemID: item.id,
                            nodeID: nodeID,
                            viewMode: newMode
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingAppendPicker) {
            DocumentPickerView { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await store.appendDocumentItems(
                        toEntryID: item.id,
                        nodeID: nodeID,
                        sourceURLs: urls
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var tilesArea: some View {
        switch effectiveViewMode {
        case .carousel:
            DocumentGalleryCarousel(
                documentItems: documentItems,
                entryID: item.id,
                nodeID: nodeID
            )
        case .grid:
            DocumentGalleryGrid(
                documentItems: documentItems,
                entryID: item.id,
                nodeID: nodeID
            )
        }
    }
}

/// Stage 4.6 commit 3 — horizontal carousel renderer for the document
/// gallery. Same 180pt × 240pt tile sizing as `LinkGalleryCarousel` so
/// a mixed feed of link- and document-gallery entries reads with the
/// same horizontal rhythm. Snap-to-tile via
/// `.scrollTargetBehavior(.viewAligned)`; `LazyHStack` keeps render cost
/// flat for long lists.
private struct DocumentGalleryCarousel: View {
    let documentItems: [DocumentItem]
    let entryID: String
    let nodeID: String

    private static let tileHeight: CGFloat = 180
    private static let tileWidth: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(documentItems) { documentItem in
                    DocumentGalleryTile(
                        documentItem: documentItem,
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

/// Stage 4.6 commit 4 — 2-column uniform-tile grid. Tile height matches
/// the carousel's 180pt so toggling carousel ↔ grid doesn't reshape the
/// tiles themselves, only the layout around them. Direct parallel to
/// `LinkGalleryGrid`. Per-tile chrome (the "…" menu) lives on
/// `DocumentGalleryTile` itself and is shared across both modes.
private struct DocumentGalleryGrid: View {
    let documentItems: [DocumentItem]
    let entryID: String
    let nodeID: String

    private static let tileHeight: CGFloat = 180

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(documentItems) { documentItem in
                DocumentGalleryTile(
                    documentItem: documentItem,
                    entryID: entryID,
                    nodeID: nodeID
                )
                .frame(height: Self.tileHeight)
            }
        }
    }
}
