import SwiftUI
import UIKit

/// Stage 4.2 commit 5 — shared tile primitive for gallery presentations.
/// Renders a single `GalleryItem` inside a parent-controlled frame; the
/// tile does NOT pick its own size. Parents (Carousel in commit 5, Bento
/// in commit 6) compute the frame from `galleryItem.aspectRatio` and apply
/// it externally via `.frame(...)` before this tile is composed in.
///
/// Reuse contract:
///   - Carousel renderer applies `.frame(width: 220 * aspect, height: 220)`.
///   - Bento renderer applies `.frame(width: tileWidth, height: tileHeight)`
///     from the deterministic layout plan.
///   - Fullscreen viewer (commit 7) may reuse this for swipe thumbnails or
///     replace it with a richer per-item player; the tile is not bound to
///     the in-card chrome.
///
/// Responsibilities the tile owns (not the parent):
///   - Resolving the sidecar URL via `resolveGalleryItemURL`.
///   - For images: decoding + measuring aspect ratio, then reporting via
///     `onMeasuredAspect`. The parent uses the measurement to (a) re-layout
///     the tile width in-session and (b) persist back via the store so
///     future sessions skip the measurement.
///   - For videos: requesting a poster-frame thumbnail from
///     `MediaThumbnailLoader` and reporting the same way.
///   - Overlaying a play-glyph badge on video tiles (carry-forward note
///     from commit 4 — affordance must survive into commits 5/6).
///
/// Responsibilities the tile delegates:
///   - Sizing — parent.
///   - Persisting measured aspect to the store — parent (since the parent
///     already holds the in-session override dict and knows when to write).
///   - Tap-to-fullscreen — parent attaches `.onTapGesture` to the framed
///     tile, since the trigger surface depends on presentation context.
struct GalleryItemTile: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem
    /// True for in-card gallery tiles (carousel + bento). The play-glyph
    /// overlay is drawn on top of the video thumbnail so the user can read
    /// "video" at thumb size. Fullscreen / inline-player contexts can pass
    /// false to suppress the badge when the player itself is the affordance.
    var showVideoBadge: Bool = true
    /// Fires once on successful media load with `width / height`. Parents use
    /// this to update both an in-session override (so the next render uses
    /// the measured aspect without waiting for store round-trip) and the
    /// persisted `GalleryItem.aspectRatio` (so cold-launch sessions skip the
    /// measure and lay out at the correct size immediately).
    var onMeasuredAspect: ((Double) -> Void)? = nil

    @Environment(CorpusStore.self) private var store

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                if galleryItem.mediaType == .video && showVideoBadge {
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
            await resolveAndLoad()
        }
    }

    // MARK: - Load pipeline

    private func resolveAndLoad() async {
        let url = await store.resolveGalleryItemURL(
            galleryItem,
            nodeID: nodeID,
            fallbackParentItem: parentItem
        )
        guard let url else { return }
        switch galleryItem.mediaType {
        case .image:
            await loadImage(from: url)
        case .video:
            await loadVideoThumbnail(from: url)
        }
    }

    private func loadImage(from url: URL) async {
        // Off-main decode — Data(contentsOf:) + UIImage(data:) both block,
        // and at gallery-tile scale (potentially many tiles per card) doing
        // this on MainActor stalls the scroll. Detached task keeps decode
        // off main; commit the @State write + aspect callback together on
        // main so a re-render can't observe an image without its aspect.
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard let decoded else { return }
        await commitLoaded(decoded)
    }

    private func loadVideoThumbnail(from url: URL) async {
        guard let thumb = await MediaThumbnailLoader.shared.thumbnail(for: url) else { return }
        await commitLoaded(thumb)
    }

    @MainActor
    private func commitLoaded(_ loaded: UIImage) {
        self.image = loaded
        guard let onMeasuredAspect, loaded.size.height > 0 else { return }
        let aspect = Double(loaded.size.width / loaded.size.height)
        // Skip the callback when the persisted aspect already matches —
        // a no-op write each time the tile re-loads (e.g. scroll-recycle)
        // would churn the store and trigger needless re-renders.
        if let stored = galleryItem.aspectRatio, abs(stored - aspect) < 0.005 { return }
        onMeasuredAspect(aspect)
    }
}
