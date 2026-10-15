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
    /// #6 (launch list) — when true and the item carries a caption, a legible
    /// caption strip is overlaid on the tile's bottom edge (gradient scrim +
    /// text). Non-invasive: it's an overlay INSIDE the parent-owned frame, so
    /// it works identically in the carousel and the 2-D bento without touching
    /// either layout. Off in the fullscreen viewer, which shows its own caption
    /// line. Covers image AND video tiles.
    var showsCaption: Bool = false
    /// Fires once on successful media load with `width / height`. Parents use
    /// this to update both an in-session override (so the next render uses
    /// the measured aspect without waiting for store round-trip) and the
    /// persisted `GalleryItem.aspectRatio` (so cold-launch sessions skip the
    /// measure and lay out at the correct size immediately).
    var onMeasuredAspect: ((Double) -> Void)? = nil

    @Environment(CorpusStore.self) private var store

    @State private var image: UIImage? = nil
    /// live-16 — the file couldn't be resolved or decoded: only then the media glyph (never while a local photo loads).
    @State private var loadFailed = false
    /// live-16 — whether the tile's first frame already had its picture (from the cache); if not, it fades in.
    @State private var appearedWithImage = false

    /// live-16 — the shared-cache key for this item's file.
    private var cacheKey: String { DisplayImageCache.key(nodeID: nodeID, relativePath: galleryItem.file) }

    /// live-16 — this frame's picture: its own decode, else a photo already decoded at gallery size or larger in the
    /// shared cache (the tap's prewarm, or an earlier open), so the first row is there on the detail's first frame.
    private var shown: UIImage? {
        if let image { return image }
        guard galleryItem.mediaType == .image else { return nil }
        return DisplayImageCache.shared.image(path: cacheKey, atLeast: DisplaySize.galleryTile)
    }

    var body: some View {
        ZStack {
            if let image = shown {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .transition(.opacity)   // a thumbnail that lands after the first frame fades in
                if galleryItem.mediaType == .video && showVideoBadge {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                }
            } else {
                // live-16 — a neutral tile while the photo decodes; the media glyph only when it truly can't load.
                Rectangle()
                    .fill(AppearancePalette.ink.opacity(0.08))
                    .overlay {
                        if loadFailed || galleryItem.mediaType == .video {
                            Image(systemName: galleryItem.mediaType == .video ? "video" : "photo")
                                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) { captionStrip }
        // live-16 — the tile as RENDERED: the first frame's state, then each change (`HeroHeaderFlash`).
        .onAppear {
            appearedWithImage = shown != nil
            HeroHeaderProbe.tile(nodeID, galleryItem.id, appearedWithImage ? "image" : "placeholder")
        }
        .onChange(of: shown != nil) { _, isShown in HeroHeaderProbe.tile(nodeID, galleryItem.id, isShown ? "image" : "placeholder") }
        .task(id: galleryItem.id) {
            await resolveAndLoad()
        }
    }

    /// #6 — bottom caption strip. Only drawn when the tile is asked to show it
    /// and a caption exists; a top-to-bottom scrim keeps the text legible over
    /// any image. Clipped to the tile shape by the parent's `.clipShape`.
    @ViewBuilder
    private var captionStrip: some View {
        if showsCaption, let caption = galleryItem.caption, !caption.isEmpty {
            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - Load pipeline

    private func resolveAndLoad() async {
        let url = await store.resolveGalleryItemURL(
            galleryItem,
            nodeID: nodeID,
            fallbackParentItem: parentItem
        )
        guard let url else { loadFailed = true; return }
        switch galleryItem.mediaType {
        case .image:
            await loadImage(from: url)
        case .video:
            await loadVideoThumbnail(from: url)
        }
    }

    private func loadImage(from url: URL) async {
        // Off-main decode, at gallery-tile size (live-16: ImageIO downsampling through the ONE shared cache — was the
        // full original via `UIImage(data:)`). Commit the @State write + aspect callback together on main so a
        // re-render can't observe an image without its aspect.
        guard let decoded = await DisplayImageCache.shared.load(path: cacheKey, url: url, pixels: DisplaySize.galleryTile) else {
            loadFailed = true
            return
        }
        commitLoaded(decoded)
    }

    private func loadVideoThumbnail(from url: URL) async {
        guard let thumb = await MediaThumbnailLoader.shared.thumbnail(for: url) else { return }
        commitLoaded(thumb)
    }

    @MainActor
    private func commitLoaded(_ loaded: UIImage) {
        // live-16 — already on screen from the cache: no change; arriving after the first frame: fade in.
        if image == nil && !appearedWithImage {
            withAnimation(.easeOut(duration: 0.2)) { self.image = loaded }
        } else {
            self.image = loaded
        }
        guard let onMeasuredAspect, loaded.size.height > 0 else { return }
        let aspect = Double(loaded.size.width / loaded.size.height)
        // Skip the callback when the persisted aspect already matches —
        // a no-op write each time the tile re-loads (e.g. scroll-recycle)
        // would churn the store and trigger needless re-renders.
        if let stored = galleryItem.aspectRatio, abs(stored - aspect) < 0.005 { return }
        onMeasuredAspect(aspect)
    }
}
