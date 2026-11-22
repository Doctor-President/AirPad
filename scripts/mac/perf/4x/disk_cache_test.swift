// Sweep 2b · 4.5 — headless check of DisplayImageDiskCache (key, LRU, cap, round-trip, reload). No app, no Simulator.
// Run: zsh scripts/mac/perf/4x/disk_cache_test.sh   (compiles this with AirPad/Services/DisplayImageDiskCache.swift)
import Foundation
import CoreGraphics
import ImageIO

var fails = 0, passes = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")"); if ok { passes += 1 } else { fails += 1 }
}
func image(_ w: Int, _ h: Int, alpha: Bool, seed: UInt32) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    var g = seed
    for y in stride(from: 0, to: h, by: 8) { for x in stride(from: 0, to: w, by: 8) {
        g = g &* 1664525 &+ 1013904223
        ctx.setFillColor(red: CGFloat(g & 255) / 255, green: CGFloat((g >> 8) & 255) / 255, blue: CGFloat((g >> 16) & 255) / 255, alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
    } }
    return ctx.makeImage()!
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("4x-disk-cache-test-\(getpid())")

try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// 1. Key: stable, and changes with bucket, modification date, size and path.
let d = Date(timeIntervalSince1970: 1_790_000_000.123)
let k = DisplayImageDiskCache.key(memoryKey: "E1/items/a.jpg", bucket: 768, modified: d, size: 100)
check("key-stable", k == DisplayImageDiskCache.key(memoryKey: "E1/items/a.jpg", bucket: 768, modified: d, size: 100))
check("key-hex-64", k.count == 64 && k.allSatisfy { $0.isHexDigit })
check("key-bucket", k != DisplayImageDiskCache.key(memoryKey: "E1/items/a.jpg", bucket: 1024, modified: d, size: 100))
check("key-mtime", k != DisplayImageDiskCache.key(memoryKey: "E1/items/a.jpg", bucket: 768, modified: d.addingTimeInterval(1), size: 100))
check("key-size", k != DisplayImageDiskCache.key(memoryKey: "E1/items/a.jpg", bucket: 768, modified: d, size: 101))
check("key-path", k != DisplayImageDiskCache.key(memoryKey: "E2/items/a.jpg", bucket: 768, modified: d, size: 100))
// From a real file: touching the original changes the key (a changed original is never served stale).
let orig = tmp.appendingPathComponent("orig.bin"); try! Data(repeating: 1, count: 10).write(to: orig)
let kf1 = DisplayImageDiskCache.key(memoryKey: "E1/orig.bin", bucket: 256, url: orig)
try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: orig.path)
let kf2 = DisplayImageDiskCache.key(memoryKey: "E1/orig.bin", bucket: 256, url: orig)
check("key-from-file-follows-mtime", kf1 != nil && kf2 != nil && kf1 != kf2)
check("key-missing-file-nil", DisplayImageDiskCache.key(memoryKey: "x", bucket: 256, url: tmp.appendingPathComponent("none")) == nil)

// 2. LRU (pure): trims oldest first to 80 % once over the cap; keeps the entry just written; rejects one bigger than the cap.
var lru = DiskCacheLRU(cap: 1000)
check("lru-under-cap", lru.put("a", bytes: 300, now: 1).isEmpty && lru.put("b", bytes: 300, now: 2).isEmpty && lru.put("c", bytes: 300, now: 3).isEmpty)
lru.touch("a", now: 4)                              // a is now the most recent
let v1 = lru.put("d", bytes: 300, now: 5)           // 1200 > 1000 → trim to ≤ 800: b (2) then c (3)
check("lru-evicts-oldest-first", v1 == ["b", "c"], "\(v1)")
check("lru-total-after-trim", lru.total == 600 && lru.count == 2, "total \(lru.total) count \(lru.count)")
let v2 = lru.put("huge", bytes: 5000, now: 6)
check("lru-rejects-oversize", v2.first == "huge" && lru.entries["huge"] == nil, "\(v2)")
let v3 = lru.put("a", bytes: 900, now: 7)           // replace a: 300 → 900; total 1200 → trim keeps a, drops d
check("lru-replace-keeps-new", v3 == ["d"] && lru.entries["a"]?.bytes == 900, "\(v3)")
var lru2 = DiskCacheLRU(cap: 1000)
let v4 = lru2.load([("x", 600, 1), ("y", 600, 2), ("z", 100, 3)])
check("lru-load-trims", v4 == ["x"] && lru2.total == 700, "\(v4) total \(lru2.total)")

// 3. Round trip on disk: opaque → JPEG, alpha → PNG; read back at the same size; counters.
let dir = tmp.appendingPathComponent("cache")
let cache = DisplayImageDiskCache(directory: dir, cap: 2 * 1024 * 1024)
let opaque = image(768, 512, alpha: false, seed: 1), clear = image(256, 256, alpha: true, seed: 2)
cache.write(opaque, key: "k-opaque"); cache.write(clear, key: "k-alpha"); cache.flush()
let r1 = cache.read("k-opaque"), r2 = cache.read("k-alpha"), r3 = cache.read("k-none")
check("roundtrip-opaque", r1?.width == 768 && r1?.height == 512)
check("roundtrip-alpha", r2?.width == 256 && (r2.map { ![.none, .noneSkipLast, .noneSkipFirst].contains($0.alphaInfo) } ?? false))
check("miss-nil", r3 == nil)
func typeOf(_ key: String) -> String {
    let s = CGImageSourceCreateWithURL(dir.appendingPathComponent(key) as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
    return s ?? "?"
}
check("format-jpeg-png", typeOf("k-opaque") == "public.jpeg" && typeOf("k-alpha") == "public.png", "\(typeOf("k-opaque")) / \(typeOf("k-alpha"))")
cache.flush()
let c = cache.snapshot
check("counters", c.diskHits == 2 && c.diskMisses == 1 && c.writes == 2, "\(c)")

// 4. The cap is enforced on disk: write ~12 × ~300 KB into a 2 MB cache → at most 2 MB stays; the newest survive.
for i in 0..<12 { cache.write(image(1024, 768, alpha: false, seed: UInt32(100 + i)), key: "big-\(i)"); cache.flush() }
cache.flush()
let onDisk = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
let bytes = onDisk.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
let u = cache.usage()
check("cap-enforced-on-disk", bytes <= 2 * 1024 * 1024 && u.bytes == bytes && u.files == onDisk.count, "\(onDisk.count) files \(bytes) B, index \(u)")
check("newest-survive", cache.read("big-11") != nil && cache.read("k-opaque") == nil)
check("evictions-counted", cache.snapshot.evictions > 0, "\(cache.snapshot.evictions)")

// 5. A new instance (a relaunch) rebuilds the index from the folder and serves the same files.
let again = DisplayImageDiskCache(directory: dir, cap: 2 * 1024 * 1024)
check("relaunch-index", again.usage().bytes == bytes)
check("relaunch-hit", again.read("big-11")?.width == 1024)
// …and a smaller cap on relaunch trims at once.
let smaller = DisplayImageDiskCache(directory: dir, cap: 600 * 1024)
let su = smaller.usage()
check("relaunch-smaller-cap-trims", su.bytes <= 600 * 1024, "\(su)")

print("\n\(fails == 0 ? "PASS" : "FAIL") \(passes)/\(passes + fails)")
try? FileManager.default.removeItem(at: tmp)
exit(fails == 0 ? 0 : 1)
