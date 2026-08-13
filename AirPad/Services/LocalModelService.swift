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
        case downloading(Double)   // fraction 0...1
        case ready                 // weights on disk
        case failed(String)
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
    private var downloadTask: Task<Void, Never>?

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
        MLX.GPU.set(cacheLimit: Self.cacheLimitBytes)
        state = .downloading(0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await LLMModelFactory.shared.loadContainer(hub: self.hub, configuration: self.config) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(progress.fractionCompleted)
                    }
                }
                try Task.checkCancellation()
                self.container = loaded
                self.isResident = true
                self.applyBackupExclusion()          // re-assert once the weights have landed
                self.state = .ready
            } catch is CancellationError {
                self.deletePartialDownload()
                self.state = .notDownloaded
            } catch {
                self.state = .failed("\(error)")
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    /// Cancel deletes the partial rather than leaving a half-written directory — resume is not surfaced
    /// this stage. (Hub does support file-level resume; a later stage could preserve the partial.)
    private func deletePartialDownload() {
        try? FileManager.default.removeItem(at: config.modelDirectory(hub: hub))
    }

    // MARK: - Load / unload

    func load() async {
        guard isAvailable, case .ready = state, container == nil else { return }
        MLX.GPU.set(cacheLimit: Self.cacheLimitBytes)
        do {
            container = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: config)  // files present → fast, no download
            isResident = true
        } catch {
            state = .failed("\(error)")
        }
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
        guard let container else { throw LocalModelError.notReady }
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
    var errorDescription: String? {
        switch self {
        case .notReady: return "The local model isn't downloaded or loaded yet."
        }
    }
}
