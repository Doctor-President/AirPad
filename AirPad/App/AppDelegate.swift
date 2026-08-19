import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// ws-bg-download (Option C) — after a background model download finishes while the app was
    /// suspended/terminated, the system relaunches us and hands back this completion handler.
    /// Route it to the downloader (via LocalModelService), which calls it once the session's queued
    /// events have been delivered (`urlSessionDidFinishEvents`). Without this the system keeps the
    /// app awake waiting and file writes can be delayed.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        LocalModelService.shared.handleBackgroundURLSessionEvents(
            identifier: identifier, completionHandler: completionHandler)
    }
}
