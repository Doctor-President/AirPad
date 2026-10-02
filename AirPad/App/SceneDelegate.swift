import UIKit

final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        applyURLs(connectionOptions.urlContexts)
        consumeQuikCaptureHandoff(attempt: 0)   // Brief CE — COLD launch from the Control
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        applyURLs(URLContexts)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Brief CE — WARM foreground from the Control / Action Button. `openAppWhenRun` can ACTIVATE the
        // app slightly BEFORE the intent's `perform()` writes the App Group flag, so poll briefly rather
        // than reading once — a flag that lands within ~1.5 s of activation is still honored.
        consumeQuikCaptureHandoff(attempt: 0)
    }

    /// Brief CE — the Quick Capture Control / Action Button hand off via an App Group flag (a custom
    /// scheme can't be delivered from a Control), consumed on scene activation so it works cold and warm,
    /// independent of URL delivery or launch timing.
    @MainActor
    private func consumeQuikCaptureHandoff(attempt: Int) {
        if QuikCaptureHandoff.consumePending() {
            if let router = AppRouter.shared {
                router.entryMode = .quikCapture
            } else {
                // Cold launch: scene connected before `AppRouter()` exists — latch; the router consumes
                // it in `init()` before the view tree first reads `entryMode`.
                AppRouter.pendingQuikCapture = true
            }
            return
        }
        guard attempt < 6 else { return }   // ~1.5 s: covers perform() landing just after activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.consumeQuikCaptureHandoff(attempt: attempt + 1)
        }
    }

    @MainActor
    private func applyURLs(_ urlContexts: Set<UIOpenURLContext>) {
        for urlContext in urlContexts {
            let url = urlContext.url
            if url.scheme == "airpad", url.host == "quikcapture" {
                // Kept for a direct `airpad://quikcapture` open (not the Control path, which uses the
                // App Group handoff above). Warm → set the router; cold → latch for its init.
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
