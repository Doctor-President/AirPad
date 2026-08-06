import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import UIKit
import ImageIO
import ObjectiveC.runtime

/// Full node detail view. Entered via NavigationStack zoom transition from the canvas.
/// All edits auto-save on disappear.
struct NodeDetailView: View {

    let nodeID: String
    /// Backlinks v1 — when set, the view scrolls to this entry on appear. Used
    /// by the entry-level backlink peek so the real detail view opens focused on
    /// the linked entry.
    var focusEntryID: String? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    // MARK: - Capture mode (QuikCapture stage 1)

    /// True when this detail view is the active capture surface (opened from the
    /// Dashboard "+"). Drives the capture chrome + keeps the Librarian ducked.
    private var isCaptureMode: Bool {
        router.isCapturing && router.captureNodeID == nodeID
    }

    /// Whether anything has actually been captured yet (drives the "Done"
    /// control's appearance — it shows once there's something to keep). The
    /// fresh node opens with one empty text item; a non-empty note or any
    /// non-text entry counts.
    private func hasCaptured(_ node: Node) -> Bool {
        node.items.contains { item in
            if item.type == .text {
                return !(item.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    /// "Done" exit: return to the ORIGIN view — wherever capture was summoned
    /// from (Map / List / Grid / Recents / Dashboard). The origin is already the
    /// surface underneath this pushed capture detail (capture never changes
    /// `entryMode`), so `dismiss()` pops back to it — no forced Recents reset.
    /// The node is already persisted; `isCapturing` / `captureNodeID` are cleared
    /// by ContentView's detail-exit handler. Tier 2: hand the new node to the
    /// shared focus request so the origin view focuses the new node on return —
    /// the grid scrolls to its tile, Map flies the camera to its orb, List/Card
    /// scroll to it. The request is set HERE, before `dismiss()` re-reveals the
    /// origin view, so `.onChange` would never fire (value set before mount) —
    /// but the origin's `onFocusRequest` re-checks on `.onAppear`, so it lands.
    private func finishCapture(node: Node) {
        router.requestFocus(node.id)
        router.captureDraftHasText = false
        dismiss()
    }

    // Capture chrome is the SHARED `CaptureChromeBar` (see the `.pinnedCaptureBar`
    // mount in `content`). The detail surface passes NO leading primitives (entries
    // are added via the node's "+" flyout); it gets the same Delete escape hatch +
    // Cancel/Done morph + bottom pinning as QuikCapture, from one component.

    /// Cancel exit: discard the blank node (nothing was captured) and leave
    /// capture mode. The Librarian restores via ContentView on detail-exit.
    private func cancelCapture(nodeID: String) {
        router.isCapturing = false
        router.captureNodeID = nil
        router.captureDraftHasText = false
        dismiss()
        Task { await store.deleteNode(id: nodeID) }
    }

    // ws-display-edit-mode — global Caps-Lock session state (false = Edit,
    // the launch default). Untyped nodes flip this directly; typed nodes use
    // `localModeOverride` instead so their toggle never touches the global.
    @AppStorage("airpad.detail.displayMode.isDisplay") private var globalIsDisplay = false
    /// ws-display-edit-mode — per-view override seat for the typed-node
    /// exception (dormant until a node-level type exists). Nil = follow the
    /// resolved default (global state, or Display for a typed node).
    @State private var localModeOverride: DisplayEditMode? = nil

    // Editable fields (mirrored from node, written back on disappear)
    @State private var editedTitle = ""
    @State private var editedSummary = ""
    @State private var editedTags: [String] = []

    @FocusState private var focusedField: Bool

    // "Add entry" floating "+" state. Stage 3.1a commit (c) replaced the
    // inline bottom composer triad with a single floating Menu button that
    // routes to one of six entry types.
    @State private var captureMode: CaptureMode? = nil
    /// Backlinks v1 — non-nil presents the backlink picker anchored on the
    /// entry whose id it carries (set by an entry's "Backlink" menu action).
    private struct BacklinkSource: Identifiable { let id: String }
    @State private var backlinkSource: BacklinkSource?
    @State private var showPromoteConfirmation = false
    @State private var showingNewTagSheet = false
    @State private var showingNewCollectionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var keyboardVisible = false
    /// The pinned capture bar's MEASURED height (item 1 — drives the capture-mode
    /// bottom reservation so content never sits under the bar).
    @State private var barHeight: CGFloat = 0
    @State private var showLinkAddAlert = false
    @State private var linkDraft = ""
    @State private var showDocumentPicker = false
    @State private var showFieldSheet = false   // Stage 5.2 — "+" → More…

    // THE LEVER — Stage 2. `showLeverTray` presents the proposals sheet.
    // `laneStackHeight` is the MEASURED combined height of the two chip lanes
    // (collections + tags); the feather circle spans exactly that so it never
    // needs a magic number that would drift if chip padding changes. The initial
    // value is only a pre-measurement placeholder — `onPreferenceChange` overrides
    // it on first layout.
    @State private var showLeverTray = false
    @State private var laneStackHeight: CGFloat = 60

    // Stage 2b — shimmer-variant tuner (draggable widget; CardTuning idiom).
    // Presented only on INTERNAL builds (DEBUG + Simulator + TestFlight) via
    // `InternalBuild.showsDevTuners`; state is always declared (unused on the
    // App Store, where the tuner is never shown).
    @State private var showShimmerTuning = false
    @State private var shimmerTuningPos: CGSize = .zero

    /// hero-empty-picker (H1, revised) — drives the file-local
    /// `HeroImagePickerSheet`. Triggered from the `•••` menu's
    /// "Set / Change Hero Image…" item. Always enabled (a node with
    /// zero own-images can still pick from Photos).
    @State private var showHeroPicker = false

    /// #7 (launch list) — when true, the hero banner enters reposition mode:
    /// a drag pans the cover's crop (persisted as `Node.heroCrop`) instead
    /// of scrolling the detail view. Toggled by the `•••` menu's "Reposition
    /// Hero…" item; the banner shows a "Done" affordance to exit.
    @State private var isAdjustingHero = false

    /// Stage 4.6 commit 3 — capture-time modal for the canvas-level
    /// "+ Document" path. When the user picks documents in a node that
    /// already has a `.document` entry, we present a modal asking
    /// whether to append to the most-recently-updated `.document` entry
    /// or create a fresh one. First-document captures skip the modal
    /// entirely (`addDocumentEntry` runs directly). The modal has no
    /// per-session memory of the user's choice — it appears every
    /// capture so each pick is a deliberate decision.
    @State private var pendingDocumentURLs: [URL] = []
    @State private var showDocumentAppendModal = false

    /// Stage 3.1b — owns the entire transient drag-to-reorder UI state.
    /// Injected into entry cards via Environment so each card can read its
    /// own offset/lifted/parting treatment without prop-drilling through
    /// the ForEach. See `EntryReorderController` for the snapshot pattern
    /// rationale (controller-holds-the-snapshot, T 2026-05-16).
    @State private var reorderController = EntryReorderController()

    /// Stage 4.4 — dev-only runtime visual settings. The inter-card
    /// spacing slider drives the nested entry-stack's `spacing:`. Removed
    /// in commit 3 when the dev panel is deleted.
    @State private var visualSettings = EntryVisualSettings.shared

    // MARK: - Scroll-collapsed hero → title band (Twitter-profile-header collapse)
    //
    // Purely scroll-driven, no gesture. Scroll down → the hero blurs out into a
    // pinned nav BAND and the node title hands off into the chrome; scroll up
    // reverses. Reuses the two shipped pieces: the collapse primitive from the
    // chat chrome (`onScrollGeometryChange`-driven offset → a ramped opacity —
    // same shape as LibrarianSurface's `titleCollapseOpacity`) and BUG 24's
    // blurred-hero backdrop. This adds only the coupling + the title hand-off.
    //
    // CONTINUOUS backdrop, DISCRETE title: the backdrop opacity ramps with
    // scroll; the title SWITCHES at a threshold (no both-titles-half state).

    /// Live scroll distance from the top (`visibleRect.minY`), same reader the
    /// chat transcript uses. 0 at scroll-top; grows as content moves up.
    @State private var heroScrollOffset: CGFloat = 0
    /// The hero's own VISIBLE content height, reported up from `heroZone` /
    /// `HeroImageBanner` (gradient → 200; `.fill` → its clamped visible height;
    /// `.fullHeight` → the crisp `contentHeight`, NOT the mirror-inset banner
    /// height). The collapse threshold is RELATIVE to this so it feels identical
    /// on every node whatever the hero's height. 0 until the hero reports.
    @State private var heroVisibleHeight: CGFloat = 0
    /// DISCRETE title state, driven by `bandProgress` with hysteresis so a slow
    /// scroll across the threshold can't flicker the title back and forth.
    @State private var bandTitleShown = false
    /// Round 2 — luminance sampled under the band title (image nodes), reported
    /// by `BandHeroBackdrop`. Gradient nodes derive it from the palette instead
    /// (`representativeLuminance`). Computed ONCE per cover and held (static
    /// backdrop → no re-sample during scroll → no ink flicker). `nil` until the
    /// image samples; the title is hidden until the hero clears, by which point
    /// the hero (long since on screen) has decoded.
    @State private var bandTitleLuminance: Double? = nil
    /// Round 2 — measured width of the RIGHT chrome group (EDIT+••• capsule, or
    /// "Done" in reorder). The band title's trailing inset is derived from this
    /// so it truncates BEFORE the pill whatever the ••• menu's width — not a
    /// magic number. Seeded at the eye+••• capsule's resting width.
    @State private var rightChromeWidth: CGFloat = 96

    // Dials (TASTE — sensible defaults; T dials on device, then baked).
    /// Fraction of the hero's visible height the backdrop ramps over. 1.0 = the
    /// band reaches full as the hero fully clears.
    private let bandCollapseFraction: CGFloat = 1.0
    /// `bandProgress` at which the title discretely swaps into the chrome —
    /// "as the hero clears."
    private let bandTitleSwapPoint: CGFloat = 0.96
    /// Hysteresis below the swap point at which the title swaps back out. The
    /// deadband is the anti-jitter margin around the discrete switch.
    private let bandTitleSwapDeadband: CGFloat = 0.14
    /// The band's chrome-row height below the status bar (houses the title,
    /// aligned with the back button + ••• capsule).
    private let bandContentHeight: CGFloat = 52
    /// Backdrop blur radius (static, GPU-cached — no per-frame re-blur).
    private let bandBackdropBlur: CGFloat = 18
    /// Round 2 — the title's leading inset: clears the back button (16pt outer +
    /// 48pt button) plus a gap. Left-aligned starts here, after the back button.
    private let bandTitleLeadingInset: CGFloat = 72
    /// Round 2 — gap between the title's truncation edge and the right chrome
    /// group (added to the measured `rightChromeWidth` + the 16pt outer inset).
    private let bandChromeTitleGap: CGFloat = 10
    /// Round 2 — luminance > this → dark ink, else light ink (the map-orb /
    /// tag-pill / chat-bubble value; shared via `legibleInk(forLuminance:)`).
    private let bandInkLuminanceThreshold: Double = 0.62
    /// Round 2 — fraction of the hero image width (from the leading edge)
    /// averaged for the ink decision — the region the left-aligned title covers.
    private let bandInkSampleLeftFraction: CGFloat = 0.66

    /// Continuous collapse progress 0…1, RELATIVE to the hero's own visible
    /// height. 0 until the hero reports a height (guards the divide).
    private var bandProgress: CGFloat {
        let denom = heroVisibleHeight * bandCollapseFraction
        guard denom > 1 else { return 0 }
        return min(1, max(0, heroScrollOffset / denom))
    }

    /// In-node capture surfaces. `.text` is intentionally absent: the "+"
    /// menu's Text action now appends an empty entry card inline (see
    /// `store.appendEmptyTextItem`) rather than presenting a sheet. Voice
    /// and Camera stay sheet-based because their capture flows are
    /// genuinely modal (recording session / camera viewfinder), not
    /// append-and-type.
    enum CaptureMode: String, Identifiable {
        case voice, camera
        var id: String { rawValue }
    }

    private var node: Node? {
        store.nodes.first { $0.id == nodeID }
    }

    var body: some View {
        Group {
            if let node {
                content(node: node)
            } else {
                Text("Node not found")
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .onAppear {
            if let node {
                editedTitle   = node.title
                editedSummary = node.summary
                editedTags    = node.tags
            }
            // Stage 3.1a — first-open lazy migration to the entry-primitive
            // schema. No-op once the node's entrySchemaVersion is current.
            Task { await store.ensureEntrySchema(forNodeID: nodeID) }
        }
        .onDisappear {
            saveIfChanged()
        }
        .onChange(of: node?.title) { old, new in
            if editedTitle == (old ?? "") { editedTitle = new ?? "" }
        }
        .onChange(of: node?.summary) { old, new in
            if editedSummary == (old ?? "") { editedSummary = new ?? "" }
        }
        .onChange(of: node?.tags) { old, new in
            if editedTags == (old ?? []) { editedTags = new ?? [] }
        }
        .confirmationDialog(
            "Make it permanent?",
            isPresented: $showPromoteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Promote to true node", role: .destructive) {
                Task { await store.promoteMetaNode(nodeID: nodeID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This makes it a permanent part of your corpus. Can't be undone.")
        }
        .confirmationDialog(
            "Delete this node?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.deleteNode(id: nodeID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the node and all its items. Can't be undone.")
        }
        .sheet(item: $captureMode) { mode in
            switch mode {
            case .voice:  VoiceCaptureSheet(targetNodeID: nodeID)
            case .camera: CameraCaptureView(targetNodeID: nodeID)
            }
        }
        .sheet(item: $backlinkSource) { src in
            BacklinkPickerSheet(sourceNodeID: nodeID, sourceEntryID: src.id)
        }
        .sheet(isPresented: $showingNewTagSheet) {
            TagEditorSheet(existing: nil) { createdName in
                if !editedTags.contains(createdName) {
                    editedTags.append(createdName)
                }
            }
        }
        .sheet(isPresented: $showingNewCollectionSheet) {
            CollectionCreationSheet(onCreate: { newCol in
                Task { await store.addNodes(ids: [nodeID], toCollection: newCol.id) }
                store.markCollectionUsed(newCol.id)
            })
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                guard !urls.isEmpty else { return }
                // Phase 1 rule: append-to-most-recently-updated for
                // documents, with an explicit "New entry" override
                // surfaced via the capture-time modal. First-document
                // captures (no existing `.document` entry) skip the
                // modal and create directly.
                if let n = node, n.items.contains(where: { $0.type == .document }) {
                    pendingDocumentURLs = urls
                    showDocumentAppendModal = true
                } else {
                    Task { await store.addDocumentEntry(nodeID: nodeID, sourceURLs: urls) }
                }
            }
        }
        .sheet(isPresented: $showFieldSheet) {
            FieldCreationSheet(nodeID: nodeID)
        }
        // THE LEVER — Stage 2 (§ C3). Partial-height proposals tray.
        .sheet(isPresented: $showLeverTray) {
            LeverTray(nodeID: nodeID)
        }
        .confirmationDialog(
            "Append to existing Documents entry?",
            isPresented: $showDocumentAppendModal,
            titleVisibility: .visible
        ) {
            Button("Append") {
                let urls = pendingDocumentURLs
                let nodeIDCopy = nodeID
                if let targetID = mostRecentDocumentEntryID() {
                    Task {
                        await store.appendDocumentItems(
                            toEntryID: targetID,
                            nodeID: nodeIDCopy,
                            sourceURLs: urls
                        )
                    }
                } else {
                    // Race fallback: a delete between picker dismiss and
                    // modal action could leave us with no append target.
                    // Fall through to a fresh entry rather than dropping
                    // the user's picked files.
                    Task { await store.addDocumentEntry(nodeID: nodeIDCopy, sourceURLs: urls) }
                }
                pendingDocumentURLs = []
            }
            Button("New entry") {
                let urls = pendingDocumentURLs
                Task { await store.addDocumentEntry(nodeID: nodeID, sourceURLs: urls) }
                pendingDocumentURLs = []
            }
            Button("Cancel", role: .cancel) {
                pendingDocumentURLs = []
            }
        } message: {
            Text("Append these documents to your most recent Documents entry, or create a new entry?")
        }
        .alert("Add link", isPresented: $showLinkAddAlert) {
            TextField("https://example.com", text: $linkDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { saveLink() }
        } message: {
            Text("Paste or type a URL to add it as a link entry.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
        }
    }

    // MARK: - Main content

    private func content(node: Node) -> some View {
        // GeometryReader reads the top safe-area inset so the hero slot
        // can be sized to `200 + topInset` — that's what keeps the title
        // anchored at its original safe-area-relative position while the
        // gradient bleeds all the way up to y=0 of the screen.
        //
        // hero-custom-toolbar-overlay — restructured to a ZStack so the
        // custom top-bar overlay sits in the parent's safe-area zone
        // (lands naturally below the status bar with no manual padding),
        // while the gradient/ScrollView keeps its `.ignoresSafeArea(.top)`
        // independently and the GeometryReader's proxy still reports the
        // real top inset. Previously `.ignoresSafeArea` was applied to
        // the GR itself, which in iOS 26 collapsed `proxy.safeAreaInsets.top`
        // to ~0 — leaving the overlay flush with the status bar.
        GeometryReader { proxy in
        let topInset = proxy.safeAreaInsets.top
        ZStack(alignment: .top) {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(spacing: 0) {
                heroZone(node: node, topInset: topInset, width: proxy.size.width,
                         onVisibleHeight: { heroVisibleHeight = $0 })
                    .measureHeaderBound("hero")
                VStack(alignment: .leading, spacing: 0) {
                // Detail-View outer rhythm — spacing:0 + explicit per-gap padding
                // (gap-before), each default 24 so this is BYTE-IDENTICAL to the
                // old `spacing: 24` until T dials one. The gap-before padding
                // lives ON each member (inside any `if`), so a hidden member
                // drops its gap exactly as VStack did — no double gaps. The
                // always-present (possibly empty) entries VStack keeps its
                // gap-before + Related's, mirroring VStack spacing on BOTH sides
                // of a zero-height member. Tail past Related is fixed 24.
                // Header + entry scaffolding: compute payload/atomic counts
                // FIRST (the header's ATTRIBUTES gate reads `atomicCount`).
                let payloadEntries = Array(node.items.enumerated()).filter { !$1.type.isAtomic }
                let payloadSnapshot = payloadEntries.map { $0.element.id }
                let atomicCount = node.items.count - payloadEntries.count
                // Images inserted inline into a note render inside that note's
                // flowing document; hide them from the standalone list below.
                let inlineImageIDs = Set(
                    node.items.compactMap { $0.type == .text ? $0.content : nil }
                        .flatMap { MarkdownCodec.referencedImageItemIDs(in: $0) }
                )

                // Header region — the SHARED `CaptureHeader` (title . summary . lever
                // + chip lanes . ATTRIBUTES). ONE component + ONE metrics source
                // (`EntryVisualSettings`) with QuikCaptureView, so the rhythm can't
                // drift. Normal viewing gates ATTRIBUTES on atomics; capture always
                // shows it (its "+" is the first-field entry point).
                CaptureHeader(
                    nodeID: nodeID,
                    showSummary: !editedSummary.isEmpty || node.summary.isEmpty,
                    showAttributes: isCaptureMode || atomicCount > 0,
                    onLeverTap: { showLeverTray = true }
                ) {
                    TextField("Title", text: $editedTitle, axis: .vertical)
                        .font(visualSettings.nodeTitle.resolvedFont())
                        .foregroundStyle(AppearancePalette.ink)
                        .tint(AppearancePalette.ink)
                        .focused($focusedField)
                        // Scroll-collapsed band — the in-flow title hands off to the
                        // band title; gated on `!focusedField` so editing never hides
                        // the field under the caret.
                        .opacity(bandTitleShown && !focusedField ? 0 : 1)
                } summary: {
                    TextField("Summary", text: $editedSummary, axis: .vertical)
                        .font(visualSettings.nodeSummary.resolvedFont())
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                        .tint(AppearancePalette.ink)
                        .focused($focusedField)
                } collections: {
                    collectionsRow(node: node)
                } tags: {
                    tagsRow
                } attributes: {
                    CaptureAttributesSection(nodeID: nodeID, showFieldSheet: $showFieldSheet, measured: true)
                }

                VStack(alignment: .leading, spacing: visualSettings.interCardSpacing) {
                    ForEach(payloadEntries, id: \.element.id) { pair in
                        let rawIndex = pair.offset
                        let item = pair.element
                        if inlineImageIDs.contains(item.id) {
                            // Rendered inline in its note; hidden here so it
                            // doesn't also show as a standalone gallery card.
                            EmptyView()
                        } else {
                        // 1pt hairline as a bottom overlay on every row except
                        // the last so the gap between entries reads as a divider
                        // without adding layout height. (The fold-boundary
                        // divider was removed — fold is AUTO by default now; the
                        // per-entry ••• still authors card visibility.)
                        EntryCard(item: item, nodeID: nodeID, index: rawIndex, snapshotIDs: payloadSnapshot,
                                  onBacklink: { backlinkSource = BacklinkSource(id: item.id) })
                            .id(item.id)
                            .overlay(alignment: .bottom) {
                                if rawIndex < node.items.count - 1 {
                                    Rectangle()
                                        .fill(AppearancePalette.ink.opacity(0.08))
                                        .frame(height: 1)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: reorderController.isReorderActive)
                // #4 — ATTRIBUTES→first entry: the shared symmetric gap when the
                // ATTRIBUTES section is present (capture / atomics); normal viewing
                // with no atomics (no section) keeps its `dividerToEntries`. The
                // measure tap sits before the padding so it reports the first card top.
                .measureHeaderBound("firstEntry")
                .padding(.top, (isCaptureMode || atomicCount > 0)
                    ? CaptureHeaderMetrics.attributesToEntries
                    : visualSettings.dividerToEntries)

                // Backlinks v1 — Related Nodes (user channel). Renders nothing
                // when the node has no connections. System-suggestion channel is
                // a later phase.
                RelatedNodesSection(nodeID: nodeID)
                    .padding(.top, visualSettings.entriesToRelated)

                // Meta-node provenance + promotion
                if node.isMeta {
                    MetaNodeBanner(nodeID: nodeID, showPromoteConfirmation: $showPromoteConfirmation)
                        .padding(.top, 24)   // tail past Related — fixed, not dialed
                }

                // Stage 4.7 C3 — Paste Pad wired to per-type routing.
                // The callback dispatches each ClipboardContent kind
                // through its existing capture path: URL → new link
                // entry (Stage 4.5 always-create-new); Image / Video →
                // append to most-recent .imageVideo entry if present,
                // else new gallery entry (Stage 4.2 rule); File →
                // reuse the Stage 4.6 modal (Append / New entry /
                // Cancel) if a .document entry already exists, else
                // direct add; Text → new text entry pre-populated
                // with the pasted content. Multi-item is a no-op
                // pending C4. Empty content can't reach this callback
                // (PastePadView gates the tap on isPrimed).
                //
                // ws-display-edit-mode — Paste Pad is an authoring affordance;
                // it recedes in Display so the node reads as a document.
                if !resolvedMode(node).isDisplay {
                    PastePadView(onPaste: handlePastedContent)
                        .transition(.opacity)
                        .padding(.top, 24)   // tail past Related — fixed, not dialed
                }

                // Trailing spacer so the last entry isn't tucked under the
                // floating "+" button. 80pt clears the 56pt button + 24pt
                // bottom inset with a small breathing margin.
                Spacer(minLength: 80)
                    .padding(.top, 24)   // tail past Related — fixed, not dialed

                // Stage 3.1b — invisible sentinel that introspects up to
                // the enclosing UIScrollView and drives auto-scroll while
                // a reorder card is lifted near the top/bottom edge zones.
                // Lives inside the ScrollView content so its superview
                // chain reaches UIScrollView. 1pt frame so it doesn't
                // perturb layout; `allowsHitTesting(false)` so it never
                // steals touches from cards or the floating "+".
                AutoScrollDriver(
                    isActive: reorderController.isCardLifted,
                    touchWindowY: reorderController.currentTouchWindowY,
                    edgeZone: EntryReorderController.edgeAutoScrollZone,
                    onScrollDelta: { delta in
                        reorderController.setScrollDelta(delta)
                    }
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .padding(.top, 24)   // tail past Related — fixed, not dialed
            }
            .padding(20)
            .dismissKeyboardOnTapOutside()
            }
            // Header parity measurement (DEBUG, `-HeaderMeasure`): rendered boundary
            // frames spanning hero → header → first entry.
            .collectHeaderMeasurements(surface: "Detail")
        }
        .overlay(alignment: .bottomTrailing) {
            // Stage 3.1a commit (c) — floating "+" replaces the inline
            // composer triad. Hidden whenever the keyboard is visible so
            // it doesn't crowd active text input (title, summary, or any
            // RichTextEditor body via accessory toolbar). Stage 3.1b also
            // hides it during reorder mode — no new entries while
            // restructuring.
            // ws-display-edit-mode — the "+" is a pure authoring affordance,
            // hidden in Display so the node reads as a document not a workspace.
            if !keyboardVisible && !reorderController.isReorderActive
                && !resolvedMode(node).isDisplay {
                floatingAddButton
                    .padding(.trailing, 24)
                    // Lift above the persistent Librarian peek pill so the
                    // "+" isn't obscured at peek; same clearance the canvas
                    // capture trigger uses (peek detent + 24pt breathing
                    // room). At medium / large the sheet covers the button
                    // — intentional, mirrors canvas behavior.
                    .padding(.bottom, LibrarianPanelLayout.peekOverlayClearance)
                    .transition(.opacity)
            }
        }
        // Stage 2b — shimmer tuner: a small trigger (top-leading, under the chrome)
        // toggles the draggable variant/duration/replay widget so T picks the
        // shimmer KIND in one pass. Gated on `InternalBuild.showsDevTuners` (DEBUG
        // + Simulator + TestFlight), NOT `#if DEBUG` — TestFlight is Release and T
        // must reach it there. Absent on the App Store. The chosen variant is read
        // in all builds; whatever the panel last wrote is what Release renders.
        .overlay(alignment: .topLeading) {
            if InternalBuild.showsDevTuners {
                Button { showShimmerTuning.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")   // neutral dev-tuner glyph (no sparkle/magic)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.30))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 96)
                .padding(.leading, 12)
            }
        }
        .overlay(alignment: .bottom) {
            if InternalBuild.showsDevTuners && showShimmerTuning {
                ShimmerTuningPanel(isPresented: $showShimmerTuning, position: $shimmerTuningPos)
                    .padding(.bottom, 80)
            }
        }
        // Item 1 — in CAPTURE mode, reserve the pinned bar's MEASURED height so
        // content never sits under it (keyboard DOWN); keyboard UP → a small caret
        // margin (item 2), NOT the bar height (no double-count). Zero when not
        // capturing (no bar), so normal detail viewing is unchanged.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: isCaptureMode
                ? (keyboardVisible ? CaptureChromeMetrics.caretBottomMargin : barHeight)
                : 0)
        }
        // Matched-gray detail surface: same warm tone as the note panel
        // (`NoteTypography.background` — #1A1A1A dark / white light, adaptive),
        // so the raised note panel separates from the ground by light (shadow +
        // rim), not colour. Replaces the fixed near-black #070709.
        .background { AppearancePalette.bgBase.ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
        // Scroll-collapsed band — same reader the chat transcript uses
        // (`visibleRect.minY` = distance scrolled from the top). Drives the
        // continuous backdrop ramp; the discrete title swap keys off it below.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.visibleRect.minY
        } action: { _, offset in
            heroScrollOffset = offset
        }
        // DISCRETE title hand-off with hysteresis: swap IN at the swap point,
        // back OUT only after dropping a full deadband below it, so a slow
        // scroll across the threshold can't flicker the title.
        .onChange(of: bandProgress) { _, p in
            if !bandTitleShown, p >= bandTitleSwapPoint {
                withAnimation(.easeOut(duration: 0.16)) { bandTitleShown = true }
            } else if bandTitleShown, p <= bandTitleSwapPoint - bandTitleSwapDeadband {
                withAnimation(.easeOut(duration: 0.16)) { bandTitleShown = false }
            }
        }
        .onAppear {
            guard let focusEntryID else { return }
            // Defer past first layout so the target entry's anchor exists.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollProxy.scrollTo(focusEntryID, anchor: .top)
                }
            }
        }
        }  // ScrollViewReader

        // Scroll-collapsed hero → title band. Sibling of the ScrollView in the
        // ZStack, z-BELOW the chrome (declared before GlassRowContainer) so the
        // back button + ••• capsule float over it and stay tappable.
        collapsedBand(node: node, topInset: topInset, width: proxy.size.width)

        // hero-custom-toolbar-overlay — sibling of the ScrollView inside
        // the ZStack, not an overlay on it. The ZStack respects the top
        // safe area; only the ScrollView ignores it. So this HStack lands
        // naturally below the status bar via `ZStack(alignment: .top)` —
        // no manual `.padding(.top, topInset)` needed (which collapsed
        // to ~0 inside the previously-ignored GR proxy on iOS 26).
        // Glass styling uses the brief's named `.ultraThinMaterial`
        // fallback rather than the iOS-26 `.glassEffect(in: .circle)`
        // API (compile-availability not verifiable at edit time; flagged
        // for follow-up upgrade).
        // GlassEffectContainer groups multiple glass surfaces so they
        // share lensing — glass-sampling-glass otherwise compounds and
        // looks muddy. Buttons inside opt in via `.glassEffect(...)`.
        // iOS 26 beta wrinkle: `.glassEffect(..., in: .circle)` may
        // mis-render as a capsule or show edge artifacts on some
        // builds; documented fallback is `.buttonStyle(.glass)` with
        // `.buttonBorderShape(.circle).clipShape(Circle())`. Swap if
        // eval shows artifacts.
        GlassRowContainer {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .modifier(InteractiveGlassCircle())
            }
            Spacer()
            // Round 2 (scroll-collapsed band) — measure the RIGHT chrome group's
            // width (both branches: Done + EDIT/••• capsule) so the band title's
            // trailing inset truncates BEFORE it, whatever the ••• menu width.
            Group {
            if reorderController.isReorderActive {
                // Stage 3.1b — Done swaps in while reorder mode is
                // active. Exits the controller cleanly with no
                // commit; the long-press path's release-to-commit
                // path is unchanged.
                Button {
                    reorderController.exit()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .modifier(InteractiveGlassCapsule())
                }
            } else {
                // ws-chrome-pill — EDIT + ••• combined into ONE two-segment
                // interactive-glass capsule, mirroring the Map's ChromeBar
                // (CanvasChrome) so the detail chrome reads consistently. The
                // per-view appearance override (a judging tool) was retired: the
                // detail view now follows the app/system appearance like every
                // other surface (List / Grid / Map have no in-app toggle either).
                HStack(spacing: 0) {
                // ws-display-edit-mode — mode toggle segment. Shows the
                // DESTINATION action: an eye in Edit (tap → Display / read), a
                // pencil in Display (tap → Edit). Hidden during capture (that
                // surface is forced Edit).
                if !isCaptureMode {
                    Button {
                        toggleMode(node)
                    } label: {
                        Image(systemName: resolvedMode(node).isDisplay ? "square.and.pencil" : "eye")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                            .frame(width: 48, height: 48)
                            // ws-glass-effect-hit-region — interactive glass
                            // swallows taps without an explicit content shape.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    Button {} label: {
                        Label("Share / Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(true)

                    // STUB — needs `store.duplicateNode(id:)` (not yet
                    // implemented). Wire once the store method lands.
                    Button {} label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    .disabled(true)
                    Divider()
                    // Priority working set (Dashboard "Priority" row). `flag` =
                    // a follow-up / working-set mark, deliberately NOT a star
                    // (T rejected "Favorites" — it's a working set, not affection).
                    Button {
                        Task { await store.setPriority(node.priority == nil, nodeID: node.id) }
                    } label: {
                        Label(
                            node.priority == nil ? "Add to Priority" : "Remove from Priority",
                            systemImage: node.priority == nil ? "flag" : "flag.slash"
                        )
                    }
                    Divider()
                    // entry-system-and-fold Commit 6 — visibility flag for
                    // the description on the card-view surface (queue #10).
                    // Orthogonal to summarySource: toggling visibility does
                    // not freeze the text. Checkmark when on.
                    Button {
                        var updated = node
                        updated.descriptionOnCard.toggle()
                        updated.updatedAt = Date()
                        Task { await store.updateNode(updated) }
                    } label: {
                        Label(
                            "Show description on card",
                            systemImage: node.descriptionOnCard ? "checkmark" : ""
                        )
                    }
                    // hero-empty-picker (H1, revised) — menu surface for
                    // hero set / change / remove. Always enabled (even a
                    // node with zero own-images can pick from Photos).
                    // Both Set and Change route to the same picker sheet;
                    // it decides which sources to show based on what
                    // exists (Photos always; node images when present).
                    // Remove still clears directly — the store's
                    // `clearCoverImage` now also cleans up library-
                    // sourced cover files (gallery files are guarded
                    // out by the `cover-` prefix rule).
                    if node.coverImageRelativePath == nil {
                        Button {
                            showHeroPicker = true
                        } label: {
                            Label("Set Hero Image…", systemImage: "photo.badge.plus")
                        }
                    } else {
                        Button {
                            // Leaving/replacing the hero: exit reposition mode
                            // so the incoming banner doesn't start in it.
                            isAdjustingHero = false
                            showHeroPicker = true
                        } label: {
                            Label("Change Hero Image…", systemImage: "photo.badge.plus")
                        }
                        // BUG 24 — per-node fit. fullHeight shows the whole image
                        // (detail zone grows; card/grid tiles letterbox). Stored in
                        // `heroCrop.fit` so ALL surfaces honour it and it survives a
                        // future template apply. Sibling of Reposition, same menu.
                        Toggle(isOn: Binding(
                            get: { node.heroCrop?.fit == .fullHeight },
                            set: { on in
                                var c = node.heroCrop ?? HeroCrop()
                                c.fit = on ? .fullHeight : .fill
                                if on { isAdjustingHero = false }   // reposition is meaningless in fullHeight
                                Task { await store.setHeroCrop(c, nodeID: node.id) }
                            }
                        )) {
                            Label("Show Full Height", systemImage: "arrow.up.and.down")
                        }
                        // #7 — enter reposition mode for the current hero. Hidden in
                        // fullHeight: there's no overflow to pan (Watch-for #1).
                        if node.heroCrop?.fit != .fullHeight {
                            Button {
                                isAdjustingHero = true
                            } label: {
                                Label("Reposition Hero…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                        }
                        Button {
                            isAdjustingHero = false
                            Task { await store.clearCoverImage(nodeID: nodeID) }
                        } label: {
                            Label("Remove Hero Image", systemImage: "photo.badge.exclamationmark")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                }  // close ws-chrome-pill HStack
                .modifier(InteractiveGlassCapsule())
            }
            }  // close Round-2 measure Group
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightChromeWidth = $0 }
        }
        .padding(.horizontal, 16)
        } // close GlassRowContainer
        } // close ZStack
        } // close GeometryReader
        // Capture chrome — SHARED `CaptureChromeBar`, applied to the OUTERMOST
        // GeometryReader (the surface that shrinks under the keyboard), so
        // `.pinnedCaptureBar` docks it at the bottom while content still avoids the
        // keyboard (note visible) and the format toolbar keeps riding it. Detail
        // capture has NO leading primitives (entries come from the "+" flyout) —
        // only the Delete + Cancel/Done pills. Present only in capture mode.
        .pinnedCaptureBar(height: $barHeight) {
            if isCaptureMode {
                CaptureChromeBar(
                    hasContent: hasCaptured(node) || router.captureDraftHasText,
                    onDone: { finishCapture(node: node) },
                    onDiscard: { cancelCapture(nodeID: node.id) }
                ) {
                    EmptyView()
                }
            }
        }
        .background {
            // Restores interactive edge-swipe-to-pop killed by
            // `.toolbar(.hidden, for: .navigationBar)`. See SwipeBackProxy.
            SwipeBackProxy()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // hero-custom-toolbar-overlay — iOS 26 Liquid Glass nav-bar
        // background is unremovable via API (`.toolbarBackground(.hidden)`
        // / `.toolbarBackgroundVisibility(.hidden)` / dropping
        // `.toolbarColorScheme(.dark)` all failed; only hiding the whole
        // bar killed the veil). Route A: hide the system bar entirely and
        // render back + `•••` ourselves as a fixed top overlay (see
        // `.overlay(alignment: .top)` on the ScrollView in `content`).
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
        .environment(reorderController)
        // ws-display-edit-mode — the resolved mode propagates down to every
        // EntryCard, which gates its header/timestamp/ellipsis chrome on it.
        .environment(\.displayEditMode, resolvedMode(node))
        // hero-empty-picker (H1, revised) — Photos + node-images picker.
        // Lives on `content`'s chain (not body) because it needs `node`
        // in scope; the body-level sheets operate on state that doesn't
        // depend on a resolved node.
        .sheet(isPresented: $showHeroPicker) {
            HeroImagePickerSheet(node: node, nodeID: nodeID)
        }
    }

    // MARK: - Hero zone

    @ViewBuilder
    private func heroZone(node: Node, topInset: CGFloat, width: CGFloat,
                          onVisibleHeight: @escaping (CGFloat) -> Void) -> some View {
        // Compact banner — top full-bleeds under the status bar (y=0),
        // bottom is a defined edge via rounded corners that match the
        // ~30pt card-family radius. No fade and no mask: the rounded
        // clip reads as an intentional banner instead of a dissolving
        // seam.
        //
        // hero-image v1 — when the node has a chosen cover image,
        // render `HeroImageBanner` (cover-cropped, adaptive height
        // clamped 200…420 + topInset). Otherwise fall back to the
        // morphing gradient at its fixed 200pt visible + topInset
        // height — the title below it lands at its original
        // safe-area-relative position (the parent ScrollView ignores
        // the top safe area).
        if node.coverImageRelativePath == nil {
            let totalHeight: CGFloat = 200 + topInset
            NodeGradientLayer(node: node, circleScale: 1.3, undulation: 1.0)
                .frame(height: totalHeight)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 30,
                        bottomTrailingRadius: 30,
                        style: .continuous
                    )
                )
                // No-hero node → the gradient IS the band backdrop (one
                // treatment, two sources); its visible height is the fixed 200.
                .onAppear { onVisibleHeight(200) }
        } else {
            HeroImageBanner(node: node, heroCrop: node.heroCrop, topInset: topInset,
                            width: width, isAdjusting: $isAdjustingHero,
                            onVisibleHeight: onVisibleHeight)
                // Force a fresh view identity whenever the source path
                // flips so the `.task(id:)` inside actually re-fires.
                // Without this the banner's identity is reused across
                // hero changes and the keyed task — though re-keyed —
                // never restarts (Case A: heroZone re-evals with the
                // new path, but `task fired` never logs).
                .id(node.coverImageRelativePath)
        }
    }

    // MARK: - Scroll-collapsed band

    /// The pinned band the hero collapses into. Backdrop = the hero BLURRED
    /// (image nodes) or a static blurred gradient (no-hero nodes) — one
    /// treatment, two sources; a fixed identity field, position-locked (does
    /// NOT scroll), its opacity ramping continuously with `bandProgress`. The
    /// title switches in discretely (`bandTitleShown`). Full-bleeds to y=0 like
    /// the hero; the title sits in the chrome row below the status bar.
    @ViewBuilder
    private func collapsedBand(node: Node, topInset: CGFloat, width: CGFloat) -> some View {
        let bandHeight = topInset + bandContentHeight
        // VStack + Spacer pins the fixed-height band to y=0 (top) and lets the
        // rest fall away; `ignoresSafeArea(.top)` bleeds the backdrop under the
        // status bar exactly like the hero. The chrome (GlassRowContainer,
        // declared later → z-above) floats over it.
        // Round 2 — ink from the SAMPLED backdrop luminance, NOT appearance
        // mode: the band backdrop is node content (unpredictable brightness), the
        // one place following light/dark mode is wrong. Image nodes sample the
        // blurred hero under the title; gradient nodes reuse the palette rule the
        // map orbs use. ONE rule (`legibleInk` @ 0.62), TWO luminance sources.
        // Computed once and HELD (static backdrop → no re-sample, no flicker).
        let bandLuminance: Double = node.coverImageRelativePath == nil
            ? NodeGradientLayer.representativeLuminance(for: node)
            : (bandTitleLuminance ?? 0.0)   // pre-sample: dark→light ink (transient; title hidden until decode)
        let titleInk = NodeGradientLayer.legibleInk(forLuminance: bandLuminance, threshold: bandInkLuminanceThreshold)
        let titleHalo = NodeGradientLayer.legibleHalo(forLuminance: bandLuminance, threshold: bandInkLuminanceThreshold)
        // Round 2 — trailing inset = 16pt outer chrome inset + MEASURED right
        // group width + gap, so the title truncates BEFORE the pill whatever the
        // ••• menu width, never under it.
        let titleTrailingInset = 16 + rightChromeWidth + bandChromeTitleGap
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                bandBackdrop(node: node, width: width, height: bandHeight)
                // Round 2 — LEFT-ALIGNED single-line title in the chrome row.
                // Starts after the back button (fixed), truncates before the
                // right chrome group (derived). Never two lines (the band must
                // stay a quiet fixed strip); never centred (asymmetric chrome
                // makes "centre" drift with the ••• width).
                Text(node.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(titleInk)
                    .shadow(color: titleHalo, radius: 1.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, bandTitleLeadingInset)
                    .padding(.trailing, titleTrailingInset)
                    .frame(height: bandContentHeight)
                    .padding(.top, topInset)
                    .opacity(bandTitleShown ? 1 : 0)
            }
            .frame(height: bandHeight)
            .clipped()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(bandProgress)                 // CONTINUOUS backdrop ramp
        .allowsHitTesting(false)               // chrome (z-above) keeps its taps
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The band's blurred identity field. Static (no `TimelineView` under the
    /// blur / drawingGroup — see the SwiftUI blur perf rule): the gradient
    /// backdrop is rendered with `animated: false` so it's a still image the
    /// GPU caches once, never a per-frame re-blur during scroll.
    @ViewBuilder
    private func bandBackdrop(node: Node, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let path = node.coverImageRelativePath {
                // The hero image, blurred to fill the band. Re-derived from the
                // source (independent of the hero's fit) so a fullHeight hero's
                // crisp-card + mirror + letterbox composition never leaks in —
                // blur is an identity wash, not a thumbnail.
                BandHeroBackdrop(node: node, coverPath: path, width: width,
                                 height: height, blur: bandBackdropBlur,
                                 sampleLeftFraction: bandInkSampleLeftFraction,
                                 onLuminance: { bandTitleLuminance = $0 })
            } else {
                NodeGradientLayer(node: node, circleScale: 1.3,
                                  undulation: 1.0, animated: false)
                    .frame(width: width, height: height)
                    .clipped()
                    .blur(radius: bandBackdropBlur, opaque: true)
                    .drawingGroup()
            }
        }
    }

    // THE LEVER — Stage 2 button lives in `LeverButton.swift` (Stage 2b extracted
    // it so it can own the shimmer's once-per-visit / viewport-gated @State). It
    // reuses `Node.surfacedProposal` for the pending predicate — the same one the
    // tray uses — so button, shimmer, and tray can't disagree.

    // MARK: - Collections row

    /// Editable membership chips for the node. User collections come from
    /// `node.collectionIDs` (resolved to display names via `store.collections`);
    /// Journal is virtual — present when `node.journalDate != nil`. Corpus
    /// is always-on and not surfaced here. Actions mutate the store
    /// immediately (no `editedTags`-style buffer); the `@Observable` store
    /// re-renders the chips after each call.
    @ViewBuilder
    private func collectionsRow(node: Node) -> some View {
        let membershipIDs = collectionMembershipIDs(node: node)
        let excludeIDs: Set<String> = Set(membershipIDs).union([NodeCollection.corpusID])
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(membershipIDs, id: \.self) { id in
                    CollectionChip(name: collectionDisplayName(for: id)) {
                        removeMembership(id: id)
                    }
                }
                Menu {
                    CollectionPickerMenuContent(
                        collections: store.collections.filter { !$0.isCorpus },
                        collectionLastUsedAt: store.collectionLastUsedAt,
                        excludeIDs: excludeIDs,
                        onPick: { addMembership(collectionID: $0) },
                        onCreateNew: { showingNewCollectionSheet = true }
                    )
                } label: {
                    Label("Add to collection", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppearancePalette.ink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    /// Membership IDs surfaced as chips, ordered by `collectionLastUsedAt`
    /// desc (matches the picker's ordering so the visible set and the
    /// add-menu stay in the same mental model). Skips `_corpus` (virtual,
    /// every node).
    private func collectionMembershipIDs(node: Node) -> [String] {
        var ids: [String] = node.collectionIDs.filter { $0 != NodeCollection.corpusID }
        if node.journalDate != nil {
            ids.append(NodeCollection.journalID)
        }
        return ids.sorted { a, b in
            let aDate = store.collectionLastUsedAt[a] ?? .distantPast
            let bDate = store.collectionLastUsedAt[b] ?? .distantPast
            return aDate > bDate
        }
    }

    private func collectionDisplayName(for id: String) -> String {
        if id == NodeCollection.journalID { return "Journal" }
        return store.collections.first { $0.id == id }?.name ?? id
    }

    private func addMembership(collectionID: String) {
        if collectionID == NodeCollection.journalID {
            // ws-card-catalog Change A — mutateNode so a Journal-membership toggle
            // can't blind-overwrite `.items` with a stale snapshot.
            Task {
                await store.mutateNode(id: nodeID) { n in
                    n.journalDate = Calendar.current.startOfDay(for: Date())
                    n.updatedAt = Date()
                }
            }
        } else {
            Task { await store.addNodes(ids: [nodeID], toCollection: collectionID) }
        }
        store.markCollectionUsed(collectionID)
    }

    private func removeMembership(id: String) {
        if id == NodeCollection.journalID {
            Task {
                await store.mutateNode(id: nodeID) { n in
                    n.journalDate = nil
                    n.updatedAt = Date()
                }
            }
        } else {
            Task { await store.removeNodes(ids: [nodeID], fromCollection: id) }
        }
    }

    // MARK: - Tags row

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(editedTags, id: \.self) { name in
                    TagChip(name: name, store: store) {
                        editedTags.removeAll { $0 == name }
                    }
                }
                // Add from vocabulary (searchable — prevents near-duplicate tags)
                TagPickerButton(
                    tags: store.tags,
                    excludeNames: Set(editedTags),
                    onPickExisting: { name in
                        if !editedTags.contains(name) {
                            editedTags.append(name)
                        }
                    },
                    onAddNew: { showingNewTagSheet = true }
                ) {
                    Label("Add tag", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppearancePalette.ink.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Floating "+" button (Stage 3.1a commit (c))

    /// Single entry point for adding entries. Bottom-right 56×56 white
    /// circle wired to a native SwiftUI `Menu` — the dropdown is the
    /// right grammar inside a detail view, where the canvas / list "+"
    /// instead opens the full in-app capture overlay. Order locked by
    /// brief: Text, Camera, Voice, Link, Document, More... (More... is a
    /// no-op stub seat for 3.1a; the eventual sheet ships when there's
    /// something to put in it).
    private var floatingAddButton: some View {
        Menu {
            Button {
                // Inline append: create an empty text entry, expanded, and
                // mark it for autofocus so the body's editor raises the
                // keyboard on appearance. No sheet — the card itself is
                // the writing surface inside a node.
                Task { await store.appendEmptyTextItem(nodeID: nodeID) }
            } label: {
                Label("Text", systemImage: "pencil")
            }
            Button { captureMode = .camera } label: {
                Label("Camera", systemImage: "camera.fill")
            }
            Button { captureMode = .voice } label: {
                Label("Voice", systemImage: "mic.fill")
            }
            Button {
                linkDraft = ""
                showLinkAddAlert = true
            } label: {
                Label("Link", systemImage: "link")
            }
            Button {
                showDocumentPicker = true
            } label: {
                Label("Document", systemImage: "doc.fill")
            }
            Divider()
            // Stage 5.2 — More… opens the field creation sheet (User-Created /
            // Presets / New Field). Supersedes the Stage 4.8 nested Rating seat:
            // rating is now the "Rating" preset (a rating FIELD in the new
            // stacked-pairs style); existing legacy `.rating` items are untouched
            // (coexistence). `appendRatingItem` stays in the store, now unused by
            // the flyout — left in place, not deleted.
            Button {
                showFieldSheet = true
            } label: {
                Label("More…", systemImage: "ellipsis")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .white.opacity(0.15), radius: 8, y: 2)
        }
    }

    // (Stage 4.8's `hasRating` singleton gate removed in 5.2 — rating is now
    // the "Rating" preset field, added through the creation sheet.)

    // MARK: - Display / Edit mode (ws-display-edit-mode)

    /// Whether this node is a "typed" node (Recipe / Film / Review / Book /
    /// Collectable, from ws-intelligent-link-scraping). Typed nodes open in
    /// Display by default and treat the toggle as a per-node override. No
    /// node-level type exists in the model yet, so this is always false today
    /// — when the type lands, returning true here activates the
    /// Display-default + local-override path below without further wiring.
    private func isTyped(_ node: Node) -> Bool {
        false
    }

    /// The resolved mode driving this detail view. Capture is always Edit (you
    /// can't author into receded chrome); otherwise an explicit per-view
    /// override wins, typed nodes default to Display, and untyped nodes follow
    /// the global Caps-Lock state.
    private func resolvedMode(_ node: Node) -> DisplayEditMode {
        if isCaptureMode { return .edit }
        if let localModeOverride { return localModeOverride }
        if isTyped(node) { return .display }
        return globalIsDisplay ? .display : .edit
    }

    /// Toggle action for the top-chrome control. Untyped nodes flip the global
    /// Caps-Lock state (and clear any stale override); typed nodes set a local
    /// override only, leaving the global untouched.
    private func toggleMode(_ node: Node) {
        let target: DisplayEditMode = resolvedMode(node).isDisplay ? .edit : .display
        withAnimation(.easeInOut(duration: 0.25)) {
            if isTyped(node) {
                localModeOverride = target
            } else {
                globalIsDisplay = target.isDisplay
                localModeOverride = nil
            }
        }
    }

    // MARK: - Document capture helpers

    /// Stage 4.6 commit 3 — resolves the modal's "Append" target. Most-
    /// recently-updated wins by `updatedAt` (falling back to `createdAt`
    /// for entries that haven't been edited since creation). Nil only
    /// when the node has no `.document` entries; the modal would not
    /// have been shown in that case, but the guard handles the race
    /// where a delete lands between picker dismiss and modal action.
    private func mostRecentDocumentEntryID() -> String? {
        node?.items
            .filter { $0.type == .document }
            .max(by: { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) })?
            .id
    }

    // MARK: - Link add

    private func saveLink() {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await store.appendLinkItem(nodeID: nodeID, urlString: trimmed) }
    }

    // MARK: - Paste Pad handlers (Stage 4.7 C3 + C4)

    /// Dispatches a classified clipboard payload through the existing
    /// per-type capture paths. Empty can't reach this callback because
    /// `PastePadView` gates the tap on `isPrimed`.
    private func handlePastedContent(_ content: ClipboardContent) {
        switch content {
        case .url(let url):
            handlePastedURL(url)
        case .image(let image):
            handlePastedImage(image)
        case .video(let url):
            handlePastedVideo(url)
        case .file(let url, let fileType):
            handlePastedFile(url, fileType: fileType)
        case .text(let text):
            handlePastedText(text)
        case .multi(let items):
            handlePastedMulti(items)
        case .empty:
            break
        }
    }

    private func handlePastedURL(_ url: URL) {
        Task { await store.appendLinkItem(nodeID: nodeID, urlString: url.absoluteString) }
    }

    private func handlePastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Route into an existing EMPTY text entry (the auto-populated first note)
        // rather than spawning a duplicate the user would then have to delete.
        // "Empty" = a `.text` entry whose content is blank (whitespace counts as
        // empty; a blank text entry carries no inline-image tokens, so no image
        // either). First empty entry wins; an entry that already has content is
        // never overwritten. Text-only rule — links keep becoming their own entry
        // (handlePastedURL). Both branches enrich: updateTextItem and
        // appendItemToNode each schedule enrichment.
        if let target = node?.items.first(where: {
            $0.type == .text && ($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            let itemID = target.id
            Task { await store.updateTextItem(itemID: itemID, newContent: text, nodeID: nodeID) }
            return
        }
        let now = Date()
        let item = NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: now,
            content: text,
            displayName: nil,
            isExpanded: true,
            updatedAt: now
        )
        // No `pendingAutoFocusItemID` write — the entry already has the
        // pasted content, so we don't raise the keyboard on creation.
        Task { await store.appendItemToNode(nodeID: nodeID, item: item) }
    }

    /// Appends the pasted image to the most-recently-updated `.imageVideo`
    /// entry on this node, or creates a fresh gallery entry when none
    /// exists. Mirrors the Stage 4.2 append-vs-new rule for picker /
    /// camera capture so paste lands in the same gallery the user is
    /// already curating.
    private func handlePastedImage(_ image: UIImage) {
        guard let pending = makePendingImageItem(from: image) else { return }
        let targetNodeID = nodeID
        if let existingID = mostRecentMediaEntryID() {
            Task {
                await store.appendMediaItems(
                    toEntryID: existingID,
                    nodeID: targetNodeID,
                    mediaItems: [pending]
                )
            }
        } else {
            Task {
                await store.addMediaItems(
                    toNodeID: targetNodeID,
                    mediaItems: [pending],
                    description: "",
                    position: .zero
                )
            }
        }
    }

    /// Same shape as `handlePastedImage` but with a security-scoped
    /// copy from the clipboard's file URL into our temp directory
    /// before handing off to `PendingMediaItem` — `persistMediaFiles`
    /// deletes the source URL after save, and clipboard URLs may point
    /// at Files.app-managed storage we must not touch.
    private func handlePastedVideo(_ url: URL) {
        guard let pending = makePendingVideoItem(from: url) else { return }
        let targetNodeID = nodeID
        if let existingID = mostRecentMediaEntryID() {
            Task {
                await store.appendMediaItems(
                    toEntryID: existingID,
                    nodeID: targetNodeID,
                    mediaItems: [pending]
                )
            }
        } else {
            Task {
                await store.addMediaItems(
                    toNodeID: targetNodeID,
                    mediaItems: [pending],
                    description: "",
                    position: .zero
                )
            }
        }
    }

    /// Routes a single pasted file through the Stage 4.6 capture-time
    /// modal: when the node already has a `.document` entry the user
    /// chooses Append / New entry / Cancel; otherwise a fresh entry is
    /// added directly. `addDocumentEntry` handles security-scoped
    /// resource access internally and copies the source into the
    /// corpus, so we pass the clipboard URL straight through.
    private func handlePastedFile(_ url: URL, fileType: String) {
        _ = fileType  // reserved for future per-extension routing
        if let n = node, n.items.contains(where: { $0.type == .document }) {
            pendingDocumentURLs = [url]
            showDocumentAppendModal = true
        } else {
            let targetNodeID = nodeID
            Task { await store.addDocumentEntry(nodeID: targetNodeID, sourceURLs: [url]) }
        }
    }

    /// Stage 4.7 C4 — multi-item batch dispatch. The router guarantees
    /// (a) `.multi` is never nested and (b) `.empty` items are filtered
    /// out before the batch reaches us, so the switch below only sees
    /// concrete single-kind cases. The dispatch deliberately deviates
    /// from "literally iterate and call each per-type handler" so that
    /// per-type batching rules are honored exactly once for the whole
    /// batch:
    ///
    ///   - Images + videos collapse into a SINGLE `PendingMediaItem`
    ///     batch routed through one `appendMediaItems` / `addMediaItems`
    ///     call. That preserves the Stage 4.2 contract that a batched
    ///     capture is ONE gallery entry — looping the C3 single-image
    ///     handler N times would race on `mostRecentMediaEntryID`
    ///     (each tick sees the pre-task state) and could create N
    ///     parallel gallery entries instead of one.
    ///   - Files collapse into a single document destination decision:
    ///     the Stage 4.6 modal is shown ONCE with `pendingDocumentURLs`
    ///     holding the full batch, so the user picks Append / New /
    ///     Cancel for the whole batch (not per file). When no
    ///     `.document` entry exists yet, `addDocumentEntry` runs
    ///     directly with the full URL array.
    ///   - URLs and text entries each remain individual entries (Stage
    ///     4.5 + 3.1 contracts — no link batching, no text batching),
    ///     but they're serialized inside a single `Task` so clipboard
    ///     order is preserved on the node's items list rather than
    ///     racing through N parallel `Task { await store… }` calls.
    ///
    /// Per-type within-batch order = clipboard order. Cross-type order
    /// is media → URLs → text → files (modal). The Stage 4.7 brief
    /// does not pin a cross-type order; this one keeps the modal
    /// pop-up last so the silent dispatches surface before the user
    /// sees a confirmation sheet.
    private func handlePastedMulti(_ items: [ClipboardContent]) {
        var mediaBatch: [CorpusStore.PendingMediaItem] = []
        var urlTargets: [String] = []
        var textBodies: [String] = []
        var fileURLs: [URL] = []

        for item in items {
            switch item {
            case .url(let url):
                urlTargets.append(url.absoluteString)
            case .image(let image):
                if let pending = makePendingImageItem(from: image) {
                    mediaBatch.append(pending)
                }
            case .video(let url):
                if let pending = makePendingVideoItem(from: url) {
                    mediaBatch.append(pending)
                }
            case .file(let url, _):
                fileURLs.append(url)
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { textBodies.append(text) }
            case .multi, .empty:
                // Router contract: `.multi` is never nested, `.empty`
                // is filtered before reaching the batch. These cases
                // are unreachable in practice; the switch must be
                // exhaustive.
                continue
            }
        }

        let targetNodeID = nodeID

        // Media batch → one gallery destination.
        if !mediaBatch.isEmpty {
            let batch = mediaBatch
            if let existingID = mostRecentMediaEntryID() {
                Task {
                    await store.appendMediaItems(
                        toEntryID: existingID,
                        nodeID: targetNodeID,
                        mediaItems: batch
                    )
                }
            } else {
                Task {
                    await store.addMediaItems(
                        toNodeID: targetNodeID,
                        mediaItems: batch,
                        description: "",
                        position: .zero
                    )
                }
            }
        }

        // Links — serialized inside one Task so clipboard order is
        // reflected in the node's items list.
        if !urlTargets.isEmpty {
            let urls = urlTargets
            Task {
                for urlString in urls {
                    await store.appendLinkItem(nodeID: targetNodeID, urlString: urlString)
                }
            }
        }

        // Text — serialized inside one Task for the same ordering
        // reason. Each text body becomes its own `.text` entry.
        if !textBodies.isEmpty {
            let bodies = textBodies
            Task {
                let now = Date()
                for text in bodies {
                    let item = NodeItem(
                        id: UUID().uuidString,
                        type: .text,
                        createdAt: now,
                        content: text,
                        displayName: nil,
                        isExpanded: true,
                        updatedAt: now
                    )
                    await store.appendItemToNode(nodeID: targetNodeID, item: item)
                }
            }
        }

        // Files — single Stage 4.6 modal decision for the whole batch
        // when a `.document` entry already exists; otherwise direct
        // `addDocumentEntry` with the full URL array (Stage 4.6 lets a
        // single entry hold N≥1 documents in one call).
        if !fileURLs.isEmpty {
            if let n = node, n.items.contains(where: { $0.type == .document }) {
                pendingDocumentURLs = fileURLs
                showDocumentAppendModal = true
            } else {
                let urls = fileURLs
                Task { await store.addDocumentEntry(nodeID: targetNodeID, sourceURLs: urls) }
            }
        }
    }

    /// Most-recently-updated `.imageVideo` entry, or nil when the node
    /// has no media gallery yet. Mirrors `mostRecentDocumentEntryID()`
    /// — same fallback ladder (`updatedAt` → `createdAt`).
    private func mostRecentMediaEntryID() -> String? {
        node?.items
            .filter { $0.type == .imageVideo }
            .max(by: { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) })?
            .id
    }

    /// Writes the pasted `UIImage` as PNG into the temp directory and
    /// wraps it in a `PendingMediaItem`. `persistMediaFiles` will copy
    /// the temp file into the corpus and then delete our temp — the
    /// owned-temp pattern keeps the corpus-side delete safe regardless
    /// of what the clipboard pointed at originally.
    private func makePendingImageItem(from image: UIImage) -> CorpusStore.PendingMediaItem? {
        let itemID = UUID().uuidString
        let ext = "png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(itemID).\(ext)")
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: tempURL)
        } catch {
            return nil
        }
        return CorpusStore.PendingMediaItem(
            itemID: itemID,
            mediaType: .image,
            sourceURL: tempURL,
            fileExtension: ext
        )
    }

    /// Copies the clipboard video file into our temp directory under a
    /// fresh UUID so the corpus-side delete in `persistMediaFiles`
    /// targets our temp, never the Files.app-managed original. Wraps
    /// the copy in `startAccessingSecurityScopedResource` for URLs
    /// produced by Files.app pickers / drops.
    private func makePendingVideoItem(from sourceURL: URL) -> CorpusStore.PendingMediaItem? {
        let itemID = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(itemID).\(ext)")
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            return nil
        }
        return CorpusStore.PendingMediaItem(
            itemID: itemID,
            mediaType: .video,
            sourceURL: tempURL,
            fileExtension: ext
        )
    }

    // MARK: - Auto-save

    private func saveIfChanged() {
        guard let node else { return }
        let nodeID = node.id
        let newTitle = editedTitle, newSummary = editedSummary, newTags = editedTags
        // Compare against the FRESHEST node so an unedited close stays a no-op.
        guard let fresh = store.nodes.first(where: { $0.id == nodeID }) else { return }
        let titleChanged = fresh.title != newTitle
        let summaryChanged = fresh.summary != newSummary
        let tagsChanged = fresh.tags != newTags
        guard titleChanged || summaryChanged || tagsChanged else { return }
        // ws-card-catalog Change A — write via mutateNode (fresh read-modify-write)
        // so this title/summary/tags save never blind-overwrites `.items` with a
        // stale snapshot. Source-stamp semantics unchanged:
        //  - title/summary stamp `.user` (Commit 6 / step 1); clearing summary is
        //    a deliberate `.user` state (the change guard already skips no-ops).
        //  - tags carry `.user` provenance; sources for removed tags are dropped.
        Task {
            await store.mutateNode(id: nodeID) { n in
                if titleChanged { n.title = newTitle; n.titleSource = .user }
                if summaryChanged { n.summary = newSummary; n.summarySource = .user }
                if tagsChanged {
                    n.tags = newTags
                    let editedSet = Set(newTags)
                    for name in newTags { n.tagSources[name] = TagOrigin(source: .user) }
                    for name in n.tagSources.keys where !editedSet.contains(name) {
                        n.tagSources.removeValue(forKey: name)
                    }
                }
                n.updatedAt = Date()
            }
        }
    }
}

// MARK: - Collection chip

/// Membership chip for the Collections row in `NodeDetailView`. Mirrors
/// `TagChip`'s sizing/padding so the two rows read as siblings, but uses
/// a `RoundedRectangle` shape and a neutral fill — collections have no
/// per-item color in the model, and the shape change is what tells the
/// user the chips below the title are *memberships* (rounded rects) and
/// the row beneath is *tags* (capsules).
private struct CollectionChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.6))
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppearancePalette.ink.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppearancePalette.ink.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Tag chip

private struct TagChip: View {
    let name: String
    let store: CorpusStore
    let onRemove: () -> Void

    private var color: Color {
        if let tag = store.tags.first(where: { $0.name == name }) {
            return Color(hex: tag.colorHex) ?? .gray
        }
        return .gray
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.3))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Voice waveform player

/// Stage 3.1a commit (b) Phase 2 — `private` dropped so `VoiceEntryBody`
/// (in `Views/Detail/Entry/`) can reference this player. Nested helpers
/// (`WaveformBars`, `AudioPlaybackController`, `CachedPeaks`) remain private
/// since they're only used inside this file.
struct VoiceWaveformPlayer: View {
    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var controller = AudioPlaybackController()
    @State private var peaks: [Float] = []
    @State private var isDragging = false

    private static let barCount = 56
    private static let dragActivationThreshold: CGFloat = 5

    var body: some View {
        HStack(spacing: 12) {
            scrubbableWaveform

            if let duration = item.durationSeconds {
                Text(formatDuration(duration))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(12)
        .background(AppearancePalette.ink.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await load()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var scrubbableWaveform: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                waveformVisual
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    @ViewBuilder
    private var waveformVisual: some View {
        if peaks.isEmpty {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppearancePalette.ink.opacity(0.18))
                .frame(height: 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !controller.isPlaying && !isDragging)) { _ in
                WaveformBars(peaks: peaks, progress: controller.progress)
            }
            .frame(height: 32)
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = abs(value.translation.width) > Self.dragActivationThreshold
                    || abs(value.translation.height) > Self.dragActivationThreshold
                if moved { isDragging = true }
                if isDragging, width > 0 {
                    let p = max(0, min(1, Double(value.location.x / width)))
                    controller.seek(toProgress: p)
                }
            }
            .onEnded { _ in
                if !isDragging {
                    controller.toggle()
                }
                isDragging = false
            }
    }

    private func load() async {
        guard let url = await store.itemFileURL(for: item, nodeID: nodeID) else { return }
        controller.prepare(url: url)
        let computed = await Self.loadOrComputePeaks(audioURL: url, barCount: Self.barCount)
        await MainActor.run { peaks = computed }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Peaks pipeline

    private struct CachedPeaks: Codable {
        let version: Int
        let barCount: Int
        let peaks: [Float]
    }

    private static let peaksFormatVersion = 1

    private static func loadOrComputePeaks(audioURL: URL, barCount: Int) async -> [Float] {
        let peaksURL = audioURL.deletingPathExtension().appendingPathExtension("peaks")

        if let data = try? Data(contentsOf: peaksURL),
           let cached = try? JSONDecoder().decode(CachedPeaks.self, from: data),
           cached.version == peaksFormatVersion,
           cached.barCount == barCount,
           cached.peaks.count == barCount {
            return cached.peaks
        }

        let computed = await computePeaks(audioURL: audioURL, barCount: barCount)
        if computed.count == barCount {
            let cached = CachedPeaks(version: peaksFormatVersion, barCount: barCount, peaks: computed)
            if let data = try? JSONEncoder().encode(cached) {
                try? data.write(to: peaksURL, options: .atomic)
            }
        }
        return computed
    }

    private static func computePeaks(audioURL: URL, barCount: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: audioURL)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                return [Float]()
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            guard let reader = try? AVAssetReader(asset: asset) else { return [Float]() }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)
            guard reader.startReading() else { return [Float]() }

            let durationCMTime = (try? await asset.load(.duration)) ?? .zero
            let durationSeconds = durationCMTime.seconds
            var sampleRate: Double = 44100
            if let formats = try? await track.load(.formatDescriptions), let desc = formats.first {
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    sampleRate = basic.pointee.mSampleRate
                }
            }
            let totalSamples = max(barCount, Int(durationSeconds * sampleRate))
            let samplesPerBar = max(1, totalSamples / barCount)

            var bars = [Float](repeating: 0, count: barCount)
            var barIndex = 0
            var sampleInBar = 0
            var maxInBar: Float = 0

            while reader.status == .reading, barIndex < barCount {
                guard let buffer = output.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { break }

                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: base
                    )
                }
                CMSampleBufferInvalidate(buffer)

                data.withUnsafeBytes { raw in
                    let pcm = raw.bindMemory(to: Int16.self)
                    for s in pcm {
                        let v = Float(abs(Int(s))) / Float(Int16.max)
                        if v > maxInBar { maxInBar = v }
                        sampleInBar += 1
                        if sampleInBar >= samplesPerBar && barIndex < barCount {
                            bars[barIndex] = maxInBar
                            barIndex += 1
                            sampleInBar = 0
                            maxInBar = 0
                        }
                    }
                }
            }
            while barIndex < barCount {
                bars[barIndex] = 0
                barIndex += 1
            }

            let peak = bars.max() ?? 0
            if peak > 0 {
                bars = bars.map { $0 / peak }
            }
            // Floor so quiet segments still show a visible tick.
            return bars.map { max(0.08, $0) }
        }.value
    }
}

// MARK: - Waveform bars

private struct WaveformBars: View {
    let peaks: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let barCount = peaks.count
            let spacing: CGFloat = 2
            let totalSpacing = CGFloat(max(0, barCount - 1)) * spacing
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(max(1, barCount)))
            let height = geo.size.height
            let minBarHeight: CGFloat = 3
            let progressThreshold = progress * Double(barCount)
            let kleinBlue = Color(hexString: "1B59C2")
            let rest = AppearancePalette.ink.opacity(0.30)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = max(minBarHeight, CGFloat(peaks[i]) * height)
                    let played = Double(i) < progressThreshold
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(played ? kleinBlue : rest)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .center)
        }
    }
}

// MARK: - Audio playback controller

@Observable
@MainActor
private final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var url: URL?
    private var pollTimer: Timer?

    var progress: Double {
        duration > 0 ? min(1.0, currentTime / duration) : 0
    }

    func prepare(url: URL) {
        self.url = url
    }

    func toggle() {
        guard let url else { return }
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopPolling()
        PlaybackAudioSession.deactivate()
    }

    /// Seek to a fractional position in [0, 1]. Lazily creates the player if needed
    /// so scrubbing works before the user has ever pressed play. Does not start playback.
    func seek(toProgress progress: Double) {
        guard let url else { return }
        if player == nil {
            guard PlaybackAudioSession.configure() else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            } catch {
                print("[VoicePlayback] Player init for seek failed: \(error)")
                return
            }
        }
        guard let player else { return }
        let clamped = max(0, min(1, progress))
        let target = clamped * player.duration
        player.currentTime = target
        currentTime = target
    }

    private func play(url: URL) {
        guard PlaybackAudioSession.configure() else { return }

        if player == nil {
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            } catch {
                print("[VoicePlayback] Player init failed: \(error)")
                return
            }
        }

        guard let player else { return }
        player.play()
        isPlaying = true
        startPolling()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player?.currentTime = 0
            self.currentTime = 0
            self.isPlaying = false
            self.stopPolling()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error { print("[VoicePlayback] Decode error: \(error)") }
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.stopPolling()
        }
    }
}

// MARK: - Async image from URL

/// Stage 3.1a commit (b) Phase 2 — `private` dropped so `ImageEntryBody`
/// (in `Views/Detail/Entry/`) can reference this helper. Same rationale as
/// `VoiceWaveformPlayer`: extraction moved the only consumer across a file
/// boundary.
struct AsyncImageFromURL: View {
    let url: URL
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppearancePalette.ink.opacity(0.08))
                    .frame(height: 200)
                    .overlay(ProgressView().tint(AppearancePalette.ink))
            }
        }
        .onAppear {
            Task {
                if let data = try? Data(contentsOf: url) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}

// MARK: - Meta-node banner

private struct MetaNodeBanner: View {
    let nodeID: String
    @Binding var showPromoteConfirmation: Bool
    @Environment(CorpusStore.self) private var store

    private var provenanceNodes: [Node] {
        guard let node = store.nodes.first(where: { $0.id == nodeID }),
              let provenance = node.provenance else { return [] }
        return provenance.compactMap { id in store.nodes.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("✦")
                    .foregroundStyle(.purple.opacity(0.8))
                Text("Thread node")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            let sources = provenanceNodes
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected from")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    ForEach(sources) { source in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppearancePalette.ink.opacity(0.2))
                                .frame(width: 5, height: 5)
                            Text(source.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Button {
                showPromoteConfirmation = true
            } label: {
                Text("Promote to true node")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.purple.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .foregroundStyle(Color.purple.opacity(0.4))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// internal (not file-private): shared with `CaptureAttributesSection`.
struct RatingAttributeRow: View {

    let item: NodeItem
    let onTap: () -> Void
    let onDelete: () -> Void

    private var rating: Rating { item.rating ?? Rating(value: 0) }

    var body: some View {
        HStack(spacing: 12) {
            Text(item.type.defaultDisplayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppearancePalette.ink)

            stars
                .accessibilityElement()
                .accessibilityLabel("Rating")
                .accessibilityValue("\(rating.value) of \(rating.scale) stars")

            Spacer(minLength: 12)

            Menu {
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var stars: some View {
        HStack(spacing: 4) {
            ForEach(0..<rating.scale, id: \.self) { idx in
                let filled = idx < rating.value
                Image(systemName: filled ? "star.fill" : "star")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        filled
                            ? Color(hexString: "FACC15")
                            : AppearancePalette.ink.opacity(0.25)
                    )
            }
        }
    }
}

/// Minimal rating editor. Five tappable stars (general: `scale`
/// stars). Tap star n → value = n; re-tap the active star → clear to
/// 0. Explicit "Clear" affordance for discoverability of the cleared
/// state. Persists via `store.setRatingValue` on every tap (no
/// stage / commit on dismiss — the store call is the edit-commit
/// path and clamps to `[0, scale]`). Sheet stays open for re-taps;
/// user dismisses via the drag indicator.
/// internal (not file-private): shared with `CaptureAttributesSection`.
struct RatingEditSheet: View {

    let itemID: String
    let nodeID: String
    let initialValue: Int
    let scale: Int

    @Environment(CorpusStore.self) private var store
    @State private var value: Int

    init(itemID: String, nodeID: String, initialValue: Int, scale: Int) {
        self.itemID = itemID
        self.nodeID = nodeID
        self.initialValue = initialValue
        self.scale = scale
        self._value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Rating")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 28)

            HStack(spacing: 12) {
                ForEach(1...scale, id: \.self) { star in
                    Button {
                        let next = (value == star) ? 0 : star
                        value = next
                        Task { await store.setRatingValue(itemID: itemID, nodeID: nodeID, value: next) }
                    } label: {
                        Image(systemName: star <= value ? "star.fill" : "star")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(
                                star <= value
                                    ? Color(hexString: "FACC15")
                                    : Color(hexString: "FFFFFF").opacity(0.25)
                            )
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                value = 0
                Task { await store.setRatingValue(itemID: itemID, nodeID: nodeID, value: 0) }
            } label: {
                Text("Clear")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(value == 0)
            .opacity(value == 0 ? 0.4 : 1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.027, green: 0.027, blue: 0.039))
    }
}

/// hero-empty-picker (H1, revised) — sheet for setting the node's
/// hero from either the user's Photos library (durable: bytes are
/// copied into the corpus as a `cover-`-prefixed standalone asset)
/// or from the node's own image items (direct reference, same path
/// as the gallery viewer's "Set as Hero").
///
/// Photos picks route through `store.setCoverImageFromTempFile`
/// (which also cleans up the *outgoing* hero when it was a
/// previously-imported library asset). Node-image picks route
/// through `store.setCoverImage(relativePath:nodeID:)`, which now
/// also runs the same outgoing-cleanup so a library→node swap
/// doesn't orphan the old library file.
///
/// We deliberately don't reuse `GalleryItemTile` — that tile is
/// built to be sized externally by its parent (carousel/bento) and
/// it self-fits at intrinsic aspect ratio, which makes it overlap
/// inside a `LazyVGrid`. The picker uses a private square-aspect
/// cell with its own decode pipeline instead.
private struct HeroImagePickerSheet: View {

    let node: Node
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Drives the nested system Photos picker. Single-select,
    /// images-only — the hero is image-only, matching the gallery
    /// viewer's Set-as-Hero video gate.
    @State private var showPhotosPicker = false

    /// Identifiable pairing so SwiftUI's `ForEach` can iterate the
    /// node's image items by stable id while keeping each item's
    /// parent `NodeItem` available for `resolveGalleryItemURL`'s
    /// migration-fallback path (where `GalleryItem.id == parent.id`
    /// after the v1 → 4.2 single-image migration).
    private struct ImagePair: Identifiable {
        let item: GalleryItem
        let parent: NodeItem
        var id: String { item.id }
    }

    private var pairs: [ImagePair] {
        node.items
            .filter { $0.type == .imageVideo }
            .flatMap { entry in
                (entry.mediaItems ?? []).map { ImagePair(item: $0, parent: entry) }
            }
            .filter { $0.item.mediaType == .image }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private var title: String {
        node.coverImageRelativePath == nil ? "Set Hero Image" : "Change Hero Image"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    photosCell
                    ForEach(pairs) { pair in
                        nodeImageCell(pair)
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.027, green: 0.027, blue: 0.039).ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .sheet(isPresented: $showPhotosPicker) {
                MediaPickerWrapper(
                    onPick: { results in
                        Task { await handlePhotosPick(results) }
                    },
                    selectionLimit: 1,
                    filter: .images
                )
            }
        }
    }

    private var photosCell: some View {
        Button {
            showPhotosPicker = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 24, weight: .medium))
                    Text("Photos")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nodeImageCell(_ pair: ImagePair) -> some View {
        let isCurrent = node.coverImageRelativePath == pair.item.file
        HeroPickerCell(galleryItem: pair.item, nodeID: nodeID, parentItem: pair.parent)
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    await store.setCoverImage(relativePath: pair.item.file, nodeID: nodeID)
                }
                dismiss()
            }
    }

    /// Mirrors `GalleryBody.handlePickedMedia` for the image branch:
    /// load `UIImage` from the provider, JPEG-encode at 0.85 to a
    /// temp file (preserving the existing import-quality default),
    /// hand the temp URL to the store, dismiss. The store copies
    /// the bytes into the corpus and removes the temp file.
    private func handlePhotosPick(_ results: [PHPickerResult]) async {
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self),
              let image = await MediaPickerWrapper.loadImage(from: provider),
              let data = image.jpegData(compressionQuality: 0.85) else { return }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try data.write(to: tmpURL)
        } catch {
            print("[HeroImagePickerSheet] temp write error: \(error)")
            return
        }
        await store.setCoverImageFromTempFile(
            sourceURL: tmpURL,
            fileExtension: "jpg",
            nodeID: nodeID
        )
        await MainActor.run { dismiss() }
    }
}

/// hero-empty-picker (H1, revised) — uniform square cell for the
/// picker grid. Does NOT reuse `GalleryItemTile` because that tile
/// self-fits at intrinsic aspect ratio (it's framed externally by
/// its parent in the carousel/bento layouts); inside a `LazyVGrid`
/// it overlaps with neighbors. This cell forces a 1:1 frame with
/// `scaledToFill().clipped()` so every cell is the same square no
/// matter the source aspect.
///
/// Resolution + decode mirror `GalleryFullscreenPage` /
/// `HeroImageBanner`: URL resolve through the store's
/// `resolveGalleryItemURL` (which handles the v1 → 4.2 migration
/// fallback) and a detached-task `Data → UIImage` decode so the
/// main thread doesn't stall on a grid with many items.
private struct HeroPickerCell: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem

    @Environment(CorpusStore.self) private var store

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: galleryItem.id) {
            await resolveAndLoad()
        }
    }

    private func resolveAndLoad() async {
        guard let url = await store.resolveGalleryItemURL(
            galleryItem,
            nodeID: nodeID,
            fallbackParentItem: parentItem
        ) else { return }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard let decoded else { return }
        image = decoded
    }
}

/// Restores interactive edge-swipe-to-pop stripped by
/// `.toolbar(.hidden, for: .navigationBar)`. The delegate is installed
/// ONCE per UINavigationController and retained by it (associated
/// object), so it survives detail pops at any depth. The per-detail
/// proxy is just the trigger that resolves the nav controller and keeps
/// the gesture enabled across pushes. (Prior design set the gesture's
/// weak delegate to each detail's own coordinator; the deepest detail
/// won the single slot, and popping it nil'd the delegate — swipe died
/// after one pop in a stack.)
struct SwipeBackProxy: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class SharedPopDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var nav: UINavigationController?
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }
    }

    final class ProbeView: UIView {
        private var didAttach = false
        private static var delegateKey = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !didAttach else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let nav = findNavigationController() else {
                print("[SwipeBackProxy] could not resolve UINavigationController — swipe-back not restored.")
                return
            }
            installSharedDelegateIfNeeded(on: nav)
            nav.interactivePopGestureRecognizer?.isEnabled = true   // re-enable on every push
            didAttach = true
        }

        /// Install exactly one delegate, retained by the nav controller,
        /// and never overwrite it on subsequent detail mounts.
        private func installSharedDelegateIfNeeded(on nav: UINavigationController) {
            if objc_getAssociatedObject(nav, &Self.delegateKey) is SharedPopDelegate { return }
            let delegate = SharedPopDelegate()
            delegate.nav = nav
            objc_setAssociatedObject(nav, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            nav.interactivePopGestureRecognizer?.delegate = delegate
        }

        private func findNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self.next
            while let r = responder {
                if let nav = r as? UINavigationController { return nav }
                if let vc = r as? UIViewController, let nav = vc.navigationController { return nav }
                responder = r.next
            }
            var vc = window?.rootViewController
            while let current = vc {
                if let nav = current as? UINavigationController { return nav }
                if let nav = current.navigationController { return nav }
                vc = current.presentedViewController ?? current.children.first
            }
            return nil
        }
    }
}

/// Glass-or-material background helpers. Deployment target is iOS 18 but
/// `GlassEffectContainer` / `.glassEffect(_:in:)` are iOS 26+ APIs, so
/// they need availability gates. On iOS 18 we fall back to the prior
/// `.ultraThinMaterial` fill so the buttons still read as frosted
/// circles/capsules (just without the gradient-refracting lensing).
private struct InteractiveGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(Circle().fill(.ultraThinMaterial))
        }
    }
}

private struct InteractiveGlassCapsule: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

private struct GlassRowContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}

// MARK: - HeroImageBanner (hero-image v1)

/// Renders the chosen cover image as the node's hero banner. Replaces
/// the morphing gradient when `node.coverImageRelativePath != nil`.
///
/// **Height:** the visible image height is `clamp(width / aspect, 200, 420)`;
/// the rendered frame adds `topInset` on top so the image full-bleeds
/// under the status bar at y=0, exactly like the gradient banner. Width
/// comes from the parent `GeometryReader` proxy — NOT `UIScreen` — so
/// the math stays correct under split-screen or other reflows.
///
/// **Resolution / decode:** the URL resolve and `Data → UIImage` decode
/// both run off-main (same pattern as `ImageEntryBody` /
/// `GalleryFullscreenPage`); only the final assignment to `@State image`
/// + `@State aspect` hops back to main. Keyed on
/// `node.coverImageRelativePath` so changing the hero mid-view triggers
/// a re-resolve without leaving stale image bytes on screen.
///
/// **Fallback:** while loading OR if the resolve / decode comes back
/// empty (dangling ref after the source image was deleted), we render
/// the `NodeGradientLayer` gradient banner in this view's place — so a
/// stale path degrades gracefully and the user never sees a broken /
/// empty banner. (A cross-fade on image-ready would be a nice-to-have.)
private struct HeroImageBanner: View {

    let node: Node
    /// BUG 24 round 2 — passed as an EXPLICIT value prop (not read off `node`)
    /// so a `heroCrop` change actually invalidates this child. `Node.==` is
    /// id-only (5b2d02d), so binding the banner to `node` alone leaves the
    /// fit/offset stale until the view remounts (the "toggle does nothing until
    /// I leave and come back" symptom). A full `Equatable` + `.equatable()` can't
    /// be used here because the `@Binding` below would compare equal on both
    /// sides and stop reposition mode from updating — so bind to the value
    /// directly instead (the fix shape the brief's second option names).
    let heroCrop: HeroCrop?
    let topInset: CGFloat
    let width: CGFloat
    /// #7 (launch list) — reposition mode. While true, a drag on the banner
    /// pans the crop (see `panGesture`) instead of scrolling the detail view,
    /// and a "Done" affordance is shown. Owned by `NodeDetailView`.
    @Binding var isAdjusting: Bool
    /// Scroll-collapsed band — reports this banner's VISIBLE content height so
    /// the host's collapse threshold is RELATIVE to it. `.fill` → the clamped
    /// visible height; `.fullHeight` → the crisp `contentHeight`, NOT the
    /// mirror-inset banner height (the inset sits behind the chrome, so counting
    /// it would fire the swap late on tall nodes). 200 while loading / on
    /// fallback (matches the gradient placeholder).
    let onVisibleHeight: (CGFloat) -> Void

    @Environment(CorpusStore.self) private var store

    @State private var image: UIImage? = nil
    @State private var aspect: CGFloat? = nil
    /// Detail-View pass — hero visible-height cap, dialed via the dev panel
    /// (default 420 = the prior literal). Gradient fallback keeps its fixed 200.
    @State private var visualSettings = EntryVisualSettings.shared

    /// #7 — live finger translation during a reposition drag (POINTS). Added to
    /// the committed offset (converted from normalized) and reset on release.
    @State private var dragTranslation: CGSize = .zero
    /// #7 — optimistic copy of the committed crop so it doesn't flash back to
    /// the store value for a frame between drag-end and the `@Observable`
    /// round-trip. Fresh identity on hero swap (via `.id`) resets it.
    @State private var localCrop: HeroCrop? = nil

    /// #7 — committed crop in effect right now (optimistic local wins, then the
    /// persisted node value, then centered). `offset` is NORMALIZED — a fraction
    /// of the rendered image, converted to points against the live frame below.
    /// Fit ALWAYS comes from the persisted `heroCrop` prop (the source of truth
    /// the ••• toggle writes); only the OFFSET is optimistic (`localCrop`, set by
    /// a reposition drag). Otherwise a prior drag's `localCrop` (always `.fill`)
    /// would mask a just-toggled `.fullHeight`.
    private var baseCrop: HeroCrop {
        let offset = (localCrop ?? heroCrop ?? HeroCrop()).offset
        return HeroCrop(offset: offset, fit: heroCrop?.fit ?? .fill)
    }

    /// Scroll-collapsed band — the VISIBLE content height for the current mode
    /// (the threshold basis). 200 (the gradient placeholder height) until the
    /// image decodes. Mirrors the height math in `body` exactly.
    private var heroVisibleContentHeight: CGFloat {
        guard let aspect else { return 200 }
        let naturalHeight = width / max(aspect, 0.01)
        switch baseCrop.fit {
        case .fullHeight:
            // The crisp card only — the mirror inset (topInset + 64) is chrome
            // clearance behind the band, deliberately excluded.
            return min(naturalHeight, UIScreen.main.bounds.height * 0.72)
        case .fill:
            return max(200, min(visualSettings.heroMaxHeight, naturalHeight))
        }
    }

    var body: some View {
        Group {
            if let image, let aspect {
                let naturalHeight = width / max(aspect, 0.01)
                if baseCrop.fit == .fullHeight {
                    // BUG 24 round 4 — TRUE top-edge mirror + chrome-clearing inset.
                    // The crisp `scaledToFit` card fills width × its NATURAL height
                    // (aspect-matched → no bars) and is bottom-aligned. Above it sits
                    // an INSET whose height clears the top chrome (48pt back button)
                    // + safe area, so the chrome floats over the MIRROR and the real
                    // card begins BELOW it, unobstructed (finding 2 — one height rule,
                    // no layout fork). The inset is a TRUE reflection of the card's
                    // top EDGE STRIP: the top `mirrorSourceFraction` of the image,
                    // vertically FLIPPED, stretched to fill the inset, blurred — so
                    // the pixel row at the seam matches (yellow continues into yellow,
                    // finding 1), NOT the round-3 whole-image blur that showed the
                    // card's ambient body colour (purple). CAPPED at 0.72× screen; a
                    // very tall image side-letterboxes, and those side bars keep the
                    // ambient blurred fill (the mirror is a TOP-edge treatment). No
                    // reposition (no overflow to pan; ••• hides it). `chromeClearance`
                    // 64 / `mirrorSourceFraction` 0.06 / `0.72` ceiling = proposed dials.
                    let ceiling = UIScreen.main.bounds.height * 0.72
                    let contentHeight = min(naturalHeight, ceiling)
                    let chromeClearance: CGFloat = 64            // 48pt back button + breathing
                    let insetHeight = topInset + chromeClearance
                    let bannerHeight = contentHeight + insetHeight
                    let mirrorSourceFraction: CGFloat = 0.06     // top 6% — the card's border band
                    // ROUND 6 — BOUND THE VERTICAL STRETCH to ≤3×. Round 5 sampled only
                    // the top 6% and stretched it to fill the inset: ~8–10× on a wide
                    // image, which turns the source into a directional vertical STREAK
                    // no isotropic blur can undo (T: "zero blur … vertical streaking").
                    // Sample at least `insetHeight/3` of source so the stretch never
                    // exceeds 3× and the ramp blur can actually soften it.
                    let mirrorSourcePts = max(mirrorSourceFraction * contentHeight, insetHeight / 3)
                    let mirrorStretch = insetHeight / mirrorSourcePts    // ≤ 3
                    let mirrorBlur = max(10, insetHeight * 0.26) // blur scales with inset (finding 1)
                    // ROUND 7 — the blur must reach FULL opacity within the first
                    // `mirrorRampEnd` of the strip above the seam, then HOLD. A plain
                    // .clear→.white ramp (round 5/6) spread it evenly, so the strip was
                    // ~50% sharp at its midpoint and full blur only landed at the very
                    // top of the frame (T's report). A fast ramp also blurs away the
                    // now-recognisable source (round 6's taller sample let T read
                    // "BASIC" reflected) — recognisable is fine if it's gone by the
                    // first fifth. Named so T can dial it. SHIPPED: 0.20.
                    let mirrorRampEnd: CGFloat = 0.20
                    ZStack(alignment: .bottom) {
                        // Ambient blurred fill — only visible in the side bars when a
                        // very tall image is capped; hidden behind the card + mirror
                        // in the common full-width case.
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: bannerHeight)
                            .clipped()
                            .blur(radius: 24, opaque: true)
                        // The crisp, WHOLE card — bottom-aligned, unobstructed.
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: width, height: contentHeight)
                    }
                    .overlay(alignment: .top) {
                        // True top-edge mirror with a RAMPED blur. `strip` = the top
                        // `mirrorSourcePts` of the image, stretched ≤3× (round 6) and
                        // FLIPPED so its bottom row is the image's top edge — a seamless
                        // butt against the card (round 4, matches actual pixel rows). The
                        // SHARP copy sits in the inset; a BLURRED copy fades in via a ramp
                        // that reaches full opacity within `mirrorRampEnd` above the seam,
                        // then holds (round 7). Blur is a STATIC layer (GPU-cached, no
                        // per-frame re-blur → no scroll cost). ★ The blur does NOT bleed
                        // onto the card (round-8 overlap was reverted, T): softening the
                        // image's own top re-obstructs the image this fix exists to reveal.
                        // The residual seam is the 1×↔3× SCALE change, which is left as-is
                        // — the prior-art bar (Music/Spotify/YouTube blurred backdrops
                        // don't hide the boundary either) is already exceeded by matching
                        // pixel rows at the seam.
                        let strip = Image(uiImage: image)
                            .resizable()
                            .frame(width: width, height: contentHeight * mirrorStretch)
                            .frame(width: width, height: insetHeight, alignment: .top)
                            .clipped()
                            .scaleEffect(x: 1, y: -1)
                        ZStack {
                            strip                                     // sharp at the seam
                            strip
                                .blur(radius: mirrorBlur, opaque: true)
                                .mask(
                                    // Full blur by `mirrorRampEnd` above the seam, then hold.
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: .white, location: mirrorRampEnd),
                                            .init(color: .white, location: 1.0)
                                        ],
                                        startPoint: .bottom, endPoint: .top
                                    )
                                )
                        }
                        .frame(width: width, height: insetHeight)
                        .allowsHitTesting(false)
                    }
                    .frame(width: width, height: bannerHeight)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 30,
                            bottomTrailingRadius: 30,
                            style: .continuous
                        )
                    )
                } else {
                    let visibleHeight = max(200, min(visualSettings.heroMaxHeight, naturalHeight))
                    let totalHeight = visibleHeight + topInset
                    // #7 — `scaledToFill` covers width×totalHeight, overflowing on
                    // the longer axis; the crop's NORMALIZED offset (+ the live drag)
                    // shifts which slice shows, clamped to the overflow so an edge
                    // gap can't appear. Shared math with the card / grid tiles
                    // (`HeroCrop.clampedPointOffset`).
                    let offset = HeroCrop.clampedPointOffset(
                        normalizedOffset: baseCrop.offset, imageAspect: aspect,
                        width: width, height: totalHeight, extraTranslation: dragTranslation)
                    Color.clear
                        .frame(width: width, height: totalHeight)
                        .overlay {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .offset(x: offset.x, y: offset.y)
                        }
                        .clipped()
                        .clipShape(
                            UnevenRoundedRectangle(
                                bottomLeadingRadius: 30,
                                bottomTrailingRadius: 30,
                                style: .continuous
                            )
                        )
                        .contentShape(Rectangle())
                        // High-priority so a pan beats the enclosing ScrollView while
                        // adjusting; masked off entirely otherwise so normal scrolling
                        // over the hero is untouched.
                        .highPriorityGesture(
                            panGesture(width: width, height: totalHeight, aspect: aspect),
                            including: isAdjusting ? .all : .none
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if isAdjusting { adjustDoneButton }
                        }
                }
            } else {
                // Loading / resolve-or-decode failure: fall back to the
                // gradient banner at its natural 200 + topInset height.
                let totalHeight: CGFloat = 200 + topInset
                NodeGradientLayer(node: node, circleScale: 1.3, undulation: 1.0)
                    .frame(height: totalHeight)
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 30,
                            bottomTrailingRadius: 30,
                            style: .continuous
                        )
                    )
            }
        }
        // Scroll-collapsed band — report the visible content height (and keep it
        // current as the image decodes or the fit toggles). `initial: true` fires
        // the 200 placeholder immediately so the host has a threshold before the
        // decode lands.
        .onChange(of: heroVisibleContentHeight, initial: true) { _, h in
            onVisibleHeight(h)
        }
        .task(id: node.coverImageRelativePath) {
            // Drop stale bytes the moment the source path changes so the
            // fallback gradient bridges the gap instead of the previous
            // image lingering during the new resolve.
            image = nil
            aspect = nil
            guard node.coverImageRelativePath != nil,
                  let url = await store.coverImageURL(for: node) else { return }
            // PERF FIX 1B — downsample at decode time via ImageIO instead
            // of `UIImage(data:)`, which held the full original bitmap and
            // forced a main-thread resample on every composite (one of the
            // two `argb32_image_mark` sources in the CA-commit hot stack).
            // `kCGImageSourceThumbnailMaxPixelSize` is the banner's max
            // display pixel size (capped by the wider of `width` or the
            // 420pt visibleHeight clamp, × screen scale). The image lands
            // already at display resolution so the downstream
            // `Image(uiImage:).resizable().scaledToFill().clipShape(...)`
            // composites without resampling. Decode stays off the main
            // thread; the placeholder gradient bridges the gap.
            let scale = UIScreen.main.scale
            let maxPixel = Int(max(width, visualSettings.heroMaxHeight) * scale)
            let decoded: (UIImage, CGFloat)? = await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                      cg.height > 0 else { return nil }
                let img = UIImage(cgImage: cg, scale: scale, orientation: .up)
                let aspect = CGFloat(cg.width) / CGFloat(cg.height)
                return (img, aspect)
            }.value
            guard let decoded else { return }
            image = decoded.0
            aspect = decoded.1
        }
    }

    // MARK: - #7 reposition

    private func panGesture(width: CGFloat, height: CGFloat, aspect: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in dragTranslation = value.translation }
            .onEnded { value in
                // Clamp the committed points, then convert back to a NORMALIZED
                // fraction so the crop survives other frames / aspects. Shared
                // math with the display surfaces (`HeroCrop`).
                let points = HeroCrop.clampedPointOffset(
                    normalizedOffset: baseCrop.offset, imageAspect: aspect,
                    width: width, height: height, extraTranslation: value.translation)
                let crop = HeroCrop(offset: HeroCrop.normalize(
                    pointOffset: points, imageAspect: aspect, width: width, height: height))
                localCrop = crop             // optimistic — no flash on release
                dragTranslation = .zero
                Task { await store.setHeroCrop(crop, nodeID: node.id) }
            }
    }

    private var adjustDoneButton: some View {
        Button { isAdjusting = false } label: {
            Text("Done")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

// MARK: - BandHeroBackdrop (scroll-collapsed band)

/// The blurred hero image behind the scroll-collapsed band — a small, STATIC
/// identity field, position-locked, GPU-cached via `.drawingGroup()` so a
/// scroll never re-blurs it. Re-derives from the source image (independent of
/// the hero's fit), so a `.fullHeight` hero's crisp-card + mirror + letterbox
/// composition never leaks in — blur is a wash, not a thumbnail. Decodes the
/// same ImageIO-downsample way as `HeroImageBanner`, keyed on the cover path;
/// bridges the decode with the node's static gradient wash so the band is
/// never empty.
private struct BandHeroBackdrop: View {
    let node: Node
    let coverPath: String
    let width: CGFloat
    let height: CGFloat
    let blur: CGFloat
    /// Fraction of the image WIDTH (from the leading edge) to average for the
    /// title-ink luminance — the region the left-aligned title sits over.
    let sampleLeftFraction: CGFloat
    /// Reports the sampled left-region luminance (0…1) ONCE per cover, computed
    /// off-main alongside the decode. Host holds it (the backdrop is static, so
    /// it never re-samples during scroll → no ink flicker).
    let onLuminance: (Double) -> Void

    @Environment(CorpusStore.self) private var store
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .blur(radius: blur, opaque: true)
                    .drawingGroup()
            } else {
                NodeGradientLayer(node: node, circleScale: 1.3,
                                  undulation: 1.0, animated: false)
                    .frame(width: width, height: height)
                    .clipped()
                    .blur(radius: blur, opaque: true)
                    .drawingGroup()
            }
        }
        .task(id: coverPath) {
            image = nil
            guard let url = await store.coverImageURL(for: node) else { return }
            let scale = UIScreen.main.scale
            // The band is short; downsample to its own pixel box (blurred anyway).
            let maxPixel = Int(max(width, height) * scale)
            let leftFraction = sampleLeftFraction
            let decoded: (UIImage, Double?)? = await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                      cg.height > 0 else { return nil }
                let lum = Self.averageLuminance(of: cg, leftFraction: leftFraction)
                return (UIImage(cgImage: cg, scale: scale, orientation: .up), lum)
            }.value
            guard let decoded else { return }
            image = decoded.0
            if let lum = decoded.1 { onLuminance(lum) }
        }
    }

    /// Average relative luminance of the left `leftFraction` of a CGImage. Draws
    /// the crop into a 1×1 context (hardware-averaged) and reads the pixel — no
    /// per-pixel loop, no second render pass. Rec.709 luma, matching
    /// `NodeGradientLayer.legibleInk`'s coefficients.
    static func averageLuminance(of cg: CGImage, leftFraction: CGFloat) -> Double? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let cropW = max(1, Int((CGFloat(w) * leftFraction).rounded()))
        guard let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: cropW, height: h)) else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

