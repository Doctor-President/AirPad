import Foundation
import os

extension Notification.Name {
    /// Mac batch B1 — library files changed on disk (another device, via iCloud). userInfo: `nodes` (Set<String> of
    /// entry ids), `files` (Set<String> of library-file names: tags.json, chats.json, …). Posted on the main queue.
    static let librarySyncChanged = Notification.Name("AirPad.librarySyncChanged")
}

/// Mac batch B1 — learns about changes another device made while the app runs.
/// - An `NSFilePresenter` on the library root: iCloud's daemon coordinates its downloads, so a synced change, a new
///   entry, a deletion or a new conflict version arrives here.
/// - A cheap rescan (modification dates only) when the app comes forward, as a backstop, and on a timer under the
///   DEBUG two-device harness (`-SyncPollSeconds`), whose stand-in for iCloud writes without coordination.
/// The store decides what each change means (`CorpusStore.librarySyncChanged`); the app's own writes come back
/// here too and are dropped there by hash.
final class LibraryWatcher: NSObject, NSFilePresenter {
    private static let current = OSAllocatedUnfairLock<LibraryWatcher?>(initialState: nil)
    /// Passed to every coordinated write so the app isn't told about its own writes.
    static var presenter: LibraryWatcher? { current.withLock { $0 } }

    let root: URL
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "AirPad.LibraryWatcher"
        return q
    }()

    private let state = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var pendingNodes = Set<String>()
        var pendingFiles = Set<String>()
        var flushScheduled = false
        var snapshot: [String: Date] = [:]
    }
    private var pollTimer: DispatchSourceTimer?

    private init(root: URL) {
        self.root = root.standardizedFileURL
        self.presentedItemURL = root
        super.init()
    }

    /// Starts watching `root` (once per run).
    static func start(root: URL) {
        let w = current.withLock { cur -> LibraryWatcher? in
            guard cur == nil else { return nil }
            let w = LibraryWatcher(root: root)
            cur = w
            return w
        }
        guard let w else { return }
        NSFileCoordinator.addFilePresenter(w)
        DispatchQueue.global(qos: .utility).async { w.rescan(report: false) }
        #if DEBUG
        let poll = UserDefaults.standard.double(forKey: "SyncPollSeconds")
        if poll > 0 {
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + poll, repeating: poll)
            t.setEventHandler { [weak w] in w?.rescan(report: true) }
            t.resume()
            w.pollTimer = t
        }
        #endif
        print("[Sync] watching \(root.lastPathComponent) (device \(SyncDevice.id) \(SyncDevice.label))")
    }

    /// The app came forward: look for anything that changed while it was away.
    static func rescanNow() {
        guard let w = presenter else { return }
        DispatchQueue.global(qos: .utility).async { w.rescan(report: true) }
    }

    // MARK: NSFilePresenter

    func presentedSubitemDidChange(at url: URL) { note(url) }
    func presentedSubitemDidAppear(at url: URL) { note(url) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { note(oldURL); note(newURL) }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { note(url) }
    func presentedSubitem(at url: URL, didResolve version: NSFileVersion) { note(url) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        note(url)
        completionHandler(nil)
    }

    // MARK: Classify + deliver

    private func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path) else { return }
        let rel = path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        guard let first = rel.first else { return }
        state.withLock { s in
            if first == "nodes" {
                if rel.count >= 2 { s.pendingNodes.insert(Self.entryID(fromDir: rel[1])) }
            } else if rel.count == 1, first.hasSuffix(".json") {
                s.pendingFiles.insert(first)
            }
        }
        scheduleFlush()
    }

    /// `nodes/<id>` → id. An iCloud directory conflict copy (`<id> 2`) belongs to `<id>`.
    static func entryID(fromDir dir: String) -> String {
        if let r = dir.range(of: #" \d+$"#, options: .regularExpression) { return String(dir[..<r.lowerBound]) }
        return dir
    }

    private func scheduleFlush() {
        let schedule = state.withLock { s -> Bool in
            guard !s.flushScheduled else { return false }
            s.flushScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let (nodes, files) = self.state.withLock { s -> (Set<String>, Set<String>) in
                defer { s.pendingNodes = []; s.pendingFiles = []; s.flushScheduled = false }
                return (s.pendingNodes, s.pendingFiles)
            }
            guard !nodes.isEmpty || !files.isEmpty else { return }
            NotificationCenter.default.post(name: .librarySyncChanged, object: nil,
                                            userInfo: ["nodes": nodes, "files": files])
        }
    }

    // MARK: Rescan (modification dates)

    private func rescan(report: Bool) {
        let fm = FileManager.default
        var snap: [String: Date] = [:]
        let stat = { (url: URL) -> Date? in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        let nodes = root.appendingPathComponent("nodes")
        for dir in (try? fm.contentsOfDirectory(atPath: nodes.path)) ?? [] where !dir.hasPrefix(".") {
            let d = nodes.appendingPathComponent(dir)
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".json") || f.hasSuffix(".icloud") || f == ".conflicts" {
                snap["nodes/\(dir)/\(f)"] = stat(d.appendingPathComponent(f))
            }
            snap["nodes/\(dir)"] = snap["nodes/\(dir)"] ?? .distantPast
        }
        for f in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where f.hasSuffix(".json") {
            snap[f] = stat(root.appendingPathComponent(f))
        }
        let fresh = snap
        let old = state.withLock { s -> [String: Date] in defer { s.snapshot = fresh }; return s.snapshot }
        guard report else { return }
        var changed = Set<String>()
        for (k, v) in snap where old[k] != v { changed.insert(k) }
        for k in old.keys where snap[k] == nil { changed.insert(k) }
        for k in changed { note(root.appendingPathComponent(k)) }
    }
}
