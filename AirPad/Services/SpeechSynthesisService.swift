import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import Observation

/// Shared text-to-speech engine. On-device AVSpeechSynthesizer — no
/// network, audio stays local (privacy spine). ONE engine as a
/// singleton; Librarian chat responses are the first consumer, SB121
/// "TTS on Note" the planned second. Only one utterance at a time
/// (`activeToken`). Flips the audio session to `.playback` before
/// speaking via PlaybackAudioSession — dictation/voice-capture leave
/// the session at `.record`, and the PlaybackAudioSession header warns
/// a playback path that doesn't reclaim `.playback` goes silent.
@MainActor
@Observable
final class SpeechSynthesisService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynthesisService()

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    /// Identity of the content currently being read (exchange id / node
    /// id). Lets each response show the stop state only when IT is the
    /// one speaking.
    private(set) var activeToken: String? = nil

    /// User-chosen voice identifier, persisted. nil = use bestVoice.
    /// Stored property (not a computed UserDefaults passthrough) so
    /// @Observable tracks it and the picker reflects changes; didSet
    /// write-through persists across launches.
    var selectedVoiceIdentifier: String? {
        didSet {
            UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Self.voiceKey)
            // A voice change can't apply mid-utterance — stop so the
            // controls return to a clean idle state. Next play uses
            // the new voice. (Without this the button's token state
            // and the synth's actual state drift → stuck control.)
            if isSpeaking { stop() }
        }
    }
    private static let voiceKey = "tts.selectedVoiceIdentifier"

    /// User-chosen Kokoro voice id (e.g. "af_heart"). nil = use the system
    /// AVSpeech voice (the default). Persisted. Changing it stops any in-flight
    /// speech so the next play starts cleanly on the newly-chosen engine/voice.
    var selectedKokoroVoiceID: String? {
        didSet {
            UserDefaults.standard.set(selectedKokoroVoiceID, forKey: Self.kokoroVoiceKey)
            if isSpeaking { stop() }
        }
    }
    private static let kokoroVoiceKey = "tts.selectedKokoroVoiceID"

    /// When true, a chosen Kokoro voice routes through the **ANE** engine
    /// (`FluidKokoroTTSEngine`, Core ML, no GPU) instead of the MLX engine — the
    /// background-survival spike. Persisted. Set by the "ANE Voices" picker tier.
    /// Changing it stops any in-flight speech so the next play starts on the
    /// newly-chosen engine.
    var useANEKokoro: Bool = false {
        didSet {
            UserDefaults.standard.set(useANEKokoro, forKey: Self.aneKokoroKey)
            if isSpeaking { stop() }
        }
    }
    private static let aneKokoroKey = "tts.useANEKokoro"

    /// Which engine owns the CURRENTLY-active utterance. Fixed at speak-time (the
    /// selection can change mid-utterance) so pause/resume/stop/remote-commands
    /// route to the right engine.
    private var activeEngineIsKokoro = false
    /// Same, for the ANE engine. Mutually exclusive with `activeEngineIsKokoro`.
    private var activeEngineIsANE = false
    /// Same, for the ORT engine (the ship path). Mutually exclusive with the others.
    private var activeEngineIsORT = false

    /// ★ Route to the ORT Kokoro engine (ONNX Runtime CPU — the SHIP path, escapes the
    /// libBNNS crash + the Metal-in-background ban) whenever a Kokoro voice is chosen AND the
    /// ORT model is bundled. Checked FIRST, so with the model present all Kokoro-voice
    /// read-aloud goes through ORT; ANE/MLX stay as fallbacks + the dev sampler. A setup
    /// failure falls back to AVSpeech (see `speakViaORT`).
    private var shouldUseORT: Bool {
        selectedKokoroVoiceID != nil && ORTKokoroTTSEngine.shared.isModelInstalled
    }

    /// Route to the ANE Kokoro engine when a Kokoro voice is chosen AND the ANE
    /// spike is enabled. Models download on demand, so there's no bundled-asset
    /// gate; a setup failure falls back to AVSpeech (see `speakViaANEKokoro`).
    /// Checked BEFORE `shouldUseKokoro` so ANE wins when enabled.
    private var shouldUseANE: Bool {
        useANEKokoro && selectedKokoroVoiceID != nil
    }

    /// Route to the MLX Kokoro engine only when a Kokoro voice is chosen AND its
    /// model is actually installed — otherwise fall back to AVSpeech (a Release
    /// build with no bundled model, or the dev asset absent, must still read aloud).
    private var shouldUseKokoro: Bool {
        selectedKokoroVoiceID != nil && KokoroTTSEngine.shared.isModelInstalled
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var remoteCommandsConfigured = false

    /// The utterance whose lifecycle owns the current state. Switching turns
    /// stops the previous utterance, and `stopSpeaking` delivers `didCancel`
    /// ASYNCHRONOUSLY — after `speak()` has already installed the new one. The
    /// delegate compares against this so a stale cancel/finish can't clobber
    /// the freshly-started utterance's state (the "won't pause after switching"
    /// bug).
    private var activeUtterance: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
        selectedKokoroVoiceID = UserDefaults.standard.string(forKey: Self.kokoroVoiceKey)
        useANEKokoro = UserDefaults.standard.bool(forKey: Self.aneKokoroKey)
        registerInterruptionObserver()
    }

    /// Handle audio-session interruptions (phone call, another app taking the
    /// session). AVSpeech manages its own resume, but the Kokoro AVAudioEngine
    /// path does not — so on `.began` we pause the active utterance, and on
    /// `.ended` with `.shouldResume` we re-assert `.playback` and resume it.
    /// Block-based observer so the callback can hop to the main actor cleanly
    /// (the notification is posted on an arbitrary thread).
    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            Task { @MainActor [weak self] in
                self?.onInterruption(rawType: raw, shouldResume: shouldResume)
            }
        }
    }

    @MainActor
    private func onInterruption(rawType: UInt, shouldResume: Bool) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            if isSpeaking && !isPaused { pauseCurrent() }
        case .ended:
            if isSpeaking && isPaused && shouldResume {
                PlaybackAudioSession.configure()   // re-assert .playback + active
                resumeCurrent()
            }
        @unknown default:
            break
        }
    }

    /// Wire MPRemoteCommandCenter once on first speak — needed so the
    /// lock-screen + Control Center transport bar controls drive the
    /// synthesizer instead of the system's default no-op handlers.
    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.isPaused else { return .commandFailed }
            self.resumeCurrent()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isSpeaking, !self.isPaused else { return .commandFailed }
            self.pauseCurrent()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isSpeaking else { return .commandFailed }
            if self.isPaused { self.resumeCurrent() } else { self.pauseCurrent() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
    }

    private static let nowPlayingArtwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "NowPlayingArtwork") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }()

    private func setNowPlaying(title: String) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "AirPad"
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        if let art = Self.nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// End-of-playback teardown: clear now-playing AND release the audio session
    /// (with `.notifyOthersOnDeactivation`) so AirPad stops holding audio focus —
    /// music/podcasts can resume. Called on explicit stop + natural completion,
    /// NOT on pause or a mid-switch cancel.
    private func endPlaybackSession() {
        clearNowPlaying()
        PlaybackAudioSession.deactivate()
    }

    /// Installed voices for the current language, best quality first.
    /// Drives the picker. Premium/enhanced surface at the top so the
    /// user sees the good ones first (and notices if they only have
    /// the robotic default — prompting a download).
    /// Resolved once and cached — voice list doesn't change mid-run.
    static let availableVoices: [AVSpeechSynthesisVoice] = {
        let prefix = String(Locale.current.identifier.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                return a.name < b.name
            }
    }()

    /// The voice speak() actually uses: explicit user choice if set +
    /// still installed, else bestVoice.
    private var resolvedVoice: AVSpeechSynthesisVoice? {
        if let id = selectedVoiceIdentifier,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return Self.bestVoice
    }

    /// Pick the highest-quality installed voice for the current
    /// language. Apple's Siri voice is NOT exposed to apps, but
    /// premium/enhanced downloadable voices ARE usable when the user
    /// has installed them (Settings → Accessibility → Spoken Content
    /// → Voices). Prefer premium > enhanced > default; fall back to
    /// the system default for the language if none are installed.
    /// Resolved once and cached — voice list doesn't change mid-run.
    private static let bestVoice: AVSpeechSynthesisVoice? = {
        let lang = Locale.current.identifier
        let langPrefix = String(lang.prefix(2))
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(langPrefix)
        }
        func best(in pool: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            pool.first { $0.quality == .premium }
                ?? pool.first { $0.quality == .enhanced }
                ?? pool.first
        }
        // Prefer exact locale match (e.g. en-US), else any same-language.
        let exact = all.filter { $0.language == lang }
        return best(in: exact)
            ?? best(in: all)
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// 3-state toggle: idle → speak, speaking → pause, paused → resume.
    /// Different token always restarts a fresh utterance.
    func toggle(token: String, text: String) {
        if activeToken == token && isSpeaking {
            if isPaused { resumeCurrent() } else { pauseCurrent() }
        } else {
            speak(token: token, text: text)
        }
    }

    /// Pause the active utterance on whichever engine owns it.
    private func pauseCurrent() {
        guard isSpeaking, !isPaused else { return }
        if activeEngineIsORT { ORTKokoroTTSEngine.shared.pause() }
        else if activeEngineIsANE { FluidKokoroTTSEngine.shared.pause() }
        else if activeEngineIsKokoro { KokoroTTSEngine.shared.pause() }
        else { synthesizer.pauseSpeaking(at: .word) }
        isPaused = true
        updateNowPlayingPlaybackState()
    }

    /// Resume the active utterance on whichever engine owns it.
    private func resumeCurrent() {
        guard isSpeaking, isPaused else { return }
        if activeEngineIsORT { ORTKokoroTTSEngine.shared.resume() }
        else if activeEngineIsANE { FluidKokoroTTSEngine.shared.resume() }
        else if activeEngineIsKokoro { KokoroTTSEngine.shared.resume() }
        else { synthesizer.continueSpeaking() }
        isPaused = false
        updateNowPlayingPlaybackState()
    }

    private func speak(token: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Stop whatever is currently playing on ANY engine before starting.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        KokoroTTSEngine.shared.stop()
        FluidKokoroTTSEngine.shared.stop()
        ORTKokoroTTSEngine.shared.stop()

        // Reclaim playback — dictation/capture may have left .record.
        PlaybackAudioSession.configure()

        isSpeaking = true
        isPaused = false
        activeToken = token
        configureRemoteCommandsIfNeeded()
        setNowPlaying(title: "AirPad")

        // Reset engine ownership, then set the winner. ORT (ship path) wins first.
        activeEngineIsORT = false
        activeEngineIsANE = false
        activeEngineIsKokoro = false
        if shouldUseORT, let voiceID = selectedKokoroVoiceID {
            activeEngineIsORT = true
            activeUtterance = nil          // AVSpeech delegates key off this; nil = "not mine"
            speakViaORT(token: token, text: trimmed, voiceID: voiceID)
        } else if shouldUseANE, let voiceID = selectedKokoroVoiceID {
            activeEngineIsANE = true
            activeUtterance = nil          // AVSpeech delegates key off this; nil = "not mine"
            speakViaANEKokoro(token: token, text: trimmed, voiceID: voiceID)
        } else if shouldUseKokoro, let voiceID = selectedKokoroVoiceID {
            activeEngineIsKokoro = true
            activeUtterance = nil          // AVSpeech delegates key off this; nil = "not mine"
            speakViaKokoro(token: token, text: trimmed, voiceID: voiceID)
        } else {
            let utterance = AVSpeechUtterance(string: trimmed)
            if let voice = resolvedVoice { utterance.voice = voice }
            // Defaults (rate 0.5, pitch 1.0) — dial later if Tom wants.
            activeUtterance = utterance
            synthesizer.speak(utterance)
        }
    }

    /// ORT Kokoro path (ONNX Runtime CPU — the ship path): streaming chunked synthesis → PCM →
    /// AVAudioEngine. Same contract as the others; a setup failure falls back to AVSpeech.
    private func speakViaORT(token: String, text: String, voiceID: String) {
        Task { @MainActor in
            do {
                try await ORTKokoroTTSEngine.shared.speak(text: text, voiceID: voiceID) { [weak self] in
                    guard let self, self.activeEngineIsORT, self.activeToken == token else { return }
                    self.isSpeaking = false
                    self.isPaused = false
                    self.activeToken = nil
                    self.endPlaybackSession()
                }
            } catch {
                guard self.activeToken == token else { return }
                self.activeEngineIsORT = false
                let utterance = AVSpeechUtterance(string: text)
                if let voice = self.resolvedVoice { utterance.voice = voice }
                self.activeUtterance = utterance
                self.synthesizer.speak(utterance)
            }
        }
    }

    /// ANE Kokoro path: streaming chunked Core ML synthesis → PCM → AVAudioEngine.
    /// Same contract as `speakViaKokoro`; on a setup failure (offline first run,
    /// unsupported OS) it falls back to AVSpeech so the answer still reads.
    private func speakViaANEKokoro(token: String, text: String, voiceID: String) {
        Task { @MainActor in
            do {
                try await FluidKokoroTTSEngine.shared.speak(text: text, voiceID: voiceID) { [weak self] in
                    guard let self, self.activeEngineIsANE, self.activeToken == token else { return }
                    self.isSpeaking = false
                    self.isPaused = false
                    self.activeToken = nil
                    self.endPlaybackSession()
                }
            } catch {
                guard self.activeToken == token else { return }
                self.activeEngineIsANE = false
                let utterance = AVSpeechUtterance(string: text)
                if let voice = self.resolvedVoice { utterance.voice = voice }
                self.activeUtterance = utterance
                self.synthesizer.speak(utterance)
            }
        }
    }

    /// Kokoro path: streaming chunked synthesis → PCM → AVAudioEngine. Returns
    /// after the producer is launched; `onFinish` fires at natural end. On a
    /// setup failure (cold-load/engine-start) it falls back to AVSpeech so the
    /// answer still reads. State resets are guarded on the owning token.
    private func speakViaKokoro(token: String, text: String, voiceID: String) {
        Task { @MainActor in
            do {
                try await KokoroTTSEngine.shared.speak(text: text, voiceID: voiceID) { [weak self] in
                    guard let self, self.activeEngineIsKokoro, self.activeToken == token else { return }
                    self.isSpeaking = false
                    self.isPaused = false
                    self.activeToken = nil
                    self.endPlaybackSession()
                }
            } catch {
                guard self.activeToken == token else { return }
                self.activeEngineIsKokoro = false
                let utterance = AVSpeechUtterance(string: text)
                if let voice = self.resolvedVoice { utterance.voice = voice }
                self.activeUtterance = utterance
                self.synthesizer.speak(utterance)
            }
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        KokoroTTSEngine.shared.stop()
        FluidKokoroTTSEngine.shared.stop()
        ORTKokoroTTSEngine.shared.stop()
        activeEngineIsKokoro = false
        activeEngineIsANE = false
        activeEngineIsORT = false
        isSpeaking = false
        isPaused = false
        activeToken = nil
        activeUtterance = nil
        endPlaybackSession()
    }

    // Delegate — reset state when speech ends naturally or is cancelled, but
    // ONLY for the currently-active utterance. A cancel delivered late for a
    // superseded utterance (switching turns) must not reset the new one.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === activeUtterance else { return }
            isSpeaking = false
            isPaused = false
            activeToken = nil
            activeUtterance = nil
            endPlaybackSession()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === activeUtterance else { return }
            isSpeaking = false
            isPaused = false
            activeToken = nil
            activeUtterance = nil
            clearNowPlaying()
        }
    }
}
