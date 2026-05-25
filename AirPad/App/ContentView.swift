import SwiftUI

struct ContentView: View {

    @Environment(AppRouter.self) private var router

    var body: some View {
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
        // Stage 4.4 — global dev-panel summon button. Mounted at the root
        // so it's reachable from canvas, list, detail (pushed inside the
        // canvas's NavigationStack), and QuikCapture. Self-deletes in
        // commit 3 of Stage 4.4 along with `EntryVisualDevPanel` and
        // `EntryVisualSettings`.
        .overlay(alignment: .topTrailing) {
            EntryVisualDevPanelHost()
        }
    }
}
