import SwiftUI

/// Stage 4.6 commit 3 — body slot for `.document` entries with
/// `documentItems.count >= 2`. Hosts a carousel of `DocumentGalleryTile`s
/// and a chrome strip with a "+" button (which presents
/// `DocumentPickerView` and routes the result to
/// `CorpusStore.appendDocumentItems(toEntryID:...)`). Parallel to
/// `LinkGalleryBody` for the link gallery and `GalleryBody` for media.
///
/// C3 chrome strip carries only the "+" — the carousel/grid view-mode
/// toggle and the corresponding grid renderer ship in C4 together so
/// the toggle never points at a placeholder. Carousel renders for all
/// counts in C3 regardless of any persisted `documentViewMode` value;
/// the field-write still happens on the 1→2 transition in
/// `appendDocumentItems` so C4's renderer reads the correct default.
struct DocumentGalleryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingAppendPicker = false

    private var documentItems: [DocumentItem] { item.documentItems ?? [] }

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
            DocumentGalleryCarousel(
                documentItems: documentItems,
                entryID: item.id,
                nodeID: nodeID
            )

            MediaEntryChrome(
                onAdd: { showingAppendPicker = true },
                accessibilityLabel: "Add document"
            ) {
                // C4 lands the carousel/grid toggle here.
                EmptyView()
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
