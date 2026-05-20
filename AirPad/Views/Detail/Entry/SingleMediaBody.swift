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
struct SingleMediaBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var mediaURL: URL? = nil
    @State private var showingPicker = false
    @State private var previewing: MediaPreviewIdentity? = nil

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
        .sheet(item: $previewing) { identity in
            MediaFullscreenViewer(url: identity.url)
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
                .onTapGesture { previewing = MediaPreviewIdentity(url: url) }
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
            // Inline AVKit player. Tap-to-fullscreen is deferred to commit 7
            // for videos — inline player already handles play/pause/scrub, and
            // adding a separate tap gesture would fight the player's own
            // touch handling.
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
