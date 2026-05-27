import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    enum EntryMode: Sendable {
        case dashboard
        case canvas
        /// QuikCapture surface. `forcedCollectionID` pins the capture to a
        /// specific collection (CollectionView "+" path in c4.7); nil leaves
        /// the active collection up to QuikCapture's pill rail. `origin`
        /// tracks where the user entered from so the exit pill knows
        /// whether to return to dashboard (in-app entry) or suspend the
        /// app (URL-scheme entry from outside).
        case quikCapture(forcedCollectionID: String?, origin: QuikCaptureOrigin)
        /// Scoped collection canvas (Canvas Chrome arc D1c). Routes
        /// through `AppRouter` rather than a `NavigationStack` push so
        /// `CanvasView` / `NodeListView` stay top-level surfaces — their
        /// internal `NavigationStack` collides with the dashboard's outer
        /// stack and renders SwiftUI's missing-destination placeholder.
        /// Back chevron returns to dashboard via `.dashboard` route.
        case collectionCanvas(id: String)
    }

    /// c4.6 — entry-point tracking for QuikCapture. Determines exit-pill
    /// behavior: dashboard origin returns to the dashboard; urlScheme
    /// origin suspends the app so the user lands back where they came from
    /// (the home screen or whichever app triggered the URL).
    enum QuikCaptureOrigin: Sendable {
        case dashboard
        case urlScheme
    }

    static var shared: AppRouter?

    var entryMode: EntryMode = .dashboard

    /// In-app capture overlay state. Non-nil presents the blur overlay above
    /// the active entry mode (dashboard / canvas / collectionCanvas) without
    /// changing entry mode itself — the user stays in their current context
    /// and the overlay slides over it. Nil dismisses the overlay.
    ///
    /// Distinct from `.quikCapture` entry mode: that's the external (URL
    /// scheme / lock screen) full-screen QuikCapture surface, which remains
    /// unchanged by the in-app capture overlay arc.
    var captureOverlay: CaptureOverlayContext? = nil

    /// One-shot navigation handoff from the capture overlay. Set when the
    /// user picks a node in `NodePickerSheet` or completes a capture that
    /// should drop them into the detail view. Each NavigationStack-owning
    /// surface (DashboardView, CanvasView, NodeListView) observes this and
    /// appends the matching node to its own path, then clears the field so
    /// it fires exactly once.
    var pendingNodeNavigationID: String? = nil

    /// Librarian session state — the morphing query / synthesis surface.
    /// Travels across canvas, list, and (future) detail-view mounts so an
    /// in-flight session survives navigation between surfaces. Single
    /// source of truth for sheet presentation today and for surface mode,
    /// scope chip selection, and conversation history as those land in
    /// subsequent commits.
    @ObservationIgnored let librarian = LibrarianState()

    init() {
        AppRouter.shared = self
    }
}

/// Context for the in-app capture overlay. `scope` controls whether the
/// collection pill rail is interactive (`.corpus`: full rail, defaults to
/// last-used) or locked to a fixed pin (`.collection(id)`: rail shows the
/// active collection only, taps no-op — capture lands in that collection).
struct CaptureOverlayContext: Sendable, Equatable {
    var scope: CanvasScope
}
