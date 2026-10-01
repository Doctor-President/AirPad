import WidgetKit
import SwiftUI

// MARK: - Brief CE — the AirPad widget extension (iOS 18 Controls)

/// The extension's `@main` entry. Today it carries ONE Control — Quick Capture — reachable from the
/// Lock Screen (bottom slots), Control Center, and the Action Button (iOS 18 can bind a control to it).
/// The target's deployment floor is iOS 18, so `ControlWidget` is available unconditionally.
@main
struct AirPadWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickCaptureControl()
    }
}
