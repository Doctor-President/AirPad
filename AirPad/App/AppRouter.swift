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
        /// `CanvasView` / `VerticalScrollView` stay top-level surfaces — their
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
    /// `VerticalScrollView` use it to hide themselves while the Librarian is
    /// raised (peek-pill clearance only covers the peek detent, so at
    /// half / full the chevron region overlaps the "+" hit target —
    /// fix-pass v3 Item 2a).
    var librarianAtPeek: Bool = false


    /// Capture mode (ws-note-primitive / capture-flow). When true the user is in
    /// the focused blank-node capture surface: the Librarian ducks, the note is
    /// live (keyboard up), and the type-buttons + PastePad are in reach. Set by
    /// the Dashboard "+"; cleared on exit (Done → Recents, or backing out).
    var isCapturing: Bool = false
    /// The node being captured into while `isCapturing`.
    var captureNodeID: String? = nil
    /// Live "the capture note has typed text" signal, fed by `TextEntryBody`
    /// while editing. Drives the Cancel↔Done pill so it flips the instant the
    /// user types — the note's `content` only persists on end-editing, so the
    /// pill can't wait for that (else a "Cancel" tap could discard typed text).
    var captureDraftHasText: Bool = false

    /// One-shot navigation handoff from the capture overlay. Set when the
    /// user picks a node in `NodePickerSheet` or completes a capture that
    /// should drop them into the detail view. Each NavigationStack-owning
    /// surface (DashboardView, CanvasView, VerticalScrollView) observes this and
    /// appends the matching node to its own path, then clears the field so
    /// it fires exactly once.
    var pendingNodeNavigationID: String? = nil

    /// #3 (search-navigates-by-view) — the ONE shared "focus a node in the
    /// user's CURRENT view" request. Whichever canvas view is mounted moves its
    /// viewport to the node — Map flies the camera to the orb, List/Card/Grid/
    /// CoverFlow scroll to the row/card/tile. Consumers are per-view (a list
    /// scrolls, a camera flies) but the REQUEST is single, so a new view mode
    /// wires itself in by handling this one value. Two producers today: a
    /// search-result row tap (focus-in-place) and capture-return (Done → focus
    /// the new node). Was `pendingGridScrollNodeID` (Grid-only), then a bare
    /// `pendingFocusNodeID: String?` set-and-consumed via `.onChange`.
    ///
    /// It is now a MONOTONIC request `{nodeID, token}` — NOT a self-clearing
    /// flag — because the flag had two silent-miss failure modes (and the
    /// FAILING view moved on unchanged code, which is what made it look like a
    /// mount race):
    ///   1. A view that MOUNTS with the flag already set never sees an
    ///      `.onChange` (no value change while mounted) → miss. This is exactly
    ///      capture-return (the producer sets the flag, THEN the origin view
    ///      re-appears) and the CoverFlow regression: CoverFlow never had a
    ///      consumer, so it left the shared flag dirty for the NEXT view.
    ///   2. Re-focusing the SAME node isn't a value change → `.onChange`
    ///      doesn't fire → miss.
    /// The `token` advances on every request even when the nodeID repeats, so
    /// consumers key on the token (fixes #2) AND re-check on `.onAppear` (fixes
    /// #1). Consumers dedupe by the token themselves (`onFocusRequest`), so an
    /// un-wired or not-yet-mounted surface can't leave anything dirty for the
    /// next one. Companion's "multiple mounted observers racing" hypothesis was
    /// disproven — the observers live in an EXCLUSIVE `switch` (CanvasChrome),
    /// only one is ever mounted; the real root was dirty-flag + `.onChange`
    /// semantics.
    struct FocusRequest: Equatable {
        let nodeID: String
        /// Monotonic — advances on every `requestFocus`, so a repeat request
        /// for the same node is still observably a change.
        let token: Int
    }

    /// The current focus request, or nil if none has been made this session.
    /// Read-only to the outside; produce requests via `requestFocus(_:)`.
    private(set) var focusRequest: FocusRequest? = nil

    @ObservationIgnored private var focusRequestCounter = 0

    /// The node currently wearing the focus HIGHLIGHT (the persistent glow /
    /// ring). Set by `requestFocus`, it PERSISTS — unlike the one-shot scroll
    /// request — until the user's next touch clears it (a window-level touch
    /// observer in `CanvasChrome` calls `clearFocusHighlight`) or the next focus
    /// replaces it. Observed (read from each surface's highlight), so
    /// setting/clearing it fades the glow in/out declaratively. Persisting also
    /// means a node scrolled off and back re-shows its glow correctly — it IS
    /// still the focused node — with no per-cell token bookkeeping.
    var focusedHighlightNodeID: String? = nil

    /// Ask the CURRENT canvas view to move its viewport to `nodeID` in place
    /// (no view-mode switch, no Detail push) AND light the persistent focus
    /// highlight on it. Monotonic scroll request: a repeat for the same node
    /// still fires because the token advances.
    func requestFocus(_ nodeID: String) {
        focusRequestCounter += 1
        focusRequest = FocusRequest(nodeID: nodeID, token: focusRequestCounter)
        focusedHighlightNodeID = nodeID
    }

    /// Clear the persistent focus highlight (the user touched something). A
    /// no-op when nothing is highlighted, so the window-level touch observer
    /// that calls this on every touch stays cheap.
    func clearFocusHighlight() {
        if focusedHighlightNodeID != nil { focusedHighlightNodeID = nil }
    }

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

    /// ws-chat-lane — deep-link target for the chats sheet. Set alongside
    /// `showChatsList = true` and `ChatsListView` loads that chat and pushes
    /// straight into it (a node's pinned-chat row taps here), then clears this.
    /// nil = open the list itself.
    var pendingChatToOpen: UUID? = nil

    init() {
        AppRouter.shared = self
        // Wire the persistence seam once. ChatSession holds the store
        // weakly so the router stays the sole owner.
        chat.store = chatStore
    }
}

