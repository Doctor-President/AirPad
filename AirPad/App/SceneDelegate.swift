import UIKit

final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        applyURLs(connectionOptions.urlContexts)
        consumeQuikCaptureHandoff(attempt: 0)   // Brief CE — COLD launch from the Control
        // Mac batch A — a minimum window: below ~900×640 the stretched phone layout's bars and sheets start to
        // collide, and the desktop layout (batch D) is planned at that size and up. No maximum.
        #if targetEnvironment(macCatalyst)
        (scene as? UIWindowScene)?.sizeRestrictions?.minimumSize = Self.macMinimumWindow
        // Mac batch D6 — the first launch opens at T's layout size (1,350 × 840, centred); after that macOS restores the
        // size and place the user left (its own frame autosave: never overridden).
        if let ws = scene as? UIWindowScene, UserDefaults.standard.object(forKey: "NSWindow Frame MainSceneWindow") == nil {
            let screen = ws.screen.bounds
            let size = CGSize(width: min(Self.macFirstWindow.width, screen.width - 40),
                              height: min(Self.macFirstWindow.height, screen.height - 80))
            let frame = CGRect(x: screen.midX - size.width / 2, y: max(screen.midY - size.height / 2, 30),
                               width: size.width, height: size.height)
            ws.requestGeometryUpdate(.Mac(systemFrame: frame)) { error in NSLog("[MacWindow] first size: %@", "\(error)") }
        }
        #if DEBUG
        // Mac batch B0 stills: `-MacWindowSize 1440x900` pins the window to that size (min = max).
        if let arg = UserDefaults.standard.string(forKey: "MacWindowSize"),
           case let wh = arg.split(separator: "x").compactMap({ Double($0) }), wh.count == 2,
           let r = (scene as? UIWindowScene)?.sizeRestrictions {
            let size = CGSize(width: wh[0], height: wh[1])
            r.minimumSize = size
            r.maximumSize = size
        }
        #endif
        #endif
    }

    /// Mac batch A — the proposed minimum window size, in points.
    static let macMinimumWindow = CGSize(width: 900, height: 640)
    /// Mac batch D6 — the window on first launch (T's layout study: 1,350 pt wide).
    static let macFirstWindow = CGSize(width: 1350, height: 840)

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
