import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    enum EntryMode: Sendable, Equatable {
        case dashboard
        /// Recents-first landing surface (Notes model). Cold-launch default;
        /// Dashboard sits one level up as the hub. Promotes the recency list
        /// from a dashboard sheet into a top-level surface — see
        /// `RecentsView`.
        case recents
        case canvas
        /// QuikCapture — a standalone capture screen reached DIRECTLY from the
        /// URL scheme (`airpad://quikcapture` / Action Button). Rendered at the
        /// ContentView root as its own view (`QuikCaptureView`), never routed
        /// through the Dashboard, so entry is instant (no flash) and the
        /// Librarian is simply not part of the surface.
        case quikCapture
        /// Scoped collection canvas (Canvas Chrome arc D1c). Routes
        /// through `AppRouter` rather than a `NavigationStack` push so
        /// `CanvasView` / `NodeListView` stay top-level surfaces — their
        /// internal `NavigationStack` collides with the dashboard's outer
        /// stack and renders SwiftUI's missing-destination placeholder.
        /// Back chevron returns to dashboard via `.dashboard` route.
        case collectionCanvas(id: String)
    }

    static var shared: AppRouter?

    var entryMode: EntryMode = .recents

    /// Mirror of the in-layout Librarian panel's detent — `true` when
    /// the panel is at peek (`.tip`), `false` at half / full / hidden.
    /// Owned by `LibrarianPanelStateModel`; mirrored here from
    /// `ContentView` via `.onChange(of: panelState.state)` so views
    /// without direct access to the panel model can gate themselves
    /// on the detent. Capture "+" buttons in `CanvasView` and
    /// `NodeListView` use it to hide themselves while the Librarian is
    /// raised (peek-pill clearance only covers the peek detent, so at
    /// half / full the chevron region overlaps the "+" hit target —
    /// fix-pass v3 Item 2a).
    var librarianAtPeek: Bool = false

    /// Capture overlay state. Non-nil presents the blur overlay above the
    /// active entry mode (dashboard / canvas / collectionCanvas) without
    /// changing entry mode itself — the user stays in their current context
    /// and the overlay slides over it. Nil dismisses the overlay.
    ///
    /// This is the single capture surface for both the in-app "+" and the
    /// external QuikCapture entry (URL scheme `airpad://quikcapture` /
    /// Action Button) — the latter just sets this from `onOpenURL` so the
    /// overlay rises over whatever's on screen. No separate QuikCapture mode.
    var captureOverlay: CaptureOverlayContext? = nil

    /// Capture mode (ws-note-primitive / capture-flow). When true the user is in
    /// the focused blank-node capture surface: the Librarian ducks, the note is
    /// live (keyboard up), and the type-buttons + PastePad are in reach. Set by
    /// the Dashboard "+"; cleared on exit (Done → Recents, or backing out).
    var isCapturing: Bool = false
    /// The node being captured into while `isCapturing`.
    var captureNodeID: String? = nil
    /// One-shot: set by the capture surface's "Done" to exit to Recents (the
    /// freshly-captured node lands on top). The NavigationStack-owning Dashboard
    /// observes it, resets its path to Recents, and clears the flag.
    var exitCaptureToRecents: Bool = false
    /// Live "the capture note has typed text" signal, fed by `TextEntryBody`
    /// while editing. Drives the Cancel↔Done pill so it flips the instant the
    /// user types — the note's `content` only persists on end-editing, so the
    /// pill can't wait for that (else a "Cancel" tap could discard typed text).
    var captureDraftHasText: Bool = false

    /// One-shot navigation handoff from the capture overlay. Set when the
    /// user picks a node in `NodePickerSheet` or completes a capture that
    /// should drop them into the detail view. Each NavigationStack-owning
    /// surface (DashboardView, CanvasView, NodeListView) observes this and
    /// appends the matching node to its own path, then clears the field so
    /// it fires exactly once.
    var pendingNodeNavigationID: String? = nil

    /// Scroll-to-node seam for the grid. Set a node ID to scroll the grid
    /// to that tile; NodeGridView observes and clears it. The access layer
    /// (sort / A–Z jump) and the Librarian drive this later. No setter yet
    /// — this is the seam so it doesn't need a retrofit.
    var pendingGridScrollNodeID: String? = nil

    /// Librarian session state — the morphing query / synthesis surface.
    /// Travels across canvas, list, and (future) detail-view mounts so an
    /// in-flight session survives navigation between surfaces. Single
    /// source of truth for sheet presentation today and for surface mode,
    /// scope chip selection, and conversation history as those land in
    /// subsequent commits.
    @ObservationIgnored let librarian = LibrarianState()

    /// Passage-free FM chat instrument. Lives in parallel to `librarian`
    /// so multi-turn history threads across navigation without losing
    /// state — the Dashboard chat surface is its only consumer today.
    @ObservationIgnored let chat = ChatSession()

    /// On-disk chat persistence. Lazily loads from iCloud Drive
    /// (`<root>/chats.json`) on first ChatView appearance; receives
    /// flushes from `ChatSession` at turn boundaries / reset / scene
    /// background so conversations survive a relaunch.
    @ObservationIgnored let chatStore = ChatStore()

    /// Presentation flag for the shared `ChatsListView` sheet. ONE flag
    /// drives both entry points (Dashboard header bubble + Librarian
    /// "Chats" tile) so the surface they open is bit-identical — the
    /// Librarian-has-no-NavigationStack problem is sidestepped because
    /// the sheet owns its own stack.
    var showChatsList: Bool = false

    init() {
        AppRouter.shared = self
        // Wire the persistence seam once. ChatSession holds the store
        // weakly so the router stays the sole owner.
        chat.store = chatStore
    }
}

/// Context for the in-app capture overlay. `scope` controls whether the
/// collection pill rail is interactive (`.corpus`: full rail, defaults to
/// last-used) or locked to a fixed pin (`.collection(id)`: rail shows the
/// active collection only, taps no-op — capture lands in that collection).
struct CaptureOverlayContext: Sendable, Equatable {
    var scope: CanvasScope
}
