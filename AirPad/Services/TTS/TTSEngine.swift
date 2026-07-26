import Foundation
import AVFoundation

/// The "produce + play" seam. A TTS engine takes text and makes it audible;
/// HOW is the engine's business. Two shapes live behind this:
///
///   • `SystemTTSEngine`  — `AVSpeechSynthesizer` self-plays as it synthesizes
///     (streaming, instant start). This is the default and mirrors what
///     `SpeechSynthesisService` already does in production.
///   • `KokoroTTSEngine`  — an MLX model PRODUCES a whole PCM clip, then we PLAY
///     it through `AVAudioEngine`. Higher latency to first sound (the clip is
///     generated up front), on-device, no network.
///
/// The seam is deliberately small: `speak` is `async` because Kokoro must
/// produce before it can play, and `onFinish` fires once playback ends
/// naturally (never on `stop()`), so a caller can reset its own control state.
/// State/now-playing/remote-command ownership stays with the CALLER
/// (`SpeechSynthesisService`), not the engine — an engine only makes sound.
@MainActor
protocol TTSEngine: AnyObject {
    /// Whether this engine can synthesize right now. `SystemTTSEngine` is always
    /// ready; `KokoroTTSEngine` is ready only once its model file is installed.
    var isReady: Bool { get }

    /// Produce `text` in `voiceID` (engine-specific identifier; nil = default)
    /// and start playback. `onFinish` fires on natural completion only.
    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws

    func pause()
    func resume()
    func stop()
}

enum KokoroEngineError: LocalizedError {
    /// The `kokoro-v1_0.safetensors` weights aren't bundled (T drops them in).
    case modelNotInstalled
    /// Requested a voice id that isn't present in the loaded `voices.npz`.
    case voiceUnavailable(String)
    /// Couldn't build the PCM buffer for playback.
    case audioBufferFailed

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "Kokoro model not installed. Drop kokoro-v1_0.safetensors + voices.npz into AirPad/Resources/Kokoro/."
        case .voiceUnavailable(let id):
            return "Voice “\(id)” is not in the loaded voices file."
        case .audioBufferFailed:
            return "Failed to build the audio buffer for Kokoro output."
        }
    }
}

/// Thin wrapper over `AVSpeechSynthesizer` conforming to the seam. This is what
/// the app's production read-aloud already is; kept minimal here to prove the
/// protocol has two real conformances and to give the sampler an A/B baseline
/// (system voices vs Kokoro voices). It intentionally does NOT own now-playing
/// or remote-command wiring — that stays in `SpeechSynthesisService`.
@MainActor
final class SystemTTSEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var active: AVSpeechUtterance?
    private var onFinish: (() -> Void)?

    var isReady: Bool { true }

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(text: String, voiceID: String?, onFinish: @escaping () -> Void) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        PlaybackAudioSession.configure()
        let u = AVSpeechUtterance(string: trimmed)
        if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) { u.voice = v }
        self.active = u
        self.onFinish = onFinish
        synth.speak(u)
    }

    func pause()  { if synth.isSpeaking { synth.pauseSpeaking(at: .word) } }
    func resume() { synth.continueSpeaking() }
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        active = nil
        onFinish = nil
    }

    // Reset only for the currently-active utterance — a late cancel for a
    // superseded utterance must not fire the new one's completion.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            guard u === active else { return }
            let cb = onFinish; onFinish = nil; active = nil
            cb?()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in
            guard u === active else { return }
            onFinish = nil; active = nil
        }
    }
}
