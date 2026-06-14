import SwiftUI
import AVKit
import PhotosUI

/// Stage 4.2 commit 3 — body slot for `.imageVideo` entries reading off
/// `item.mediaItems`. Renders the first (and in single-presentation, only)
/// gallery item, plus the in-card chrome strip with the "+" add-more button.
///
/// Used by the EntryCard `.imageVideo` arm for ALL counts during commits 3–4:
/// commit 4's `GalleryBody` will take over count ≥ 2 once it lands. Until
/// then, multi-item entries created via commit 2's multi-select picker (or by
/// pressing "+" here) render the first item only — the data is intact, only
/// the rendering is single-view-limited. The TODO breadcrumb in
/// `CorpusStore.addMediaItems` documents this transitional state.
///
/// ## Tap-to-fullscreen (unified-media-viewer commit 2)
///
/// Both the image preview and the video preview open `GalleryFullscreenViewer`
/// — the same viewer the gallery (≥2 items) presentation uses. Single-media
/// entries pass a one-element `galleryItems` array; the viewer clamps the
/// start index defensively. This retires the previous QuickLook-backed
/// `MediaFullscreenViewer`, which couldn't host the viewer's action chrome
/// (Share / Copy / Set Hero / Delete). Video preview gets a corner "expand"
/// button rather than a full-area tap so it doesn't fight the inline
/// `VideoPlayer`'s transport-controls touch handling — commit 3 of the
/// brief replaces the inline player with `AVPlayerViewController` and its
/// own native fullscreen button.
///
/// ## Deferred-delete (sole-item case)
///
/// Mirrors `GalleryBody`'s pattern: the viewer's Delete dismisses the sheet
/// and stashes the `GalleryItem` in `pendingDeletion`; the real store work
/// runs in the `onDismiss` callback so the card behind the sheet doesn't
/// mutate while the viewer is still visible. The single-media wrinkle is
/// that removing the sole item would leave the entry with zero media —
/// which is meaningless and would render via the defensive empty-state
/// below. Instead we delete the whole entry. Because `deleteEntry`'s
/// legacy file-cleanup path uses `item.id` (not the gallery item's id)
/// as the file basename, the gallery item's file would otherwise be
/// orphaned; we chain `deleteGalleryItem` first to clean the file via
/// its correct itemID, then `deleteEntry` to remove the now-empty entry.
struct SingleMediaBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var mediaURL: URL? = nil
    @State private var showingPicker = false
    /// Drives the tap-to-fullscreen unified viewer. Single-media entries
    /// always open at index 0 (their `mediaItems` array is length 1).
    @State private var viewerStart: GalleryViewerStart? = nil
    /// Deferred-deletion buffer for the viewer's Delete action. The real
    /// store delete runs in the sheet's `onDismiss` callback so the
    /// transition to the empty-entry state (and the subsequent entry
    /// removal) lands after the viewer has fully faded out.
    @State private var pendingDeletion: GalleryItem? = nil

    private var primaryItem: GalleryItem? { item.mediaItems?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaPreview

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            } else if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }

            MediaEntryChrome(
                onAdd: { showingPicker = true },
                accessibilityLabel: "Add more media"
            ) {
                // Commit 4 fills this slot with the Carousel/Bento view-mode
                // toggle. Empty in commit 3 — the chrome row exists at full
                // height so the transition single → gallery is visually
                // continuous (no resize when commit 4 lands).
                EmptyView()
            }
        }
        .sheet(isPresented: $showingPicker) {
            MediaPickerWrapper { results in
                Task { await handlePickedMedia(results) }
            }
        }
        .fullScreenCover(item: $viewerStart, onDismiss: flushPendingDeletion) { start in
            GalleryFullscreenViewer(
                galleryItems: item.mediaItems ?? [],
                nodeID: nodeID,
                parentItem: item,
                startIndex: start.index,
                onRequestDelete: { gItem in
                    // Stash and let the viewer dismiss; `flushPendingDeletion`
                    // runs after the sheet is gone, applying the file-cleanup
                    // + entry-removal sequence described in the header doc.
                    pendingDeletion = gItem
                }
            )
            .environment(store)
        }
    }

    // MARK: - Media preview

    @ViewBuilder
    private var mediaPreview: some View {
        if let primary = primaryItem {
            switch primary.mediaType {
            case .image: imagePreview
            case .video: videoPreview
            }
        } else {
            // Defensive: an `.imageVideo` entry with empty `mediaItems` slipped
            // through. EntryCard's dispatch guards against this, but a future
            // refactor might route an empty entry here directly — keep the
            // local fallback so this view never renders an undefined state.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .frame(height: 120)
                .overlay(Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(.white.opacity(0.35)))
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let url = mediaURL {
            AsyncImageFromURL(url: url)
                .contentShape(Rectangle())
                .onTapGesture { viewerStart = GalleryViewerStart(index: 0) }
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
                .frame(height: 200)
                .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
                .onAppear { loadMediaURL() }
        }
    }

    @ViewBuilder
    private var videoPreview: some View {
        if let url = mediaURL {
            // Inline AVKit player. A full-area tap gesture would fight the
            // player's own touch handling (play/pause/scrub on tap), so the
            // tap-to-fullscreen affordance is a corner button instead.
            // Commit 3 of `briefs/unified-media-viewer.md` swaps the inline
            // player for `AVPlayerViewController`, which has a built-in
            // fullscreen button and retires this corner overlay.
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    Button {
                        viewerStart = GalleryViewerStart(index: 0)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .padding(8)
                    .accessibilityLabel("Open fullscreen")
                }
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
                .frame(height: 200)
                .overlay(Image(systemName: "video").foregroundStyle(.white.opacity(0.3)))
                .onAppear { loadMediaURL() }
        }
    }

    private func loadMediaURL() {
        guard let primary = primaryItem else { return }
        Task {
            let resolved = await store.resolveGalleryItemURL(
                primary,
                nodeID: nodeID,
                fallbackParentItem: item
            )
            await MainActor.run { mediaURL = resolved }
        }
    }

    // MARK: - Deferred delete

    /// Runs after `fullScreenCover` fully dismisses. Sole-item case
    /// (always, for `SingleMediaBody`): chain `deleteGalleryItem` →
    /// `deleteEntry` so the gallery item's file is cleaned up via its
    /// own itemID before the entry is removed. `deleteEntry`'s own
    /// file-cleanup is entry-id-based and would miss the gallery file
    /// if called alone — see the file-header doc for the full rationale.
    /// Falls back to a single `deleteGalleryItem` call if a background
    /// sync somehow grew the entry past 1 item while the viewer was up.
    private func flushPendingDeletion() {
        guard let gItem = pendingDeletion else { return }
        pendingDeletion = nil
        let remainingCount = item.mediaItems?.count ?? 0
        Task {
            await store.deleteGalleryItem(
                entryID: item.id,
                nodeID: nodeID,
                galleryItemID: gItem.id
            )
            if remainingCount <= 1 {
                await store.deleteEntry(itemID: item.id, nodeID: nodeID)
            }
        }
    }

    // MARK: - "+" handler

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
                    print("[SingleMediaBody] Image temp write error: \(error)")
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
