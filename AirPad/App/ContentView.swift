import SwiftUI

struct ContentView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(QuarantineStore.self) private var quarantineStore

    /// Host scope passed into the Librarian presenter's
    /// `LibrarianSurface(hostScope:)`. Mirrors the active entry mode so
    /// a Librarian opened on a collection canvas seeds its scope chip
    /// from that collection. Dashboard / QuikCapture both reduce to
    /// `.corpus` — the sheet is dismissed there, so the value is only
    /// read on the next `.canvas` / `.collectionCanvas` transition.
    private var librarianHostScope: CanvasScope {
        if case .collectionCanvas(let id) = router.entryMode {
            return .collection(id)
        }
        return .corpus
    }

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
        // Stable Librarian sheet owner. Mounted on the outer ZStack so the
        // representable / UIHostingController / Coordinator persist for the
        // whole app session — not torn down by `router.entryMode` switches
        // (which only re-evaluate the inner `Group`) and not by graph↔list
        // toggles (those live two levels down inside `CanvasChrome`).
        // Presentation intent is reconciled in `updateUIViewController`
        // against the live `presentedHostingVC`; existence is driven by the
        // `.onChange(of: router.entryMode)` below.
        .background {
            LibrarianSheetPresenter(
                store: store,
                router: router,
                selection: selection,
                quarantineStore: quarantineStore,
                hostScope: librarianHostScope
            )
        }
        // Single existence rule: canvas / collectionCanvas present at peek;
        // dashboard / quikCapture dismiss. Replaces the per-surface
        // `.onAppear` / `.onDisappear` pair that used to fire from
        // CanvasChrome — those tore down and re-presented on every chrome
        // rebuild, which flooded "already presenting" errors and left
        // orphan sheets with their own grabber.
        .onChange(of: router.entryMode) { _, newMode in
            switch newMode {
            case .canvas, .collectionCanvas:
                router.librarian.sheetInitialDetent = .peek
                router.librarian.sheetPresented = true
            case .dashboard, .quikCapture:
                router.librarian.sheetPresented = false
            }
        }
    }
}
