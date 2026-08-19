import Foundation
import Metal
import Observation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

/// Owns the optional downloadable on-device model (Qwen3-1.7B-4bit via MLX).
///
/// ★ ws-local-model **Stage 1 — plumbing + lifecycle ONLY.** NO generation call site uses this yet;
/// `AIService` and `ModelRouter` are untouched. The spike is device-verified
/// (`Ops/briefs/device-local-model.md`): 0/12 refusals under shipping config, ~1.2s/node, peak ~1159 MB,
/// mlx-swift #17/#407 not reproduced, **thinking OFF mandatory** (with it on Qwen3 burns the whole token
/// budget in `<think>` and emits no JSON — a correctness failure, not a latency choice).
@MainActor
@Observable
final class LocalModelService {
    static let shared = LocalModelService()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)   // BYTE fraction 0...1 (bytes on disk / bytes total)
        case paused(Double)        // ws-bg-download: interrupted (e.g. offline) — auto-resumes; keeps the fraction
        case ready                 // weights on disk
        case failed(String)        // DOWNLOAD failure (network / disk / integrity) — remedy = re-download
        case loadFailed(String)    // weights ARE on disk but the model wouldn't LOAD — remedy = retry LOAD (repair sidecars), NOT re-download
    }

    private(set) var state: State = .notDownloaded
    private(set) var isResident = false           // model currently loaded into memory
    private(set) var lastTokPerSec: Double = 0
    private(set) var lastOutTokens = 0
    private(set) var excludedFromBackup = false   // VERIFIED by reading the resource value back

    /// MLX needs a Metal GPU — unavailable on the Simulator and any device that can't run it.
    /// When false every operation fails to a clear state instead of crashing.
    let isAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false                              // MLX/Metal shaders don't run on the sim
        #else
        return MTLCreateSystemDefaultDevice() != nil
        #endif
    }()

    let modelDisplayName = "Qwen3 1.7B (4-bit)"
    let downloadSizeLabel = "~1.8 GB"

    private let modelID = "mlx-community/Qwen3-1.7B-4bit"
    private static let cacheLimitBytes = 20 * 1024 * 1024   // the spike's measured setting

    private let modelHome: URL                    // Application Support/LocalModel (excluded from backup)
    private let hub: HubApi
    private let config: ModelConfiguration
    private var container: ModelContainer?

    /// ws-bg-download (Option C) — downloads the model's files with a BACKGROUND URLSession
    /// (survives suspension/termination; byte-based progress; resumable). `load()` below still
    /// loads the on-disk files and is device-verified — this only replaces the DOWNLOAD step.
    @ObservationIgnored private lazy var downloader: BackgroundModelDownloader = {
        let d = BackgroundModelDownloader(
            hub: hub, repoID: modelID,
            modelDir: config.modelDirectory(hub: hub), downloadBase: modelHome)
        d.onProgress  = { [weak self] f in self?.state = .downloading(f) }
        d.onPaused    = { [weak self] f in self?.state = .paused(f) }
        d.onCompleted = { [weak self] in
            guard let self else { return }
            self.applyBackupExclusion()       // re-assert exclusion once the weights have landed
            self.state = .ready               // files on disk; load() loads them lazily (unchanged)
        }
        d.onFailed = { [weak self] failure in self?.state = self?.failureState(failure) ?? .notDownloaded }
        return d
    }()

    /// Maps a downloader failure to an honest, distinguishable UI state (BUG 35 §7).
    private func failureState(_ failure: BackgroundModelDownloader.Failure) -> State {
        switch failure {
        case .cancelled:              return .notDownloaded
        case .networkUnavailable:     return .failed("No internet connection. Connect to Wi-Fi and tap Retry.")
        case .diskFull:               return .failed("Not enough storage to finish the download. Free up space and tap Retry.")
        case .integrityFailed(let f): return .failed("A downloaded file was incomplete (\(f)). Tap Retry to re-download.")
        case .other(let msg):         return .failed(msg)
        }
    }

    /// The exact on-disk model directory (surfaced for verification).
    var modelDirectoryPath: String { config.modelDirectory(hub: hub).path }

    private init() {
        // ★ Application Support — persistent (unlike Caches, which the OS evicts under storage
        // pressure) and NOT Documents (which IS AirPad's iCloud container — a 1.8 GB model must
        // never land in iCloud). The mlx default (`.cachesDirectory`) is overridden via the hub.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelHome = appSupport.appendingPathComponent("LocalModel", isDirectory: true)
        hub = HubApi(downloadBase: modelHome)
        config = ModelConfiguration(id: modelID)
        try? FileManager.default.createDirectory(at: modelHome, withIntermediateDirectories: true)
        applyBackupExclusion()
        refreshDownloadedState()
        // ws-bg-download — reconnect to any background download the system kept running while we
        // were suspended/terminated, and resume anything left in flight. NO manual re-tap (BUG 35 §3).
        if isAvailable {
            downloader.reattach()
            // ★ Fix Path A — a download from a PRE-FIX build has the weights on disk but no HubApi
            // `.metadata` sidecars → the offline load path fails. Repair proactively on launch when the
            // files exist but sidecars don't (HEADs only, no body; no-ops once sidecars are present).
            // Best-effort: if the network is unreachable right now, the load path repairs + reports honestly.
            if isDownloadedOnDisk() {
                Task { [weak self] in try? await self?.downloader.ensureSidecars() }
            }
        }
    }

    // MARK: - Disk state

    private func isDownloadedOnDisk() -> Bool {
        let dir = config.modelDirectory(hub: hub)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    private func refreshDownloadedState() {
        guard isAvailable else {
            state = .failed("The local model needs a device with a Metal GPU (it can't run on the Simulator).")
            return
        }
        state = isDownloadedOnDisk() ? .ready : .notDownloaded
    }

    /// Exclude the model tree from iCloud / device backup, then VERIFY by reading the value back
    /// (a `setResourceValues` can silently no-op). `excludedFromBackup` reflects the read, not the set.
    private func applyBackupExclusion() {
        var url = modelHome
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        let read = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        excludedFromBackup = (read?.isExcludedFromBackup == true)
    }

    // MARK: - Download (loadContainer both downloads AND loads)

    func download() {
        guard isAvailable else {
            state = .failed("Local model unavailable on this device (no Metal GPU).")
            return
        }
        if case .downloading = state { return }
        if case .paused = state { return }
        state = .downloading(0)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloader.start()
            } catch {
                // Only the resolve step (getFilenames/getFileMetadata) throws here; per-file transfer
                // failures come back via onFailed. Keep the message honest.
                let ns = error as NSError
                self.state = ns.domain == NSURLErrorDomain
                    ? .failed("Couldn't reach the model server. Check your connection and tap Retry.")
                    : .failed(error.localizedDescription)
            }
        }
    }

    /// ws-bg-download — cancel means CANCEL: stop every task, delete the partials + our resume state,
    /// and reflect it. (The old `deletePartialDownload()` was inert — a cancelled transfer surfaces as
    /// `URLError.cancelled`, not `CancellationError`, so it never ran. BUG 35 §6.)
    func cancelDownload() {
        downloader.cancel()
        if isAvailable { state = .notDownloaded }
    }

    /// AppDelegate → us on relaunch: the system finished background transfers for this session and
    /// handed back a completion handler to call once we've processed the events.
    func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard isAvailable, identifier == BackgroundModelDownloader.sessionIdentifier else {
            completionHandler(); return
        }
        downloader.setBackgroundCompletionHandler(completionHandler)
    }

    // MARK: - Load / unload

    func load() async {
        guard isAvailable, isDownloadedOnDisk(), container == nil else { return }
        // ★ Fix Path A — ensure HubApi's per-file `.metadata` sidecars exist BEFORE loading. Without them
        // the offline path (taken on cellular, where NWPath is `isExpensive`) throws "Metadata not
        // available…". Repairs a pre-fix download once (HEADs only, no body); no-ops with no network once
        // the sidecars are present. A LOAD failure is `.loadFailed` — NOT `.failed`, so the UI never
        // offers a 1.8 GB re-download as the remedy.
        do {
            try await downloader.ensureSidecars()
        } catch {
            state = .loadFailed(loadFailureMessage(error))
            return
        }
        MLX.GPU.set(cacheLimit: Self.cacheLimitBytes)
        do {
            container = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: config)  // files present → fast, no download
            isResident = true
            state = .ready
        } catch {
            state = .loadFailed(loadFailureMessage(error))
        }
    }

    /// Retry a failed LOAD without re-downloading — repairs sidecars if needed, then loads.
    func retryLoad() {
        guard isAvailable, isDownloadedOnDisk() else { return }
        Task { [weak self] in
            guard let self else { return }
            self.container = nil
            await self.load()
        }
    }

    /// Honest, distinguishable copy for a LOAD-side failure (vs a download failure).
    private func loadFailureMessage(_ error: Error) -> String {
        if let repair = error as? BackgroundModelDownloader.RepairError {
            return repair.errorDescription ?? "Couldn't prepare the model to load."
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't reach the model server to finish setup. Connect to the internet and tap Try again."
        }
        return "The model is on disk but couldn't be loaded. Tap Try again. (\(error.localizedDescription))"
    }

    /// Free the resident model (weights stay on disk). ARC releases the MLXArrays; the GPU buffer cache
    /// is already bounded to 20 MB by cacheLimit.
    func unload() {
        container = nil
        isResident = false
    }

    // MARK: - Delete (reclaim all disk)

    func deleteModel() {
        cancelDownload()
        unload()
        try? FileManager.default.removeItem(at: modelHome)
        try? FileManager.default.createDirectory(at: modelHome, withIntermediateDirectories: true)
        applyBackupExclusion()
        state = isAvailable ? .notDownloaded : state
    }

    /// Bytes currently on disk under the model home (for a "reclaimed N MB" readout).
    func diskUsageBytes() -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: modelHome, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    // MARK: - Generate (thinking OFF — a correctness requirement, source-traced in the spike)

    /// One distillation. Thinking is disabled via the real chat-template flag
    /// (`UserInput.additionalContext["enable_thinking"]` → `applyChatTemplate(additionalContext:)`), not a
    /// prompt hack. Sets `lastOutTokens` / `lastTokPerSec` as a side effect for the Settings test hook.
    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        if container == nil { await load() }
        guard let container else {
            if case .loadFailed(let reason) = state { throw LocalModelError.loadFailed(reason) }
            throw LocalModelError.notReady
        }
        let result: GenerateResult = try await container.perform { (ctx: ModelContext) in
            let input = UserInput(
                chat: [.system(systemPrompt), .user(userPrompt)],
                additionalContext: ["enable_thinking": false])
            let lmInput = try await ctx.processor.prepare(input: input)
            return try MLXLMCommon.generate(
                input: lmInput, parameters: GenerateParameters(maxTokens: 400), context: ctx
            ) { _ in .more }
        }
        lastOutTokens = result.tokens.count
        lastTokPerSec = result.generateTime > 0 ? Double(result.tokens.count) / result.generateTime : 0
        return result.output
    }
}

enum LocalModelError: Error, LocalizedError {
    case notReady
    case loadFailed(String)   // downloaded but couldn't load — distinct from "not downloaded"
    var errorDescription: String? {
        switch self {
        case .notReady: return "The local model isn't downloaded yet."
        case .loadFailed(let reason): return reason
        }
    }
}
