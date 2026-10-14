import Foundation
import AVFoundation
import Speech
import Observation

/// Arc A (T approved, 2026-10-12) — the app's own words, passed as `contextualStrings` on every speech
/// request (voice capture, imported audio, live dictation) so the recognizer favours them: "AirPad" was
/// transcribing as "ear pad(s)". App vocabulary only — never anything from a person's library.
enum SpeechVocabulary {
    static let contextualStrings = ["AirPad", "AirPad Host", "Librarian", "Quick Capture", "Recents",
                                    "Sample Library", "Curious Objects"]
}

/// live-10 (4) — ★ T approved 2026-10-13: speech never leaves the device. Every recognition request in the app is
/// built here and requires on-device recognition. When this iPhone can't transcribe the language on-device, the
/// audio is still kept and its transcript area says so — there is no silent fallback to Apple's server.
enum OnDeviceSpeech {
    static let unavailableMessage = "Transcript unavailable — this iPhone can't transcribe this language on-device."

    /// The current locale's recognizer, only when it can transcribe on-device. Nil ⇒ unavailable (never the server).
    static func recognizer(locale: Locale = .current) -> SFSpeechRecognizer? {
        #if DEBUG
        if CommandLine.arguments.contains("-StubSpeechUnavailable") { return nil }
        #endif
        guard let r = SFSpeechRecognizer(locale: locale), canTranscribe(supportsOnDevice: r.supportsOnDeviceRecognition) else { return nil }
        return r
    }

    /// On-device support is the whole test. `isAvailable` is deliberately not consulted: it can read false offline (it
    /// tracks the server path), and offline — airplane mode — is exactly where on-device must still work. If the
    /// on-device engine then can't run, the task errors and the item is marked unavailable.
    static func canTranscribe(supportsOnDevice: Bool) -> Bool { supportsOnDevice }

    /// A recorded file (voice capture, shared-in audio).
    static func fileRequest(url: URL, partialResults: Bool) -> SFSpeechURLRecognitionRequest {
        let r = SFSpeechURLRecognitionRequest(url: url)
        r.shouldReportPartialResults = partialResults
        configure(r)
        return r
    }

    /// Live microphone buffers (Librarian Search / Ask dictation).
    static func bufferRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        configure(r)
        return r
    }

    private static func configure(_ r: SFSpeechRecognitionRequest) {
        r.requiresOnDeviceRecognition = true
        r.contextualStrings = SpeechVocabulary.contextualStrings
    }

    /// A recognition error that ended with no words reads as "unavailable on-device" — unless it was only silence
    /// or a cancel. The domain/code is logged (never the audio or words) so a device log shows which it was.
    static func meansUnavailable(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == "kAFAssistantErrorDomain", [1110, 216, 301].contains(e.code) { return false }   // no speech · cancelled
        if e.domain == NSCocoaErrorDomain, e.code == NSUserCancelledError { return false }
        return true
    }

    /// `-OnDeviceSpeechSelfTest` — every request builder the app uses, plus the unavailable path. Synthetic only.
    static func selfTest() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool) { rows.append("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { fails += 1 } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.m4a")
        let voice = fileRequest(url: url, partialResults: true)      // VoiceCaptureSheet.transcribe
        let shared = fileRequest(url: url, partialResults: false)    // CorpusStore.transcribeAudioFile
        let dictation = bufferRequest()                              // LiveDictationService.start
        row("voice-capture-request-on-device", voice.requiresOnDeviceRecognition)
        row("shared-audio-request-on-device", shared.requiresOnDeviceRecognition)
        row("dictation-request-on-device", dictation.requiresOnDeviceRecognition)
        row("vocabulary-kept-on-every-request",
            [voice, shared, dictation].allSatisfy { $0.contextualStrings == SpeechVocabulary.contextualStrings })
        row("no-server-fallback-when-unsupported", !canTranscribe(supportsOnDevice: false))
        row("on-device-capable-transcribes", canTranscribe(supportsOnDevice: true))
        row("silence-is-not-unavailable", !meansUnavailable(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        row("engine-error-is-unavailable", meansUnavailable(NSError(domain: "kLSRErrorDomain", code: 300)))
        var item = NodeItem.audio(file: "items/x.m4a", transcript: "", duration: 3)
        item.transcriptUnavailable = true
        let enc = JSONEncoder(), dec = JSONDecoder()
        let json = (try? enc.encode(item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let back = (try? enc.encode(item)).flatMap { try? dec.decode(NodeItem.self, from: $0) }
        let legacy = try? dec.decode(NodeItem.self, from: Data(#"{"id":"a","type":"audio","created_at":0}"#.utf8))
        row("unavailable-mark-round-trips", json.contains("\"transcript_unavailable\":true") && back?.transcriptUnavailable == true
            && legacy != nil && legacy?.transcriptUnavailable == nil)
        return "[OnDeviceSpeechSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}

/// A3 (T, TF 202610131010) — the app's own words may reach a generated title or summary only when the entry itself
/// uses them. Case-insensitive; "librarian" in a note about a librarian is the note's word, not a leak.
enum AppTermLeak {
    static let terms = SpeechVocabulary.contextualStrings
    static func leaked(in output: String, content: String) -> [String] {
        terms.filter { output.range(of: $0, options: .caseInsensitive) != nil && content.range(of: $0, options: .caseInsensitive) == nil }
    }

    /// `-AppTermLeakSelfTest` — synthetic rows only.
    static func selfTest() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool) { rows.append("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { fails += 1 } }
        let spoken = "Walked the orchard with Sam after lunch; the first frost is due next week"
        row("summary-naming-the-app-is-a-leak", leaked(in: "Sam and the Librarian enjoy autumn at the orchard", content: spoken) == ["Librarian"])
        row("title-naming-the-app-is-a-leak", leaked(in: "AirPad orchard walk", content: spoken) == ["AirPad"])
        row("clean-summary-passes", leaked(in: "An orchard walk with Sam before the first frost", content: spoken).isEmpty)
        row("the-entry's-own-word-passes", leaked(in: "Returning books to the librarian", content: "Return the books to the librarian by Friday").isEmpty)
        row("instructions-name-no-app-term", terms.allSatisfy { AIService.namingInstructions.range(of: $0, options: .caseInsensitive) == nil })
        return "[AppTermLeakSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}

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
        guard speech == .authorized else { return }
        // live-10 (4) — on-device only: no on-device recognizer for this language/device ⇒ no dictation (never the server).
        guard let recognizer = OnDeviceSpeech.recognizer() else {
            print("[Speech] dictation not started — on-device recognition unavailable")
            return
        }

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

        // On-device only (live-10 (4)): near-instant partials + audio never leaves the device (privacy spine).
        let req = OnDeviceSpeech.bufferRequest()
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
