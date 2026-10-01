import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Brief CE — Quick Capture Control

/// An iOS 18 `ControlWidget`: a single button that drops the user straight into AirPad's Quick Capture
/// surface. It runs the SHARED `CaptureIntent` (the SAME intent the Action Button uses — "one entry
/// point, not two"), which foregrounds the app and opens `airpad://quikcapture` via `OpenURLIntent`.
///
/// Placement: the Lock Screen's two bottom slots, Control Center, and (iOS 18) the Action Button. The
/// symbol is a TASTE call (Brief CE2 — T picks); `square.and.pencil` is the shipped default. User-facing
/// name is "Quick Capture" (matches the share-sheet row, vocabulary.md).
struct QuickCaptureControl: ControlWidget {

    /// Stable identity for the control across reloads. Namespaced under the app's bundle id.
    static let kind = "com.doctorpresident.airpad.quickcapture"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: CaptureIntent()) {
                Label("Quick Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Quick Capture")
        .description("Start a new capture in AirPad.")
    }
}
