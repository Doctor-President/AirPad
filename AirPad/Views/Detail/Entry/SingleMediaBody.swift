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

    /// Stable inline AVPlayer (unified-media-viewer double-playback fix). Held
    /// in @State — NOT rebuilt in `body` — so it survives re-renders and, more
    /// importantly, can be paused + relinquished when the fullscreen lightbox
    /// presents. The old `VideoPlayer(player: AVPlayer(url:))` had no reference
    /// to pause, so the inline player kept playing behind the cover and the
    /// system promoted the orphan to PiP (doubled audio).
    @State private var inlinePlayer: AVPlayer? = nil
    /// Whether the inline player was playing when the lightbox took over, so
    /// dismiss can restore it.
    @State private var inlineWasPlaying = false
    /// Import-failure surface — set when picked photos couldn't be copied (e.g.
    /// iCloud-hosted originals that failed to download). Failures are counted,
    /// not silently dropped.
    @State private var importFailureCount = 0
    @State private var showImportFailure = false

    private var primaryItem: GalleryItem? { item.mediaItems?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaPreview

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .padding(.horizontal, 4)
            } else if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
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
        // Double-playback fix: when the lightbox presents, the inline player is
        // still mounted behind it and keeps playing (the system then promotes
        // it to PiP). Pause + remember state so audio doesn't double up.
        .onChange(of: viewerStart) { _, newValue in
            guard newValue != nil, let inlinePlayer else { return }
            inlineWasPlaying = (inlinePlayer.timeControlStatus == .playing)
            inlinePlayer.pause()
        }
        // Leaving the entry entirely (nav pop) also stops the inline audio.
        .onDisappear { inlinePlayer?.pause() }
        .alert("Couldn’t add \(importFailureCount) \(importFailureCount == 1 ? "item" : "items")",
               isPresented: $showImportFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("They may be stored in iCloud and need to be downloaded first. Try again once they’ve finished downloading.")
        }
        .fullScreenCover(item: $viewerStart, onDismiss: handleViewerDismiss) { start in
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
                .fill(AppearancePalette.ink.opacity(0.06))
                .frame(height: 120)
                .overlay(Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35)))
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
                .fill(AppearancePalette.ink.opacity(0.08))
                .frame(height: 200)
                .overlay(Image(systemName: "photo").foregroundStyle(AppearancePalette.ink.opacity(0.3)))
                .onAppear { loadMediaURL() }
        }
    }

    @ViewBuilder
    private var videoPreview: some View {
        Group {
            if let player = inlinePlayer {
                // Inline AVKit player. A full-area tap gesture would fight the
                // player's own touch handling (play/pause/scrub on tap), so the
                // tap-to-fullscreen affordance is a corner button instead. The
                // player is a stable @State ref so it can be paused when the
                // lightbox presents (see `.onChange(of: viewerStart)`).
                VideoPlayer(player: player)
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
                    .fill(AppearancePalette.ink.opacity(0.08))
                    .frame(height: 220)
                    .overlay(Image(systemName: "video").foregroundStyle(AppearancePalette.ink.opacity(0.3)))
                    .onAppear { loadMediaURL() }
            }
        }
        // Build the stable player once the URL resolves.
        .task(id: mediaURL) {
            guard let url = mediaURL, inlinePlayer == nil else { return }
            inlinePlayer = AVPlayer(url: url)
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
    /// Lightbox dismiss: run the deferred delete, then restore the inline
    /// player to its pre-present state (resume only if it was playing).
    private func handleViewerDismiss() {
        flushPendingDeletion()
        if inlineWasPlaying { inlinePlayer?.play() }
        inlineWasPlaying = false
    }

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
        var failures = 0
        for result in results {
            let provider = result.itemProvider
            if MediaPickerWrapper.isImageProvider(provider) {
                // Copy the ORIGINAL bytes — no decode, no re-encode. The photo
                // keeps its source format (HEIC/JPEG/PNG/RAW) at full quality.
                if let (tmpURL, ext) = await MediaPickerWrapper.loadOriginalImageFile(from: provider) {
                    pending.append(.init(itemID: UUID().uuidString, mediaType: .image, sourceURL: tmpURL, fileExtension: ext))
                } else {
                    failures += 1   // e.g. iCloud-hosted original that failed to download
                }
            } else if let (tmpURL, ext) = await MediaPickerWrapper.loadVideo(from: provider) {
                pending.append(.init(itemID: UUID().uuidString, mediaType: .video, sourceURL: tmpURL, fileExtension: ext))
            } else {
                failures += 1
            }
        }

        // Never lose a picked item silently — surface the count.
        if failures > 0 {
            importFailureCount = failures
            showImportFailure = true
        }

        guard !pending.isEmpty else { return }
        await store.appendMediaItems(toEntryID: item.id, nodeID: nodeID, mediaItems: pending)
    }
}
