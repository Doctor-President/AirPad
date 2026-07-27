import Foundation
import AVFoundation
import Observation
import os
import FluidAudio

/// Localized log for the ANE synth path. Read on device with
/// `log stream --predicate 'subsystem == "com.doctorpresident.airpad" && category == "kokoro-ane"'`
/// — shows per-chunk generate time + RTF so a slow CPU-iSTFT fallback (or a
/// background stall/crash) is visible, and names the exact chunk if synth faults.
private let kokoroAneLog = Logger(subsystem: "com.doctorpresident.airpad", category: "kokoro-ane")

/// `TTSEngine` conformance for Kokoro on the **Apple Neural Engine** via
/// FluidAudio's 7-stage Core ML chain — the background-survival SPIKE.
///
/// This exists alongside the MLX `KokoroTTSEngine` (which stays as fallback) to
/// test one hypothesis: **can read-aloud keep synthesizing while the app is
/// backgrounded/locked?** The MLX path can't — iOS bans Metal (GPU) work in the
/// background, which crashes MLX synth, so that engine PARKS synthesis while
/// backgrounded and races 16 chunks ahead to pre-buffer the whole answer first.
///
/// FluidAudio is driven here with the `.allAne` compute-unit routing: every
/// stage requests `.cpuAndNeuralEngine`, and the two fp32 stages the ANE rejects
/// (noise + tail iSTFT) fall back to the **CPU**, not the GPU that FluidAudio's
/// *default* routing uses. No Metal anywhere → the background ban shouldn't apply.
/// So this engine deliberately does **NOT** park while backgrounded — it keeps
/// synthesizing on-demand. Whether that survives is exactly T's device test.
///
/// Shape mirrors `KokoroTTSEngine`: the actor `KokoroAneManager` PRODUCES PCM
/// off-main; we PLAY it through an `AVAudioEngine`/`AVAudioPlayerNode` graph on
/// the main thread, chunked via the shared `TextChunker` (the 512-token IPA cap
/// is the same window the MLX path chunks for). Models DOWNLOAD on first use to
/// the app cache (they are not dev-bundled like the MLX weights), so the first
/// read-aloud needs network; cached across relaunches after that.
@MainActor
@Observable
final class FluidKokoroTTSEngine: TTSEngine {
    static let shared = FluidKokoroTTSEngine()

    // Kokoro ANE output is fixed 24 kHz mono fp32 (KokoroAneConstants.sampleRate).
    private static let sampleRate: Double = 24_000

    /// Built lazily on the first synth (never at launch — FM/cold-load rule).
    /// `.english` variant + `.allAne` routing (no GPU; see the type doc).
    private var manager: KokoroAneManager?

    // Playback graph (main thread; built once, lazily on first play).
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphReady = false
    private var onFinish: (() -> Void)?

    // Dev telemetry — surfaced so T can read cold-load + time-to-first-sound on
    // device (the numbers that decide whether a read-aloud progress meter is even
    // needed; per the brief we do NOT build the meter, we measure instead).
    private(set) var isWarmingUp = false
    private(set) var isLoaded = false
    private(set) var coldLoadSeconds: Double?         // first initialize() (incl. model download)
    private(set) var lastGenerateSeconds: Double?     // total synth wall time, last utterance
    private(set) var lastRTF: Double?                 // generate / audio (<1 = faster than real-time)
    private(set) var timeToFirstAudioSeconds: Double? // start → first sound scheduled

    // Streaming-synthesis pipeline state (main thread only).
    private var speakTask: Task<Void, Never>?
    private var buffersInFlight = 0
    private var producerDone = false
    // Small look-ahead: enough to keep playback smooth if a chunk runs slow, but
    // deliberately NOT the MLX path's race-16-ahead. We WANT a long answer to keep
    // synthesizing chunks WHILE backgrounded — that is the whole point of the test.
    private let lookAhead = 4
    private var utteranceGenerateSeconds = 0.0
    private var utteranceAudioSeconds = 0.0

    private init() {}

    // MARK: TTSEngine

    /// Optimistic: models download on demand, so we can always attempt. A setup
    /// failure (offline first run, unsupported OS) is caught by the caller, which
    /// falls back to AVSpeech so the answer still reads.
    var isReady: Bool { true }

    /// Cold-load the 7-stage chain OFF the launch path. First call downloads (if
    /// missing) + loads all stages + the default voice pack; later calls are cheap.
    @discardableResult
    func warmUpIfNeeded() async throws -> Bool {
        if isLoaded { return true }
        isWarmingUp = true
        defer { isWarmingUp = false }
        let mgr = manager ?? KokoroAneManager(variant: .english, computeUnits: .allAne)
        manager = mgr
        let t0 = CFAbsoluteTimeGetCurrent()
        try await mgr.initialize()
        coldLoadSeconds = CFAbsoluteTimeGetCurrent() - t0
        isLoaded = true
        kokoroAneLog.info("cold-load done in \(self.coldLoadSeconds ?? 0, format: .fixed(precision: 2))s (routing=allAne)")
        return true
    }

    /// Streaming synthesis: chunk the answer, synthesize each chunk on the actor
    /// (off-main, ANE), schedule PCM onto the player as it's ready. Playback starts
    /// after the first chunk → low latency to first sound. NO background park.
    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws {
        stop()  // cancel any in-flight utterance + clear the player queue
        let chunks = TextChunker.chunk(text)
        guard !chunks.isEmpty else { return }
        try await warmUpIfNeeded()
        guard let mgr = manager else { throw KokoroEngineError.modelNotInstalled }
        // Voice IDs are identical to the MLX catalog (af_heart, bm_george, …), so
        // pass straight through; nil → the English default voice.
        let id = voiceID ?? KokoroAneConstants.defaultVoice

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
        let utteranceStart = CFAbsoluteTimeGetCurrent()

        kokoroAneLog.info("speak start: \(chunks.count) chunks, voice=\(id, privacy: .public)")
        speakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { return }
                // Park only on the look-ahead bound (memory) — NOT on background.
                // Unlike the MLX engine, we keep synthesizing while backgrounded;
                // `.allAne` uses no Metal, so the background GPU ban shouldn't bite.
                while self.buffersInFlight >= self.lookAhead && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
                }
                if Task.isCancelled { return }
                // iOS may have suspended the engine while buffers drained — re-arm.
                if self.graphReady && !self.engine.isRunning {
                    PlaybackAudioSession.configure()
                    try? self.engine.start()
                }
                kokoroAneLog.info("chunk \(i)/\(chunks.count) len=\(chunk.count) text=\(String(chunk.prefix(48)), privacy: .public)")
                do {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let result = try await mgr.synthesizeDetailed(text: chunk, voice: id)
                    let seconds = CFAbsoluteTimeGetCurrent() - t0
                    if Task.isCancelled { return }
                    self.recordChunk(
                        seconds: seconds,
                        sampleCount: result.samples.count,
                        isFirst: i == 0,
                        utteranceStart: utteranceStart)
                    self.schedule(samples: result.samples)
                    if self.engine.isRunning && !self.player.isPlaying { self.player.play() }
                } catch {
                    // Skip a faulting chunk so the rest of the answer still reads.
                    kokoroAneLog.error("chunk \(i) synth failed: \(String(describing: error), privacy: .public)")
                }
            }
            kokoroAneLog.info("producer done: \(chunks.count) chunks, RTF=\(self.lastRTF ?? 0, format: .fixed(precision: 2)), \(self.buffersInFlight) draining")
            self.producerDone = true
            if self.buffersInFlight == 0 { self.fireFinish() }
        }
    }

    func pause()  { if graphReady { player.pause() } }
    func resume() {
        guard graphReady else { return }
        if !engine.isRunning { try? engine.start() }
        if engine.isRunning { player.play() }
    }
    func stop() {
        speakTask?.cancel()
        speakTask = nil
        onFinish = nil
        producerDone = false
        buffersInFlight = 0
        guard graphReady else { return }
        player.stop()
        player.reset()
        if engine.isRunning { engine.stop() }
    }

    // MARK: Playback (main thread) — mirrors KokoroTTSEngine

    private var kokoroFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.sampleRate,
                      channels: 1, interleaved: false)!
    }

    private func ensureGraph() {
        guard !graphReady else { return }
        engine.attach(player)
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

    private func recordChunk(seconds: Double, sampleCount: Int, isFirst: Bool, utteranceStart: Double) {
        utteranceGenerateSeconds += seconds
        utteranceAudioSeconds += Double(sampleCount) / Self.sampleRate
        if isFirst { timeToFirstAudioSeconds = CFAbsoluteTimeGetCurrent() - utteranceStart }
        lastGenerateSeconds = utteranceGenerateSeconds
        lastRTF = utteranceAudioSeconds > 0 ? utteranceGenerateSeconds / utteranceAudioSeconds : nil
    }

    private func fireFinish() {
        if engine.isRunning { engine.stop() }
        let cb = onFinish; onFinish = nil
        cb?()
    }
}
