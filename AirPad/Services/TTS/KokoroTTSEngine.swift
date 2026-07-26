import Foundation
import AVFoundation
import Observation
import os
import UIKit
import KokoroSwift
import MLX
import MLXUtilsLibrary

/// Localized log for the streaming synth path. Read on device with
/// `log stream --predicate 'subsystem == "com.doctorpresident.airpad" && category == "kokoro"'`
/// or in Xcode's console — shows per-chunk MLX memory so a memory climb (→ OS
/// kill on long answers) is visible, and names the exact chunk if synth faults.
private let kokoroLog = Logger(subsystem: "com.doctorpresident.airpad", category: "kokoro")

/// Off-main owner of the Kokoro model + voice styles. An `actor` so the
/// multi-second weight load and every GPU synth run OFF the main thread
/// automatically, and so `KokoroTTS` / `MLXArray` never cross a thread boundary.
/// Only Sendable values (`URL`, `[Float]`, `String`, `Language`) enter or leave.
actor KokoroCore {
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    var isLoaded: Bool { tts != nil }
    var voiceIDs: [String] { Array(voices.keys) }

    /// Build the model (loads ~600 MB of weights via `WeightLoader` → force-try
    /// on the file, so the CALLER must have verified the file exists first) and
    /// read the voice styles. Returns cold-load wall time in seconds. Idempotent.
    func warmUp(modelURL: URL, voicesURL: URL?) -> Double {
        guard tts == nil else { return 0 }
        let t0 = CFAbsoluteTimeGetCurrent()
        tts = KokoroTTS(modelPath: modelURL, g2p: .misaki)
        // Cap MLX's Metal buffer cache. Without this, repeated chunk synthesis
        // over a long answer lets cached GPU memory grow until iOS memory-kills
        // the app (the "short works, long crashes, no crash report" signature).
        GPU.set(cacheLimit: 48 * 1024 * 1024)   // 48 MB
        if let voicesURL, let dict = NpyzReader.read(fileFromPath: voicesURL) {
            // The .npz stores each style under a ".npy"-suffixed key
            // (e.g. "af_heart.npy"). Normalize to the bare voice id so callers
            // — the Settings picker and the sampler — can look up by "af_heart".
            var normalized: [String: MLXArray] = [:]
            for (key, value) in dict {
                let id = String(key.split(separator: ".").first ?? Substring(key))
                normalized[id] = value
            }
            voices = normalized
        }
        return CFAbsoluteTimeGetCurrent() - t0
    }

    /// Synthesize `text` in `voiceID`. Returns PCM samples (24 kHz mono float32)
    /// and the generate wall time in seconds.
    func generate(voiceID: String, language: Language, text: String) throws -> (samples: [Float], seconds: Double) {
        guard let tts else { throw KokoroEngineError.modelNotInstalled }
        guard let voice = voices[voiceID] else { throw KokoroEngineError.voiceUnavailable(voiceID) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let (samples, _) = try tts.generateAudio(voice: voice, language: language, text: text)
        return (samples, CFAbsoluteTimeGetCurrent() - t0)
    }
}

/// `TTSEngine` conformance for Kokoro. Produces a whole PCM clip on the actor
/// (off-main), then plays it through an `AVAudioEngine`/`AVAudioPlayerNode`
/// graph on the main thread. `@Observable` so the sampler can show cold-load /
/// RTF telemetry. Lazy: the model is built on the FIRST synth, never at launch.
@MainActor
@Observable
final class KokoroTTSEngine: TTSEngine {
    static let shared = KokoroTTSEngine()

    // ── Bundle asset locations. T drops these two files into
    //    AirPad/Resources/Kokoro/ (a folder reference → they bundle under the
    //    "Kokoro" subdirectory). See README-DROP-MODEL-HERE.txt for filenames.
    static let modelURL: URL? = Bundle.main.url(
        forResource: "kokoro-v1_0", withExtension: "safetensors", subdirectory: "Kokoro")
    static let voicesURL: URL? = Bundle.main.url(
        forResource: "voices", withExtension: "npz", subdirectory: "Kokoro")

    private let core = KokoroCore()

    // Playback graph (main thread; built once, lazily on first play).
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphReady = false
    private var onFinish: (() -> Void)?

    // Dev telemetry — the sampler HUD reads these.
    private(set) var isWarmingUp = false
    private(set) var isLoaded = false
    private(set) var coldLoadSeconds: Double?
    private(set) var lastGenerateSeconds: Double?      // total synth time, last utterance
    private(set) var lastRTF: Double?                  // total generate / total audio (<1 = faster than real-time)
    private(set) var timeToFirstAudioSeconds: Double?  // first-chunk synth latency (time to first sound)
    private(set) var loadedVoiceIDs: [String] = []

    // Streaming-synthesis pipeline state (main thread only).
    private var speakTask: Task<Void, Never>?
    private var buffersInFlight = 0
    private var producerDone = false
    // Race synthesis well ahead of playback (bounded) so a whole typical answer
    // is buffered as PCM BEFORE the user locks/backgrounds — background playback
    // of already-synthesized audio needs no GPU. 16 chunks ≈ 30 MB PCM; the 48 MB
    // MLX cache cap bounds GPU memory independently (so this can't re-trigger the
    // earlier jetsam, which was cache growth, not audio buffers).
    private let lookAhead = 16
    private var utteranceGenerateSeconds = 0.0
    private var utteranceAudioSeconds = 0.0

    /// True while the app is backgrounded/locked. iOS blocks GPU (Metal) work in
    /// the background — a synth call there stalls or CRASHES — so the producer
    /// PARKS while this is set and resumes on foreground. Set from lifecycle
    /// notifications (see `observeLifecycle`).
    private var isBackgrounded = false

    private init() {
        observeLifecycle()
    }

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.isBackgrounded = true }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.isBackgrounded = false }
        }
    }

    // MARK: TTSEngine

    var isReady: Bool { isModelInstalled }

    /// True only when a plausibly-real weights file is present. Guards the
    /// force-unwrapping `WeightLoader` from crashing on a missing/stub file
    /// (e.g. an un-pulled Git-LFS pointer, which is a few bytes).
    var isModelInstalled: Bool {
        guard let url = Self.modelURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 100_000_000     // real safetensors ≈ 600 MB
    }

    /// Cold-load the model OFF the launch path. First call does the heavy work
    /// on the actor (off-main); later calls are cheap. Safe from a button tap —
    /// the UI can watch `isWarmingUp`. Throws if the model isn't installed.
    @discardableResult
    func warmUpIfNeeded() async throws -> Bool {
        if isLoaded { return true }
        guard let modelURL = Self.modelURL, isModelInstalled else {
            throw KokoroEngineError.modelNotInstalled
        }
        isWarmingUp = true
        defer { isWarmingUp = false }
        let secs = await core.warmUp(modelURL: modelURL, voicesURL: Self.voicesURL)
        loadedVoiceIDs = await core.voiceIDs.sorted()
        isLoaded = await core.isLoaded
        if secs > 0 { coldLoadSeconds = secs }
        return isLoaded
    }

    /// Streaming synthesis. A full Librarian answer is far longer than Kokoro's
    /// ~510-token window (a single `generateAudio` would throw `tooManyTokens`),
    /// so the text is split into sentence-sized chunks and synthesized one at a
    /// time on the actor (off-main), each scheduled onto the player as it's ready.
    /// Playback starts after the FIRST chunk → low latency to first sound; at most
    /// `lookAhead` chunks are held in flight → bounded memory on long passages.
    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws {
        stop()  // cancel any in-flight utterance + clear the player queue
        let chunks = TextChunker.chunk(text)
        guard !chunks.isEmpty else { return }
        try await warmUpIfNeeded()
        let id = voiceID ?? loadedVoiceIDs.first ?? "af_heart"
        let lang = KokoroVoiceCatalog.language(for: id)

        PlaybackAudioSession.configure()
        ensureGraph()
        if !engine.isRunning { try engine.start() }

        // Reset per-utterance state + telemetry.
        self.onFinish = onFinish
        buffersInFlight = 0
        producerDone = false
        utteranceGenerateSeconds = 0
        utteranceAudioSeconds = 0
        timeToFirstAudioSeconds = nil
        GPU.resetPeakMemory()   // so the peak logged at end reflects THIS answer

        kokoroLog.info("speak start: \(chunks.count) chunks, voice=\(id, privacy: .public)")
        speakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { return }
                // Park here while (a) we're already `lookAhead` chunks ahead of
                // playback, or (b) the app is backgrounded — iOS blocks GPU work
                // in the background, so we must NOT call synth there (stall/crash).
                // Parking (not breaking) means synthesis RESUMES on foreground.
                // Because we race far ahead, a typical answer is fully buffered
                // before the user locks, so background playback just drains PCM.
                while (self.buffersInFlight >= self.lookAhead || self.isBackgrounded)
                        && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
                }
                if Task.isCancelled { return }
                // Resuming after a background park may find the engine stopped
                // (system suspended it once buffers drained) — re-arm the graph.
                if self.graphReady && !self.engine.isRunning {
                    PlaybackAudioSession.configure()
                    try? self.engine.start()
                }
                // Per-chunk breadcrumb BEFORE synth: if the app dies here, the last
                // line names the chunk (degenerate text?) and MLX memory at the time
                // (climbing → memory kill). active+cache is MLX's own footprint.
                kokoroLog.info("chunk \(i)/\(chunks.count) len=\(chunk.count) mlxActive=\(GPU.activeMemory / 1_048_576)MB mlxCache=\(GPU.cacheMemory / 1_048_576)MB text=\(String(chunk.prefix(48)), privacy: .public)")
                do {
                    let (samples, seconds) = try await self.core.generate(voiceID: id, language: lang, text: chunk)
                    if Task.isCancelled { return }
                    self.recordChunk(seconds: seconds, sampleCount: samples.count, isFirst: i == 0)
                    self.schedule(samples: samples)
                    // Start on the first chunk, and re-start if a background
                    // suspension left the player stopped.
                    if self.engine.isRunning && !self.player.isPlaying { self.player.play() }
                } catch {
                    // A chunk that still exceeds the token window (or a synth
                    // error) is skipped so the rest of the answer still reads.
                    kokoroLog.error("chunk \(i) synth failed: \(String(describing: error), privacy: .public)")
                }
            }
            kokoroLog.info("producer done: \(chunks.count) chunks, mlxPeak=\(GPU.peakMemory / 1_048_576)MB mlxCache=\(GPU.cacheMemory / 1_048_576)MB (cap 48MB), \(self.buffersInFlight) draining")
            self.producerDone = true
            // All chunks failed → nothing scheduled → finish now.
            if self.buffersInFlight == 0 { self.fireFinish() }
        }
    }

    func pause()  { if graphReady { player.pause() } }
    /// Robust resume — after an interruption the engine may have stopped, so
    /// restart it before playing (the session is re-asserted by the caller).
    func resume() {
        guard graphReady else { return }
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning { player.play() }
    }
    func stop() {
        speakTask?.cancel()
        speakTask = nil
        onFinish = nil           // null before flushing so no spurious finish fires
        producerDone = false
        buffersInFlight = 0
        guard graphReady else { return }
        player.stop()
        player.reset()           // drop any queued-but-unplayed buffers
        // Stop the engine too so the caller can deactivate the audio session
        // cleanly (a running engine blocks setActive(false)). Restarted lazily
        // on the next speak().
        if engine.isRunning { engine.stop() }
    }

    // MARK: Playback (main thread)

    private var kokoroFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Double(KokoroTTS.Constants.samplingRate),
                      channels: 1, interleaved: false)!
    }

    private func ensureGraph() {
        guard !graphReady else { return }
        engine.attach(player)
        // mainMixerNode resamples 24 kHz → the hardware rate.
        engine.connect(player, to: engine.mainMixerNode, format: kokoroFormat)
        graphReady = true
    }

    private func schedule(samples: [Float]) {
        guard let buf = makeBuffer(samples) else { return }
        buffersInFlight += 1
        player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.buffersInFlight -= 1
                if self.producerDone && self.buffersInFlight == 0 {
                    self.fireFinish()
                }
            }
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: kokoroFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buf.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        return buf
    }

    private func recordChunk(seconds: Double, sampleCount: Int, isFirst: Bool) {
        utteranceGenerateSeconds += seconds
        utteranceAudioSeconds += Double(sampleCount) / Double(KokoroTTS.Constants.samplingRate)
        if isFirst { timeToFirstAudioSeconds = seconds }
        lastGenerateSeconds = utteranceGenerateSeconds
        lastRTF = utteranceAudioSeconds > 0 ? utteranceGenerateSeconds / utteranceAudioSeconds : nil
    }

    private func fireFinish() {
        // Natural end: stop the engine so the caller's session deactivation
        // succeeds (restarted lazily on the next speak()).
        if engine.isRunning { engine.stop() }
        let cb = onFinish; onFinish = nil
        cb?()
    }
}
