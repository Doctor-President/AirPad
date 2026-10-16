import UIKit
import ImageIO

/// live-16 — ONE display-size image cache for every surface that shows a photo: the Card view's cards and tiles, the
/// Map's card, the detail hero, the gallery tiles, Quick Capture's hero and the Librarian's thumbnails.
///
/// T: opening an entry flashed a placeholder (first the glass, then the band) before its hero, and the gallery showed
/// grey icon tiles — while the Card he tapped was ALREADY showing that photo. Each surface decoded on its own (most the
/// full original via `UIImage(data:)`, a 108 MB bitmap for a 6000×4500 photo), so nothing could be handed over.
///
///   - Decode at DISPLAY size: ImageIO downsampling (`CGImageSourceCreateThumbnailAtIndex`, decoded immediately) off
///     the main thread, at the view's pixel size rounded UP to a bucket so neighbouring surfaces share entries. Never
///     the full original for display (the fullscreen viewer keeps full resolution for zoom).
///   - Keyed by `<entry id>/<file path relative to the entry>` + bucket, so a view can look itself up SYNCHRONOUSLY on its
///     first frame, before any async path resolution.
///   - Hand-off: `best(path:)` returns the largest cached decode of a file at any size, so the detail hero renders on its
///     first frame from what the card already decoded, then upgrades to its own size in place (no placeholder between).
///   - Prewarm: `CorpusStore.prewarmOpening(_:)` starts the hero + first gallery decodes when an entry is chosen.
///   - Memory: an `NSCache` with a cost limit (bytes), emptied on a memory warning.
final class DisplayImageCache: NSObject, NSCacheDelegate, @unchecked Sendable {

    static let shared = DisplayImageCache()

    /// Decode sizes (longest side, pixels). A request rounds UP to the next bucket.
    static let buckets = [256, 512, 768, 1024, 1536, 2048, 3072]
    static func bucket(_ pixels: Int) -> Int { buckets.first { $0 >= pixels } ?? buckets[buckets.count - 1] }
    /// Bytes the cache may hold before it evicts (least recently used first).
    static let costLimit = 150 * 1024 * 1024

    /// The cache key for a file inside an entry: what every surface can compute without touching the disk.
    static func key(nodeID: String, relativePath: String) -> String { "\(nodeID)/\(relativePath)" }
    static func coverKey(_ node: Node) -> String? {
        node.coverImageRelativePath.map { key(nodeID: node.id, relativePath: $0) }
    }

    private final class Entry: NSObject {
        let image: UIImage, path: String, bucket: Int, cost: Int
        init(image: UIImage, path: String, bucket: Int, cost: Int) {
            self.image = image; self.path = path; self.bucket = bucket; self.cost = cost
        }
    }

    private let cache = NSCache<NSString, Entry>()
    /// Recursive: NSCache may call `willEvictObject` synchronously from inside `setObject` while the lock is held.
    private let lock = NSRecursiveLock()
    /// path → the buckets cached for it (so a lookup can find "this size or larger" / "the best there is").
    private var index: [String: Set<Int>] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var cost = 0
    /// Report numbers (DEBUG self-test / live-16 report): the most bytes held at once, decodes, hits.
    private(set) var peakCost = 0
    private(set) var decodes = 0
    private(set) var hits = 0

    private override init() {
        super.init()
        cache.totalCostLimit = Self.costLimit
        cache.delegate = self
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.purge(reason: "memory warning") }
    }

    // MARK: - Synchronous lookups (safe in `body`: an in-memory dictionary + NSCache read, no I/O)

    /// A cached decode of `path` at `pixels`' bucket or larger, if there is one.
    func image(path: String, atLeast pixels: Int) -> UIImage? {
        let want = Self.bucket(pixels)
        lock.lock(); defer { lock.unlock() }
        guard let sizes = index[path] else { return nil }
        for b in sizes.sorted() where b >= want {
            if let e = cache.object(forKey: Self.cacheKey(path, b)) { hits += 1; return e.image }
        }
        return nil
    }

    /// The largest cached decode of `path` at any size — the hand-off from a surface that already showed it.
    func best(path: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let sizes = index[path] else { return nil }
        for b in sizes.sorted(by: >) {
            if let e = cache.object(forKey: Self.cacheKey(path, b)) { return e.image }
        }
        return nil
    }

    /// Is a decode of `path` running right now (any size)?
    func isLoading(path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.keys.contains { $0.hasPrefix(path + "#") }
    }

    // MARK: - Load

    /// The decode of the file at `url` for display at `pixels` (longest side): from the cache when there is one at this
    /// size or larger, else decoded off the main thread at the bucket size and cached. Concurrent requests for the same
    /// file + bucket share one decode. Nil when the file can't be read or decoded.
    func load(path: String, url: URL, pixels: Int) async -> UIImage? {
        if let hit = image(path: path, atLeast: pixels) { return hit }
        let b = Self.bucket(pixels)
        let k = Self.cacheKey(path, b) as String
        let task: Task<UIImage?, Never>
        lock.lock()
        if let running = inFlight[k] {
            task = running
            lock.unlock()
        } else {
            task = Task.detached(priority: .userInitiated) { Self.decode(url: url, maxPixel: b) }
            inFlight[k] = task
            lock.unlock()
        }
        let image = await task.value
        lock.lock()
        if inFlight[k] == task { inFlight[k] = nil }
        lock.unlock()
        if let image { insert(image, path: path, bucket: b) }
        return image
    }

    /// Decode at display size: ImageIO's thumbnail path reads the JPEG at a reduced scale where it can, applies the
    /// EXIF orientation, and decodes now (not lazily on the main thread at first draw).
    static func decode(url: URL, maxPixel: Int) -> UIImage? {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), cg.width > 0, cg.height > 0 else { return nil }
        #if DEBUG
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        print("[DisplayImage] decode \(url.lastPathComponent) → \(cg.width)×\(cg.height) (bucket \(maxPixel)) in \(ms) ms")
        #endif
        return UIImage(cgImage: cg)
    }

    // MARK: - Store / evict

    private static func cacheKey(_ path: String, _ bucket: Int) -> NSString { "\(path)#\(bucket)" as NSString }

    private func insert(_ image: UIImage, path: String, bucket: Int) {
        let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * 4)
        lock.lock(); defer { lock.unlock() }
        let k = Self.cacheKey(path, bucket)
        if let old = cache.object(forKey: k) { cost -= old.cost; cache.removeObject(forKey: k) }
        cache.setObject(Entry(image: image, path: path, bucket: bucket, cost: bytes), forKey: k, cost: bytes)
        index[path, default: []].insert(bucket)
        cost += bytes
        decodes += 1
        peakCost = max(peakCost, cost)
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let e = obj as? Entry else { return }
        lock.lock(); defer { lock.unlock() }
        cost -= e.cost
        index[e.path]?.remove(e.bucket)
        if index[e.path]?.isEmpty == true { index[e.path] = nil }
    }

    /// Empty the cache (a memory warning). Views keep the images they already hold; new lookups decode again.
    func purge(reason: String) {
        lock.lock()
        let had = index.values.reduce(0) { $0 + $1.count }, bytes = cost
        cache.removeAllObjects()
        index.removeAll()
        cost = 0
        lock.unlock()
        print("[DisplayImage] \(reason) — emptied \(had) decode(s), \(bytes / 1_048_576) MB")
    }

    /// Bytes held right now (self-test / report).
    var currentCost: Int { lock.lock(); defer { lock.unlock() }; return cost }
    var count: Int { lock.lock(); defer { lock.unlock() }; return index.values.reduce(0) { $0 + $1.count } }
}

// MARK: - Display sizes per surface

@MainActor
enum DisplaySize {
    /// live-20 (3) — the foreground window scene's screen (was `UIScreen.main`, deprecated in iOS 26; on iPhone it is
    /// the same screen). Every former `UIScreen.main` read in the app goes through here.
    static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen
    }
    static var scale: CGFloat { screen?.scale ?? UITraitCollection.current.displayScale }
    static var screenWidth: CGFloat { screen?.bounds.width ?? 0 }
    static var screenHeight: CGFloat { screen?.bounds.height ?? 0 }
    /// The detail hero (and Quick Capture's): the banner's width or its height cap, whichever is larger.
    static var hero: Int { Int(max(screenWidth, EntryVisualSettings.shared.heroMaxHeight) * scale) }
    /// A full-width card (Card view's carousel / vertical cards, the Map's card): the same bucket as the hero, so the
    /// hand-off is already at the hero's sharpness.
    static var card: Int { Int(screenWidth * scale) }
    /// A Card-view grid tile (2–3 across).
    static var tile: Int { Int(screenWidth / 2 * scale) }
    /// A gallery tile (the 220 pt carousel band / bento cells).
    static var galleryTile: Int { Int(260 * scale) }
}

// MARK: - Prewarm on choosing an entry

extension CorpusStore {
    /// How many gallery photos to decode ahead when an entry is chosen (its first row and a little more).
    static let prewarmGalleryCount = 6

    /// live-16 — the entry was chosen (a tap on its row / card / tile): start decoding its hero and its gallery's first
    /// photos NOW, before the navigation transition, at the sizes the detail view will ask for. Returns when the hero's
    /// decode is done (cached or decoded), so a caller may hold the push briefly for an uncached hero.
    @discardableResult
    func prewarmOpening(_ node: Node) async -> Bool {
        let heroPx = DisplaySize.hero, tilePx = DisplaySize.galleryTile
        let cache = DisplayImageCache.shared
        let media = node.items.filter { $0.type == .imageVideo }.flatMap { item in
            (item.mediaItems ?? []).filter { $0.mediaType == .image }.map { (item, $0) }
        }.prefix(Self.prewarmGalleryCount)
        for (item, g) in media {
            let path = DisplayImageCache.key(nodeID: node.id, relativePath: g.file)
            guard cache.image(path: path, atLeast: tilePx) == nil else { continue }
            Task {
                if let url = await self.resolveGalleryItemURL(g, nodeID: node.id, fallbackParentItem: item) {
                    _ = await cache.load(path: path, url: url, pixels: tilePx)
                }
            }
        }
        guard let path = DisplayImageCache.coverKey(node) else { return true }
        if cache.image(path: path, atLeast: heroPx) != nil { return true }
        guard let url = await coverImageURL(for: node) else { return false }
        return await cache.load(path: path, url: url, pixels: heroPx) != nil
    }

    /// The gallery photos on screen when the entry opens (its first row).
    static let firstRowCount = 3

    /// Choose an entry: prewarm, and when what its detail shows FIRST — its hero and its gallery's first row — isn't
    /// decoded yet, hold the push up to `maxWait` for it, so the detail opens on the photos instead of placeholders.
    /// When they are already cached (the Card view showed the cover, an earlier open decoded the row) it pushes at once.
    func openAfterPrewarm(_ node: Node, maxWait: Duration = .milliseconds(300), push: @escaping @MainActor () -> Void) {
        let cache = DisplayImageCache.shared, tilePx = DisplaySize.galleryTile
        let hero = DisplayImageCache.coverKey(node)
        let row = node.items.filter { $0.type == .imageVideo }
            .flatMap { ($0.mediaItems ?? []).filter { $0.mediaType == .image } }
            .prefix(Self.firstRowCount)
            .map { DisplayImageCache.key(nodeID: node.id, relativePath: $0.file) }
        let ready: () -> Bool = {
            (hero.map { cache.best(path: $0) != nil } ?? true)
                && row.allSatisfy { cache.image(path: $0, atLeast: tilePx) != nil }
        }
        Task { await prewarmOpening(node) }   // its own task: the cap below never cancels or waits out the decodes
        guard !ready() else { push(); return }
        let t0 = ContinuousClock.now, deadline = t0 + maxWait
        Task {
            while ContinuousClock.now < deadline, !ready() {
                try? await Task.sleep(for: .milliseconds(8))
            }
            let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
            print("[DisplayImage] open \(node.id): held \(ms) ms for its hero + first row (\(ready() ? "ready" : "not ready — placeholders show"))")
            push()
        }
    }
}
