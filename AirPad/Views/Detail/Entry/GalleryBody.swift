import SwiftUI
import PhotosUI

/// Stage 4.2 commit 4 — body slot for `.imageVideo` entries with `mediaItems
/// .count >= 2`. Hosts the chrome strip (the "+" add-more button on the
/// left, `ViewModeToggle` on the right) and a media area that branches on
/// the resolved view mode.
///
/// Commits 5 and 6 fill the carousel and bento media areas respectively.
/// Until then this shell renders count- and mode-aware placeholders so the
/// transition from `SingleMediaBody` is observable end-to-end:
///   - "+" appends through `CorpusStore.appendMediaItems`, same flow as
///     `SingleMediaBody`. A single-item entry growing to 2+ flips the
///     dispatch in `EntryCard` from `SingleMediaBody` to `GalleryBody` on
///     the next render — at which point the first-transition viewMode
///     default written by `appendMediaItems` is already in place.
///   - The view-mode toggle writes through `CorpusStore.setEntryViewMode`
///     and round-trips via the store's `@Observable` state.
///
/// The placeholder media area exists so commit 4 ships a working build
/// per T's "each commit leaves the app working" rule. It is visibly
/// different from a finished gallery — explicitly labeled — so a user
/// running commit 4 on-device sees the state honestly rather than thinking
/// the gallery is broken. Commits 5/6 replace the placeholders one at a
/// time.
struct GalleryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingPicker = false

    private var galleryItems: [GalleryItem] { item.mediaItems ?? [] }

    /// Defensive resolution of the active view mode. `appendMediaItems` and
    /// `addMediaItems` already write a default at first transition, but a
    /// migrated v1→v2 entry that grew via a code path we haven't covered
    /// could in theory reach here with viewMode == nil — fall back to the
    /// same count-based heuristic so the renderer never has to handle that
    /// as an error state.
    private var effectiveViewMode: GalleryViewMode {
        if let viewMode = item.viewMode { return viewMode }
        return galleryItems.count <= 3 ? .carousel : .bento
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaArea

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }

            MediaEntryChrome(onAddMore: { showingPicker = true }) {
                ViewModeToggle(active: effectiveViewMode) { newMode in
                    Task {
                        await store.setEntryViewMode(
                            itemID: item.id,
                            nodeID: nodeID,
                            viewMode: newMode
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            MediaPickerWrapper { results in
                Task { await handlePickedMedia(results) }
            }
        }
    }

    // MARK: - Media area (commit-5/6 placeholder)

    @ViewBuilder
    private var mediaArea: some View {
        switch effectiveViewMode {
        case .carousel: carouselPlaceholder
        case .bento:    bentoPlaceholder
        }
    }

    private var carouselPlaceholder: some View {
        // Horizontal strip — sized so the visible state matches what
        // commit 5's carousel will occupy, so the swap is content-only and
        // doesn't reflow the card height.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(galleryItems) { galleryItem in
                    GalleryItemTile(galleryItem: galleryItem, nodeID: nodeID, parentItem: item)
                        .frame(width: 180, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 220)
    }

    private var bentoPlaceholder: some View {
        // 2-column grid — commit 6 replaces with variable-tile bento, but
        // a 2-col uniform grid is the right "compact, multi-item" visual
        // baseline so the shell isn't visibly broken in the meantime.
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(galleryItems) { galleryItem in
                GalleryItemTile(galleryItem: galleryItem, nodeID: nodeID, parentItem: item)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - "+" handler (parity with SingleMediaBody)

    private func handlePickedMedia(_ results: [PHPickerResult]) async {
        guard !results.isEmpty else { return }

        var pending: [CorpusStore.PendingMediaItem] = []
        for result in results {
            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                guard let image = await MediaPickerWrapper.loadImage(from: result.itemProvider),
                      let data = image.jpegData(compressionQuality: 0.85) else { continue }
                let itemID = UUID().uuidString
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(itemID).jpg")
                do {
                    try data.write(to: tmpURL)
                } catch {
                    print("[GalleryBody] Image temp write error: \(error)")
                    continue
                }
                pending.append(.init(itemID: itemID, mediaType: .image, sourceURL: tmpURL, fileExtension: "jpg"))
            } else if let (tmpURL, ext) = await MediaPickerWrapper.loadVideo(from: result.itemProvider) {
                pending.append(.init(itemID: UUID().uuidString, mediaType: .video, sourceURL: tmpURL, fileExtension: ext))
            }
        }

        guard !pending.isEmpty else { return }
        await store.appendMediaItems(toEntryID: item.id, nodeID: nodeID, mediaItems: pending)
    }
}

/// Stage 4.2 commit 4 — a single tile inside the carousel-/bento-placeholder
/// renderers. Resolves the sidecar URL once via `resolveGalleryItemURL` and
/// shows an `AsyncImageFromURL` for images / a static thumbnail badge for
/// videos. Commits 5 and 6 will swap this for richer per-mode renderers
/// (carousel uses a tappable inline player; bento uses a thumb with a play
/// overlay), but the tile-level resolution + placeholder pattern is shared
/// scaffolding both paths can keep.
private struct GalleryItemTile: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem

    @Environment(CorpusStore.self) private var store
    @State private var resolvedURL: URL? = nil

    var body: some View {
        ZStack {
            if let url = resolvedURL {
                AsyncImageFromURL(url: url)
                if galleryItem.mediaType == .video {
                    // Static play-glyph badge — commit 5/6 swap for a
                    // proper video-thumb pipeline; this gets the multi-item
                    // visual right (you can see a video is a video) without
                    // a full thumbnail extractor in commit 4.
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: galleryItem.mediaType == .video ? "video" : "photo")
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .task(id: galleryItem.id) {
            resolvedURL = await store.resolveGalleryItemURL(
                galleryItem,
                nodeID: nodeID,
                fallbackParentItem: parentItem
            )
        }
    }
}
