import AppIntents

// MARK: - Intent

/// Triggered when the user presses the Action Button while AirPad is assigned.
/// Opens the app and posts a notification so the capture fan is shown.
/// No Shortcuts provider — avoids the Shortcuts lookup failure on Action Button press.
struct CaptureIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture to AirPad"
    static let description = IntentDescription("Open the AirPad capture surface.")

    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .airPadActionButtonPressed,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let airPadActionButtonPressed = Notification.Name("airPadActionButtonPressed")
}
