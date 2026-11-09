import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Mac batch C1 — take out the system menu items that do nothing in AirPad: Help (no help book), the document
    /// items (Duplicate, Move, Rename, Export As — AirPad isn't document-based), the toolbar items (no toolbar), and the
    /// system Close (disabled for a one-window app; File › Close Window ⌘W replaces it). AirPad's own items are the
    /// SwiftUI `AppCommands`.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MenuStructureLog") {
            func walk(_ e: UIMenuElement, _ d: Int) {
                let pad = String(repeating: "  ", count: d)
                if let m = e as? UIMenu {
                    NSLog("[MenuStructure] %@menu %@ \"%@\"", pad, m.identifier.rawValue, m.title)
                    m.children.forEach { walk($0, d + 1) }
                } else if let c = e as? UICommand {
                    NSLog("[MenuStructure] %@cmd \"%@\" action=%@", pad, c.title, NSStringFromSelector(c.action))
                } else if let a = e as? UIAction {
                    NSLog("[MenuStructure] %@action \"%@\" id=%@", pad, a.title, a.identifier.rawValue)
                }
            }
            for id in [UIMenu.Identifier.file, .view, .edit] { builder.menu(for: id).map { walk($0, 0) } }
        }
        #endif
        builder.remove(menu: .help)
        builder.remove(menu: .document)
        builder.remove(menu: .toolbar)
        // The View items share the sidebar group; its Show Sidebar (⌃⌘S) waits for batch D's sidebar.
        builder.replaceChildren(ofMenu: .sidebar) { children in
            children.filter { ($0 as? UICommand)?.action != NSSelectorFromString("toggleSidebar:") }
        }
    }

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
