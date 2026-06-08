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
        ZStack {
            Group {
                switch router.entryMode {
                case .dashboard:
                    DashboardView()
                case .quikCapture(let forcedCollectionID, let origin):
                    QuikCaptureView(forcedCollectionID: forcedCollectionID, origin: origin)
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
                    case .dashboard, .quikCapture:
                        proxy.controller.hide(animated: false)
                    }
                }
        }
        .floatingPanelLayout(panelLayout)
        // Single existence rule: canvas / collectionCanvas raise the panel
        // to peek; dashboard / quikCapture duck it offscreen. Panel stays
        // mounted across all modes — never torn down. `.hidden` is not in
        // the layout's anchor set, so the duck goes through `hide()` (which
        // routes to a library-default offscreen anchor) — keeping `.tip`
        // as the hard user-facing floor for drag.
        .onChange(of: router.entryMode) { _, newMode in
            switch newMode {
            case .canvas, .collectionCanvas:
                panelState.raiseToPeek(animated: true)
            case .dashboard, .quikCapture:
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
        // dashboard / quikCapture the panel was already ducked so this
        // is a no-op there.
        .onChange(of: router.captureOverlay) { _, ctx in
            if ctx != nil {
                panelState.duck(animated: true)
            } else {
                switch router.entryMode {
                case .canvas, .collectionCanvas:
                    panelState.raiseToPeek(animated: true)
                case .dashboard, .quikCapture:
                    break
                }
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

    /// Collapse the four entry modes to a Librarian scope.
    /// `canvas` and the two ducked modes (dashboard/quikCapture) show
    /// the whole-corpus slice; only an explicit collection canvas
    /// scopes the Librarian to that collection. The Librarian reads
    /// this on first appear in a new host and seeds
    /// `LibrarianState.selectedScope` so search/Ask default to the
    /// slice the user is already looking at.
    private func hostScope(for mode: AppRouter.EntryMode) -> CanvasScope {
        switch mode {
        case .collectionCanvas(let id):
            return .collection(id)
        case .canvas, .dashboard, .quikCapture:
            return .corpus
        }
    }
}
