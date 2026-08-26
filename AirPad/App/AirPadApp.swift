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
    @Environment(\.colorScheme) private var colorScheme
    private let router = AppRouter()

    private var node: Node { SpineGateView.node(for: section) }

    var body: some View {
        Group {
            if section == "related" { relatedRepro }
            else if section == "attrs" { attrsRepro }
            else if section == "mewtwo" { mewtwoRepro }
            else if section == "arrange" { arrangeRepro }
            else if section == "trunc" { truncRepro }
            else if section == "typesizes" { typeSizesRepro }
            else if section == "sizematrix" { sizeMatrixRepro }
            else { entriesRepro }
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
            switch section {
            case "related": store.nodes = SpineGateView.relatedSeed()
            case "attrs":
                store.fieldDefinitions = FieldValueSelfTest.fixtureDefinitions()
                store.nodes = [SpineGateView.attrsNode()]
            case "mewtwo":
                // Defs only — `mewtwoRepro` builds its own tile items per variant.
                store.fieldDefinitions = SpineGateView.mewtwoDefs()
            case "arrange":
                store.fieldDefinitions = SpineGateView.mewtwoDefs()
                store.nodes = [SpineGateView.mewtwoNode()]
            case "trunc":
                store.fieldDefinitions = SpineGateView.truncDefs()
            case "typesizes":
                store.fieldDefinitions = SpineGateView.recipeDefs()
            case "sizematrix": break   // self-contained sampler (builds its own defs/values)
            default: store.nodes = [node]
            }
        }
    }

    /// ws-attributes-grid P1 gate — the field grid rendered at three widths so one
    /// screenshot shows the 2-up floor (190) / 3-up / 4-up reflow, over a seeded
    /// node carrying one `.field` of every kind + a few explicit sizes.
    private var attrsRepro: some View {
        // A focused, stacked-only subset so BOTH candidates fit on ONE screen at the
        // ~190 card-back, where the geometry differs. (Full size-variety is in the
        // scrollable gate; this view answers the one geometry taste call.)
        let keep = ["def-measurement", "def-duration", "def-date", "def-location"]
        let fields = (store.nodes.first?.items ?? [])
            .filter { $0.type == .field && keep.contains($0.field?.definitionID ?? "") }
        let nid = store.nodes.first?.id ?? ""
        func labeled(_ title: String, width w: CGFloat, fixed: Bool) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                FieldPairsGrid(nodeID: nid, fieldItems: fields, fixedFourUp: fixed)
                    .frame(width: w, alignment: .leading)
            }
        }
        return VStack(alignment: .leading, spacing: 30) {
            labeled("A · ADAPTIVE — 190pt card-back  (readable, 1-up)", width: 190, fixed: false)
            labeled("B · FIXED 4-UP — 190pt card-back  (2-up, truncates)", width: 190, fixed: true)
            Divider().overlay(AppearancePalette.ink.opacity(0.15))
            labeled("Both at 360pt detail width (they converge → 2-up)", width: 360, fixed: false)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ws-attributes-grid — the MEWTWO bento test (T's ask): the attribute grid shown
    /// IN a card surface, three ways, so "designed vs big-and-blocky" can be judged in
    /// real context — and so the ONE design question the test surfaced is visible:
    ///   A · stats `.stacked` (the RATIFIED per-kind set — `.number` can't go compact) →
    ///       every stat is a full-width 2-wide slab. This is the "blocky" T saw.
    ///   B · stats `.compact` (PROPOSED — extend `.compact` to numeric kinds) at the
    ///       card back → HP as a 2×2 hero + the five stats as small 1×1 tiles, 2-up.
    ///   C · the same PROPOSED arrangement at detail width → opens to 4-up.
    private func mewtwoCard(width w: CGFloat, statSize: AttributeSizeClass) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mewtwo")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Text("PSYCHIC")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            FieldPairsGrid(nodeID: "mewtwo", fieldItems: SpineGateView.mewtwoItems(statSize: statSize))
        }
        .padding(16)
        .frame(width: w, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(AppearancePalette.ink.opacity(0.08)))
    }

    private func mewtwoCaption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
    }

    private var mewtwoRepro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                mewtwoCaption("C · STATS COMPACT — proposed · detail 370")
                mewtwoCard(width: 370, statSize: .compact)
                mewtwoCaption("B · STATS COMPACT — proposed · card back 210")
                mewtwoCard(width: 210, statSize: .compact)
                mewtwoCaption("A · STATS STACKED — as ratified · card back 210")
                mewtwoCard(width: 210, statSize: .stacked)
            }
            .padding(16)
        }
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color(hexString: "1E1E1E") : Color(hexString: "FFFFFA")
    }

    /// ws-attributes-grid P2 — arrange-mode gate. Top: the REAL `CaptureAttributesSection`
    /// so the header's arrange glyph (⊞ by the +) is visible in normal mode. Bottom: the
    /// grid FORCED into arrange mode (isArranging:true) so the arrange styling + per-tile
    /// resize affordance (⤢, on resizable tiles) are visible in a screenshot (taps that
    /// cycle sizes are device-verified, not sim-tappable).
    private var arrangeRepro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if DEBUG
                Text("d:\(ArrangeGestureProbe.shared.drags) c:\(ArrangeGestureProbe.shared.cycles) r:\(ArrangeGestureProbe.shared.reorders) L:\(ArrangeGestureProbe.shared.lifts) m:\(ArrangeGestureProbe.shared.moves)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("arrHUD")
                #endif
                // P4 — ONE-ROW node in arrange: the panel must contain the occupied row PLUS
                // one empty "next page" row of recess cells, with NOTHING drawn outside the
                // rounded background (the phantom row used to bleed onto the sections below).
                mewtwoCaption("P4 — ONE ROW + phantom: 4 recess cells beneath, all inside the panel")
                VStack(alignment: .leading, spacing: 12) {
                    FieldPairsGrid(nodeID: "mewtwo",
                                   fieldItems: SpineGateView.oneRowItems(),
                                   isArranging: true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppearancePalette.ink.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 12))

                mewtwoCaption("ARRANGE — grabber drag = resize · body long-press = reorder · body tap = nothing")
                VStack(alignment: .leading, spacing: 12) {
                    FieldPairsGrid(nodeID: "mewtwo",
                                   fieldItems: SpineGateView.ratingProbeItems(),
                                   isArranging: true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)   // on-screen for the gesture test
                .background(AppearancePalette.ink.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
    }

    /// P4 one-row fixture — two `.stacked` tiles fill row 0 (cols 0-1, 2-3); arrange mode
    /// then reserves the phantom row 1 (four empty recess cells) inside the panel.
    static func oneRowItems() -> [NodeItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func f(_ id: String, _ v: FieldPayload) -> NodeItem {
            var it = NodeItem(id: "mf1-\(id)", type: .field, createdAt: now,
                              field: FieldValue(definitionID: id, value: v))
            it.attributeTile = AttributeTile(sizeClass: .stacked)
            return it
        }
        return [
            f("m-type", .vocabulary(valueIDs: ["psychic"])),
            f("m-atk",  .number(8))
        ]
    }

    /// Defect-2 probe: four tiles all forced to `.stacked` (2 units) — a vocabulary, a
    /// number, a RATING, and a compact number — so at 4-col a screenshot shows whether the
    /// rating fills its 2-unit cell like the others or shrinks to the five-star intrinsic.
    static func ratingProbeItems() -> [NodeItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func f(_ id: String, _ v: FieldPayload, _ size: AttributeSizeClass) -> NodeItem {
            var it = NodeItem(id: "mf-\(id)", type: .field, createdAt: now,
                              field: FieldValue(definitionID: id, value: v))
            it.attributeTile = AttributeTile(sizeClass: size)
            return it
        }
        return [
            f("m-type",   .vocabulary(valueIDs: ["psychic"]), .stacked),   // ~ CUISINE
            f("m-hp",     .number(330), .large),                           // ~ COOK TIME (large)
            f("m-atk",    .number(8), .stacked),                           // ~ SERVES
            f("m-rating", .rating(4), .stacked)                            // ~ RATING
        ]
    }

    /// ws-attributes-grid — TRUNCATION probe: every kind at `.compact` (1u) with a value
    /// long enough to overflow, at a ~190pt card back + a 370pt detail, so truncation can
    /// be judged INTENTIONAL (tail ellipsis / stars degrade-to-fit, never a clipped glyph).
    private var truncRepro: some View {
        func card(_ title: String, width w: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                mewtwoCaption(title)
                FieldPairsGrid(nodeID: "trunc", fieldItems: SpineGateView.truncItems())
                    .padding(12)
                    .frame(width: w, alignment: .leading)
                    .background(AppearancePalette.ink.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 12))
            }
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                mewtwoCaption("3 compact tiles, NO floor/clamp — is the 190pt card back legible as-is?")
                card("CARD BACK ~190pt", width: 190)
                card("PHONE WIDTH ~390pt (T-confirmed legible)", width: 390)
            }
            .padding(16)
        }
    }

    /// VALUE-TYPE-SIZE sampler — the recipe attributes (4 compact tiles + a taste-notes
    /// row) at DETAIL width (~390pt, the real surface T sees) rendered at several type
    /// scales, so T can pick the base value/label size. Card-back is NOT sampled (that
    /// flip surface isn't built yet).
    private var typeSizesRepro: some View {
        let samples: [(String, AttrLabelStyle)] = [
            ("REGULAR · rounded (baked / current)", .regular),
            ("ITALIC · serif (matches the app's titles)", .serifItalic),
            ("ITALIC · sans", .sansItalic)
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mewtwoCaption("14pt + centered. Field-name label: regular vs two ITALIC options (SF Rounded has no italic).")
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 6) {
                        mewtwoCaption(s.0)
                        FieldPairsGrid(nodeID: "recipe",
                                       fieldItems: SpineGateView.recipeItems(),
                                       labelStyle: s.1)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .frame(width: 390, alignment: .leading)
                            .background(AppearancePalette.ink.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(16)
        }
    }

    static func recipeDefs() -> [FieldDefinition] {
        [
            FieldDefinition(id: "r-cuisine", displayName: "Cuisine", kind: .vocabulary,
                            config: FieldConfig(vocabularyValues: [VocabularyValue(id: "des", label: "Dessert")])),
            FieldDefinition(id: "r-cook", displayName: "Cook time", kind: .text),
            FieldDefinition(id: "r-rating", displayName: "Rating", kind: .rating),
            FieldDefinition(id: "r-serves", displayName: "Serves", kind: .number),
            FieldDefinition(id: "r-taste", displayName: "Taste notes", kind: .text)
        ]
    }

    /// Four `.compact` tiles + a full-width taste-notes row — the real recipe layout.
    static func recipeItems() -> [NodeItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func f(_ id: String, _ v: FieldPayload, _ size: AttributeSizeClass?) -> NodeItem {
            var it = NodeItem(id: "rf-\(id)", type: .field, createdAt: now,
                              field: FieldValue(definitionID: id, value: v))
            if let size { it.attributeTile = AttributeTile(sizeClass: size) }
            return it
        }
        return [
            f("r-cuisine", .vocabulary(valueIDs: ["des"]), .compact),
            f("r-cook",    .text("3 hr 30"), .compact),
            f("r-rating",  .rating(4), .compact),
            f("r-serves",  .number(8), .compact),
            f("r-taste",   .text("Citrusy, creamy, bright, fresh & tangy"), nil)   // default → .row
        ]
    }

    // MARK: - `-SPINEGATE sizematrix` — attribute tile SHAPE-MATRIX sampler (DEBUG spike)

    /// SPIKE (shape-matrix): renders EVERY `FieldKind` across the full w∈1…4 × h∈1…4 footprint
    /// matrix (16 shapes) under a PROVISIONAL derived rendering rule (the hypothesis under
    /// test — NOT a ruling) so T can SEE arbitrary shapes before deciding whether the fixed
    /// footprint set {1×1,1×2,1×4,2×2} should exist at all. Fully self-contained + DEBUG-only:
    /// builds its own definitions/values, touches NO production render path, deletes cleanly.
    /// Launch args: `-SMKIND <kind raw>` (default number), `-SMWIDTH detail|card` (default
    /// detail), `-SMLEN short|med|long` (default med).
    @ViewBuilder private var sizeMatrixRepro: some View {
        #if DEBUG
        let kind = FieldKind(rawValue: UserDefaults.standard.string(forKey: "SMKIND") ?? "number") ?? .number
        let isCard = (UserDefaults.standard.string(forKey: "SMWIDTH") ?? "detail") == "card"
        let length = UserDefaults.standard.string(forKey: "SMLEN") ?? "med"
        let columns = isCard ? 2 : 4
        let containerW: CGFloat = isCard ? 190 : 370
        let spacing: CGFloat = 10
        let unitWidth = (containerW - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let unitHeight: CGFloat = 52, rowSpacing: CGFloat = 12, colGap: CGFloat = 10
        // The full 4×4 matrix laid out as a GRID (rows = h, cols = w) at TRUE tile sizes, then
        // UNIFORMLY scaled to fit one screen (box + type scale together, so the empty-space
        // ratio + clipping stay faithful) — one sheet = one screenshot.
        let colW = (1...4).map { w -> CGFloat in let e = min(w, columns); return CGFloat(e) * unitWidth + CGFloat(e - 1) * spacing }
        let rowH = (1...4).map { h -> CGFloat in CGFloat(h) * unitHeight + CGFloat(h - 1) * rowSpacing }
        let gridW = colW.reduce(0, +) + colGap * 3
        let gridH = rowH.reduce(0, +) + rowSpacing * 3
        let scale = min(1, 384 / gridW)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("SHAPE MATRIX · \(kind.rawValue) · \(isCard ? "card 190 (2-up)" : "detail 370 (4-up)") · \(length) · ×\(String(format: "%.2f", scale))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                Text("rule(HYPOTHESIS): h1&w≥3→row · w≥2&h≥2→large(big type) · 2×1→stacked · else→compact. Type FIXED (no height-scale). rows=h, cols=w. w→N badge = card collapse.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(1...4, id: \.self) { h in
                        HStack(alignment: .top, spacing: colGap) {
                            ForEach(1...4, id: \.self) { w in
                                ShapeMatrixCell(kind: kind, w: w, h: h, length: length,
                                                columns: columns, unitWidth: unitWidth, spacing: spacing)
                            }
                        }
                    }
                }
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: gridW * scale, height: gridH * scale, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    /// A realistic definition per kind for the shape-matrix sampler.
    static func matrixDefinition(_ kind: FieldKind) -> FieldDefinition {
        switch kind {
        case .number:        return FieldDefinition(id: "sm", displayName: "Serves", kind: .number, config: FieldConfig())
        case .measurement:   return FieldDefinition(id: "sm", displayName: "Weight", kind: .measurement, config: FieldConfig(dimension: .weight))
        case .duration:      return FieldDefinition(id: "sm", displayName: "Cook time", kind: .duration, config: FieldConfig())
        case .date:          return FieldDefinition(id: "sm", displayName: "Released", kind: .date, config: FieldConfig())
        case .money:         return FieldDefinition(id: "sm", displayName: "Price", kind: .money, config: FieldConfig())
        case .rating:        return FieldDefinition(id: "sm", displayName: "Rating", kind: .rating, config: FieldConfig(ratingScale: 5, ratingStyle: .stars))
        case .location:      return FieldDefinition(id: "sm", displayName: "Origin", kind: .location, config: FieldConfig())
        case .text:          return FieldDefinition(id: "sm", displayName: "Notes", kind: .text, config: FieldConfig())
        case .vocabulary:    return FieldDefinition(id: "sm", displayName: "Cuisine", kind: .vocabulary,
                                config: FieldConfig(vocabularyValues: [VocabularyValue(id: "a", label: "Dessert"), VocabularyValue(id: "b", label: "Thai"),
                                                                       VocabularyValue(id: "c", label: "Korean"), VocabularyValue(id: "d", label: "Japanese"),
                                                                       VocabularyValue(id: "e", label: "Chinese")]))
        case .boolean:       return FieldDefinition(id: "sm", displayName: "Owned", kind: .boolean, config: FieldConfig())
        case .url:           return FieldDefinition(id: "sm", displayName: "Link", kind: .url, config: FieldConfig())
        case .nodeReference: return FieldDefinition(id: "sm", displayName: "Related", kind: .nodeReference, config: FieldConfig())
        }
    }

    /// A realistic value per kind × length (short/med/long) — real content, not lorem.
    static func matrixValue(_ kind: FieldKind, length: String) -> FieldPayload {
        let short = length == "short", long = length == "long"
        switch kind {
        case .number:        return .number(short ? 4 : long ? 1234567890 : 1234)
        case .measurement:   return .measurement(amount: short ? 120 : long ? 123456 : 1250, unit: "g")
        case .duration:      return .duration(seconds: short ? 300 : long ? 356400 : 12600)
        case .date:          return .date(Date(timeIntervalSince1970: 1_700_000_000), hasTime: long)
        case .money:         return .money(amount: short ? 9 : long ? 1234567.89 : 1299.99, currencyCode: "USD")
        case .rating:        return .rating(4)
        case .location:      return .location(name: short ? "Paris" : long ? "Onomichi, Hiroshima Prefecture, Japan" : "San Francisco, CA", latitude: nil, longitude: nil)
        case .text:          return .text(short ? "French"
                                : long ? "Created by a scientist after years of horrific gene-splicing and DNA-engineering experiments, it was designed to be the most powerful of them all."
                                : "Citrusy, creamy, bright, fresh & tangy")
        case .vocabulary:    return .vocabulary(valueIDs: short ? ["a"] : long ? ["a", "b", "c", "d", "e"] : ["a", "b"])
        case .boolean:       return .boolean(true)
        case .url:           return .url(short ? "a.co" : long ? "https://very-long-subdomain.example-store.co.uk/catalog/item?ref=1234" : "example.com/recipes/soup")
        case .nodeReference: return .nodeReference(nodeID: "n1")
        }
    }

    static func matrixNodeTitle(length: String) -> String {
        length == "short" ? "Mewtwo" : length == "long" ? "Mewtwo, the Genetic Pokémon (Kanto No. 150)" : "Mewtwo (Psychic)"
    }
    #endif

    static func truncDefs() -> [FieldDefinition] {
        [
            FieldDefinition(id: "t-cuisine", displayName: "Cuisine", kind: .vocabulary,
                            config: FieldConfig(vocabularyValues: [VocabularyValue(id: "fr", label: "French")])),
            FieldDefinition(id: "t-serves", displayName: "Serves", kind: .number),
            FieldDefinition(id: "t-cook", displayName: "Cook time", kind: .text)
        ]
    }

    /// T's exact three compact tiles (Cuisine "French" / Serves "10" / Cook time "5 hr 40"),
    /// all `.compact` — to eyeball the card back with NO floor/clamp.
    static func truncItems() -> [NodeItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func f(_ id: String, _ v: FieldPayload) -> NodeItem {
            var it = NodeItem(id: "tf-\(id)", type: .field, createdAt: now,
                              field: FieldValue(definitionID: id, value: v))
            it.attributeTile = AttributeTile(sizeClass: .compact)
            return it
        }
        return [
            f("t-cuisine", .vocabulary(valueIDs: ["fr"])),   // French
            f("t-serves",  .number(10)),                     // 10
            f("t-cook",    .text("5 hr 40"))                 // 5 hr 40
        ]
    }

    /// A seeded Mewtwo node (the composed bento) for gates that need it in the store.
    static func mewtwoNode() -> Node {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Node(id: "mewtwo", createdAt: now, updatedAt: now,
                    title: "Mewtwo", summary: "", tags: [],
                    items: mewtwoItems(statSize: .compact), foldIndex: nil)
    }

    /// Mewtwo field definitions (nine `.field`s: six numeric stats, a vocabulary type,
    /// a text category, a text flavor line).
    static func mewtwoDefs() -> [FieldDefinition] {
        [
            FieldDefinition(id: "m-hp", displayName: "HP", kind: .number),
            FieldDefinition(id: "m-atk", displayName: "Attack", kind: .number),
            FieldDefinition(id: "m-def", displayName: "Defense", kind: .number),
            FieldDefinition(id: "m-spa", displayName: "Sp. Atk", kind: .number),
            FieldDefinition(id: "m-spd", displayName: "Sp. Def", kind: .number),
            FieldDefinition(id: "m-spe", displayName: "Speed", kind: .number),
            FieldDefinition(id: "m-type", displayName: "Type", kind: .vocabulary,
                            config: FieldConfig(vocabularyValues: [VocabularyValue(id: "psychic", label: "Psychic")])),
            FieldDefinition(id: "m-cat", displayName: "Category", kind: .text),
            FieldDefinition(id: "m-flavor", displayName: "Flavor", kind: .text),
            FieldDefinition(id: "m-rating", displayName: "Rating", kind: .rating)
        ]
    }

    /// Mewtwo tile items — HP is always the 2×2 hero; the five stats take `statSize`
    /// (the A/B variable); type/category stacked, flavor a full row.
    static func mewtwoItems(statSize: AttributeSizeClass) -> [NodeItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func f(_ id: String, _ v: FieldPayload, _ size: AttributeSizeClass) -> NodeItem {
            var it = NodeItem(id: "mf-\(id)", type: .field, createdAt: now,
                              field: FieldValue(definitionID: id, value: v))
            it.attributeTile = AttributeTile(sizeClass: size)
            return it
        }
        return [
            f("m-hp",  .number(106), .large),
            f("m-atk", .number(110), statSize),
            f("m-def", .number(90),  statSize),
            f("m-spa", .number(154), statSize),
            f("m-spd", .number(90),  statSize),
            f("m-spe", .number(130), statSize),
            f("m-type", .vocabulary(valueIDs: ["psychic"]), .stacked),
            f("m-cat",  .text("Genetic Pokémon"), .stacked),
            // .large text = the growable full-width block (grows to fit all the prose).
            f("m-flavor", .text("Created by a scientist after years of horrific gene-splicing and DNA-engineering experiments, it was designed to be the most powerful Pokémon in the world."), .large),
            // Defect-2 repro: a .stacked rating (matches a real node's default) — check it
            // FILLS its 2-unit cell rather than shrinking to the five-star intrinsic width.
            f("m-rating", .rating(4), .stacked)
        ]
    }

    /// Seed node for `-SPINEGATE attrs`: the field-of-every-kind fixture, with a few
    /// explicit `AttributeTile` sizes to exercise every rendering (compact / row /
    /// large; the rest fall to the kind default — stacked, text → row).
    static func attrsNode() -> Node {
        let defs = FieldValueSelfTest.fixtureDefinitions()
        var node = FieldValueSelfTest.fixtureNode(defs: defs)
        node.items = node.items.map { item in
            var it = item
            switch it.field?.definitionID {
            case "def-rating", "def-boolean": it.attributeTile = AttributeTile(sizeClass: .compact)
            case "def-money":                 it.attributeTile = AttributeTile(sizeClass: .large)
            case "def-number":                it.attributeTile = AttributeTile(sizeClass: .row)
            default: break
            }
            return it
        }
        return node
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

/// One cell of the shape-matrix sampler (`-SPINEGATE sizematrix`): a kind's value rendered
/// under the PROVISIONAL derived treatment at a true w×h box (with the card-back column
/// clamp), FIXED type (no height-scaling), labelled with its "w×h". DEBUG-only survey scaffold
/// — reuses `FieldValueFormatter` + `AttributeTileShell` for fidelity but does NOT touch the
/// production `FieldPairCell` render path, so it deletes cleanly if T rules against the change.
private struct ShapeMatrixCell: View {
    let kind: FieldKind
    let w: Int, h: Int
    let length: String
    let columns: Int
    let unitWidth: CGFloat
    let spacing: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private let unitHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 12

    private enum Treatment { case row, large, stacked, compact }
    /// The hypothesis under test — derived from the ORIGINAL w,h (not the clamped width).
    private var treatment: Treatment {
        if h == 1 && w >= 3 { return .row }
        if w >= 2 && h >= 2 { return .large }
        if w == 2 && h == 1 { return .stacked }
        return .compact
    }
    /// Card-back collapse: `columnMetrics` clamps a tile to the column count, so w=3/4 render
    /// 2-wide at ~190pt — the survey reproduces that so the collapse is visible.
    private var effW: Int { min(w, columns) }
    private var tileW: CGFloat { CGFloat(effW) * unitWidth + CGFloat(effW - 1) * spacing }
    private var tileH: CGFloat { CGFloat(h) * unitHeight + CGFloat(h - 1) * rowSpacing }

    private var def: FieldDefinition { SpineGateView.matrixDefinition(kind) }
    private var text: String? {
        FieldValueFormatter.display(
            FieldValue(definitionID: "sm", value: SpineGateView.matrixValue(kind, length: length)),
            definition: def,
            resolveNodeTitle: { _ in SpineGateView.matrixNodeTitle(length: length) })
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(width: tileW, height: tileH)
            .background(AttributeTileShell.fill(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AttributeTileShell.rim(colorScheme), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text("\(w)×\(h)\(effW != w ? "→\(effW)" : "")")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 2)
                    .background(Color.black.opacity(0.35))
                    .allowsHitTesting(false)
            }
    }

    @ViewBuilder private var content: some View {
        switch treatment {
        case .row:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                value(big: false)
            }.padding(.horizontal, 12)
        case .large:
            VStack(alignment: .center, spacing: 6) { label; value(big: true) }.padding(12)
        case .stacked, .compact:
            VStack(alignment: .center, spacing: 3) { label; value(big: false) }.padding(.horizontal, 10)
        }
    }

    private var label: some View {
        Text(def.displayName.uppercased())
            .font(.system(size: 9, weight: .medium, design: .serif).italic())
            .tracking(0.7).foregroundStyle(AppearancePalette.ink.opacity(0.5))
            .lineLimit(1).minimumScaleFactor(0.75)
    }

    @ViewBuilder private func value(big: Bool) -> some View {
        if kind == .rating {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: i < 4 ? "star.fill" : "star")
                        .font(.system(size: big ? 22 : 14, weight: .medium))
                        .foregroundStyle(i < 4 ? Color(hexString: "FACC15") : AppearancePalette.ink.opacity(0.25))
                }
            }
        } else {
            Text(text ?? "\u{2014}")
                .font(.system(size: big ? 34 : 14, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .lineLimit(treatment == .large ? 2 : 1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
        }
    }
}
#endif
