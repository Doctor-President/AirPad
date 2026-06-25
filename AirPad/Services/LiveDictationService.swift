import Foundation
import AVFoundation
import Speech
import Observation

/// Shared live-dictation engine. Buffer-based SFSpeechRecognizer +
/// AVAudioEngine tap streaming partial results into a caller-supplied
/// closure. ONE engine, owned as a singleton — the Librarian Search
/// and Ask fields are its first two consumers; the VoiceCaptureSheet
/// upgrade is a future third. Only one field dictates at a time
/// (`activeToken`). On stop it deactivates the audio session
/// (mirrors VoiceCaptureSheet) so a subsequent playback path can
/// reclaim `.playback` via PlaybackAudioSession — the invariant the
/// PlaybackAudioSession header warns about.
@MainActor
@Observable
final class LiveDictationService {
    static let shared = LiveDictationService()
    private init() {}

    /// True while the engine is actively listening.
    private(set) var isListening = false
    /// Caller-supplied identity of the field that currently owns the
    /// engine ("search" / "ask"). Lets each field's glyph show the
    /// stop state only when IT is the active dictation target.
    private(set) var activeToken: String? = nil

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var baseline: String = ""
    private var onUpdate: ((String) -> Void)?

    /// Tap-to-toggle entry point. Same field tapped while listening →
    /// stop. A different field tapped while listening → stop the old,
    /// start the new. Idle → start.
    func toggle(token: String, baseline: String, onUpdate: @escaping (String) -> Void) {
        if isListening && activeToken == token {
            stop()
        } else {
            if isListening { stop() }
            Task { await start(token: token, baseline: baseline, onUpdate: onUpdate) }
        }
    }

    private func start(token: String, baseline: String, onUpdate: @escaping (String) -> Void) async {
        // Permissions — bail silently if either is denied (build 1
        // keeps the denied-state UI out of scope; glyph stays mic).
        let mic = await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        guard mic else { return }
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized,
              let recognizer, recognizer.isAvailable else { return }

        self.baseline = baseline
        self.onUpdate = onUpdate

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[LiveDictation] Session error: \(error)")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // On-device when the locale model is available: near-instant
        // partials + audio never leaves the device (privacy spine).
        // Falls back to default (server-capable) path when unsupported.
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req

        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)   // audio thread — append is the only off-main call
        }

        engine.prepare()
        do { try engine.start() } catch {
            print("[LiveDictation] Engine error: \(error)")
            teardownAudio()
            return
        }

        isListening = true
        activeToken = token

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                Task { @MainActor in
                    let base = self.baseline
                    let combined = base.isEmpty ? spoken : base + " " + spoken
                    self.onUpdate?(combined)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
    }

    /// Stop + restore. Removes the tap, stops the engine, ends the
    /// request, cancels the task, deactivates the session. Idempotent.
    func stop() {
        guard isListening || request != nil else { return }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        teardownAudio()
        isListening = false
        activeToken = nil
        onUpdate = nil
    }

    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
