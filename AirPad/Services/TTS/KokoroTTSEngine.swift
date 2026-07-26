import Foundation
import AVFoundation
import Observation
import KokoroSwift
import MLX
import MLXUtilsLibrary

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
        if let voicesURL, let dict = NpyzReader.read(fileFromPath: voicesURL) {
            voices = dict
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
    private(set) var lastGenerateSeconds: Double?
    private(set) var lastRTF: Double?            // generate / audio-duration (<1 = faster than real-time)
    private(set) var loadedVoiceIDs: [String] = []

    private init() {}

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

    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await warmUpIfNeeded()
        let id = voiceID ?? loadedVoiceIDs.first ?? "af_heart"
        let lang = KokoroVoiceCatalog.language(for: id)
        let (samples, seconds) = try await core.generate(voiceID: id, language: lang, text: trimmed)
        lastGenerateSeconds = seconds
        let audioDuration = Double(samples.count) / Double(KokoroTTS.Constants.samplingRate)
        lastRTF = audioDuration > 0 ? seconds / audioDuration : nil
        try play(samples: samples, onFinish: onFinish)
    }

    func pause()  { player.pause() }
    func resume() { if engine.isRunning { player.play() } }
    func stop() {
        // Null the callback BEFORE stopping so the flush-triggered completion
        // handler doesn't fire a spurious "finished".
        onFinish = nil
        if player.isPlaying { player.stop() }
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

    private func play(samples: [Float], onFinish: @escaping () -> Void) throws {
        PlaybackAudioSession.configure()
        ensureGraph()
        guard let buf = AVAudioPCMBuffer(pcmFormat: kokoroFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw KokoroEngineError.audioBufferFailed
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let dst = buf.floatChannelData?[0], let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        if !engine.isRunning { try engine.start() }
        if player.isPlaying { player.stop() }
        self.onFinish = onFinish
        player.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let cb = self.onFinish; self.onFinish = nil
                cb?()
            }
        }
        player.play()
    }
}
