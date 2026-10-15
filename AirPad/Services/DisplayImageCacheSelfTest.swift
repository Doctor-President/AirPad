#if DEBUG
import UIKit

/// live-16 — `-DisplayImageCacheSelfTest` (with `-UITestLibrary -UITestSeedHeroEntries`): the shared display-image
/// cache, measured and checked on synthetic photos only.
///   1. Decode time + memory for a 6000×4500 photo: BEFORE (the card's old path — the full original via `UIImage(data:)`,
///      decoded for display) vs AFTER (ImageIO at the card / tile / hero sizes).
///   2. A second request is a cache hit; the hero's hand-off (`best`) sees the card's decode; requests for a size in
///      the same bucket share one entry.
///   3. Peak cost when every photo in the library is decoded at every size a surface asks for (the upper bound of a
///      browse: every card, tile, hero and gallery tile at once).
///   4. A simulated memory warning empties it.
enum DisplayImageCacheSelfTest {

    @MainActor
    static func run(store: CorpusStore) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if !ok { fails += 1 }
        }
        let cache = DisplayImageCache.shared
        cache.purge(reason: "self-test start")
        func ms(_ t0: CFAbsoluteTime) -> Int { Int((CFAbsoluteTimeGetCurrent() - t0) * 1000) }
        func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

        // 1. The large synthetic photo the hero rows use.
        guard let large = store.nodes.first(where: { $0.id == "uitest-hero-large" }),
              let key = DisplayImageCache.coverKey(large), let url = await store.coverImageURL(for: large) else {
            return "[DisplayImageCacheSelfTest] FAIL — 0/1\nFAIL seeded-large-photo — run with -UITestLibrary -UITestSeedHeroEntries"
        }
        var before: [Int] = [], beforeBytes = 0
        for _ in 0..<3 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let full: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
                return img.preparingForDisplay()   // what drawing it does: the full bitmap, decoded
            }.value
            before.append(ms(t0))
            if let cg = full?.cgImage { beforeBytes = cg.bytesPerRow * cg.height }
        }
        var after: [String] = []
        for (label, px) in [("card", DisplaySize.card), ("tile", DisplaySize.tile), ("hero", DisplaySize.hero)] {
            var times: [Int] = [], bytes = 0, dims = ""
            for _ in 0..<3 {
                let t0 = CFAbsoluteTimeGetCurrent()
                let img = await Task.detached(priority: .userInitiated) {
                    DisplayImageCache.decode(url: url, maxPixel: DisplayImageCache.bucket(px))
                }.value
                times.append(ms(t0))
                if let cg = img?.cgImage { bytes = cg.bytesPerRow * cg.height; dims = "\(cg.width)×\(cg.height)" }
            }
            after.append("\(label) \(dims) \(times.sorted()[1]) ms, \(mb(bytes))")
        }
        let beforeMedian = before.sorted()[1]
        row("decode-6000x4500", true, "BEFORE full original \(beforeMedian) ms, \(mb(beforeBytes)) · AFTER \(after.joined(separator: " · ")) (median of 3)")

        // 2. Hit, hand-off, bucket sharing.
        let t0 = CFAbsoluteTimeGetCurrent()
        let first = await cache.load(path: key, url: url, pixels: DisplaySize.card)
        let firstMs = ms(t0)
        let t1 = CFAbsoluteTimeGetCurrent()
        let second = await cache.load(path: key, url: url, pixels: DisplaySize.card)
        row("second-request-is-a-hit", first != nil && second === first, "first \(firstMs) ms, second \(ms(t1)) ms")
        row("hero-hand-off-sees-the-card's-decode", cache.best(path: key) === first)
        let sameBucket = await cache.load(path: key, url: url, pixels: DisplaySize.card - 40)
        row("same-bucket-shares-one-entry", sameBucket === first && cache.count == 1, "entries \(cache.count)")
        let smallerFromLarger = cache.image(path: key, atLeast: DisplaySize.tile)
        row("a-smaller-request-uses-the-larger-decode", smallerFromLarger === first)

        // 3. Peak: every photo in the library at every size a surface asks for.
        cache.purge(reason: "self-test peak")
        var photos = 0
        for node in store.nodes {
            if let k = DisplayImageCache.coverKey(node), let u = await store.coverImageURL(for: node) {
                photos += 1
                for px in [DisplaySize.tile, DisplaySize.card, DisplaySize.hero] { _ = await cache.load(path: k, url: u, pixels: px) }
            }
            for item in node.items where item.type == .imageVideo {
                for g in item.mediaItems ?? [] where g.mediaType == .image {
                    guard let u = await store.resolveGalleryItemURL(g, nodeID: node.id, fallbackParentItem: item) else { continue }
                    photos += 1
                    _ = await cache.load(path: DisplayImageCache.key(nodeID: node.id, relativePath: g.file), url: u, pixels: DisplaySize.galleryTile)
                }
            }
        }
        let peak = cache.peakCost
        row("peak-cost-whole-library", peak > 0 && peak <= DisplayImageCache.costLimit,
            "\(store.nodes.count) entries, \(photos) photos → \(cache.count) decodes, peak \(mb(peak)) (limit \(mb(DisplayImageCache.costLimit)))")

        // 4. Memory warning.
        let heldBefore = cache.count
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        row("memory-warning-empties-it", heldBefore > 0 && cache.count == 0 && cache.currentCost == 0,
            "\(heldBefore) decodes → \(cache.count), \(mb(cache.currentCost)) held")

        return "[DisplayImageCacheSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
