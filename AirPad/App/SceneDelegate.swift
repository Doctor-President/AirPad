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
                AppRouter.shared?.entryMode = .quikCapture
                return
            }
        }
    }
}
