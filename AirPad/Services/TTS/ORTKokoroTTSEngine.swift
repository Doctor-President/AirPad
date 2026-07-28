import Foundation
import AVFoundation
import Observation
import os
import OnnxRuntimeBindings
import MisakiSwift
import MLX
import MLXUtilsLibrary

/// Read on device with
/// `log stream --predicate 'subsystem == "com.doctorpresident.airpad" && category == "kokoro-ort"'`.
private let kokoroOrtLog = Logger(subsystem: "com.doctorpresident.airpad", category: "kokoro-ort")

/// Process resident memory (`phys_footprint`, MB) — the figure iOS jetsam + Xcode use.
/// Diff before/after session load = the ORT model's resident cost (an M1 report metric).
private func ortFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
}

/// QoS of the CURRENT thread — the effective priority the code runs at. Logged at the actual
/// inference site to answer "is the real read-aloud path throttled below the sampler?".
private func qosClassName() -> String {
    switch qos_class_self() {
    case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
    case QOS_CLASS_USER_INITIATED:   return "userInitiated"
    case QOS_CLASS_DEFAULT:          return "default"
    case QOS_CLASS_UTILITY:          return "utility"
    case QOS_CLASS_BACKGROUND:       return "background"
    default:                         return "unspecified"
    }
}

private func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:  return "nominal"
    case .fair:     return "fair"
    case .serious:  return "serious"
    case .critical: return "critical"
    @unknown default: return "?"
    }
}

/// Kokoro phoneme→id vocab (114 entries) from `hexgrad/Kokoro-82M` config.json (Apache-2.0).
/// The SAME map the model was trained with; `n_token = 178`. Embedded (not a resource) so
/// there's no bundle-path risk. MisakiSwift emits these exact IPA symbols.
private let kokoroVocab: [String: Int] = [
    ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10, "\"": 11, "(": 12,
    ")": 13, "“": 14, "”": 15, " ": 16, "̃": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22,
    "ꭧ": 23, "A": 24, "I": 25, "O": 31, "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41, "ᵊ": 42,
    "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48, "h": 50, "i": 51, "j": 52, "k": 53,
    "l": 54, "m": 55, "n": 56, "o": 57, "p": 58, "q": 59, "r": 60, "s": 61, "t": 62, "u": 63,
    "v": 64, "w": 65, "x": 66, "y": 67, "z": 68, "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75,
    "ɔ": 76, "ɕ": 77, "ç": 78, "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86, "ɜ": 87,
    "ɟ": 90, "ɡ": 92, "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103, "ɯ": 110, "ɰ": 111, "ŋ": 112,
    "ɳ": 113, "ɲ": 114, "ɴ": 115, "ø": 116, "ɸ": 118, "θ": 119, "œ": 120, "ɹ": 123, "ɾ": 125,
    "ɻ": 126, "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132, "ʧ": 133, "ʊ": 135, "ʋ": 136,
    "ʌ": 138, "ɣ": 139, "ɤ": 140, "χ": 142, "ʎ": 143, "ʒ": 147, "ʔ": 148, "ˈ": 156, "ˌ": 157,
    "ː": 158, "ʰ": 162, "ʲ": 164, "↓": 169, "→": 171, "↗": 172, "↘": 173, "ᵻ": 177,
]

/// fp32 baseline + quantized variants for the M1.5 footprint measurement. Files live in
/// Resources/Kokoro/ (same tensor contract — only weight precision differs). Switchable at
/// runtime so both can be measured in one session; fp32 stays intact + default.
enum ORTModelVariant: String, CaseIterable, Sendable {
    // int8 is the SHIP choice (T-verified: sounds identical to fp32, 187MB vs 441MB resident,
    // 92MB vs 326MB disk, RTF 0.55). fp32 kept switchable in the dev sampler. q8f16 dropped
    // (dominated — more memory than int8 AND slower).
    case int8, fp32
    var filename: String {
        switch self {
        case .int8:  return "kokoro-v1_0-int8"
        case .fp32:  return "kokoro-v1_0"
        }
    }
    var label: String {
        switch self {
        case .int8:  return "int8"
        case .fp32:  return "fp32"
        }
    }
    var url: URL? { Bundle.main.url(forResource: filename, withExtension: "onnx", subdirectory: "Kokoro") }
}

/// Off-main owner of the ORT session + voice styles + MisakiSwift G2P. An `actor` so the
/// CPU-heavy ORT inference and the ~326 MB model load run OFF the main thread, and the
/// `ORTSession` / `MLXArray` never cross a thread boundary. Only Sendable values (`URL`,
/// `String`, `[Float]`) enter or leave.
actor ORTCore {
    private var env: ORTEnv?
    private var session: ORTSession?
    private var voices: [String: MLXArray] = [:]
    private var g2pUS: EnglishG2P?
    private var g2pGB: EnglishG2P?
    private(set) var inputNames: [String] = []
    private(set) var outputNames: [String] = []
    private var loggedInferenceQoS = false

    var isLoaded: Bool { session != nil }
    var voiceIDs: [String] { Array(voices.keys) }

    /// Drop the session + voices so the next warmUp reloads (used when switching model
    /// variant for the fp32-vs-int8 measurement).
    func evict() {
        session = nil
        env = nil
        voices = [:]
        loggedInferenceQoS = false
    }

    /// Build the ORT session (CPU EP) + load voice styles. Returns cold-load wall time and
    /// whether the CoreML EP is even available (logged so we PROVE we didn't append it).
    func warmUp(modelURL: URL, voicesURL: URL?, intraOpThreads: Int?) throws -> (seconds: Double, coreMLAvailable: Bool) {
        guard session == nil else { return (0, false) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        let opts = try ORTSessionOptions()
        // Optional intra-op thread pin (M3-alongside measurement: default vs explicit). ORT's
        // default may not use all A19 performance cores for a single inference.
        if let n = intraOpThreads { try opts.setIntraOpNumThreads(Int32(n)) }
        // ★★ CPU EXECUTION PROVIDER ONLY. The CoreML EP is OPT-IN in ORT — you must call
        // `appendCoreMLExecutionProvider…`. We DELIBERATELY DO NOT, because CoreML re-enters
        // Espresso/BNNS — the exact libBNNS crash this whole pivot exists to escape. With no
        // EP appended, ORT runs on its own CPU kernels (no BNNS, no Metal).
        let coreMLAvailable = ORTIsCoreMLExecutionProviderAvailable()
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
        self.env = env
        self.session = session
        self.inputNames = (try? session.inputNames()) ?? []
        self.outputNames = (try? session.outputNames()) ?? []
        // Voice styles: the SAME voices.npz the MLX path bundles ([510,1,256] per voice,
        // indexed by phoneme-token count). Reuse NpyzReader; strip the ".npy" key suffix.
        if let voicesURL, let dict = NpyzReader.read(fileFromPath: voicesURL) {
            var norm: [String: MLXArray] = [:]
            for (key, value) in dict {
                norm[String(key.split(separator: ".").first ?? Substring(key))] = value
            }
            voices = norm
        }
        return (CFAbsoluteTimeGetCurrent() - t0, coreMLAvailable)
    }

    private func g2p(british: Bool) -> EnglishG2P {
        if british {
            if g2pGB == nil { g2pGB = EnglishG2P(british: true) }
            return g2pGB!
        }
        if g2pUS == nil { g2pUS = EnglishG2P(british: false) }
        return g2pUS!
    }

    /// text → phonemes (MisakiSwift) → ids (Kokoro vocab) → ORT (CPU) → 24 kHz mono float PCM.
    /// Returns the samples, the inference wall time, and the phoneme count (for telemetry).
    func generate(text: String, voiceID: String) throws -> (samples: [Float], seconds: Double, phonemes: Int) {
        guard let session else { throw KokoroEngineError.modelNotInstalled }
        // ★ QoS/thermal at the ACTUAL inference site (actor executor, inherited from the caller's
        // Task). Answers whether the real read-aloud path runs throttled below the sampler.
        if !loggedInferenceQoS {
            loggedInferenceQoS = true
            kokoroOrtLog.info("★ ORT INFERENCE CONTEXT: qos=\(qosClassName(), privacy: .public) thermal=\(thermalName(), privacy: .public)")
        }
        // British voices (bf_/bm_) use the en-GB frontend; everything else en-US.
        let british = voiceID.hasPrefix("bf_") || voiceID.hasPrefix("bm_")
        let (phonemeString, _) = g2p(british: british).phonemize(text: text)
        // Map each IPA scalar to its id; unknown scalars are dropped (same as Kokoro).
        let tokens: [Int64] = phonemeString.unicodeScalars.compactMap {
            kokoroVocab[String($0)].map(Int64.init)
        }
        guard !tokens.isEmpty else { return ([], 0, 0) }
        guard let voiceArr = voices[voiceID] else { throw KokoroEngineError.voiceUnavailable(voiceID) }

        // style = the 256-dim row at index = phoneme-token count (kokoro-onnx `voice[len(tokens)]`).
        let idx = max(0, min(tokens.count, voiceArr.shape[0] - 1))
        let style: [Float] = voiceArr[idx].asArray(Float.self)
        // input_ids = BOS(0) + tokens + EOS(0), int64.
        var ids: [Int64] = [0]
        ids.append(contentsOf: tokens)
        ids.append(0)
        let speed: [Float] = [1.0]

        let t0 = CFAbsoluteTimeGetCurrent()
        // Hold the backing NSData alive through run() (ORTValue wraps, may not copy).
        let idsData = NSMutableData(bytes: ids, length: ids.count * MemoryLayout<Int64>.size)
        let styleData = NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size)
        let speedData = NSMutableData(bytes: speed, length: speed.count * MemoryLayout<Float>.size)
        let idsVal = try ORTValue(tensorData: idsData, elementType: .int64,
                                  shape: [NSNumber(value: 1), NSNumber(value: ids.count)])
        let styleVal = try ORTValue(tensorData: styleData, elementType: .float,
                                    shape: [NSNumber(value: 1), NSNumber(value: style.count)])
        let speedVal = try ORTValue(tensorData: speedData, elementType: .float,
                                    shape: [NSNumber(value: 1)])
        let inputs: [String: ORTValue] = ["input_ids": idsVal, "style": styleVal, "speed": speedVal]
        let outSet: Set<String> = Set(outputNames.isEmpty ? ["waveform"] : outputNames)
        let result = try session.run(withInputs: inputs, outputNames: outSet, runOptions: nil)
        guard let waveVal = result.values.first else { throw KokoroEngineError.audioBufferFailed }
        let data = try waveVal.tensorData() as Data
        let samples = data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
        _ = (idsData, styleData, speedData)  // keep alive to here
        return (samples, CFAbsoluteTimeGetCurrent() - t0, tokens.count)
    }
}

/// `TTSEngine` conformance for Kokoro on **ONNX Runtime (CPU)** — the pivot away from Core ML/
/// BNNS (Apple libBNNS crash, unfixable) and MLX/Metal (background ban). ORT's CPU kernels touch
/// NEITHER, so both failures are out of reach by construction. This is the MLX path with the
/// inference engine swapped: same MisakiSwift G2P, same voices.npz, same string voice IDs.
/// Produces a whole PCM clip per chunk off-main (the `ORTCore` actor), then plays it through an
/// `AVAudioEngine`/`AVAudioPlayerNode` graph — the proven pattern from `KokoroTTSEngine`.
@MainActor
@Observable
final class ORTKokoroTTSEngine: TTSEngine {
    static let shared = ORTKokoroTTSEngine()

    private static let sampleRate: Double = 24_000

    // Assets in AirPad/Resources/Kokoro/ (folder ref). T drops the ONNX model in, parallel to
    // the MLX safetensors; voices.npz is the SAME file the MLX path already uses. Bundled in-app
    // — NO runtime download (contrast FluidAudio).
    static let voicesURL: URL? = Bundle.main.url(
        forResource: "voices", withExtension: "npz", subdirectory: "Kokoro")

    /// Which weight precision to load. Switching evicts the session so the next play reloads
    /// the new variant (for the fp32-vs-int8 footprint/RTF measurement). fp32 default + intact.
    var modelVariant: ORTModelVariant = .int8 {
        didSet { if oldValue != modelVariant { switchVariant() } }
    }

    /// Intra-op thread count for ORT (nil = ORT default). Changing it reloads the session —
    /// for the M3-alongside measurement (default vs explicit thread count). Not persisted.
    var intraOpThreads: Int? = nil {
        didSet { if oldValue != intraOpThreads { switchVariant() } }
    }

    private let core = ORTCore()

    // Playback graph (main thread; built once).
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var graphReady = false
    private var onFinish: (() -> Void)?
    private var speakTask: Task<Void, Never>?
    private var buffersInFlight = 0
    private var producerDone = false

    // Telemetry.
    private(set) var isLoaded = false
    private(set) var coldLoadSeconds: Double?
    private(set) var lastRTF: Double?
    private(set) var loadedVoiceIDs: [String] = []
    private(set) var loadedFootprintMB: Double?
    private(set) var peakResidentMB: Double?   // peak phys_footprint during the last utterance (M3 #5)

    // ── Warm-up design (ported from the Fluid spike): speculative warm + idle eviction.
    private let idleEvictionSeconds: TimeInterval = 5 * 60
    private var idleTimer: Task<Void, Never>?

    // ── Perceived-wait instrumentation (tap → first AUDIBLE sample out of the mixer, NOT
    //    scheduleBuffer's return). All CFAbsoluteTime.
    private var tTap = 0.0
    private var tColdStart = 0.0
    private var tColdDone = 0.0
    private var tEngineReady = 0.0
    private var tFirstSynthStart = 0.0
    private var tFirstSynthDone = 0.0
    private var tFirstPlay = 0.0
    private var firstAudibleLogged = false
    private var renderTapInstalled = false

    // ── Speculative synthesis seam (build the shape; UNWIRED — M4 wires the trigger). Synthesize
    //    the first chunk to PCM WITHOUT playing, cached by exact (voice, text); speak() plays a
    //    hit instantly. `firstChunkMaxChars` keeps chunk 0 small (~one short sentence ≈ ~2 s at
    //    int8) so first-audio is fast AND the speculative unit is cheap.
    private static let firstChunkMaxChars = 60
    private var specCache: [(key: String, samples: [Float])] = []   // tiny, FIFO
    private let specCacheCap = 4

    private init() {}

    // MARK: TTSEngine

    var isReady: Bool { isModelInstalled }

    /// True only when a plausibly-real ONNX model is bundled (guards a stub / un-pulled LFS
    /// pointer). Real `model.onnx` ≈ 326 MB fp32.
    var isModelInstalled: Bool {
        guard let url = modelVariant.url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 50_000_000
    }

    /// Evict the loaded session on a variant change so the next play reloads the new precision.
    private func switchVariant() {
        stop()
        isLoaded = false
        coldLoadSeconds = nil
        lastRTF = nil
        loadedVoiceIDs = []
        clearSpec()
        Task { await core.evict() }
        kokoroOrtLog.info("ORT session reset (variant=\(self.modelVariant.rawValue, privacy: .public) threads=\(self.intraOpThreads.map(String.init) ?? "default", privacy: .public)) — reloads on next play")
    }

    /// Cold-load the ORT session + voices OFF the launch path. First call does the heavy work
    /// on the actor; later calls are cheap. Logs the active EP (asserts CPU by construction).
    func warmUpIfNeeded() async throws {
        if isLoaded { return }
        guard let modelURL = modelVariant.url, isModelInstalled else {
            throw KokoroEngineError.modelNotInstalled
        }
        let footBefore = ortFootprintMB()
        let (secs, coreMLAvailable) = try await core.warmUp(modelURL: modelURL, voicesURL: Self.voicesURL, intraOpThreads: intraOpThreads)
        let footAfter = ortFootprintMB()
        loadedFootprintMB = footAfter - footBefore
        let inN = await core.inputNames
        let outN = await core.outputNames
        loadedVoiceIDs = await core.voiceIDs.sorted()
        isLoaded = await core.isLoaded
        if secs > 0 { coldLoadSeconds = secs }
        kokoroOrtLog.info("★ ORT cold-load [\(self.modelVariant.rawValue, privacy: .public), threads=\(self.intraOpThreads.map(String.init) ?? "default", privacy: .public)] \(secs, format: .fixed(precision: 2))s · EP=CPU (default; CoreML EP available=\(coreMLAvailable) but DELIBERATELY NOT appended) · resident \(footBefore, format: .fixed(precision: 0))→\(footAfter, format: .fixed(precision: 0))MB (model ≈ \(footAfter - footBefore, format: .fixed(precision: 0))MB) · inputs=\(inN, privacy: .public) · outputs=\(outN, privacy: .public) · voices=\(self.loadedVoiceIDs.count)")
    }

    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws {
        stop()
        noteActivity()  // reset idle-eviction clock
        // Perceived-wait clock. speak() is entered synchronously off the play tap (sub-ms hop).
        // ★ preloaded answers whether cold-load runs now (felt wait includes it) or was already
        // done by a prior play / warm() (felt wait excludes the load).
        tTap = CFAbsoluteTimeGetCurrent()
        firstAudibleLogged = false
        tFirstSynthStart = 0; tFirstSynthDone = 0; tFirstPlay = 0
        let preloaded = isLoaded
        kokoroOrtLog.info("▶ PLAY TAPPED — preloaded=\(preloaded) (cold-load \(preloaded ? "already done" : "runs now"))")

        let chunks = TextChunker.chunk(text, firstChunkMaxChars: Self.firstChunkMaxChars)
        guard !chunks.isEmpty else { return }
        tColdStart = CFAbsoluteTimeGetCurrent()
        try await warmUpIfNeeded()
        tColdDone = CFAbsoluteTimeGetCurrent()
        let id = voiceID ?? "af_heart"

        PlaybackAudioSession.configure()
        ensureGraph()
        if !engine.isRunning { try engine.start() }
        tEngineReady = CFAbsoluteTimeGetCurrent()
        installFirstSampleTap()   // first AUDIBLE frame out of the mixer

        self.onFinish = onFinish
        buffersInFlight = 0
        producerDone = false
        peakResidentMB = ortFootprintMB()
        var totalGen = 0.0
        var totalAudio = 0.0

        kokoroOrtLog.info("speak start: \(chunks.count) chunks, voice=\(id, privacy: .public), variant=\(self.modelVariant.rawValue, privacy: .public), threads=\(self.intraOpThreads.map(String.init) ?? "default", privacy: .public), thermal=\(thermalName(), privacy: .public), mainQoS=\(qosClassName(), privacy: .public)")
        speakTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { return }
                do {
                    if i == 0 { self.tFirstSynthStart = CFAbsoluteTimeGetCurrent() }
                    let samples: [Float]
                    let seconds: Double
                    let phonemes: Int
                    let rBefore = ortFootprintMB()   // resident before this chunk's inference
                    if let cached = self.takeSpec(chunkText: chunk, voiceID: id) {
                        // Speculative HIT — synthesized ahead of the tap; play with ~0 latency.
                        samples = cached; seconds = 0; phonemes = -1
                        kokoroOrtLog.info("chunk \(i) SPECULATIVE HIT — \(cached.count) samples, no synth")
                    } else {
                        let r = try await self.core.generate(text: chunk, voiceID: id)
                        samples = r.samples; seconds = r.seconds; phonemes = r.phonemes
                    }
                    let rAfter = ortFootprintMB()    // resident after — Δ per chunk exposes the arena growth
                    if i == 0 { self.tFirstSynthDone = CFAbsoluteTimeGetCurrent() }
                    if Task.isCancelled { return }
                    guard !samples.isEmpty else { continue }
                    totalGen += seconds
                    totalAudio += Double(samples.count) / Self.sampleRate
                    self.lastRTF = totalAudio > 0 ? totalGen / totalAudio : nil
                    // Track peak resident across the answer (M3 #5 — confirm int8 holds under load).
                    self.peakResidentMB = max(self.peakResidentMB ?? 0, rAfter)
                    kokoroOrtLog.info("chunk \(i)/\(chunks.count) phonemes=\(phonemes) synth \(seconds, format: .fixed(precision: 2))s → \(samples.count) samples, RTF=\(self.lastRTF ?? 0, format: .fixed(precision: 2)) · resident \(rBefore, format: .fixed(precision: 0))→\(rAfter, format: .fixed(precision: 0)) (Δ\(rAfter - rBefore, format: .fixed(precision: 0)))MB")
                    self.schedule(samples: samples)
                    if self.engine.isRunning && !self.player.isPlaying {
                        self.player.play()
                        if self.tFirstPlay == 0 { self.tFirstPlay = CFAbsoluteTimeGetCurrent() }
                    }
                } catch {
                    kokoroOrtLog.error("chunk \(i) synth failed: \(String(describing: error), privacy: .public)")
                }
            }
            self.producerDone = true
            kokoroOrtLog.info("producer done: \(chunks.count) chunks, RTF=\(self.lastRTF ?? 0, format: .fixed(precision: 2)), peakResident=\(self.peakResidentMB ?? 0, format: .fixed(precision: 0))MB")
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
        removeFirstSampleTap()
        guard graphReady else { return }
        player.stop()
        player.reset()
        if engine.isRunning { engine.stop() }
    }

    // MARK: Playback (main thread) — mirrors KokoroTTSEngine

    private var kokoroFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
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
                if self.producerDone && self.buffersInFlight == 0 { self.fireFinish() }
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

    private func fireFinish() {
        removeFirstSampleTap()
        if engine.isRunning { engine.stop() }
        noteActivity()  // playback ended → start the idle-eviction clock from here
        let cb = onFinish; onFinish = nil
        cb?()
    }

    // MARK: Warm-up design (speculative warm + idle eviction) — ported, mechanism only, UNWIRED

    /// Speculative, fire-and-forget model load the UI can call AHEAD of playback. Cheap if
    /// already loaded/loading. Deliberately **not wired to launch or any hook** — the caller
    /// picks the trigger. Failures swallowed (the first real `speak` surfaces + falls back).
    func warm() {
        noteActivity()
        guard !isLoaded else { return }
        Task { @MainActor in try? await warmUpIfNeeded() }
    }

    /// Reset the idle-eviction clock (called on warm/speak/finish) so the model is dropped
    /// only after a genuine quiet period.
    private func noteActivity() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            let secs = self?.idleEvictionSeconds ?? 300
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle()
        }
    }

    /// Drop the loaded model (frees resident RAM) only if nothing is playing/loading.
    private func evictIfIdle() async {
        guard isLoaded, speakTask == nil, buffersInFlight == 0 else { return }
        await core.evict()
        isLoaded = false
        clearSpec()
        kokoroOrtLog.info("idle eviction: released ORT model after \(Int(self.idleEvictionSeconds / 60)) min unused (footprint now \(ortFootprintMB(), format: .fixed(precision: 0))MB)")
    }

    // MARK: Speculative synthesis (UNWIRED — M4 wires the trigger to the chat surface)

    /// Synthesize the FIRST chunk of `text` in `voiceID` to PCM and cache it WITHOUT playing, so
    /// the eventual `speak()` plays it with ~0 latency. Called speculatively (e.g. once the
    /// answer's first sentence has streamed). No-op if already cached. **UNWIRED** — no trigger.
    func speculativeSynthesize(text: String, voiceID: String?) {
        noteActivity()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.warmUpIfNeeded()
                let id = voiceID ?? "af_heart"
                let chunks = TextChunker.chunk(text, firstChunkMaxChars: Self.firstChunkMaxChars)
                guard let first = chunks.first else { return }
                let key = Self.specKey(first, id)
                if self.specCache.contains(where: { $0.key == key }) { return }
                let (samples, seconds, _) = try await self.core.generate(text: first, voiceID: id)
                guard !samples.isEmpty else { return }
                self.insertSpec(key: key, samples: samples)
                kokoroOrtLog.info("speculative synth cached: \(first.count) chars in \(seconds, format: .fixed(precision: 2))s, voice=\(id, privacy: .public) (cache=\(self.specCache.count))")
            } catch {
                kokoroOrtLog.error("speculative synth failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func specKey(_ text: String, _ voiceID: String) -> String { "\(voiceID)\u{1}\(text)" }

    private func insertSpec(key: String, samples: [Float]) {
        specCache.removeAll { $0.key == key }
        specCache.append((key: key, samples: samples))
        if specCache.count > specCacheCap { specCache.removeFirst(specCache.count - specCacheCap) }
    }

    /// Consume a cached speculative chunk (one-shot) if present.
    private func takeSpec(chunkText: String, voiceID: String) -> [Float]? {
        let k = Self.specKey(chunkText, voiceID)
        guard let idx = specCache.firstIndex(where: { $0.key == k }) else { return nil }
        return specCache.remove(at: idx).samples
    }

    private func clearSpec() { specCache.removeAll() }

    // MARK: Perceived-wait render tap (first AUDIBLE sample out of the mixer)

    /// Passive tap on the mixer output; the FIRST non-silent frame = audio actually reaching
    /// the device (the real start of the felt wait, which scheduleBuffer's return does NOT
    /// capture). Detected on the audio thread; logged + removed on main.
    private func installFirstSampleTap() {
        guard graphReady, !renderTapInstalled else { return }
        let node = engine.mainMixerNode
        node.installTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { [weak self] buf, _ in
            guard Self.hasAudio(buf) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            Task { @MainActor [weak self] in self?.logPerceivedWait(firstSampleAt: now) }
        }
        renderTapInstalled = true
    }

    private func removeFirstSampleTap() {
        guard renderTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        renderTapInstalled = false
    }

    private nonisolated static func hasAudio(_ buf: AVAudioPCMBuffer) -> Bool {
        guard let ch = buf.floatChannelData else { return false }
        let n = Int(buf.frameLength)
        let p = ch[0]
        var i = 0
        while i < n { if abs(p[i]) > 1e-4 { return true }; i += 1 }
        return false
    }

    /// Emit the full tap→first-audible interval + breakdown. Fires once per utterance.
    private func logPerceivedWait(firstSampleAt tFirst: Double) {
        guard !firstAudibleLogged, tTap > 0 else { return }
        firstAudibleLogged = true
        removeFirstSampleTap()
        let total     = tFirst - tTap
        let tapToCold = tColdStart - tTap
        let cold      = tColdDone - tColdStart
        let sessEng   = tEngineReady - tColdDone
        let synth     = (tFirstSynthStart > 0 && tFirstSynthDone > 0) ? tFirstSynthDone - tFirstSynthStart : 0
        let playToAud = (tFirstPlay > 0) ? tFirst - tFirstPlay : tFirst - tEngineReady
        kokoroOrtLog.info("★ PERCEIVED WAIT tap→first-audible = \(total, format: .fixed(precision: 2))s  [tap→coldStart \(tapToCold, format: .fixed(precision: 3))s · cold-load \(cold, format: .fixed(precision: 2))s · session+engine \(sessEng, format: .fixed(precision: 3))s · synth(chunk0) \(synth, format: .fixed(precision: 2))s · play→audible \(playToAud, format: .fixed(precision: 3))s]  variant=\(self.modelVariant.rawValue, privacy: .public)")
    }
}
