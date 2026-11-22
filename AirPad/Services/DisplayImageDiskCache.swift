import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers

/// Sweep 2b · 4.5 — the display-size decodes kept ON DISK between launches (the Mac), under `DisplayImageCache`'s memory
/// tier. T (sweep-1 check, 11-20): a gallery "needing to load" the first time after every Xcode build — on the Mac every
/// build is a cold launch, the memory cache is empty, and each photo was decoded again from its multi-MB original.
///
///   - What: the bucket-sized image `DisplayImageCache.decode` made (JPEG 0.85; PNG when it has alpha), and the video
///     poster frames `MediaThumbnailLoader` extracts. Never the original; never anything inside the library.
///   - Key: SHA-256 of (format version · the memory key · the bucket · the ORIGINAL file's modification date and size).
///     A changed original gets a new key; its old decode is never read again and ages out. Reading the key only stats
///     the original (an iCloud placeholder answers without downloading).
///   - Where: `Caches/DisplayImages/v1/` — the system's caches location: never backed up, and macOS may purge it when
///     the disk runs low (the app then decodes again; nothing is lost).
///   - Cap: **512 MB**, enforced here (least recently used goes first, down to 80 % so it doesn't trim on every write).
///     Why 512: the realistic test library (T's shape: 80 covers + 195 photos in galleries) at the sizes a 1703-pt Mac
///     window asks for (card 3072 px, tile 2048, gallery tile 768, list / Librarian 256) is ≈ 250–350 MB of JPEGs, so the
///     whole browsing set of a library like T's fits with room; it is about a sixth of what 4.6 pins (≈ 3 GB), so the
///     cache never costs more disk than a small fraction of the library it speeds up.
///   - Threads: every read, encode, write and trim runs off the main thread (the decode task's thread for a read, one
///     serial utility queue for writes / index / trims). Nothing here is reachable from `body`.
///   - On: the Mac only (`enabled`). The iPhone keeps today's memory-only cache (the app usually stays alive there).
///
/// Self-contained (Foundation / ImageIO / CryptoKit only) so `scripts/mac/perf/4x/disk_cache_test.sh` compiles it with
/// `swiftc` and checks the key, LRU, cap and round-trip headless.
final class DisplayImageDiskCache: @unchecked Sendable {

    static let capBytes = 512 * 1024 * 1024
    static let formatVersion = "v1"

    static var enabled: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    static let shared = DisplayImageDiskCache(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DisplayImages", isDirectory: true)
            .appendingPathComponent(formatVersion, isDirectory: true),
        cap: capBytes)

    let directory: URL
    let cap: Int
    private let queue = DispatchQueue(label: "airpad.displayimage.disk", qos: .utility)
    /// Only touched on `queue`. Loaded from the folder on first use.
    private var lru: DiskCacheLRU?
    /// Files already touched this launch (an LRU touch writes the file's date once, not on every hit). On `queue`.
    private var touched: Set<String> = []

    // MARK: Counters (the 4.5 proof: a cold launch shows the library's images from disk, no original decoded again)
    private let counterLock = NSLock()
    private var counters = Counters()
    struct Counters: Equatable {
        var diskHits = 0, diskMisses = 0, originalDecodes = 0, posterExtracts = 0, writes = 0, evictions = 0, writesSkipped = 0
        var writtenBytes = 0
    }
    var snapshot: Counters { counterLock.lock(); defer { counterLock.unlock() }; return counters }
    /// Called (debounced, off the main thread) with a one-line summary after the counters change. The app hangs the
    /// perf recorder's mark and the DEBUG / PERFLOG log on it.
    var onReport: (@Sendable (String) -> Void)? {
        get { counterLock.lock(); defer { counterLock.unlock() }; return report }
        set { counterLock.lock(); report = newValue; counterLock.unlock() }
    }
    private var report: (@Sendable (String) -> Void)?
    private var reportScheduled = false
    /// Decoded images waiting for their encode + write (each up to ~25 MB at 3072 px, outside the memory cache's limit):
    /// past `maxPendingWrites` a write is skipped (that photo is written on a later launch). Under `counterLock`.
    private var pendingWrites = 0
    static let maxPendingWrites = 4

    init(directory: URL, cap: Int) {
        self.directory = directory
        self.cap = cap
    }

    // MARK: - Key

    /// The disk key for one decode of the file at `url` at `bucket`, or nil when the original can't be stat'ed.
    /// `memoryKey` is `DisplayImageCache`'s path key (`<entry id>/<relative path>`, or an absolute path).
    static func key(memoryKey: String, bucket: Int, url: URL) -> String? {
        var fresh = url
        fresh.removeAllCachedResourceValues()   // a URL caches its resource values: a reused one would hide a change
        guard let v = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = v.contentModificationDate else { return nil }
        return key(memoryKey: memoryKey, bucket: bucket, modified: modified, size: v.fileSize ?? -1)
    }

    static func key(memoryKey: String, bucket: Int, modified: Date, size: Int) -> String {
        let ms = Int64((modified.timeIntervalSince1970 * 1000).rounded())
        let raw = "\(formatVersion)|\(memoryKey)|\(bucket)|\(ms)|\(size)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key, isDirectory: false) }

    // MARK: - Read (the caller's thread: the decode task, never the main thread)

    /// The cached decode for `key`, decoded now, or nil.
    func read(_ key: String) -> CGImage? {
        let url = fileURL(key)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              cg.width > 0, cg.height > 0 else {
            count { $0.diskMisses += 1 }
            return nil
        }
        count { $0.diskHits += 1 }
        queue.async { self.touch(key) }
        return cg
    }

    /// Counts a decode of an ORIGINAL file (a miss below this cache: the expensive path the cache is there to avoid).
    func noteOriginalDecode() { count { $0.originalDecodes += 1 } }
    func notePosterExtract() { count { $0.posterExtracts += 1 } }

    // MARK: - Write (off the caller: the serial utility queue)

    /// Encodes and stores `image` under `key`, then trims to the cap. Returns at once.
    func write(_ image: CGImage, key: String) {
        counterLock.lock()
        let full = pendingWrites >= Self.maxPendingWrites
        if !full { pendingWrites += 1 }
        counterLock.unlock()
        if full { count { $0.writesSkipped += 1 }; return }
        queue.async {
            self.writeNow(image, key: key)
            self.counterLock.lock(); self.pendingWrites -= 1; self.counterLock.unlock()
        }
    }

    /// Waits for every queued write / trim (tests, the self-test). Never from `queue` itself (nor from `onReport`).
    func flush() { queue.sync {} }

    private func writeNow(_ image: CGImage, key: String) {
        guard let data = Self.encode(image) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(key), options: .atomic)
        } catch { return }
        var lru = loadedLRU()
        let victims = lru.put(key, bytes: data.count, now: Date().timeIntervalSince1970)
        self.lru = lru
        touched.insert(key)
        for v in victims { try? fm.removeItem(at: fileURL(v)) }
        count { $0.writes += 1; $0.writtenBytes += data.count; $0.evictions += victims.count }
    }

    /// JPEG (quality 0.85) for an opaque image, PNG when it carries alpha.
    static func encode(_ image: CGImage) -> Data? {
        let alpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        let out = NSMutableData()
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let props: [CFString: Any] = alpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - LRU index (on `queue`)

    private func loadedLRU() -> DiskCacheLRU {
        if let lru { return lru }
        var fresh = DiskCacheLRU(cap: cap)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var entries: [(String, Int, Double)] = []
        for f in files {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            entries.append((f.lastPathComponent, v.fileSize ?? 0, v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        let victims = fresh.load(entries)
        for v in victims { try? fm.removeItem(at: fileURL(v)) }
        if !victims.isEmpty { count { $0.evictions += victims.count } }
        lru = fresh
        return fresh
    }

    /// A hit: most recently used now, in the index and (once per launch) on the file's date, so the order survives
    /// a relaunch.
    private func touch(_ key: String) {
        var lru = loadedLRU()
        let now = Date()
        lru.touch(key, now: now.timeIntervalSince1970)
        self.lru = lru
        guard touched.insert(key).inserted else { return }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fileURL(key).path)
    }

    /// Bytes and files the index holds right now (after loading it). Never from `queue` (nor from `onReport`).
    func usage() -> (files: Int, bytes: Int) {
        queue.sync { let l = loadedLRU(); return (l.count, l.total) }
    }

    /// Empties the folder (tests; a future "clear caches"). Never from `queue` (nor from `onReport`).
    func removeAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            lru = DiskCacheLRU(cap: cap)
            touched.removeAll()
        }
    }

    // MARK: - Counters

    private func count(_ change: (inout Counters) -> Void) {
        counterLock.lock()
        change(&counters)
        let schedule = !reportScheduled && report != nil
        if schedule { reportScheduled = true }
        counterLock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.counterLock.lock(); self.reportScheduled = false; let c = self.counters; let r = self.report; self.counterLock.unlock()
            let l = self.loadedLRU()
            r?(Self.summary(c, files: l.count, bytes: l.total, cap: self.cap))
        }
    }

    static func summary(_ c: Counters, files: Int, bytes: Int, cap: Int) -> String {
        "thumbs disk-hits \(c.diskHits) disk-misses \(c.diskMisses) original-decodes \(c.originalDecodes) "
            + "poster-extracts \(c.posterExtracts) writes \(c.writes) write-skipped \(c.writesSkipped) evicted \(c.evictions) "
            + "on-disk \(files) files \(bytes / 1_048_576) MB cap \(cap / 1_048_576) MB"
    }
}

/// Sweep 2b · 4.5 — the disk cache's least-recently-used index: pure bookkeeping (no I/O), so the cap logic is testable.
/// `put` / `load` return the keys the caller must delete. Over the cap it trims to `lowWater` (80 % of the cap),
/// oldest first, and never evicts the entry just written unless that entry alone is bigger than the cap.
struct DiskCacheLRU {
    struct Entry { var bytes: Int; var lastUse: Double }
    let cap: Int
    var lowWater: Int { cap / 5 * 4 }
    private(set) var entries: [String: Entry] = [:]
    private(set) var total = 0
    var count: Int { entries.count }

    init(cap: Int) { self.cap = cap }

    /// Seeds the index from the folder's files (name, bytes, last use); returns what to delete to get under the cap.
    mutating func load(_ files: [(String, Int, Double)]) -> [String] {
        entries = [:]; total = 0
        for (k, b, t) in files { entries[k] = Entry(bytes: b, lastUse: t); total += b }
        return trim(keeping: nil)
    }

    mutating func put(_ key: String, bytes: Int, now: Double) -> [String] {
        if let old = entries[key] { total -= old.bytes }
        entries[key] = Entry(bytes: bytes, lastUse: now)
        total += bytes
        if bytes > cap { entries[key] = nil; total -= bytes; return [key] + trim(keeping: nil) }
        return trim(keeping: key)
    }

    mutating func touch(_ key: String, now: Double) {
        entries[key]?.lastUse = now
    }

    mutating func remove(_ key: String) {
        if let e = entries.removeValue(forKey: key) { total -= e.bytes }
    }

    private mutating func trim(keeping: String?) -> [String] {
        guard total > cap else { return [] }
        var victims: [String] = []
        for (k, e) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse || ($0.value.lastUse == $1.value.lastUse && $0.key < $1.key) }) {
            guard total > lowWater else { break }
            if k == keeping { continue }
            entries[k] = nil; total -= e.bytes; victims.append(k)
        }
        return victims
    }
}
