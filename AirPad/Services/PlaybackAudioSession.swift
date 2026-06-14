import Foundation
import AVFoundation

/// Shared audio-session configurator for in-app playback paths.
///
/// Voice-transcript playback (`VoiceWaveformPlayer`) and the gallery
/// video viewer (`GalleryFullscreenViewer`'s video page) both route
/// through this helper rather than each setting the session
/// independently. Reason: `VoiceCaptureSheet`'s recording flow leaves
/// the session category at `.record` after `setActive(false)`, and a
/// subsequent playback path that doesn't re-set `.playback` will
/// silently produce no audio. A single setter keeps that invariant in
/// one place so a new playback path can't be added without flipping
/// the category back to `.playback`.
///
/// Category and mode are reused verbatim from the original
/// `VoiceWaveformPlayer` helper: `.playback` is the hard requirement
/// (it's what unmutes the output); `.spokenAudio` is a system hint
/// that's tuned for voice transcripts but doesn't gate audio output
/// for music videos either — keeping one setter is preferred over
/// per-callsite mode tuning at this stage.
enum PlaybackAudioSession {

    @discardableResult
    static func configure() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            return true
        } catch {
            print("[PlaybackAudioSession] Configure failed: \(error)")
            return false
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
