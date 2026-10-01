import UIKit

final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        applyURLs(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        applyURLs(URLContexts)
    }

    @MainActor
    private func applyURLs(_ urlContexts: Set<UIOpenURLContext>) {
        for urlContext in urlContexts {
            let url = urlContext.url
            if url.scheme == "airpad", url.host == "quikcapture" {
                // Brief CE — one shared route for Control Center / Lock Screen / Action Button, cold OR
                // warm. WARM (app running, incl. the Action Button's usual case): the router exists, set
                // it directly. COLD (the Control launches the app from the extension): this scene callback
                // runs BEFORE `AppRouter()` is created, so `shared` is nil — latch a flag the router
                // consumes in `init()`. Only latch when nil so a stray late router can't pick up a stale flag.
                if let router = AppRouter.shared {
                    router.entryMode = .quikCapture
                } else {
                    AppRouter.pendingQuikCapture = true
                }
                return
            }
        }
    }
}
