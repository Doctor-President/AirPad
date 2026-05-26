import SwiftUI

struct ContentView: View {

    @Environment(AppRouter.self) private var router

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
    }
}
