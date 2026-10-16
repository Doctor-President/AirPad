#if DEBUG
import SwiftUI
import SpriteKit

/// live-20 (3) — the eight surfaces that joined two `Text`s with `+` (deprecated in iOS 26), rendered with synthetic
/// content for before/after Simulator stills (light + dark): `-Screen textruns-<page>`. The sheets, the detail view and
/// the Librarian are the real screens over `DebugScreenHost`'s seeded store; the rest are the production components.
///   recents · reviewqueue · quarantine · entrycard · offer (Librarian, `-LibrarianDetent full`) · transcript · table · overlay
/// Dates are a fixed past moment, so the relative-time text reads the same minutes apart.
struct TextRunsGallery: View {
    let page: String
    static let past = Date(timeIntervalSince1970: 1_700_000_000)

    @Environment(CorpusStore.self) private var store

    var body: some View {
        ZStack {
            AppearancePalette.bgBase.ignoresSafeArea()
            content.padding(.horizontal, 20)
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "recents":
            VStack(alignment: .leading, spacing: 14) {
                ForEach(store.nodes.prefix(3), id: \.id) { n in
                    RecentNodeRow(node: n, timestamp: Self.past, ink: AppearancePalette.ink)
                }
            }
        case "transcript":
            LiveTranscriptView(settled: "Walked the harbour wall at low tide; the north mooring rings are rusting through and need replacing before winter",
                               volatile: "and the slipway gate sticks", font: .system(size: 20))
        case "table":
            ScrollView {
                MarkdownBlockText(raw: """
                The tide logs, side by side:

                | Week | High water | Low water | Note |
                |---|---|---|---|
                | 1 | 06:12 | 12:30 | **Spring** tide mid-week |
                | 2 | 07:05 | 13:21 | Neap at the end |
                """)
                .padding(.top, 120)
            }
        case "overlay":
            if let n = store.nodes.first(where: { $0.id == "seed-runs" }) {
                NodeDetailOverlay(node: n, canvasState: CanvasState(), isDismissing: .constant(false),
                                  navigationPath: .constant(NavigationPath()),
                                  scene: CorpusPhysicsScene(size: CGSize(width: 400, height: 800)))
            }
        default:
            Text("unknown textruns page: \(page)")
        }
    }

    /// Seeds for every page (runs once, after `DebugScreenHost.seed`'s own corpus).
    static func seed(screen: String, store: CorpusStore, router: AppRouter, quarantine: QuarantineStore) {
        store.nodes.append(Node(id: "seed-runs", createdAt: past, updatedAt: past, title: "Harbour wall survey",
                                summary: "Mooring rings and the slipway gate before winter.", tags: [],
                                items: [NodeItem(id: "seed-runs-text", type: .text, createdAt: past,
                                                 content: "The north mooring rings are rusting through."),
                                        { var d = NodeItem(id: "seed-runs-doc", type: .document, createdAt: past)
                                          d.documentItems = [ParityShotsView.mockDoc]; return d }(),
                                        // a chats entry wears the plain title row — the one with "… ago"
                                        NodeItem(id: "seed-runs-chats", type: .chats, createdAt: past)],
                                entrySchemaVersion: 1))
        switch screen {
        case "textruns-reviewqueue":
            store.reviewQueue = [
                RejectedBlock(id: "rq-1", text: "half a thought about the tide tables and", reason: .heuristic, importTimestamp: "seed", rejectedAt: past),
                RejectedBlock(id: "rq-2", text: "see above", reason: .coherence, importTimestamp: "seed", rejectedAt: past),
            ]
        case "textruns-quarantine":
            for t in ["ok", "the the the"] {
                quarantine.add(BatchParser.QuarantinedEntry(rawText: t, l1Labels: BatchParser.classifyLayer1(t), reason: "too short", importedAt: past))
            }
        case "textruns-offer":
            router.librarian.pendingReadInFullOffer = .init(query: "What did the tide logs say?", nodeID: "seed-runs", title: "Harbour wall survey")
        default:
            break
        }
    }
}
#endif
