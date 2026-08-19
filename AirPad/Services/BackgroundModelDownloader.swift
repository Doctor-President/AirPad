import Foundation
import Hub
import CryptoKit

/// Option C (ws-bg-download) — downloads the on-device model's files with a
/// **background** `URLSession` (`URLSessionDownloadTask` per file), so the transfer
/// survives app suspension/termination and the system relaunches us on completion.
///
/// HubApi is used ONLY to resolve the file list + per-file size (`getFilenames` /
/// `getFileMetadata`); the transfer is ours. This is deliberately pin-independent —
/// it needs nothing from swift-transformers beyond those two public calls.
///
/// ★ Progress is **BYTE-BASED** — `Σ bytes on disk / Σ expected bytes` — never
/// file-count (BUG 35: HubApi's own snapshot progress weighted each file as one
/// unit regardless of size and shuffled file order, so the % lied and jumped
/// backwards). Files are written into `modelDirectory` (= `config.modelDirectory(hub:)`);
/// `loadContainer` (in `LocalModelService.load()`, untouched) then hash-validates and
/// accepts that directory — spike-verified, no re-download of the weights.
///
/// Delegate callbacks arrive on the session's private serial queue; internal state is
/// lock-guarded and all owner callbacks are hopped to the main thread.
final class BackgroundModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// The system background-session identifier. FIXED (not per-instance) so the
    /// session can be re-attached across launches to reconnect to in-flight transfers.
    static let sessionIdentifier = "com.doctorpresident.airpad.bgmodeldl"

    /// Honest, distinguishable terminal reasons (BUG 35 §7 — no silent stalls).
    enum Failure: Equatable {
        case cancelled
        case networkUnavailable
        case diskFull
        case integrityFailed(String)   // a finished file's byte size != the expected size
        case other(String)             // verbatim, never swallowed
    }

    // Owner callbacks — always invoked on the MAIN thread.
    var onProgress: ((Double) -> Void)?     // byte fraction 0...1, monotonic within a run
    var onPaused: ((Double) -> Void)?       // waiting for connectivity; keeps the byte fraction
    var onCompleted: (() -> Void)?
    var onFailed: ((Failure) -> Void)?

    private let hub: HubApi
    private let repoID: String
    private let modelDir: URL                 // = config.modelDirectory(hub:)
    private let stateDir: URL                 // <downloadBase>/.bgdl — OUR bookkeeping, NOT HubApi's .cache

    private let lock = NSLock()
    private var manifest: Manifest?
    private var running: [String: Int64] = [:]   // filename -> totalBytesWritten this run (incl. resumed offset)
    private var userCancelled = false
    private var lastPublish = Date(timeIntervalSince1970: 0)

    /// Handed to us by the AppDelegate on relaunch; called once the session's events drain.
    private var backgroundCompletionHandler: (() -> Void)?

    init(hub: HubApi, repoID: String, modelDir: URL, downloadBase: URL) {
        self.hub = hub
        self.repoID = repoID
        self.modelDir = modelDir
        self.stateDir = downloadBase.appendingPathComponent(".bgdl", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        manifest = loadManifest()
    }

    /// The single background session (fixed identifier). Lazy so it's created exactly once;
    /// touching it on launch reconnects to any transfers the system kept running.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false            // start now, don't defer to a "good time"
        cfg.sessionSendsLaunchEvents = true     // relaunch the app when the transfer finishes
        cfg.waitsForConnectivity = true         // offline => PAUSE (honest), not a hard failure
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Manifest (persisted resume state, survives launches)

    struct Manifest: Codable {
        // commitHash + etag come from the getFileMetadata call we already make; they're what HubApi's
        // per-file `.metadata` sidecar needs (Fix Path A). An old manifest (pre-fix, missing these) just
        // fails to decode → treated as no manifest; harmless, the repair path covers it.
        struct File: Codable {
            let name: String; let urlString: String; let expectedSize: Int64
            let commitHash: String; let etag: String; var done: Bool
        }
        let repoID: String
        var files: [File]
        var totalBytes: Int64
        var isActive: Bool          // a download was started and not completed/cancelled
    }

    private var manifestURL: URL { stateDir.appendingPathComponent("manifest.json") }
    private func loadManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
    private func saveManifest() {
        lock.lock(); let m = manifest; lock.unlock()
        guard let m, let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func resumeDataURL(_ name: String) -> URL {
        stateDir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_") + ".resume")
    }
    private func saveResumeData(_ data: Data, name: String) { try? data.write(to: resumeDataURL(name), options: .atomic) }
    private func loadResumeData(_ name: String) -> Data? { try? Data(contentsOf: resumeDataURL(name)) }
    private func deleteResumeData(_ name: String) { try? FileManager.default.removeItem(at: resumeDataURL(name)) }

    // MARK: - Public API

    /// True if a download was started and hasn't completed/cancelled — drives auto-resume-on-launch.
    var hasActiveDownload: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let m = manifest else { return false }
        return m.isActive && !m.files.allSatisfy(\.done)
    }

    /// Resolve the repo file list + sizes via HubApi, then start a background download task per file.
    /// Throws only on the resolve step (no network / repo error); per-file transfer errors come back
    /// through the delegate as `onFailed`/`onPaused`.
    func start() async throws {
        lock.lock(); userCancelled = false; lock.unlock()
        let repo = Hub.Repo(id: repoID)
        let names = try await hub.getFilenames(from: repo, matching: ["*.safetensors", "*.json"]).sorted()
        var files: [Manifest.File] = []
        var total: Int64 = 0
        for name in names {
            // Ask HubApi for the size (LFS-accurate). Download the STABLE resolve URL (it 302s to a
            // fresh CDN URL each attempt — robust for resume, unlike a signed CDN URL that expires).
            let meta = try await hub.getFileMetadata(url: resolveURL(name))
            let size = Int64(meta.size ?? 0)
            files.append(.init(name: name, urlString: resolveURL(name).absoluteString,
                               expectedSize: size,
                               commitHash: meta.commitHash ?? "", etag: meta.etag ?? "",
                               done: isFileComplete(name, expected: size)))
            total += size
        }
        lock.lock()
        if userCancelled { lock.unlock(); return }   // cancelled during the metadata fetch — honour it
        manifest = Manifest(repoID: repoID, files: files, totalBytes: total, isActive: true)
        running.removeAll()
        lock.unlock()
        saveManifest()

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        for f in files where !f.done { startTask(for: f) }
        publishProgress(force: true)
    }

    /// On launch: reconnect to any transfers the system kept running, reconcile against disk, and
    /// resume anything missing — WITHOUT a manual re-tap (BUG 35 §3).
    func reattach() {
        _ = session                        // recreate the session -> reconnect to background tasks
        lock.lock(); let m = manifest; lock.unlock()
        guard let m, m.isActive else { return }

        // Reconcile against disk first: files that finished (correct size) while we were gone.
        var reconciled = m
        for i in reconciled.files.indices where !reconciled.files[i].done {
            if isFileComplete(reconciled.files[i].name, expected: reconciled.files[i].expectedSize) {
                reconciled.files[i].done = true
            }
        }
        lock.lock(); manifest = reconciled; lock.unlock(); saveManifest()

        if reconciled.files.allSatisfy(\.done) { finishActive(); publishCompleted(); return }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let runningNames = Set(tasks.compactMap { $0.taskDescription })
            self.lock.lock(); let files = self.manifest?.files ?? []; self.lock.unlock()
            for f in files where !f.done && !runningNames.contains(f.name) { self.startTask(for: f) }
            self.publishProgress(force: true)   // reflect "downloading X%", never "not downloaded"
        }
    }

    /// User cancel = cancel. Stop every task, delete the partials + our bookkeeping, mark inactive.
    /// (This is what makes cancel honest — the old `deletePartialDownload` never fired because a
    /// cancelled transfer surfaced as `URLError.cancelled`, not `CancellationError`.)
    func cancel() {
        lock.lock(); userCancelled = true; manifest?.isActive = false; lock.unlock()
        saveManifest()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        cleanupPartials()
    }

    /// AppDelegate hands us the background completion handler on relaunch; we call it once the
    /// session's queued events have been delivered (`urlSessionDidFinishEvents`).
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock(); backgroundCompletionHandler = handler; lock.unlock()
        _ = session   // ensure the session exists so its events flush and the delegate fires
    }

    enum RepairError: LocalizedError {
        case incompleteFileSet(String)
        case integrityFailed(String)
        var errorDescription: String? {
            switch self {
            case let .incompleteFileSet(n): return "The model download is incomplete (missing or wrong-size \(n)). Delete and re-download to finish."
            case let .integrityFailed(n): return "A model file failed its integrity check (\(n)). Delete and re-download to fix."
            }
        }
    }

    /// ★ Fix Path A — REPAIR. For an install whose weights are on disk but whose HubApi `.metadata`
    /// sidecars are missing (e.g. a pre-fix download), re-fetch metadata (HEAD only, NO body) and write
    /// the sidecars so the OFFLINE load path succeeds. No-ops with NO network once the sidecars exist —
    /// so only the first post-fix load pays for it; it is never a per-load cost.
    func ensureSidecars() async throws {
        if sidecarsComplete() { return }
        let names = try await hub.getFilenames(from: Hub.Repo(id: repoID), matching: ["*.safetensors", "*.json"]).sorted()
        // Every file must be present before we vouch for it with a sidecar.
        for name in names where !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(name).path) {
            throw RepairError.incompleteFileSet(name)
        }
        for name in names {
            let dest = modelDir.appendingPathComponent(name)
            let meta = try await hub.getFileMetadata(url: resolveURL(name))   // HEAD; no body
            if let sz = meta.size, sz > 0, fileSize(dest) != Int64(sz) { throw RepairError.incompleteFileSet(name) }
            let etag = meta.etag ?? ""
            writeSidecar(name: name, commitHash: meta.commitHash ?? "", etag: etag)
            // Same one-time LFS check as the download path — surface a CLEAR error here rather than
            // letting loadContainer throw its opaque "Hash mismatch" (HubApi.swift:605).
            if etag.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, let computed = sha256Hex(of: dest) {
                let ok = computed == etag
                print("[bgdl] repair LFS verify \(name): → \(ok ? "MATCH" : "MISMATCH")")
                if !ok { throw RepairError.integrityFailed(name) }
            }
        }
    }

    // MARK: - Internals

    private func resolveURL(_ name: String) -> URL {
        URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(name)")!
    }

    private func isFileComplete(_ name: String, expected: Int64) -> Bool {
        let url = modelDir.appendingPathComponent(name)
        guard let size = fileSize(url) else { return false }
        return expected > 0 ? size == expected : size > 0
    }
    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
    }

    private func startTask(for file: Manifest.File) {
        let task: URLSessionDownloadTask
        if let resumeData = loadResumeData(file.name) {
            task = session.downloadTask(withResumeData: resumeData)
        } else if let url = URL(string: file.urlString) {
            task = session.downloadTask(with: url)
        } else {
            return
        }
        task.taskDescription = file.name   // persists across launches -> identifies the file in callbacks
        lock.lock(); if running[file.name] == nil { running[file.name] = 0 }; lock.unlock()
        task.resume()
    }

    private func manifestFile(_ name: String) -> Manifest.File? {
        lock.lock(); defer { lock.unlock() }
        return manifest?.files.first { $0.name == name }
    }

    private func markDone(_ name: String) {
        lock.lock()
        if let i = manifest?.files.firstIndex(where: { $0.name == name }) { manifest?.files[i].done = true }
        running[name] = manifest?.files.first { $0.name == name }?.expectedSize ?? running[name] ?? 0
        lock.unlock()
    }

    private func finishActive() {
        lock.lock(); manifest?.isActive = false; lock.unlock(); saveManifest()
    }

    private func aggregateBytes() -> (done: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let m = manifest else { return (0, 0) }
        var sum: Int64 = 0
        for f in m.files { sum += f.done ? f.expectedSize : (running[f.name] ?? 0) }
        return (sum, m.totalBytes)
    }

    private func cleanupPartials() {
        // Our resume/manifest state.
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        // Any files we wrote (a clean cancel leaves nothing behind).
        lock.lock(); let names = manifest?.files.map(\.name) ?? []; manifest = nil; running.removeAll(); lock.unlock()
        for n in names { try? FileManager.default.removeItem(at: modelDir.appendingPathComponent(n)) }
    }

    private func classify(_ error: NSError) -> Failure {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed,
                 NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .networkUnavailable
            default:
                return .other("Network error \(error.code): \(error.localizedDescription)")
            }
        }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return .diskFull }
        if error.domain == NSPOSIXErrorDomain, error.code == 28 /* ENOSPC */ { return .diskFull }
        return .other(error.localizedDescription)
    }

    // MARK: - Metadata sidecars (Fix Path A)

    /// The HubApi `.metadata` sidecar for a file: `<modelDir>/.cache/huggingface/download/<name>.metadata`.
    /// (`.cache` is a hidden dir → the offline snapshot's `getFileUrls(.skipsHiddenFiles)` skips it, so it
    /// never tries to validate the sidecars themselves.)
    private func sidecarURL(_ name: String) -> URL {
        modelDir.appendingPathComponent(".cache/huggingface/download/\(name).metadata")
    }

    /// Writes the sidecar in HubApi's exact format (`writeDownloadMetadata`, HubApi.swift:434):
    /// three UTF-8 lines + trailing newline — commitHash, etag, unix-epoch timestamp.
    private func writeSidecar(name: String, commitHash: String, etag: String) {
        let url = sidecarURL(name)
        let content = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// True when every top-level model file on disk already has a sidecar (so repair needs NO network).
    private func sidecarsComplete() -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        else { return false }
        let modelFiles = entries.filter { !$0.lastPathComponent.hasPrefix(".") }   // skip .cache
        guard !modelFiles.isEmpty else { return false }
        return modelFiles.allSatisfy { FileManager.default.fileExists(atPath: sidecarURL($0.lastPathComponent).path) }
    }

    /// Streaming SHA-256 of a file (1 MB chunks) — matches HubApi's `computeFileHash`.
    private func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the LFS etag==sha256 assumption the offline path relies on (HubApi.swift:605).
    /// Only files whose etag is a 64-hex sha256 (the LFS weights) are hashed; small git-blob-etag files
    /// are skipped. Returns a `.integrityFailed` if any LFS file's bytes don't match its etag, else nil.
    private func verifyLFSFiles() -> Failure? {
        let files = { () -> [Manifest.File] in self.lock.lock(); defer { self.lock.unlock() }; return self.manifest?.files ?? [] }()
        for f in files {
            guard f.etag.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { continue }
            guard let computed = sha256Hex(of: modelDir.appendingPathComponent(f.name)) else {
                return .other("Couldn't hash \(f.name) to verify integrity.")
            }
            let ok = computed == f.etag
            print("[bgdl] LFS verify \(f.name): sha256=\(computed.prefix(16))… etag=\(f.etag.prefix(16))… → \(ok ? "MATCH" : "MISMATCH")")
            if !ok { return .integrityFailed("\(f.name) failed hash check (etag≠sha256)") }
        }
        return nil
    }

    // MARK: - Publishing (main thread)

    private func publishProgress(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastPublish) < 0.2 { return }   // throttle UI churn
        lastPublish = now
        let (done, total) = aggregateBytes()
        let f = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        DispatchQueue.main.async { [weak self] in self?.onProgress?(f) }
    }
    private func publishPaused() {
        let (done, total) = aggregateBytes()
        let f = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        DispatchQueue.main.async { [weak self] in self?.onPaused?(f) }
    }
    private func publishCompleted() { DispatchQueue.main.async { [weak self] in self?.onCompleted?() } }
    private func publishFailure(_ failure: Failure) {
        finishActive()
        DispatchQueue.main.async { [weak self] in self?.onFailed?(failure) }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_: URLSession, downloadTask t: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        guard let name = t.taskDescription else { return }
        lock.lock(); running[name] = totalBytesWritten; lock.unlock()
        publishProgress()
    }

    func urlSession(_: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = t.taskDescription else { return }
        let dest = modelDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)   // MUST move synchronously (temp is reaped after)
        } catch {
            publishFailure(classify(error as NSError)); return
        }
        // Integrity: the finished file must match the expected byte size (BUG 35 §7).
        if let expected = manifestFile(name)?.expectedSize, expected > 0, fileSize(dest) != expected {
            publishFailure(.integrityFailed(name)); return
        }
        // ★ Fix Path A — write HubApi's per-file `.metadata` sidecar so loadContainer's OFFLINE path
        // (taken on cellular, where NWPath is `isExpensive`) finds it. commitHash + etag were captured
        // from getFileMetadata at start(); NO new network request.
        if let f = manifestFile(name) { writeSidecar(name: name, commitHash: f.commitHash, etag: f.etag) }
        markDone(name)
        deleteResumeData(name)
        saveManifest()
        lock.lock(); let allDone = manifest?.files.allSatisfy(\.done) ?? false; lock.unlock()
        if allDone {
            // One-time verification of the LFS etag==sha256 assumption the offline path relies on
            // (HubApi.swift:605). Runs once at download completion, never per-load.
            if let fail = verifyLFSFiles() { finishActive(); publishFailure(fail); return }
            finishActive(); publishCompleted()
        } else {
            publishProgress(force: true)
        }
    }

    func urlSession(_: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }   // success is handled in didFinishDownloadingTo
        let name = t.taskDescription ?? "unknown"
        if let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { saveResumeData(resume, name: name) }
        lock.lock(); let cancelled = userCancelled; lock.unlock()
        if cancelled || error.code == NSURLErrorCancelled { return }   // handled by cancel()
        publishFailure(classify(error))
    }

    func urlSession(_: URLSession, taskIsWaitingForConnectivity _: URLSessionTask) {
        publishPaused()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        lock.lock(); let handler = backgroundCompletionHandler; backgroundCompletionHandler = nil; lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
