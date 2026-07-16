import SwiftUI

/// ws-display-edit-mode — the universal display-density toggle available on
/// every node detail view.
///
/// - **Edit** (default): full entry-card chrome — headers, per-section
///   timestamps, ellipsis menus, plus the floating "+" and Paste Pad.
///   Everything editable and reorderable. The frictionless authoring surface.
/// - **Display**: chrome recedes. Entry headers, timestamps, and ellipsis
///   menus hide; entries read open; the node reads as a document rather than
///   a workspace. Bodies stay live, so tapping a note still edits inline.
///
/// State model (locked 2026-05-30): a global session state persisted via
/// `@AppStorage`, Caps-Lock style — flip once, applies to every subsequent
/// untyped node until flipped back. Typed nodes (Recipe / Film / Review /
/// Book / Collectable, from ws-intelligent-link-scraping) open in Display
/// regardless, with Edit a per-node override. That typed path is wired but
/// dormant: no node-level type exists in the model yet, so
/// `NodeDetailView.isTyped(_:)` returns false and every node follows the
/// global state today.
enum DisplayEditMode: String {
    case edit
    case display

    var isDisplay: Bool { self == .display }
}

private struct DisplayEditModeKey: EnvironmentKey {
    static let defaultValue: DisplayEditMode = .edit
}

extension EnvironmentValues {
    /// The resolved mode for the node detail view currently on screen.
    /// `NodeDetailView` computes it (global `@AppStorage` + typed-node
    /// exception + per-view override) and injects it here; entry cards read
    /// it to gate their chrome.
    var displayEditMode: DisplayEditMode {
        get { self[DisplayEditModeKey.self] }
        set { self[DisplayEditModeKey.self] = newValue }
    }
}
