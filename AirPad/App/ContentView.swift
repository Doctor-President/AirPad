import SwiftUI
import FloatingPanel

struct ContentView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(QuarantineStore.self) private var quarantineStore

    /// Single persistent in-layout panel. Mounted at ContentView root via
    /// the non-modal `.floatingPanel { proxy in … }` modifier on the outer
    /// ZStack — added as a child VC by the modifier, never `present()`.
    /// Entry-mode transitions raise it to `.tip` on canvas surfaces and
    /// `.hidden` on dashboard / QuikCapture; user drag covers
    /// `.tip` ↔ `.half` ↔ `.full`.
    @State private var panelState = LibrarianPanelStateModel()
    private let panelLayout = LibrarianPanelLayout()

    var body: some View {
        @Bindable var routerBinding = router
        ZStack {
            Group {
                switch router.entryMode {
                case .dashboard:
                    DashboardView(initialRoute: nil)
                case .recents:
                    DashboardView(initialRoute: .recents)
                case .quikCapture:
                    QuikCaptureView()
                case .canvas:
                    CanvasChrome(scope: .corpus)
                case .collectionCanvas(let id):
                    CollectionView(collectionID: id)
                }
            }
        }
        // Chats list sheet — shared by the Dashboard header bubble and
        // the Librarian "Chats" tile via `router.showChatsList`. Mounted
        // at the root so both entry points present the bit-identical
        // surface, and so the sheet floats over the Librarian's
        // FloatingPanel regardless of entry mode.
        .sheet(isPresented: $routerBinding.showChatsList) {
            ChatsListView()
                .environment(store)
                .environment(router)
                .environment(selection)
                .environment(quarantineStore)
        }
        // In-layout FloatingPanel — the Librarian's structural home. Mounted
        // once at ContentView root and never torn down across entry-mode
        // switches. Step C below moves it to `.tip` / `.hidden` per mode.
        // Move 1 ships dummy content; Move 2 swaps `LibrarianSurface` in.
        .floatingPanel { proxy in
            // Env objects don't cross FloatingPanel's UIHostingController
            // mount automatically, so we inject the four the surface
            // needs explicitly. `hostScope` drives the Librarian's
            // first-appear scope seed; we collapse the four entry modes
            // to corpus/collection so the surface sees a clean slice.
            LibrarianSurface(
                hostScope: hostScope(for: router.entryMode),
                panelModel: panelState,
                proxy: proxy
            )
                .environment(store)
                .environment(router)
                .environment(selection)
                .environment(quarantineStore)
                .onAppear {
                    panelState.controller = proxy.controller
                    proxy.controller.delegate = panelState
                    // FloatingPanel always draws its own grabber on the
                    // surface (`SurfaceView.grabberHandle`); the
                    // Librarian draws a styled SwiftUI Capsule in its
                    // expanded header. Hide the library's so we ship a
                    // single grabber owner (Step E carry-forward; the
                    // probe's doubled-pill artifact was the two
                    // stacking).
                    proxy.controller.surfaceView.grabberHandle.isHidden = true
                    // Clear FloatingPanel's default opaque SurfaceView fill
                    // so the Librarian's `.regularMaterial` rectangle has
                    // the canvas behind it to blur. Both layers need to go
                    // clear: `appearance.backgroundColor` paints the
                    // containerView, `backgroundColor` is the UIView itself.
                    proxy.controller.surfaceView.appearance.backgroundColor = .clear
                    proxy.controller.surfaceView.backgroundColor = .clear
                    // ws-dark-light-mode — remove FloatingPanel's default
                    // surface drop-shadow (`SurfaceAppearance.shadows =
                    // [Shadow()]`). It's invisible on the #1A1A1A dark ground
                    // but reads as a faint line at the surface's top edge on
                    // cream — the hairline above the peek pill. Not
                    // load-bearing (no visible lift in dark).
                    //
                    // ⚠️ Must REPLACE the appearance object, not mutate
                    // `appearance.shadows` in place. `SurfaceAppearance` is a
                    // class, and the `SurfaceView.appearance` didSet — the only
                    // thing that rebuilds the shadow sublayers — fires only on
                    // whole-object assignment. A nested `appearance.shadows =
                    // []` never rebuilds them, and `updateShadow()` (per
                    // layoutSubviews) only configures PRESENT shadows, never
                    // clears an already-drawn one. So reassigning the object is
                    // what actually removes it (measured from SurfaceView.swift;
                    // a prior nested-mutation attempt was a no-op). Durable
                    // across detents: the library never reassigns `appearance`,
                    // and the only other `shadowLayers` rebuild is init-only
                    // (`addSubViews`). Reassigning the SAME object still fires
                    // didSet (Swift runs it on every assignment) and preserves
                    // the `.clear` backgroundColor set above.
                    let clearedAppearance = proxy.controller.surfaceView.appearance
                    clearedAppearance.shadows = []
                    proxy.controller.surfaceView.appearance = clearedAppearance
                    // First-render alignment with the current surface.
                    // SwiftUI's `.onChange` doesn't fire for the initial
                    // value reliably across the panel-mount boundary, so
                    // align here once the controller is wired up. Routes
                    // through the same `librarianSuppressed` SSOT as every
                    // runtime transition (BUG 11).
                    applyLibrarianVisibility(animated: false)
                    #if DEBUG
                    // `-LibrarianDetent tip|half|full` — drives the panel to a
                    // detent for headless real-screen shots of the light panel
                    // (peek/half/full). No-op without the arg.
                    switch UserDefaults.standard.string(forKey: "LibrarianDetent") {
                    case "half": proxy.controller.move(to: .half, animated: false)
                    case "full": proxy.controller.move(to: .full, animated: false)
                    default:     break
                    }
                    #endif
                }
        }
        .floatingPanelLayout(panelLayout)
        // BUG 5 — snappy detent spring. Overrides the library default
        // springResponseTime (0.4, a ~1.6s critically-damped crawl half→full)
        // with a shorter response. Applies to every programmatic move and the
        // drag-release settle; morph-preserving (see LibrarianPanelBehavior).
        .floatingPanelBehavior(LibrarianPanelBehavior())
        // Content tracks each detent's bounds instead of being laid out once
        // at full height and slid down (the .static default). Under .static,
        // the surface stays full-detent-tall and translates for shorter
        // detents, dragging the content's bottom — the Ask input row + end-
        // session footer — off-screen at .half. With .fitToBounds the surface
        // is re-fit per detent (top pinned by the state constraint, bottom
        // pinned to vc.view.bottom), so the pinned bottom row stays visible
        // at every posture. Applied here at configuration time, NOT inside
        // .onAppear: setting `contentMode` after the panel mounts triggers
        // a relayout against the controller's initial state one tick before
        // our `move(to: .tip)` runs, producing a posture flash.
        .floatingPanelContentMode(.fitToBounds)
        // Single existence rule: canvas / collectionCanvas raise the panel
        // to peek; dashboard / recents duck it offscreen. Panel stays
        // mounted across all modes — never torn down. `.hidden` is not in
        // the layout's anchor set, so the duck goes through `hide()` (which
        // routes to a library-default offscreen anchor) — keeping `.tip`
        // as the hard user-facing floor for drag.
        // BUG 11 — single suppression SSOT. Both the entry-mode switch AND
        // capture mode feed `librarianSuppressed`; re-applying visibility on
        // either input change (instead of two independent imperative ducks
        // that a later raise could silently override) is what keeps the peek
        // out of every canvas-COVERING surface — QuikCapture, the ducked entry
        // modes, and capture mode alike. The FloatingPanel is a root-mounted
        // ZStack sibling that's never auto-dismissed, so this is the level
        // where all of those surfaces get suppression.
        .onChange(of: router.entryMode) { _, _ in
            applyLibrarianVisibility(animated: true)
        }
        // Capture mode (Dashboard "+"): the focused blank-node surface ducks the
        // Librarian so the note + capture buttons own the screen — folded into
        // the same SSOT so exit restores per the live surface.
        .onChange(of: router.isCapturing) { _, _ in
            applyLibrarianVisibility(animated: true)
        }
        // Detail-view coexistence. ContentView's panel visibility is keyed
        // on entryMode, but a node detail is pushed inside the host
        // surface's NavigationStack without changing entryMode — so a
        // detail reached from a ducked host (Recents) would inherit the
        // ducked panel and hide the Librarian. `store.isInDetailView` is
        // a depth-derived computed bool driven by each host's
        // `path.count` observer: it flips false→true only on first-
        // detail-enter (depth 0→1) and true→false only on last-detail-
        // exit (depth 1→0). Stacked transitions (1↔2) don't reach this
        // handler — the Librarian's `openNode` half stays put.
        //
        // Enter-branch is rescue-only: raise only if the panel is
        // actually hidden. Leaves the Librarian's own choreography
        // (`openNode`'s `dropToHalf`) and any user-chosen detent alone.
        // Exit-branch fires at pop-commit (path.count → 0 lands
        // synchronously with `dismiss()` for chevron, at release for
        // swipe), so the duck animates alongside the pop without a
        // separate early-restore signal.
        .onChange(of: store.isInDetailView) { _, inDetail in
            if inDetail {
                // Rescue-raise ONLY when the current surface actually wants the
                // Librarian (a canvas / collection-canvas detail). Any suppressed
                // surface — capture mode OR QuikCapture / dashboard / recents —
                // must stay ducked, so gate on the same SSOT (BUG 11). The bare
                // `!isCapturing` guard let a detail-depth flip re-raise the peek
                // over a non-canvas surface.
                if panelState.state == .hidden && !librarianSuppressed {
                    panelState.raiseToPeek(animated: true)
                }
            } else {
                // Leaving the detail ends capture mode (Done → Recents and a
                // plain back-out both land here).
                if router.isCapturing {
                    router.isCapturing = false
                    router.captureNodeID = nil
                }
                restorePanelForEntryMode()
            }
        }
        // Selection coexistence. When batch selection activates in
        // Map / List view, retract the panel to peek so the bottom
        // BatchActionBar (shifted up by peekDetentHeight + 12 in
        // CanvasChrome) reads as the dominant action. No restore on
        // exit — peek is the correct resting state after a batch action.
        .onChange(of: selection.isActive) { _, isActive in
            // Retract-to-peek is a canvas affordance (the BatchActionBar sits
            // above the peek). Guard on the SSOT so activating selection can
            // never raise the peek in a suppressed surface (BUG 11).
            if isActive && !librarianSuppressed {
                panelState.raiseToPeek(animated: true)
            }
        }
        // Mirror the panel detent onto the router (fix-pass v3 Item 2a)
        // so views without a direct handle on `panelState` can gate
        // themselves on peek vs raised — the "+" capture trigger in
        // CanvasView / VerticalScrollView uses this.
        .onChange(of: panelState.state) { _, newState in
            router.librarianAtPeek = (newState == .tip)
        }
    }

    /// BUG 11 — single source of truth for whether the Librarian peek must be
    /// ducked for the CURRENT surface. Every canvas-COVERING surface hides it:
    /// capture mode (the Dashboard "+" note editor) and the three ducked entry
    /// modes (dashboard / QuikCapture / recents). Only a plain canvas /
    /// collection-canvas shows the peek. Because the FloatingPanel is a
    /// root-mounted ZStack sibling that's never auto-dismissed, this predicate
    /// — not a scattered set of imperative ducks — is what guarantees the peek
    /// can't persist into a surface that never asked for it.
    private var librarianSuppressed: Bool {
        if router.isCapturing { return true }
        switch router.entryMode {
        case .canvas, .collectionCanvas:
            return false
        case .dashboard, .quikCapture, .recents:
            return true
        }
    }

    /// Drive the panel position from `librarianSuppressed`. Called on every
    /// input change (entry mode, capture) and at first-render alignment, so the
    /// position never drifts from the visible surface. Raise-intent callers
    /// (selection retract, detail rescue) stay separate but gate on the same
    /// predicate so they can't override a suppression.
    private func applyLibrarianVisibility(animated: Bool) {
        // BUG 11 dead-zone fix. The position duck can be raced by a concurrent
        // NavigationStack push (warm Map→"+" capture), leaving the panel's UIKit
        // surfaceView physically at peek. `LibrarianSurface`'s opacity gate hides
        // it visually, but the surfaceView (and its pan recognizer) still SWALLOW
        // touches in the bottom band — the QuikCapture / capture toolbar under it
        // needs ~a dozen taps to register. A SwiftUI `.allowsHitTesting(false)`
        // can't reach that UIKit view, so make the whole panel non-interactive at
        // the controller level when suppressed: touches then fall through to the
        // surface below. Instant (not animated), so it can't be raced.
        panelState.controller?.view.isUserInteractionEnabled = !librarianSuppressed
        if librarianSuppressed {
            panelState.duck(animated: animated)
        } else {
            panelState.raiseToPeek(animated: animated)
        }
    }

    /// Restore panel visibility for the live surface. Shared by capture-overlay
    /// dismiss and detail-view exit; delegates to the `librarianSuppressed` SSOT.
    private func restorePanelForEntryMode() {
        applyLibrarianVisibility(animated: true)
    }

    /// Collapse the entry modes to a Librarian scope.
    /// `canvas` and the two ducked modes (dashboard/recents) show
    /// the whole-corpus slice; only an explicit collection canvas
    /// scopes the Librarian to that collection. The Librarian reads
    /// this on first appear in a new host and seeds
    /// `LibrarianState.selectedScope` so search/Ask default to the
    /// slice the user is already looking at.
    private func hostScope(for mode: AppRouter.EntryMode) -> CanvasScope {
        switch mode {
        case .collectionCanvas(let id):
            return .collection(id)
        case .canvas, .dashboard, .quikCapture, .recents:
            return .corpus
        }
    }
}
