import AppIntents

// MARK: - Intent

/// Triggered when the user presses the Action Button while AirPad is assigned.
/// Opens the app to the voice capture surface (default) or the fan if already foreground.
struct CaptureIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture to AirPad"
    static let description = IntentDescription("Open the AirPad capture surface.")

    /// Bring the app to foreground automatically.
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // Post a notification that AirPadApp observes.
        // The app uses this to open voice capture when it becomes active.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .airPadActionButtonPressed,
                object: nil
            )
        }
        return .result()
    }
}

// MARK: - Shortcuts provider

struct AirPadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Open \(.applicationName) capture",
                "New idea in \(.applicationName)"
            ],
            shortTitle: "Capture",
            systemImageName: "mic.circle.fill"
        )
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let airPadActionButtonPressed = Notification.Name("airPadActionButtonPressed")
}
