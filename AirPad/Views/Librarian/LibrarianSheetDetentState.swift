import Foundation
import Observation

/// Mirrors the live `UISheetPresentationController.selectedDetentIdentifier`
/// into observable state so `LibrarianSurface` can branch its body content
/// per detent (`collapsedBody` / whispers at peek vs `expandedBody` at
/// medium/large). Owned by the presenter's `Coordinator`, written from the
/// sheet delegate callback, and read by the surface via its
/// `detentState:` init parameter.
@Observable
final class LibrarianSheetDetentState {
    /// Which detent the sheet is currently sitting at. Three-valued so
    /// downstream chrome (the canvas "+" capture button) can adjust
    /// padding per detent — peek lifts above 95pt, medium lifts above
    /// the half-screen, large hides the button entirely.
    enum SelectedDetent: Sendable {
        case peek
        case medium
        case large
    }

    /// Live detent. Defaults to `.peek` because we open the sheet at
    /// peek — the first `didChangeSelectedDetentIdentifier` callback
    /// only fires on subsequent user-driven detent changes, not on the
    /// initial presentation.
    var selectedDetent: SelectedDetent = .peek

    /// Convenience for the surface body branch (collapsedBody vs
    /// expandedBody). Computed so it stays in lockstep with
    /// `selectedDetent`; @Observable propagates tracking through
    /// computed properties.
    var isAtPeek: Bool { selectedDetent == .peek }
}
