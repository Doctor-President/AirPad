import AppIntents

// MARK: - Intent

/// The ONE capture entry point (Brief CE — "one entry point, not two"). Shared by BOTH the Action
/// Button (iPhone 15 Pro+) and the iOS 18 Control (Lock Screen / Control Center) — compiled into the
/// app target AND the `AirPadWidgets` extension target.
///
/// Opens `airpad://quikcapture` via `OpenURLIntent`, the sanctioned, EXTENSION-SAFE mechanism:
/// `UIApplication.shared` is unavailable in an app extension, so the old `UIApplication.shared.open`
/// could not be shared with the widget target. `openAppWhenRun` foregrounds the app; the returned
/// `OpenURLIntent` routes through the SAME deep-link path the Action Button always used — warm launch
/// via `onOpenURL` on the WindowGroup, cold launch via `launchOptions[.url]` in AppDelegate — so both
/// surfaces land in Quick Capture, not the Dashboard.
struct CaptureIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture to AirPad"
    static let description = IntentDescription("Open the AirPad capture surface.")

    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "airpad://quikcapture")!))
    }
}
