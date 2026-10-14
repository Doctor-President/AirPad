import Foundation
import AVFoundation
import Observation

/// live-11 (4) — the voice recorder's engine (T approved the renders 2026-10-13). One `AVAudioEngine` input tap writes
/// the take to an AAC file, drives the waveform, and feeds the live on-device recogniser (`LiveVoiceEngine.swift`), so
/// the words appear as they're spoken and the live text is what's saved. Replaces `AVAudioRecorder` + a file
/// transcription after Done (which replayed the words — T: "rapid and not useful").
@MainActor @Observable
final class LiveVoiceRecorder {
    private(set) var settled = ""
    private(set) var volatile = ""
    private(set) var levels: [Float] = Array(repeating: 0, count: 40)
    private(set) var elapsed: TimeInterval = 0
    /// No on-device recognition for this take (language/device/model): the audio is kept, the item says so.
    private(set) var unavailable = false

    struct Take { let url: URL; let transcript: String; let duration: TimeInterval; let transcriptUnavailable: Bool }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sink: TapSink?
    @ObservationIgnored private var transcriber: (any LiveTranscribing)?
    @ObservationIgnored private var take: Take?

    /// Opens the microphone and starts listening. False ⇒ the microphone couldn't start (nothing to save).
    func start() async -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[VoiceCapture] Audio session error: \(error)")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { print("[VoiceCapture] no microphone input"); return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                              AVNumberOfChannelsKey: format.channelCount,
                                              AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue],
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            print("[VoiceCapture] file error: \(error)"); return false
        }

        let transcriber = await Self.makeTranscriber(micFormat: format) { [weak self] settled, volatile in
            Task { @MainActor in self?.settled = settled; self?.volatile = volatile }
        }
        unavailable = transcriber == nil
        self.transcriber = transcriber

        #if DEBUG
        let renderEnvelope = VoiceCaptureSheet.stubLiveTranscript != nil
        #else
        let renderEnvelope = false
        #endif
        let sink = TapSink(file: file, url: url, sampleRate: format.sampleRate, transcriber: transcriber) { [weak self] mic, seconds in
            // Recorder render (`-StubLiveTranscript`, DEBUG): the Simulator's microphone hears a quiet room, so the bars
            // follow a speech-shaped envelope instead — the same one the approved renders used.
            let level = renderEnvelope ? Self.speechEnvelope(at: seconds) : mic
            Task { @MainActor in
                guard let self else { return }
                self.levels.append(level)
                if self.levels.count > 40 { self.levels.removeFirst() }
                self.elapsed = seconds
            }
        }
        self.sink = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in sink.receive(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            print("[VoiceCapture] engine error: \(error)")
            input.removeTap(onBus: 0); transcriber?.cancel()
            return false
        }
        return true
    }

    /// Done (or leaving the app): stop listening, close the file, wait for the last words. Idempotent: a second call
    /// returns the same take.
    func stop() async -> Take? {
        if let take { return take }
        guard let sink else { return nil }
        stopEngine()
        let (url, duration) = sink.close()
        let result = await transcriber?.finish() ?? (text: "", unavailable: true)
        transcriber = nil
        deactivateSession()
        let t = Take(url: url, transcript: result.text, duration: duration,
                     transcriptUnavailable: unavailable || (result.unavailable && result.text.isEmpty))
        take = t
        return t
    }

    /// Cancel / dismiss: free the microphone now, keep nothing running. Idempotent (BUG 8).
    func teardown() {
        stopEngine()
        transcriber?.cancel(); transcriber = nil
        deactivateSession()
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func deactivateSession() {
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { print("[VoiceCapture] Session deactivate error: \(error)") }
    }

    nonisolated static func speechEnvelope(at t: TimeInterval) -> Float {
        let syllable = max(0, sin(2 * .pi * 3.1 * t)) * (0.55 + 0.45 * sin(2 * .pi * 0.37 * t + 1.3))
        return Float(t.truncatingRemainder(dividingBy: 3.2) < 2.7 ? 0.12 + 0.8 * syllable : 0.04)
    }

    /// The recogniser for this take, always on-device (built by `OnDeviceSpeech`): the iOS 26 analyzer when its model is
    /// on the phone, else the on-device `SFSpeechRecognizer`, else nil (unavailable — the audio is still kept).
    private static func makeTranscriber(micFormat: AVAudioFormat,
                                        onUpdate: @escaping @Sendable (String, String) -> Void) async -> (any LiveTranscribing)? {
        #if DEBUG
        if CommandLine.arguments.contains("-StubSpeechUnavailable") { return nil }
        if let stub = VoiceCaptureSheet.stubTranscript ?? VoiceCaptureSheet.stubLiveTranscript {
            return StubLiveTranscriber(stub: stub, onUpdate: onUpdate)
        }
        #endif
        if #available(iOS 26.0, *), let (analyzer, live) = await OnDeviceSpeech.liveAnalyzer(),
           let t = await AnalyzerLiveTranscriber.start(analyzer: analyzer, live: live, micFormat: micFormat, onUpdate: onUpdate) {
            print("[Speech] recorder: on-device analyzer (\(OnDeviceSpeech.liveModel.rawValue))")
            return t
        }
        if let recognizer = OnDeviceSpeech.recognizer() {
            print("[Speech] recorder: on-device SFSpeechRecognizer (segmented)")
            return SegmentedLiveTranscriber(recognizer: recognizer, onUpdate: onUpdate)
        }
        print("[Speech] recorder: on-device recognition unavailable — audio only")
        return nil
    }
}

/// What the audio thread touches: the file, the recogniser, the level meter. Every buffer is written whole (no
/// recording-length limit of its own); the file is closed exactly once.
private final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let url: URL
    private let sampleRate: Double
    private let transcriber: (any LiveTranscribing)?
    private let onLevel: @Sendable (Float, TimeInterval) -> Void
    private var frames: AVAudioFramePosition = 0
    private var lastLevelAt: AVAudioFramePosition = 0

    init(file: AVAudioFile, url: URL, sampleRate: Double, transcriber: (any LiveTranscribing)?,
         onLevel: @escaping @Sendable (Float, TimeInterval) -> Void) {
        self.file = file; self.url = url; self.sampleRate = sampleRate; self.transcriber = transcriber; self.onLevel = onLevel
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        let written: AVAudioFramePosition? = lock.withLock {
            guard let file else { return nil }
            do { try file.write(from: buffer) } catch { print("[VoiceCapture] write error: \(error)") }
            frames += AVAudioFramePosition(buffer.frameLength)
            return frames
        }
        guard let written else { return }
        transcriber?.append(buffer)
        // ~20 waveform bars a second, as before.
        if Double(written - lastLevelAt) >= sampleRate / 20 {
            lastLevelAt = written
            onLevel(Self.level(buffer), Double(written) / sampleRate)
        }
    }

    func close() -> (URL, TimeInterval) {
        lock.withLock {
            file = nil   // releasing the AVAudioFile finishes the AAC stream
            return (url, Double(frames) / sampleRate)
        }
    }

    /// RMS → 0…1 on the same scale the old meter used (~-50 dB … 0 dB).
    private static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return 0 }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        return max(0, min(1, (db + 50) / 50))
    }
}
