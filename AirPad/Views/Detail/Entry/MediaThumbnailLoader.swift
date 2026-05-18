import UIKit
import AVFoundation

/// Stage 4.2 commit 5 — video poster-frame extractor. Used by `GalleryItemTile`
/// to render a still thumbnail for video gallery items in the Carousel and
/// (commit 6) Bento renderers, instead of either an inline `VideoPlayer`
/// (too heavy at tile size — every tile would hold a decoder) or a generic
/// "video" placeholder glyph (loses the per-clip visual signal).
///
/// In-memory cache keyed on absoluteString. Cache is process-lifetime — small
/// enough (UIImages at tile resolution) that an LRU bound isn't worth the
/// complexity at commit 5 corpus sizes. Commits 7/8 can revisit if we ever
/// hit memory pressure from a many-clip gallery.
///
/// Frame chosen: 0.0s (first frame). The brief is silent on which frame is
/// the "poster"; first-frame matches Apple Photos and avoids the cost +
/// nondeterminism of mid-clip sampling.
actor MediaThumbnailLoader {

    static let shared = MediaThumbnailLoader()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Returns a first-frame thumbnail for the video at `url`. Cached on
    /// success; failed extractions are NOT cached (so a transient error can
    /// recover on retry). Concurrent calls for the same URL share one
    /// extraction Task — second caller awaits the first's result.
    func thumbnail(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [url] in
            await Self.extractFirstFrame(from: url)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache[key] = image }
        return image
    }

    /// Stand-alone extraction so the actor's body stays serialized on the
    /// cache state, not on the AVFoundation call (which is independent per
    /// URL and benefits from running off the actor).
    private static func extractFirstFrame(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        do {
            let cgImage = try await generator.image(at: .zero).image
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}
