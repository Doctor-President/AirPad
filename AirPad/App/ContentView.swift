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
            DummyLibrarianPanelContent(model: panelState, proxy: proxy)
                .onAppear {
                    panelState.controller = proxy.controller
                    proxy.controller.delegate = panelState
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
    }
}
