import AppIntents
import UIKit

// MARK: - Intent

/// Triggered when the user presses the Action Button while AirPad is assigned.
/// Opens `airpad://quikcapture`; cold-launch path is handled in AppDelegate
/// via `launchOptions[.url]` before SwiftUI renders. Warm-launch path is
/// handled by `onOpenURL` on the WindowGroup.
struct CaptureIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture to AirPad"
    static let description = IntentDescription("Open the AirPad capture surface.")

    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "airpad://quikcapture") {
            await UIApplication.shared.open(url)
        }
        return .result()
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let airPadActionButtonPressed = Notification.Name("airPadActionButtonPressed")
}
