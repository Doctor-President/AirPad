import SwiftUI
import AppIntents
#if DEBUG
import SpriteKit
#endif

@main
struct AirPadApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var store = CorpusStore()
    @State private var quarantineStore = QuarantineStore()
    @State private var selectionService = SelectionService()
    private let router: AppRouter

    init() {
        let appRouter = AppRouter()
        self.router = appRouter
        AppDependencyManager.shared.add(dependency: appRouter)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Data-independent measurement harnesses. Bypass the whole app
            // (store/iCloud) so CC can run them headless in the Simulator.
            if UserDefaults.standard.bool(forKey: "SPRCaretMeasure") {
                // MD14 note-caret tap-trace fixture (driven by XCUITest).
                CaretMeasureView()
            } else if UserDefaults.standard.bool(forKey: "SPRMeasure") {
                SPRMeasureView()
            } else if let shot = UserDefaults.standard.string(forKey: "PARITYShot"), !shot.isEmpty {
                // Quick-parity-sweep screenshot fixture (#13/#15/#17/#18).
                ParityShotsView(shot: shot)
            } else if let screen = UserDefaults.standard.string(forKey: "Screen"), !screen.isEmpty {
                // Light-mode convergence — REAL production surface over a seeded
                // real store (not a fixture), reached via `-Screen <name>`.
                DebugScreenHost(screen: screen)
            } else if let spine = UserDefaults.standard.string(forKey: "SPINEGATE"), !spine.isEmpty {
                // SPIKE v3 (spike-entry-spine) — THROWAWAY render gate fixture.
                // `-SPINEGATE notes|edge|gallery` renders fixed entry states (no
                // taps) so the container/spine idiom can be screenshot + diffed
                // against the T-approved reference before any TestFlight upload.
                SpineGateView(section: spine)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
    }

    private var mainContent: some View {
        ContentView()
            .environment(store)
            .environment(quarantineStore)
            .environment(router)
            .environment(selectionService)
            .task {
                store.quarantineStore = quarantineStore
                await store.setup()
            }
            .onOpenURL { url in
                guard url.scheme == "airpad", url.host == "quikcapture" else { return }
                // Open the standalone QuikCapture screen DIRECTLY — rendered
                // at the ContentView root, no Dashboard/Recents routing, so
                // there's no flash on entry.
                router.entryMode = .quikCapture
            }
    }
}

#if DEBUG
/// Node-perf measurement host — a bare `CorpusPhysicsScene` + SKView HUD. The
/// scene self-injects a synthetic corpus on `didMove` when launched with
/// `-SPRMeasure YES` (`-SPRLight ON|OFF` forces the render appearance). Reusable
/// for future node-perf / EFFECT spikes; reached only via that launch arg.
private struct SPRMeasureView: View {
    @State private var scene: CorpusPhysicsScene = {
        let s = CorpusPhysicsScene(size: CGSize(width: 393, height: 852))
        s.scaleMode = .resizeFill
        return s
    }()

    var body: some View {
        SpriteView(
            scene: scene,
            preferredFramesPerSecond: 60,
            options: [.allowsTransparency, .ignoresSiblingOrder],
            debugOptions: [.showsFPS, .showsDrawCount, .showsNodeCount]
        )
        .ignoresSafeArea()
        .background(.black)
    }
}

/// SPIKE v3 (`spike-entry-spine`) — THROWAWAY render gate. `-SPINEGATE <section>`
/// (notes | edge | gallery) renders fixed entry states through the REAL
/// `EntryCard` on a seeded in-memory store, so CC can screenshot each state
/// (expanded + collapsed, light + dark) and diff against the T-approved
/// reference (`Ops/design-refs/entry-primitives-mockup.html`) BEFORE TestFlight.
/// No taps: fold state comes from each fixture item's `isExpanded`.
private struct SpineGateView: View {
    let section: String
    @State private var store = CorpusStore()
    @State private var reorder = EntryReorderController()
    @State private var quarantineStore = QuarantineStore()
    @State private var selectionService = SelectionService()
    private let router = AppRouter()

    private var node: Node { SpineGateView.node(for: section) }

    var body: some View {
        Group {
            if section == "related" { relatedRepro } else { entriesRepro }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        // ws-entry-containers hold-drag repro HUD — reads the reorder controller
        // live so a UI-test long-press can observe whether the background
        // recognizer ever fired. Gated behind `-REORDERHUD YES` so normal visual
        // gates stay clean; non-hit-testing so it never eats a press.
        .overlay(alignment: .top) {
            if UserDefaults.standard.bool(forKey: "REORDERHUD") {
                Text("att:\(reorder.debugLiftAttempts) act:\(reorder.isReorderActive ? "Y" : "N") held:\(reorder.isCardLifted ? "Y" : "N")")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(5)
                    .background(Color.black)
                    .accessibilityIdentifier("reorderHUD")
                    .allowsHitTesting(false)
            }
        }
        // Dashboard Related-nav repro — the REAL DashboardView writes node-detail
        // depth to `store.detailViewDepth`; this HUD exposes it so a UI-test can
        // observe whether a Related push inside a Dashboard-pushed detail navigates
        // (depth 1 → 2). The typed-[DashboardRoute]-path bug held it at 1.
        .overlay(alignment: .top) {
            if section == "related" {
                Text("depth:\(store.detailViewDepth)")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(5)
                    .background(Color.black)
                    .accessibilityIdentifier("navDepthHUD")
                    .allowsHitTesting(false)
            }
        }
        .environment(store)
        .environment(reorder)
        .environment(quarantineStore)
        .environment(selectionService)
        .environment(router)
        .onAppear {
            store.nodes = section == "related" ? SpineGateView.relatedSeed() : [node]
        }
    }

    private var entriesRepro: some View {
        let items = node.items
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {   // reference `.phone { gap: 16 }`
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    EntryCard(item: item, nodeID: node.id, index: idx,
                              snapshotIDs: items.map(\.id), onBacklink: nil)
                }
            }
            .padding(20)
        }
    }

    /// Dashboard Related-nav repro (2026-08-24) — hosts the REAL `DashboardView`
    /// started directly in the src node's detail (`initialRoute: .node(src)`), so
    /// the FIRST push is a `DashboardRoute` on the Dashboard's own stack. Tapping a
    /// Related link inside then fires `NavigationLink(value: NodeDetailRoute)` — the
    /// exact push a typed `[DashboardRoute]` path silently dropped (the
    /// Recents→detail→Related "registers but never navigates" bug). The
    /// `navDepthHUD` (`store.detailViewDepth`) shows whether it navigates: the fix
    /// (`NavigationPath`) takes it 1 → 2; the bug held it at 1.
    private var relatedRepro: some View {
        DashboardView(initialRoute: .node(SpineGateView.relatedSeed()[0]))
    }

    private static func relatedSeed() -> [Node] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var note = NodeItem(id: "src-note", type: .text, createdAt: now,
                            content: "Roasted tomato base\nA slow oven, good oil, patience.")
        note.isExpanded = true
        let t1 = Node(id: "tgt1", createdAt: now, updatedAt: now, title: "Confit garlic method", summary: "", tags: [])
        let t2 = Node(id: "tgt2", createdAt: now, updatedAt: now, title: "Sourdough, day 3", summary: "", tags: [])
        let src = Node(id: "src", createdAt: now, updatedAt: now, title: "Sauce", summary: "", tags: [],
                       items: [note],
                       connections: [NodeConnection(nodeID: "tgt1", createdAt: now),
                                     NodeConnection(nodeID: "tgt2", createdAt: now)])
        return [src, t1, t2]
    }

    private static func node(for section: String) -> Node {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func note(_ id: String, _ content: String, _ expanded: Bool) -> NodeItem {
            var n = NodeItem(id: id, type: .text, createdAt: now, content: content)
            n.isExpanded = expanded
            return n
        }
        func link(_ id: String, _ url: String, _ title: String) -> NodeItem {
            var n = NodeItem(id: id, type: .link, createdAt: now)
            n.url = url; n.title = title; n.isExpanded = true
            return n
        }
        func doc(_ id: String, _ file: String) -> NodeItem {
            var n = NodeItem(id: id, type: .document, createdAt: now)
            n.file = file; n.isExpanded = true
            return n
        }
        func gallery(_ id: String, _ count: Int, _ expanded: Bool) -> NodeItem {
            var it = NodeItem(id: id, type: .imageVideo, createdAt: now)
            it.displayName = "Moodboard"
            it.mediaItems = (1...count).map {
                GalleryItem(id: "\(id)-\($0)", mediaType: .image, file: "\(id)-\($0).jpg", capturedAt: now)
            }
            it.isExpanded = expanded
            return it
        }
        // ws-entry-containers step 3 — generic-container types.
        func voice(_ id: String, _ duration: Double, _ transcript: String, _ expanded: Bool) -> NodeItem {
            var n = NodeItem(id: id, type: .audio, createdAt: now)
            n.displayName = "Idea walk 8/19"
            n.durationSeconds = duration
            n.transcript = transcript
            n.isExpanded = expanded
            return n
        }
        func singleMedia(_ id: String, _ expanded: Bool) -> NodeItem {
            var n = NodeItem(id: id, type: .imageVideo, createdAt: now)
            n.displayName = "Cover shot"
            n.mediaItems = [GalleryItem(id: "\(id)-1", mediaType: .image, file: "\(id)-1.jpg", capturedAt: now)]
            n.isExpanded = expanded
            return n
        }
        func multiLink(_ id: String, _ count: Int, _ expanded: Bool) -> NodeItem {
            var n = NodeItem(id: id, type: .link, createdAt: now)
            n.displayName = "Reading list"
            n.linkItems = (1...count).map { i in
                LinkItem(id: "\(id)-\(i)", url: "https://example\(i).com",
                         title: "Article \(i)", siteName: "example\(i).com", capturedAt: now)
            }
            n.isExpanded = expanded
            return n
        }
        func multiDoc(_ id: String, _ count: Int, _ expanded: Bool) -> NodeItem {
            var n = NodeItem(id: id, type: .document, createdAt: now)
            n.displayName = "Specs"
            n.documentItems = (1...count).map { i in
                DocumentItem(id: "\(id)-\(i)", filePath: "\(id)-\(i).pdf",
                             fileName: "doc-\(i).pdf", fileType: "pdf", capturedAt: now)
            }
            n.isExpanded = expanded
            return n
        }

        let items: [NodeItem]
        switch section {
        case "notes":
            items = [
                note("n-exp",
                     "Ingredients\n2 lbs roma tomatoes, halved\n1 head garlic, top sliced off\n3 tbsp olive oil\nFresh basil, torn · salt · cracked pepper",
                     true),
                note("n-col",
                     "Ingredients\n2 lbs roma tomatoes, halved\n1 head garlic, top sliced off",
                     false),
                note("n-link",
                     "[Designing calm interfaces](https://essays.arc) — the north star\nThe whole read is about restraint: fewer moving parts, quieter defaults, and letting the content breathe.",
                     true),
            ]
        case "edge":
            items = [
                note("n-bold",
                     "**Moodboard brief** for the launch\nWarm, editorial, a little analog — serif headers, generous margins.",
                     true),
                // Explicit HEADING style on paragraph 1 — must be HONORED (rendered as
                // the note's Heading, NOT force-faced to the entry-title serif).
                note("n-head",
                     "## Weeknight pastas\nkeep it simple: garlic, oil, chili, a little pasta water.",
                     true),
                // "first line deleted" (realistic: the line + its newline are removed,
                // no leading blank) — whatever is now first becomes the styled title.
                note("n-del",
                     "eggs, room temp\nsourdough, day-old\nParmigiano, grated\na good olive oil",
                     true),
                link("l1", "https://essays.arc", "Reading list"),
                doc("d1", "bridge-contract-v1.pdf"),
            ]
        case "gallery":
            items = [
                gallery("g-exp", 6, true),
                gallery("g-col", 6, false),
            ]
        case "types":
            // Step-3 generic-container types: collapsed rows first (metadata is
            // the thing to read), then expanded bodies.
            items = [
                voice("v-col", 161, "…what if pulling a thread felt like actually pulling…", false),
                multiLink("ml-col", 3, false),
                multiDoc("md-col", 2, false),
                voice("v-exp", 161, "…what if pulling a thread felt like actually pulling — resistance, then release…", true),
                singleMedia("sm-exp", true),
                multiLink("ml-exp", 3, true),
                multiDoc("md-exp", 2, true),
            ]
        default:
            items = [note("n", "Unknown SPINEGATE section '\(section)'", true)]
        }
        return Node(id: "spine-gate-\(section)", createdAt: now, updatedAt: now,
                    title: "Spine gate — \(section)", summary: "", tags: [], items: items)
    }
}
#endif
