import SwiftUI
import PhotosUI

/// Stage 4.2 commit 4 — body slot for `.imageVideo` entries with `mediaItems
/// .count >= 2`. Hosts the chrome strip (the "+" add-more button on the
/// left, `ViewModeToggle` on the right) and a media area that branches on
/// the resolved view mode.
///
/// Commit 5 fills the carousel media area with `GalleryCarousel` — a proper
/// horizontal renderer with aspect-aware variable-width tiles and snap-to-
/// tile scrolling. Commit 6 fills the bento area with the deterministic
/// packed grid. Both renderers share `GalleryItemTile` as the per-item
/// primitive, sized externally by each parent.
struct GalleryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingPicker = false
    /// Per-session aspect-ratio overrides keyed by `GalleryItem.id`. Tiles
    /// report their measured aspect on first load via
    /// `onMeasuredAspect`; the override takes precedence over the model's
    /// persisted `aspectRatio` during this session so layout updates
    /// immediately without waiting for the store's @Observable round-trip.
    /// Persistence is fire-and-forget alongside the override write — future
    /// sessions read the persisted value and skip the measurement.
    @State private var measuredAspects: [String: Double] = [:]
    /// Drives the tap-to-fullscreen QuickLook sheet. Cleared on dismiss.
    /// Commit 7 swaps the sheet content for a swipeable multi-item viewer;
    /// the trigger surface (this @State) is unchanged so the swap is
    /// content-only.
    @State private var previewing: MediaPreviewIdentity? = nil

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
        .sheet(item: $previewing) { identity in
            MediaFullscreenViewer(url: identity.url)
        }
    }

    // MARK: - Media area

    @ViewBuilder
    private var mediaArea: some View {
        switch effectiveViewMode {
        case .carousel:
            GalleryCarousel(
                galleryItems: galleryItems,
                nodeID: nodeID,
                parentItem: item,
                aspectFor: { aspectForTile($0) },
                onMeasuredAspect: { itemID, aspect in
                    recordMeasured(itemID: itemID, aspect: aspect)
                },
                onTapTile: { tappedItem in
                    Task {
                        if let url = await store.resolveGalleryItemURL(
                            tappedItem,
                            nodeID: nodeID,
                            fallbackParentItem: item
                        ) {
                            await MainActor.run { previewing = MediaPreviewIdentity(url: url) }
                        }
                    }
                }
            )
        case .bento:
            // Commit 6 replaces this with the proper deterministic packer.
            // Until then the 2-col uniform grid is the right "compact,
            // multi-item" baseline so a user who toggled to bento doesn't
            // see a blank slate.
            bentoPlaceholder
        }
    }

    private var bentoPlaceholder: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(galleryItems) { galleryItem in
                GalleryItemTile(
                    galleryItem: galleryItem,
                    nodeID: nodeID,
                    parentItem: item,
                    onMeasuredAspect: { aspect in
                        recordMeasured(itemID: galleryItem.id, aspect: aspect)
                    }
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Aspect override pipeline

    /// In-session aspect for a tile, falling back through:
    ///   1. `measuredAspects[id]` — tile reported during this session.
    ///   2. `galleryItem.aspectRatio` — persisted from an earlier session.
    ///   3. `1.0` — square placeholder until the first measurement lands.
    /// Clamped to the bento brief's anticipated working range (0.3, 4.0) so
    /// a malformed/EXIF-mangled aspect can't produce a degenerate tile.
    private func aspectForTile(_ galleryItem: GalleryItem) -> Double {
        let raw = measuredAspects[galleryItem.id] ?? galleryItem.aspectRatio ?? 1.0
        return min(max(raw, 0.3), 4.0)
    }

    /// Records a tile's measured aspect both in the session override (so
    /// the next render uses it immediately) and on the persisted
    /// `GalleryItem` (so future sessions skip the measurement). Idempotent
    /// at the store layer — `setGalleryItemAspectRatio` no-ops if the
    /// stored value already matches.
    private func recordMeasured(itemID: String, aspect: Double) {
        measuredAspects[itemID] = aspect
        Task {
            await store.setGalleryItemAspectRatio(
                entryID: item.id,
                nodeID: nodeID,
                galleryItemID: itemID,
                aspectRatio: aspect
            )
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

/// Stage 4.2 commit 5 — proper carousel renderer for the gallery presentation.
///
/// Design points fixed in this commit:
///   - **Variable-width tiles.** Each tile's width = 220pt × aspect. Portrait
///     shots stay portrait, landscape stays landscape — the brief's "original
///     aspect with a max height" stance. Height is uniform at 220pt so the
///     row reads as a single horizontal strip; reflow only happens
///     left-to-right, never vertically.
///   - **Snap-to-tile.** `.scrollTargetBehavior(.viewAligned)` +
///     `.scrollTargetLayout()` on the `LazyHStack`. The view aligns to a
///     tile's leading edge on settle so a partial-tile-mid-stream rest
///     state is impossible — matches Apple Photos' carousel feel.
///   - **Lazy.** `LazyHStack` means a 50-tile gallery doesn't decode 50
///     UIImages on first render. Tiles materialize as they scroll into view.
///   - **Tap → fullscreen.** Per-tile tap routes to `MediaFullscreenViewer`
///     (QuickLook). Commit 7 replaces with a swipeable multi-item viewer;
///     this commit keeps the same trigger surface so that swap is
///     content-only.
///
/// Out of scope (deferred):
///   - Scroll-position memory across navigation / view-mode toggles. Polish
///     value; the user always lands on the first tile when re-entering. If
///     that proves disruptive on real corpora, commit 8 can persist the
///     position as a transient (not Codable) state on `GalleryBody`.
///   - Per-tile delete / reorder gestures (commit 7).
private struct GalleryCarousel: View {

    let galleryItems: [GalleryItem]
    let nodeID: String
    let parentItem: NodeItem
    let aspectFor: (GalleryItem) -> Double
    let onMeasuredAspect: (_ itemID: String, _ aspect: Double) -> Void
    let onTapTile: (GalleryItem) -> Void

    /// Uniform tile height. Matches the placeholder height shipped in
    /// commit 4 so the visual transition from placeholder → real renderer
    /// (and from real renderer → commit-6 bento on toggle) doesn't reflow
    /// the entry card.
    private static let tileHeight: CGFloat = 220

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(galleryItems) { galleryItem in
                    GalleryItemTile(
                        galleryItem: galleryItem,
                        nodeID: nodeID,
                        parentItem: parentItem,
                        onMeasuredAspect: { aspect in
                            onMeasuredAspect(galleryItem.id, aspect)
                        }
                    )
                    .frame(
                        width: Self.tileHeight * aspectFor(galleryItem),
                        height: Self.tileHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { onTapTile(galleryItem) }
                }
            }
            .padding(.horizontal, 2)
            .scrollTargetLayout()
        }
        .frame(height: Self.tileHeight)
        .scrollTargetBehavior(.viewAligned)
    }
}
