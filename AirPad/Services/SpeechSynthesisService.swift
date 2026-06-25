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

    private let synthesizer = AVSpeechSynthesizer()
    private var remoteCommandsConfigured = false

    private override init() {
        super.init()
        synthesizer.delegate = self
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
    }

    /// Wire MPRemoteCommandCenter once on first speak — needed so the
    /// lock-screen + Control Center transport bar controls drive the
    /// synthesizer instead of the system's default no-op handlers.
    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isPaused {
                self.synthesizer.continueSpeaking()
                self.isPaused = false
                self.updateNowPlayingPlaybackState()
                return .success
            }
            return .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isSpeaking, !self.isPaused else { return .commandFailed }
            self.synthesizer.pauseSpeaking(at: .word)
            self.isPaused = true
            self.updateNowPlayingPlaybackState()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.isSpeaking else { return .commandFailed }
            if self.isPaused {
                self.synthesizer.continueSpeaking()
                self.isPaused = false
            } else {
                self.synthesizer.pauseSpeaking(at: .word)
                self.isPaused = true
            }
            self.updateNowPlayingPlaybackState()
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

    /// Installed voices for the current language, best quality first.
    /// Drives the picker. Premium/enhanced surface at the top so the
    /// user sees the good ones first (and notices if they only have
    /// the robotic default — prompting a download).
    static var availableVoices: [AVSpeechSynthesisVoice] {
        let prefix = String(Locale.current.identifier.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue {
                    return a.quality.rawValue > b.quality.rawValue
                }
                return a.name < b.name
            }
    }

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
            if isPaused {
                synthesizer.continueSpeaking()
                isPaused = false
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isPaused = true
            }
        } else {
            speak(token: token, text: text)
        }
    }

    private func speak(token: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Reclaim playback — dictation/capture may have left .record.
        PlaybackAudioSession.configure()

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voice = resolvedVoice {
            utterance.voice = voice
        }
        // Defaults (rate 0.5, pitch 1.0) — dial later if Tom wants.

        isSpeaking = true
        isPaused = false
        activeToken = token
        configureRemoteCommandsIfNeeded()
        setNowPlaying(title: "AirPad")
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        isPaused = false
        activeToken = nil
        clearNowPlaying()
    }

    // Delegate — reset state when speech ends naturally or is cancelled.
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            isPaused = false
            activeToken = nil
            clearNowPlaying()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            isPaused = false
            activeToken = nil
            clearNowPlaying()
        }
    }
}
