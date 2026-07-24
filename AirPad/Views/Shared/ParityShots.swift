import SwiftUI
import UIKit

// Quick-parity-sweep screenshot fixture (DEBUG-only, data-independent). Reached
// via `-PARITYShot gutter|card|chips|body|list`. Bypasses the store/iCloud so CC
// can boot it headless in the Simulator and capture LIGHT/DARK artifacts:
//   • gutter → #15 note-entry width (three candidate horizontal gutters)
//   • card   → #17 + #18 AFTER, integrated in a real NodeCardView
//   • chips  → #17 chip ink, BEFORE (cream) vs AFTER (shipped tiles), one image
//   • body   → #18 note-body, BEFORE (raw markdown) vs AFTER (formatted), one image
//   • list   → #13 warm row shadow, BEFORE (none) vs AFTER (warm), one image
// Inert unless the launch arg is set; the whole file is DEBUG-only.

#if DEBUG
struct ParityShotsView: View {
    let shot: String

    // A bare store: NodeCardView / CardLinkTile / CardDocumentTile / RecentNodeRow
    // all read `@Environment(CorpusStore.self)`. The card looks up its live node
    // and falls back to `fallbackNode`; the chip tiles' cached-image `.task`
    // returns nil (no sidecars) → SF-symbol fallback, which is the ink path #17
    // fixes. `setup()` is never called → no iCloud/disk work.
    @State private var store = CorpusStore()
    /// Router for the `dash` shot's real `DashboardView` (unused by other shots).
    @State private var dashRouter = AppRouter()
    /// For the `canvas` shot's map ground (mapBackground is `dark:`-parameterised).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch shot {
            case "gutter": gutterShot
            case "card":   cardShot
            case "chips":  chipsShot
            case "body":   bodyShot
            case "list":   listShot
            case "dash":   dashShot
            case "recents": recentsShot
            case "canvas": canvasShot
            case "capture": captureShot
            default:       Text("unknown PARITYShot: \(shot)")
            }
        }
        .environment(store)
    }

    // MARK: - #3 fix-up · dashboard pane parity (Today / Recents / Collections)

    /// The REAL `DashboardView` (hub; `initialRoute` nil) over a small seeded
    /// store + a fresh router, so Today / Recents / Collections render with live
    /// rows and the lava lamp behind. Screenshot LIGHT/DARK to confirm the three
    /// panes read as ONE family (same `.thinMaterial`, radius 22, white rim, no
    /// shadow) and that the lava reads THROUGH Recents + Collections as it does
    /// through Today. Seeds `store.nodes` directly (no setup()/iCloud).
    private var dashShot: some View {
        DashboardView()
            .environment(dashRouter)
            .onAppear { if store.nodes.isEmpty { store.nodes = Self.dashSeedNodes } }
    }

    /// A few nodes so Corpus counts, the Today "Activity" list, and Recents have
    /// content. None carry a `journalDate`, so the Journal collection row stays a
    /// regular (non-Corpus) row — the Recents height parity target.
    private static let dashSeedNodes: [Node] = (0..<4).map { i in
        Node(id: "dash-\(i)", createdAt: epoch, updatedAt: epoch,
             title: ["On the Gerund", "Tomoe River paper",
                     "Cucumber-water light", "Fold index notes"][i],
             summary: "", tags: [])
    }

    // MARK: - Recents light-mode pass · the REAL RecentsView

    /// The REAL `RecentsView` over a seeded store, in a NavigationStack (its own
    /// glass-chrome header hides the nav bar). Nodes are dated relative to now so
    /// the Today / Previous 7 Days / Previous 30 Days / month buckets all appear —
    /// screenshot LIGHT/DARK to check ink legibility, container parity with the
    /// dashboard panes, and the standard back/sort chrome.
    private var recentsShot: some View {
        NavigationStack {
            RecentsView(onOpenNode: { _ in })
                .onAppear { if store.nodes.isEmpty { seedRecents() } }
        }
    }

    /// Spreads seed nodes across the buckets (now / −3d / −10d / −40d). Empty
    /// tags → gray color dots, which is fine for the parity shot.
    private func seedRecents() {
        let now = Date()
        let cal = Calendar.current
        let offsets: [(String, Int)] = [
            ("On the Gerund", 0), ("Tomoe River paper", -3),
            ("Cucumber-water light", -10), ("Fold index notes", -40),
        ]
        store.nodes = offsets.enumerated().map { i, pair in
            let d = cal.date(byAdding: .day, value: pair.1, to: now) ?? now
            return Node(id: "recents-\(i)", createdAt: d, updatedAt: d,
                        title: pair.0, summary: "", tags: [])
        }
    }

    // MARK: - Canvas light-mode sweep · SwiftUI overlays over the real map ground

    /// The changed Canvas SwiftUI overlays, each over the REAL adaptive map ground
    /// (`AppearancePalette.mapBackground`, cream in light / near-black in dark), so
    /// LIGHT/DARK screenshots show the exact ink/chrome on the exact background:
    ///   • focal-engagement text — reconstructed with the REAL `NodeGradientBackground`
    ///     bubble + the REAL `AppearancePalette.ink` treatment (the live overlay
    ///     needs a physics scene, so the text block is rebuilt faithfully here).
    ///   • a couple of cluster `LabelPill`-style pills (`.ultraThinMaterial` + ink).
    ///   • the drill-down back pill.
    ///   • the real `EmptyStateOverlay` + `ModelProcessingIndicator`.
    /// (The capture `CollectionPillRail` has its own `captureShot`.)
    private var canvasShot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                captionLabel("FOCAL ENGAGEMENT — text over the node bubble (ink)")
                focalSample(Self.mockNode)

                captionLabel("CLUSTER / DRILL-DOWN PILLS — .ultraThinMaterial + ink")
                HStack(spacing: 10) {
                    mapPill { Label("Grammar", systemImage: "chevron.left") }
                    mapPill { Text("Stationery") }
                    mapPill { Text("Cucumber Water") }
                }

                captionLabel("MODEL PROCESSING + EMPTY STATE")
                ModelProcessingIndicator()
                EmptyStateOverlay()
                    .frame(height: 120)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppearancePalette.mapBackground(dark: colorScheme == .dark).ignoresSafeArea())
    }

    /// Faithful rebuild of the focal-engagement text block: the REAL node bubble
    /// gradient + the REAL `AppearancePalette.ink` (1.0 / 0.85 / 0.65 ratios).
    private func focalSample(_ node: Node) -> some View {
        ZStack {
            NodeGradientBackground(node: node, cornerRadius: 32)
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                Text("A node summary line that must stay legible whether the bubble goes light on parchment or dark under Solar Flare.")
                    .font(.system(size: 16))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                Spacer()
                HStack(spacing: 16) {
                    Label("3", systemImage: "pencil").font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    Label("2", systemImage: "link").font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    Text("2 days ago").font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.65))
                }
            }
            .padding(24)
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    /// The map-pill treatment I applied to `LabelPill` / the drill-down button:
    /// adaptive `.ultraThinMaterial` + `AppearancePalette.ink`.
    private func mapPill<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        label()
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(AppearancePalette.ink.opacity(0.95))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: - Capture surface · the REAL CollectionPillRail

    /// The REAL `CollectionPillRail` over the adaptive capture ground
    /// (`AppearancePalette.bgBase`), with one pill pre-selected so both the
    /// selected (white) and unselected (glass) states show. Seeds a few
    /// collections. Screenshot LIGHT/DARK to confirm the unselected pills are the
    /// standard glass (not a solid dark circle) and the labels are legible.
    private var captureShot: some View {
        VStack(spacing: 20) {
            captionLabel("CAPTURE — CollectionPillRail (one selected, rest glass)")
            CollectionPillRail(
                selectedCollectionID: .constant("cap-1"),
                onCreateNew: {}
            )
            Spacer()
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .onAppear {
            if store.collections.isEmpty {
                store.collections = ["Reading", "Field Notes", "Grammar", "Stationery"]
                    .enumerated().map { i, name in NodeCollection(id: "cap-\(i)", name: name) }
            }
        }
    }

    // MARK: - #15 · note-entry gutter candidates

    private static let noteFixture = """
    **Gerund** — a noun made from a verb by adding *-ing*. Writing is the \
    gerund here; it names the activity, not the act.
    See the [style note](https://example.com) for the full rule, and check:
    - [ ] rewrite the opening line
    - [ ] tighten the second paragraph
    A comfortably multi-line note so the text column width is easy to judge \
    at each gutter.
    """

    /// Faithful repro of the detail column: the whole column is inset 20 pt
    /// (NodeDetailView `.padding(20)`); the TITLE sits at that 20 pt edge, and
    /// each entry card adds a further horizontal inset (EntryCard
    /// `.padding(.horizontal, 12)`) — so the note's OUTER gutter today is 20+12
    /// = 32 pt, wider than the title. The candidates vary ONLY that entry inset
    /// (12 → 6 → 0); the note panel widens toward the title. Internal text
    /// padding (22) is unchanged — this is the outer gutter T marked.
    private var gutterShot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The title reference — sits at the 20 pt column edge, unchanged.
                Text("Vocabulary words")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(AppearancePalette.ink)

                notePanel(entryInset: 12, caption: "Entry inset 12 pt — CURRENT (note outer gutter 32 pt)")
                notePanel(entryInset: 6,  caption: "Entry inset 6 pt — note moderately wider (outer gutter 26 pt)")
                notePanel(entryInset: 0,  caption: "Entry inset 0 pt — note flush with title column (outer gutter 20 pt)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)   // the real detail-column inset
        }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
    }

    /// One entry row: the note panel (TextEntryBody styling — bgElevated, rim,
    /// shadow, corner 24, internal text padding 22) inset by `entryInset` inside
    /// the 20 pt column, exactly as EntryCard wraps it. The dashed rule marks the
    /// title/column edge so the panel's outer gutter is legible.
    private func notePanel(entryInset: CGFloat, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            captionLabel(caption)
            RichTextEditor(text: .constant(Self.noteFixture),
                           placeholder: "note…",
                           documentStyle: true,
                           documentFont: .sourceSerif4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)   // TextEntryBody internal text padding (unchanged)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppearancePalette.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                )
                .shadow(color: AppearancePalette.panelShadow, radius: 12, x: 0, y: 4)
                .padding(.horizontal, entryInset)   // EntryCard outer gutter (the knob)
        }
    }

    // MARK: - #17 + #18 · one integrated card (AFTER)

    /// Payload order [link, doc, text]: the two rigid chips (64 pt each) are
    /// selected first, then the elastic text fills the remainder — so the #17
    /// chips are visible AND the #18 body renders formatted, in one real card.
    private var cardShot: some View {
        NodeCardView(nodeID: Self.mockNode.id,
                     fallbackNode: Self.mockNode,
                     animateEntry: false,
                     presentation: .vertical)
            .frame(width: 340, height: 640)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppearancePalette.bgBase.ignoresSafeArea())
    }

    // MARK: - #17 · chip ink before/after

    /// The two card chips over the real card gradient (their true ground).
    /// BEFORE: the old cream ink (near-white → washes out on the light card face).
    /// AFTER: the shipped CardLinkTile / CardDocumentTile (appearance-aware ink).
    private var chipsShot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                captionLabel("BEFORE — cream ink (illegible on the light card face)")
                chipRow { creamChipPair }

                captionLabel("AFTER — shipped tiles (appearance-aware ink)")
                chipRow {
                    HStack(spacing: 8) {
                        CardLinkTile(linkItem: Self.mockLink, nodeID: Self.mockNode.id)
                        CardDocumentTile(documentItem: Self.mockDoc, nodeID: Self.mockNode.id)
                    }
                }
            }
            .padding(20)
        }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
    }

    /// Chips sit on the same gradient the card draws behind them.
    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NodeGradientLayer(node: Self.mockNode)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            )
    }

    /// Inline repro of the two chips with the OLD cream ink (the #17 bug).
    private var creamChipPair: some View {
        let cream = Color(red: 1.0, green: 0.976, blue: 0.941)
        return HStack(spacing: 8) {
            legacyChip(icon: "link", title: "A Short Guide to the Gerund",
                       meta: "example.com", titleInk: cream.opacity(0.95), metaInk: cream.opacity(0.55))
            legacyChip(icon: "doc.richtext.fill", title: "Gerunds & Participles",
                       meta: "12 pages · 3400 words", titleInk: cream.opacity(0.95), metaInk: cream.opacity(0.55))
        }
    }

    /// The CardLinkTile/CardDocumentTile layout, ink-parameterised, for the BEFORE.
    private func legacyChip(icon: String, title: String, meta: String,
                            titleInk: Color, metaInk: Color) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.08))
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(metaInk)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundColor(titleInk).lineLimit(2)
                Text(meta).font(.system(size: 10, design: .serif))
                    .foregroundColor(metaInk).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 64, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }

    // MARK: - #18 · note-body before/after

    private static let bodyMarkdown = """
    **Gerund** names an activity: *writing* is the classic case. \
    See the [style note](https://example.com) and finish:
    - [ ] rewrite the opening
    - [x] cite the source
    """

    /// BEFORE: the raw markdown string dumped as plain Text (literal asterisks).
    /// AFTER: the same string through the MarkdownCodec pipeline #18 reuses,
    /// rendered read-only as a SwiftUI Text(AttributedString) — no UITextView.
    private var bodyShot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                captionLabel("BEFORE — raw markdown (asterisks dumped)")
                bodyPanel { Text(Self.bodyMarkdown)
                    .font(.system(size: 15, design: .serif))
                    .foregroundColor(bodyInk) }

                captionLabel("AFTER — formatted via the note markdown pipeline")
                bodyPanel { Text(Self.renderedBody)
                    .foregroundColor(bodyInk) }
            }
            .padding(20)
        }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
    }

    private var bodyInk: Color { AppearancePalette.ink.opacity(0.9) }

    private func bodyPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppearancePalette.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// Read-only AttributedString built from the same NSAttributedString the card
    /// body uses (`MarkdownCodec.decode`), mapping UIFont traits → SwiftUI font —
    /// the exact shape of NodeCardView.markdownBody, so the AFTER matches the card.
    private static let renderedBody: AttributedString = {
        let ns = MarkdownCodec.decode(bodyMarkdown)
        guard ns.length > 0 else { return AttributedString(bodyMarkdown) }
        var out = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length), options: []) { attrs, range, _ in
            let seg = (ns.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !seg.isEmpty else { return }
            var piece = AttributedString(seg)
            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic)
            var font = Font.system(size: 15, weight: isBold ? .bold : .regular, design: .serif)
            if isItalic { font = font.italic() }
            piece.font = font
            if (attrs[.underlineStyle] as? Int).map({ $0 != 0 }) ?? false { piece.underlineStyle = .single }
            if (attrs[.strikethroughStyle] as? Int).map({ $0 != 0 }) ?? false { piece.strikethroughStyle = .single }
            out.append(piece)
        }
        return out.characters.isEmpty ? AttributedString(bodyMarkdown) : out
    }()

    // MARK: - #13 · list-row separation candidates (light mode)

    // Warm shadow hue = cardShadow's warm value (#43372A). T picked B (bgElevated
    // warm fill) but wants a heavier shadow than the shipped 0.22 — this ramps
    // alpha/blur/offset so T can dial the exact weight. Light-mode context only.
    private static func warm(_ a: Double) -> Color {
        Color(red: 67/255, green: 55/255, blue: 42/255).opacity(a)
    }

    /// B's warm elevated fill (`bgElevated`), ramped through four shadow weights
    /// over the dotted parchment (real insetGrouped List). DARK stays on
    /// `.ultraThinMaterial` byte-identical regardless of pick — only LIGHT changes.
    private var listShot: some View {
        ZStack {
            AppearancePalette.mapBackground(dark: false).ignoresSafeArea()
            BackgroundGridView().ignoresSafeArea().allowsHitTesting(false)
            List {
                candidateSection("B0 — first-pass soft shadow (0.22 · r12 · y4)", index: 0) {
                    Rectangle().fill(AppearancePalette.bgElevated)
                        .shadow(color: Self.warm(0.22), radius: 12, x: 0, y: 4)
                }
                candidateSection("B1 — 0.35 · r14 · y5", index: 1) {
                    Rectangle().fill(AppearancePalette.bgElevated)
                        .shadow(color: Self.warm(0.35), radius: 14, x: 0, y: 5)
                }
                candidateSection("B2 — 0.50 · r18 · y7", index: 2) {
                    Rectangle().fill(AppearancePalette.bgElevated)
                        .shadow(color: Self.warm(0.50), radius: 18, x: 0, y: 7)
                }
                candidateSection("B3 — 0.62 · r22 · y9", index: 3) {
                    Rectangle().fill(AppearancePalette.bgElevated)
                        .shadow(color: Self.warm(0.62), radius: 22, x: 0, y: 9)
                }
                candidateSection("B4 — 0.75 · r26 · y11", index: 0) {
                    Rectangle().fill(AppearancePalette.bgElevated)
                        .shadow(color: Self.warm(0.75), radius: 26, x: 0, y: 11)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private func candidateSection<BG: View>(_ label: String, index: Int,
                                            @ViewBuilder background: () -> BG) -> some View {
        let bg = background()
        return Section {
            RecentNodeRow(node: Self.mockListNodes[index], timestamp: Self.mockListNodes[index].updatedAt,
                          ink: AppearancePalette.ink)
                .listRowBackground(bg)
        } header: { listHeader(label) }
    }

    private func listHeader(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold))
            .foregroundStyle(AppearancePalette.ink.opacity(0.6))
            .textCase(.uppercase).tracking(0.8)
    }

    // MARK: - Shared

    private func captionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(AppearancePalette.ink.opacity(0.7))
    }

    // MARK: - Mocks

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static let mockLink = LinkItem(
        id: "px-link", url: "https://example.com/grammar",
        title: "A Short Guide to the Gerund", description: nil, imageFile: nil,
        siteName: "example.com", faviconFile: nil, capturedAt: epoch)

    static let mockDoc = DocumentItem(
        id: "px-doc", filePath: "grammar.pdf", fileName: "grammar.pdf", fileType: "pdf",
        documentTitle: "Gerunds & Participles", extractedText: nil, thumbnailFile: nil,
        pageCount: 12, wordCount: 3400, capturedAt: epoch)

    /// One node: [link, doc, text] so the chips render before the elastic body.
    static let mockNode: Node = {
        var link = NodeItem(id: "px-link", type: .link, createdAt: epoch)
        link.linkItems = [mockLink]
        var doc = NodeItem(id: "px-doc", type: .document, createdAt: epoch)
        doc.documentItems = [mockDoc]
        let text = NodeItem(id: "px-text", type: .text, createdAt: epoch, content: bodyMarkdown)
        return Node(
            id: "px-node", createdAt: epoch, updatedAt: epoch,
            title: "On the Gerund",
            summary: "",
            tags: ["grammar", "writing"],
            items: [link, doc, text],
            descriptionOnCard: false)
    }()

    static let mockListNodes: [Node] = (0..<4).map { i in
        Node(id: "px-row-\(i)", createdAt: epoch, updatedAt: epoch,
             title: ["On the Gerund", "Tomoe River paper", "Cucumber-water light", "Fold index notes"][i],
             summary: "", tags: [["grammar"], ["stationery"], ["design"], ["engineering"]][i])
    }
}

// MARK: - Real-screen presenter for the light-mode convergence pass

/// Renders an ACTUAL production surface (not a reconstruction) over a seeded REAL
/// store, reached via `-Screen <name>`. Unlike the parity fixtures, this is the
/// real view with real data — the same SettingsView / ChatsListView / TagEditor
/// the app shows — so LIGHT/DARK screenshots are recognisable real screens. The
/// launch arg is set per shot; each real view is rendered directly (its own
/// NavigationStack + `.presentationBackground` are honoured where present).
struct DebugScreenHost: View {
    let screen: String

    @State private var store = CorpusStore()
    @State private var router = AppRouter()
    @State private var quarantineStore = QuarantineStore()
    @State private var selectionService = SelectionService()

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    var body: some View {
        content
            .environment(store)
            .environment(router)
            .environment(quarantineStore)
            .environment(selectionService)
            .onAppear(perform: seed)
    }

    /// Seed a small REAL corpus: tags (a DARK blue + a LIGHT yellow so the
    /// selected-tag-pill luminance ink is visible both ways), collections, nodes.
    private func seed() {
        guard store.tags.isEmpty else { return }
        store.tags = [
            Tag(id: UUID(), name: "grammar",    colorHex: "#1B59C2", createdAt: Self.epoch, useCount: 5),
            Tag(id: UUID(), name: "stationery", colorHex: "#F5C542", createdAt: Self.epoch, useCount: 3),
            Tag(id: UUID(), name: "design",     colorHex: "#E8820A", createdAt: Self.epoch, useCount: 2),
        ]
        store.collections = ["Reading", "Field Notes", "Grammar"].enumerated().map { i, n in
            NodeCollection(id: "seed-col-\(i)", name: n)
        }
        store.nodes = ["On the Gerund", "Tomoe River paper", "Cucumber-water light"].enumerated().map { i, t in
            Node(id: "seed-\(i)", createdAt: Self.epoch, updatedAt: Self.epoch,
                 title: t, summary: "Field notes converging on one question.",
                 tags: [store.tags[i].name])
        }
        // `-Screen librarian` renders the REAL ContentView; put it on the canvas
        // so the Librarian FloatingPanel is mounted over the map (the panel's real
        // home). `-LibrarianDetent tip|half|full` (handled in ContentView) drives
        // the detent for peek/half/full shots.
        if screen == "librarian" { router.entryMode = .canvas }

        // Chat content for `chatview` (and the Librarian if it surfaces the
        // transcript): a real user turn + a cited assistant answer, so the chat
        // ink / user bubble / sources footer / scroll arrow all render for the
        // light-mode legibility check.
        if screen == "chatview" || screen == "librarian" {
            let cites = [ChatSession.Message.Citation(
                index: 1, nodeID: "seed-0", title: "On the Gerund",
                snippet: "A gerund is a verbal noun formed with -ing.")]
            let msgs: [ChatSession.Message] = [
                .init(role: .user, text: "What's a gerund, and how is it different from a participle?"),
                .init(role: .assistant,
                      text: "A **gerund** is a verb form ending in *-ing* that works as a noun — *writing* is hard. A participle, by contrast, is adjectival or part of a verb tense. [1]",
                      citations: cites),
            ]
            router.chat.load(Chat(id: UUID(), title: "Gerunds",
                                  createdAt: Self.epoch, updatedAt: Self.epoch, messages: msgs))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "settings":         SettingsView()
        case "substrate":        SubstrateInspectView()
        case "import":           ImportIdeasSheet()
        case "reviewqueue":      ReviewQueueSheet()
        case "quarantine":       QuarantineReviewSheet()
        case "collectioncreate": CollectionCreationSheet { _ in }
        case "history":          HistoryPanel(onSelect: { _ in })
        case "editmap":          EditMapSheet()
        case "canvasplaceholder": CanvasPlaceholderView()
        case "tageditor":        TagEditorSheet(existing: store.tags.first)
        case "tagcreate":        TagEditorSheet(existing: nil)   // create-mode of the same editor
        case "rename":           RenameCollectionSheet(collectionID: "seed-col-0", currentName: "Reading")
        case "tagselect":        TagSelectionSheet(selectedTagNames: .constant(["grammar"]))
        case "textcapture":      TextCaptureSheet()
        case "voicecapture":     VoiceCaptureSheet()
        case "camera":           CameraCaptureView()
        case "chatslist":        ChatsListView()
        case "backlink":         BacklinkPickerSheet(sourceNodeID: "seed-0", sourceEntryID: nil)
        case "librarian":        ContentView()   // real app → canvas + Librarian panel
        case "chatview":         NavigationStack { ChatView() }   // real chat transcript
        default:                 Text("unknown -Screen: \(screen)")
        }
    }
}
#endif
