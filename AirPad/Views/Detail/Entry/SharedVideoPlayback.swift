import SwiftUI
import AVKit

/// E fix-up 6 (M2) — ONE player per video across the inline player, the full-screen player and Picture in Picture.
///
/// T: inline and full screen were "two separate and unrelated sessions" (each surface built its own `AVPlayer`, so
/// full screen restarted at 0:00 and its volume was its own); closing the full-screen player paused a PiP video
/// (its `onDisappear` paused); and PiP's own × then left the audio playing to the end with no way to stop it (the
/// controller that started PiP was gone, so nothing heard PiP stop).
///
/// Now every surface asks here for the video's player (keyed by the gallery item's id), so position, play/pause and
/// volume are the same object everywhere. Each `AVPlayerViewController` gets this object as its delegate, and the
/// one that starts PiP is kept alive here until PiP ends, whatever happens to the view that showed it:
/// - PiP's × stops playback (the entry then shows it paused at that point);
/// - PiP's "return" goes back to the player it came from when that is still on screen and carries on there;
/// - the player it came from is gone (the full-screen player was closed) → paused, for × and "return" alike: on
///   the Mac both buttons arrive as the same restore + stop callbacks (measured, E fix-up 6), and with the source
///   on screen AVKit itself pauses on × and plays on "return" — only a gone source left the audio orphaned;
/// - a surface going away pauses only when nothing else shows the video and PiP isn't running.
@MainActor
final class SharedVideoPlayback: NSObject, AVPlayerViewControllerDelegate {
    static let shared = SharedVideoPlayback()

    private var players: [String: AVPlayer] = [:]
    /// Surfaces currently showing each video (the inline player, the full-screen player).
    private var holders: [String: Int] = [:]
    private var controllerKeys: [ObjectIdentifier: String] = [:]
    /// The controller that started PiP, retained so its PiP outlives the view that presented it.
    private var pipController: AVPlayerViewController?
    private(set) var pipKey: String?
    private var pipRestoring = false

    func player(for key: String, url: URL) -> AVPlayer {
        if let p = players[key] { return p }
        let p = AVPlayer(url: url)
        players[key] = p
        return p
    }

    func hold(_ key: String) { holders[key, default: 0] += 1 }

    /// A surface stopped showing the video. Pauses (and forgets the player) only when nothing else shows it and
    /// it isn't playing in PiP.
    func release(_ key: String) {
        let left = max(0, holders[key, default: 0] - 1)
        holders[key] = left == 0 ? nil : left
        guard left == 0, pipKey != key else { return }
        players[key]?.pause()
        players[key] = nil
    }

    func isInPictureInPicture(_ key: String) -> Bool { pipKey == key }
    var anyPictureInPicture: Bool { pipKey != nil }

    func configure(_ controller: AVPlayerViewController, key: String) {
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controllerKeys[ObjectIdentifier(controller)] = key
    }

    // MARK: AVPlayerViewControllerDelegate

    nonisolated func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated {
            pipController = controller
            pipKey = controllerKeys[ObjectIdentifier(controller)]
            pipRestoring = false
            log("PiP start \(pipKey ?? "?")")
        }
    }

    nonisolated func playerViewController(_ controller: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            pipRestoring = true
            let onScreen = controller.viewIfLoaded?.window != nil
            log("PiP return (its player on screen: \(onScreen), rate \(controller.player?.rate ?? -1))")
            completionHandler(onScreen)
        }
    }

    nonisolated func playerViewControllerWillStopPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated { log("PiP will stop (rate \(controller.player?.rate ?? -1), restoring \(pipRestoring))") }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated {
            let key = pipKey
            let returned = pipRestoring
            let rateAtStop = controller.player?.rate ?? -1
            pipKey = nil
            pipController = nil
            pipRestoring = false
            guard let key, let player = players[key] else { return }
            // Its player gone → nothing would ever stop it: pause. On screen → AVKit's own × / return behaviour.
            if !returned || controller.viewIfLoaded?.window == nil { player.pause() }
            log("PiP stop \(key): \(returned ? "return" : "close") rate-at-stop \(rateAtStop) → \(player.rate == 0 ? "paused" : "playing")")
            if holders[key, default: 0] == 0 { players[key] = nil }
        }
    }

    private func log(_ s: @autoclosure () -> String) {
        #if DEBUG
        NSLog("[Video] %@", s())
        #endif
    }
}

/// The standard AVKit player (`AVPlayerViewController`: its own transport, volume, full-screen and PiP controls,
/// laid out by the platform so nothing of ours sits on them) showing a video's shared player.
struct SharedVideoPlayerView: UIViewControllerRepresentable {
    let key: String
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        _ = PlaybackAudioSession.configure()
        let controller = AVPlayerViewController()
        SharedVideoPlayback.shared.configure(controller, key: key)
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
