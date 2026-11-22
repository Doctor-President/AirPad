#if targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Sweep 2b · 4.6 — "Keep the library downloaded on the Mac" (ruled 11-20; T's library would pin ≈ 3 GB < 5 GB → on).
///
/// T's slow first images after a build were mostly iCloud placeholders being fetched (the Mac at ~37 GB free evicts
/// iCloud files under "Optimize Mac Storage"). There is **no public API to pin** an item in an app's iCloud container:
/// Finder's "Keep Downloaded" (NSFileProviderContentPolicy `.downloadEagerlyAndKeepDownloaded`, stored as the
/// `com.apple.fileprovider.pinned` attribute) is reserved for user action — Apple DTS, developer.apple.com/forums/thread/756963
/// ("There is no API for developers to programmatically set the option"). So the app does the next best thing with the
/// public API: it finds the library's files macOS has evicted and asks iCloud to download them again
/// (`FileManager.startDownloadingUbiquitousItem(at:)`), at launch, when the app comes back to the front (at most every 10
/// min), and every 30 min while it runs. It cannot stop an eviction while AirPad is closed; it undoes it on the next run.
///
///   - Never writes a library file or attribute (the format rule): reads resource values, calls the download request.
///   - Off the main thread (a detached utility task), throttled: 16 requests, then waits until at most 16 of those are
///     still not downloaded (polled each second, up to a minute) before the next 16 — iCloud is never handed the
///     whole library at once.
///   - The Mac only (this file is Catalyst-only); the iPhone is unchanged.
///   - Switch: About › Version ×5 › "Mac feel (testing)" (DEVSWITCHES builds) turns it off; off = no more requests (a
///     sweep in progress stops before its next 16); already-downloaded files stay as they are, and macOS may evict them
///     again as before. App Store builds: always on.
///   - Each sweep logs what it found (files and bytes in the library, how many macOS evicted and their bytes, how many it
///     requested) via `MacProofLog` — the "measure what it pins" number, on any library.
enum MacKeepDownloaded {
    #if DEBUG || DEVSWITCHES
    static let key = "mac.keepDownloaded"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    #else
    static var isOn: Bool { true }
    #endif
}

/// What one sweep found (numbers only).
struct LibraryDownloadScan: Sendable {
    var files = 0
    var bytes: Int64 = 0
    var iCloudFiles = 0
    var evicted: [URL] = []
    var evictedBytes: Int64 = 0
    var downloading = 0

    var line: String {
        func mb(_ b: Int64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
        return "files \(files) (\(mb(bytes))) · iCloud \(iCloudFiles) · not downloaded \(evicted.count) (\(mb(evictedBytes))) · downloading \(downloading)"
    }
}

actor MacLibraryKeeper {
    static let shared = MacLibraryKeeper()

    static let batchSize = 16
    static let resweepEvery: Duration = .seconds(30 * 60)
    static let activeMinInterval: TimeInterval = 10 * 60

    private var root: URL?
    private var sweep: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastSweep: Date?
    private var observer: NSObjectProtocol?
    /// The last sweep's line, for the Mac feel panel (read on the main thread; written there too).
    @MainActor static var lastSummary = "not run yet"

    /// After the library's first load: sweep now, then on activation and on the timer.
    func start(root: URL) {
        guard self.root == nil else { return }
        self.root = root
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await MacLibraryKeeper.shared.kick("active", minInterval: Self.activeMinInterval) }
        }
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.resweepEvery)
                self.kick("timer")
            }
        }
        kick("launch")
    }

    /// Starts a sweep unless one runs, the switch is off, or the last one is younger than `minInterval`.
    func kick(_ reason: String, minInterval: TimeInterval = 0) {
        guard let root, sweep == nil, MacKeepDownloaded.isOn else { return }
        if let lastSweep, Date().timeIntervalSince(lastSweep) < minInterval { return }
        lastSweep = Date()
        sweep = Task.detached(priority: .utility) {
            let summary = await Self.run(root: root, reason: reason)
            await self.finished(summary)
        }
    }

    /// The switch moved: off cancels a running sweep (it stops before its next batch); on sweeps now.
    func switchChanged() {
        if MacKeepDownloaded.isOn { kick("switch on") } else { sweep?.cancel(); MacProofLog.note("4.6", "switch off: no more download requests") }
    }

    private func finished(_ summary: String) async {
        sweep = nil
        await MainActor.run { Self.lastSummary = summary }
    }

    // MARK: - The sweep (a detached utility task)

    static func run(root: URL, reason: String) async -> String {
        let t0 = ContinuousClock.now
        #if DEBUG || PERFLOG
        let fake = UserDefaults.standard.bool(forKey: "KeeperFakeEvicted")
        #else
        let fake = false
        #endif
        let scan = Self.scan(root: root, fakeEvictedEvery: fake ? 3 : 0)
        MacProofLog.note("4.6", "sweep \(reason): \(scan.line)\(fake ? " · FAKE (every 3rd file, no requests sent)" : "")")
        var requested = 0, batches = 0, stopped = false
        var pending: [URL] = []
        var queue = scan.evicted[...]
        while !queue.isEmpty {
            guard MacKeepDownloaded.isOn, !Task.isCancelled else { stopped = true; break }
            let batch = queue.prefix(batchSize)
            queue = queue.dropFirst(batch.count)
            for url in batch {
                if !fake { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
                requested += 1
            }
            batches += 1
            pending += batch
            MacProofLog.note("4.6", "batch \(batches): requested \(requested)/\(scan.evicted.count) · in flight \(pending.count)")
            // Throttle: the next batch only once at most one batch is still on its way (a minute at most).
            for _ in 0..<60 {
                pending = fake ? [] : pending.filter(Self.notDownloaded)
                if pending.count <= batchSize || Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(1))
            }
            if fake { try? await Task.sleep(for: .milliseconds(500)) }   // stands in for iCloud's time
        }
        let secs = Double((ContinuousClock.now - t0) / .milliseconds(1)) / 1000
        let done = scan.iCloudFiles == 0 && !fake ? "not an iCloud library: nothing to keep"
            : "requested \(requested) in \(batches) batch(es)\(stopped ? " · STOPPED (switch off)" : "")"
        let summary = "\(scan.line) · \(done) · \(String(format: "%.1f", secs)) s"
        MacProofLog.note("4.6", "sweep \(reason) end: \(summary) · main thread \(Thread.isMainThread ? "YES" : "no")")
        return summary
    }

    /// Walks the library (hidden files too: an old-style placeholder is `.<name>.icloud`). Reads resource values only.
    static func scan(root: URL, fakeEvictedEvery: Int = 0) -> LibraryDownloadScan {
        var s = LibraryDownloadScan()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isUbiquitousItemKey,
                                      .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return s }
        var k = 0
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 {
                let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                s.files += 1; s.iCloudFiles += 1; s.evicted.append(real)
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            s.files += 1; s.bytes += size
            if v.isUbiquitousItem == true {
                s.iCloudFiles += 1
                if v.ubiquitousItemDownloadingStatus == .notDownloaded {
                    if v.ubiquitousItemIsDownloading == true { s.downloading += 1 } else { s.evicted.append(url); s.evictedBytes += size }
                }
            } else if fakeEvictedEvery > 0 {
                k += 1
                if k % fakeEvictedEvery == 0 { s.evicted.append(url); s.evictedBytes += size }
            }
        }
        return s
    }

    /// Still not downloaded? A fresh URL each time (a URL caches its resource values).
    private static func notDownloaded(_ url: URL) -> Bool {
        let u = URL(fileURLWithPath: url.path)
        // No status (not there yet under its real name, or not iCloud) → not waited for.
        guard let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        else { return false }
        return status == .notDownloaded
    }
}
#endif
