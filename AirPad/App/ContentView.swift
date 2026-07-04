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
    @StateObject private var panelState = LibrarianPanelStateModel()
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
            // Stage 4.4 — global dev-panel summon button. Mounted at the
            // root so it's reachable from canvas, list, detail (pushed
            // inside the canvas's NavigationStack), and QuikCapture.
            // Self-deletes in commit 3 of Stage 4.4 along with
            // `EntryVisualDevPanel` and `EntryVisualSettings`.
            .overlay(alignment: .topTrailing) {
                EntryVisualDevPanelHost()
            }

            // In-app capture overlay (ws-in-app-capture-overlay). Lives at
            // the ContentView root so it floats over whichever entry mode
            // is active without changing the entry mode itself. Navigation
            // is deferred to the active surface via
            // `router.pendingNodeNavigationID` — the NavigationStack-owning
            // view (Dashboard, CanvasView, NodeListView) observes that
            // field and pushes onto its own path.
            if let ctx = router.captureOverlay {
                CaptureOverlayView(
                    context: ctx,
                    onDismiss: { router.captureOverlay = nil },
                    onNavigateToNode: { id in
                        router.pendingNodeNavigationID = id
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: router.captureOverlay)
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
                    // First-render alignment with the current entry mode.
                    // SwiftUI's `.onChange` doesn't fire for the initial
                    // value reliably across the panel-mount boundary, so
                    // align here once the controller is wired up.
                    switch router.entryMode {
                    case .canvas, .collectionCanvas:
                        proxy.controller.move(to: .tip, animated: false)
                    case .dashboard, .quikCapture, .recents:
                        proxy.controller.hide(animated: false)
                    }
                }
        }
        .floatingPanelLayout(panelLayout)
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
        .onChange(of: router.entryMode) { _, newMode in
            switch newMode {
            case .canvas, .collectionCanvas:
                panelState.raiseToPeek(animated: true)
            case .dashboard, .quikCapture, .recents:
                // Dashboard-persistence seam — Move 4 (or later) replaces
                // this duck with Dashboard-appropriate panel content so
                // the Librarian persists across dashboard too. Do NOT
                // build that here; it belongs to a later move.
                panelState.duck(animated: true)
            }
        }
        // Capture coexistence (fix-pass v3 Item 2b). When the in-app
        // capture overlay activates, duck the Librarian so its panel
        // doesn't render over the capture UI (Librarian is the topmost
        // layout resident — same reason QuikCapture mode ducks above).
        // On dismiss restore per current entry mode; if we're on
        // dashboard / recents the panel was already ducked so this
        // is a no-op there.
        .onChange(of: router.captureOverlay) { _, ctx in
            if ctx != nil {
                panelState.duck(animated: true)
            } else {
                restorePanelForEntryMode()
            }
        }
        // Capture mode (Dashboard "+"): the focused blank-node surface ducks the
        // Librarian so the note + capture buttons own the screen. Same duck path
        // as the capture overlay above; restore per entry mode on exit.
        .onChange(of: router.isCapturing) { _, capturing in
            if capturing {
                panelState.duck(animated: true)
            } else {
                restorePanelForEntryMode()
            }
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
                // Capture mode keeps the Librarian ducked — don't rescue-raise it
                // when entering the capture detail.
                if panelState.state == .hidden && !router.isCapturing {
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
            if isActive {
                panelState.raiseToPeek(animated: true)
            }
        }
        // Mirror the panel detent onto the router (fix-pass v3 Item 2a)
        // so views without a direct handle on `panelState` can gate
        // themselves on peek vs raised — the "+" capture trigger in
        // CanvasView / NodeListView uses this.
        .onChange(of: panelState.state) { _, newState in
            router.librarianAtPeek = (newState == .tip)
        }
    }

    /// Apply the entryMode → panel visibility rule. Extracted so both
    /// capture-overlay dismiss and detail-view exit can share it without
    /// duplicating the switch.
    private func restorePanelForEntryMode() {
        // Capture mode overrides the entry-mode rule — stay ducked until it ends.
        if router.isCapturing {
            panelState.duck(animated: true)
            return
        }
        switch router.entryMode {
        case .canvas, .collectionCanvas:
            panelState.raiseToPeek(animated: true)
        case .dashboard, .quikCapture, .recents:
            panelState.duck(animated: true)
        }
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
