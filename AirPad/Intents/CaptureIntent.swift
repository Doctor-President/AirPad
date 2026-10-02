import AppIntents
import Foundation

// MARK: - Intent

/// The ONE capture entry point (Brief CE — "one entry point, not two"). Shared by BOTH the Action
/// Button (iPhone 15 Pro+) and the iOS 18 Control (Lock Screen / Control Center) — compiled into the
/// app target AND the `AirPadWidgets` extension target.
///
/// ★ Why NOT `OpenURLIntent`: a CUSTOM-scheme URL (`airpad://`) is NOT delivered when an intent runs
/// from a Control (Apple: Controls' `OpenURLIntent` supports UNIVERSAL links only — confirmed on device,
/// the Control landed on Recents while the Action Button, running in-app, worked). So we don't rely on
/// URL delivery at all. Instead `perform()` writes a PENDING flag to the App Group that the app + this
/// extension share; `openAppWhenRun` foregrounds the app; the app consumes the flag on scene activation
/// (cold AND warm — see `SceneDelegate`). One route, delivery-independent, for Control Center, Lock
/// Screen and the Action Button.
struct CaptureIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture to AirPad"
    static let description = IntentDescription("Open the AirPad capture surface.")

    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        QuikCaptureHandoff.setPending()
        return .result()
    }
}

/// The App Group handoff for the Quick Capture Control — the one place the shared suite name + key live,
/// so the extension (write) and the app (read) can't drift. Both targets have the
/// `group.com.doctorpresident.airpad` App Group entitlement.
enum QuikCaptureHandoff {
    private static let suite = "group.com.doctorpresident.airpad"
    private static let key = "pendingQuikCapture"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }

    /// Extension side — latch "the user asked to Quick Capture".
    static func setPending() { defaults?.set(true, forKey: key) }

    /// App side — consume the latch once. Returns true if a capture was pending.
    static func consumePending() -> Bool {
        guard defaults?.bool(forKey: key) == true else { return false }
        defaults?.set(false, forKey: key)
        return true
    }
}
