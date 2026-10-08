import SwiftUI
import UIKit
import ImageIO

/// QuikCapture root surface (AT19.3+). A self-contained copy of the
/// `NodeDetailView` capture presentation, mounted directly as a
/// `ContentView` entry mode (`router.entryMode == .quikCapture`) rather
/// than pushed via the Dashboard NavigationStack. Creates a fresh blank
/// capture node on appear and always shows the four entry-type circles +
/// the state-driven Cancel/Done pill.
///
/// The layout/chrome is a faithful COPY of `NodeDetailView.content(node:)`
/// and its helpers; only shared LEAF components (NodeGradientLayer,
/// EntryCard, PastePadView, the capture sheets, etc.) are reused. The
/// private-to-NodeDetailView helpers this presentation needs
/// (HeroImageBanner, AttributesSection, the chips) are copied
/// in below as file-private structs.
struct QuikCaptureView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router
    /// Brief BF — a fresh capture has no per-entry override, so its title + summary follow
    /// the app-wide Font (the pairing), no longer Fraunces. The dialed SIZE is still read
    /// from `visualSettings`; only the FACE resolves through the registry.
    @Environment(\.appBodyFont) private var appFont
    /// Ghost suggestions (Brief CD) honour Reduce Motion: the glint sweep is dropped; the ghost's
    /// resting dimness carries the signal (the component falls back to a plain appearance).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The capture node's id, created on appear. Nil until
    /// `createCaptureNode()` returns.
    @State private var nodeID: String? = nil

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

    // MARK: - Editable fields (mirrored from node, written back on disappear)

    @State private var editedTitle = ""
    @State private var editedSummary = ""
    @State private var editedTags: [String] = []

    /// Brief CD (no-overwrite rule) — did the USER actually edit this field in this session?
    /// The save commits a field ONLY when its flag is true. An empty, never-edited mirror must
    /// never overwrite a value the model promoted at Done (the teardown race blanked the title);
    /// an edited-to-empty field DOES commit, so a user-cleared field stays cleared. Set only on a
    /// change WHILE the field holds focus, so the programmatic node→mirror syncs below don't trip it.
    @State private var titleEdited = false
    @State private var summaryEdited = false

    /// Which header field holds the keyboard. Per-field (the shared `CaptureHeaderFocus`) so a ghost
    /// clears for the field you TAP and stays for the one you don't (Brief CD rule 3).
    @FocusState private var focusedField: CaptureHeaderFocus?

    /// Ghost shimmer triggers (Brief CD rule 2): bump when a NEW title/summary suggestion lands so the
    /// ghost plays the lever's specular glint ONCE — never on a plain re-render/scroll/focus toggle.
    @State private var titleShimmer = 0
    @State private var summaryShimmer = 0
    /// Ghost opacity (Brief CD1 look option). Shipped default = 45%; T overrides on device review.
    private let ghostOpacity: Double = 0.45

    /// Brief CD4 (BP4) — armed a beat after the FIRST capture opens with an empty title, to show the
    /// one-time ghost tip ("Leave it blank — AirPad names it when you hit Done"). Shows once, ever.
    @State private var titleTipArmed = false

    /// Brief CD5 (BP5) — the AI-refusal note. Shown (non-modal, once per capture) when Apple
    /// Intelligence refused this node's authoring AND the on-device model isn't installed to recover
    /// with (if it were installed, CD5's silent retry would have authored it). `onSetUp` opens Settings.
    @State private var showRefusalSettings = false
    @State private var refusalNoteDismissed = false

    @State private var captureMode: CaptureMode? = nil
    @State private var showingNewTagSheet = false
    @State private var showingNewCollectionSheet = false
    @State private var showLinkAddAlert = false
    @State private var linkDraft = ""
    @State private var showDocumentPicker = false

    /// Capture-time modal for the "+ Document" path. When the user picks
    /// documents in a node that already has a `.document` entry, we present
    /// a modal asking whether to append to the most-recently-updated
    /// `.document` entry or create a fresh one. First-document captures skip
    /// the modal entirely (`addDocumentEntry` runs directly).
    @State private var pendingDocumentURLs: [URL] = []
    @State private var showDocumentAppendModal = false
    /// Shared `CaptureAttributesSection`'s "+" opens the Add-Field sheet (parity with
    /// the detail surface's binding-driven section).
    @State private var showFieldSheet = false

    /// Keyboard visibility (drives the bottom reservation: bar height when down, a
    /// small caret margin when up) and the pinned bar's MEASURED height (item 1 —
    /// the reservation that keeps content clear of the bar).
    @State private var keyboardVisible = false
    @State private var barHeight: CGFloat = 0

    // THE LEVER — Stage 2c. Reuses `LeverButton` + the existing `LeverTray`; the
    // circle spans the MEASURED height of the two chip lanes (same `LaneStackHeightKey`
    // mechanism as the detail view — not duplicated).
    @State private var showLeverTray = false
    @State private var laneStackHeight: CGFloat = 60

    /// Owns the entire transient drag-to-reorder UI state. Injected into
    /// entry cards via Environment so each card can read its own
    /// offset/lifted/parting treatment without prop-drilling through the
    /// ForEach.
    @State private var reorderController = EntryReorderController()

    /// Dev-only runtime visual settings. The inter-card spacing slider
    /// drives the nested entry-stack's `spacing:`.
    @State private var visualSettings = EntryVisualSettings.shared

    /// In-node capture surfaces. `.text` is intentionally absent: the note
    /// itself is the text surface. Voice and Camera stay sheet-based because
    /// their capture flows are genuinely modal.
    enum CaptureMode: String, Identifiable {
        case voice, camera
        var id: String { rawValue }
    }

    private var node: Node? {
        guard let nodeID else { return nil }
        return store.nodes.first { $0.id == nodeID }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let node {
                content(node: node)
                    .environment(reorderController)
                    // Brief CD4 (BP4) — the one-time ghost tip, ringing the title field. Shows a beat
                    // after the first capture opens with an empty title; any tap dismisses + marks shown.
                    .overlayPreferenceValue(FirstRunCalloutTargetsKey.self) { anchors in
                        if titleTipArmed, !FirstRunCalloutKey.captureTitle.hasShown {
                            FirstRunCalloutOverlay(key: .captureTitle, targetAnchors: anchors) {
                                FirstRunCalloutKey.captureTitle.markShown()
                                titleTipArmed = false
                            }
                            .id(FirstRunCalloutKey.captureTitle)
                        }
                    }
                    .task {
                        guard !FirstRunCalloutKey.captureTitle.hasShown else { return }
                        try? await Task.sleep(for: .milliseconds(600))
                        // Only if the user hasn't already started titling it (don't coach over typing).
                        if !Task.isCancelled, editedTitle.isEmpty { titleTipArmed = true }
                    }
                    .onAppear {
                        editedTitle   = node.title
                        editedSummary = node.summary
                        editedTags    = node.tags
                        // First-open lazy migration to the entry-primitive
                        // schema. No-op once the node's schema is current.
                        Task { await store.ensureEntrySchema(forNodeID: node.id) }
                    }
                    .onDisappear {
                        saveIfChanged()
                    }
                    .onChange(of: node.title) { old, new in
                        if editedTitle == old { editedTitle = new }
                    }
                    .onChange(of: node.summary) { old, new in
                        if editedSummary == old { editedSummary = new }
                    }
                    .onChange(of: node.tags) { old, new in
                        if editedTags == old { editedTags = new }
                    }
                    // Brief CD (no-overwrite rule) — a change WHILE the field is focused is a real
                    // user edit (typing, dictation, paste into the field). The node→mirror syncs
                    // above run unfocused (promote lands at Done after focus resigns), so they don't
                    // mark the field edited.
                    .onChange(of: editedTitle) { _, _ in if focusedField == .title { titleEdited = true } }
                    .onChange(of: editedSummary) { _, _ in if focusedField == .summary { summaryEdited = true } }
                    .sheet(item: $captureMode) { mode in
                        switch mode {
                        case .voice:  VoiceCaptureSheet(targetNodeID: node.id)
                        case .camera: CameraCaptureView(targetNodeID: node.id)
                        }
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
                            let id = node.id
                            Task { await store.addNodes(ids: [id], toCollection: newCol.id) }
                            store.markCollectionUsed(newCol.id)
                        })
                    }
                    // THE LEVER — Stage 2c. The same proposals tray as the detail view.
                    .sheet(isPresented: $showLeverTray) {
                        LeverTray(nodeID: node.id)
                    }
                    // Shared ATTRIBUTES "+" → Add-Field sheet (same as the detail view).
                    .sheet(isPresented: $showFieldSheet) {
                        FieldCreationSheet(nodeID: node.id)
                    }
                    // Brief CD5 — the refusal note's "Set up the private model" → Settings → Models.
                    .sheet(isPresented: $showRefusalSettings) {
                        SettingsView(initialAnchor: .models)
                    }
                    .sheet(isPresented: $showDocumentPicker) {
                        DocumentPickerView { urls in
                            guard !urls.isEmpty else { return }
                            // Phase 1 rule: append-to-most-recently-updated
                            // for documents, with an explicit "New entry"
                            // override surfaced via the capture-time modal.
                            if node.items.contains(where: { $0.type == .document }) {
                                pendingDocumentURLs = urls
                                showDocumentAppendModal = true
                            } else {
                                let id = node.id
                                Task { await store.addDocumentEntry(nodeID: id, sourceURLs: urls) }
                            }
                        }
                    }
                    .confirmationDialog(
                        "Append to existing Documents entry?",
                        isPresented: $showDocumentAppendModal,
                        titleVisibility: .visible
                    ) {
                        Button("Append") {
                            let urls = pendingDocumentURLs
                            let nodeIDCopy = node.id
                            if let targetID = mostRecentDocumentEntryID() {
                                Task {
                                    await store.appendDocumentItems(
                                        toEntryID: targetID,
                                        nodeID: nodeIDCopy,
                                        sourceURLs: urls
                                    )
                                }
                            } else {
                                // Race fallback: a delete between picker
                                // dismiss and modal action could leave us
                                // with no append target. Fall through to a
                                // fresh entry rather than dropping the files.
                                Task { await store.addDocumentEntry(nodeID: nodeIDCopy, sourceURLs: urls) }
                            }
                            pendingDocumentURLs = []
                        }
                        Button("New entry") {
                            let urls = pendingDocumentURLs
                            let id = node.id
                            Task { await store.addDocumentEntry(nodeID: id, sourceURLs: urls) }
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
            } else {
                AppearancePalette.bgBase.ignoresSafeArea()
            }
        }
        .task {
            #if DEBUG
            // Capture harness (`-Screen quikcapture`): adopt a pre-seeded capture
            // node instead of creating one, so the surface renders headlessly
            // (createCaptureNode() needs iCloud). No-op in the real flow.
            if nodeID == nil, let seeded = router.captureNodeID,
               store.nodes.contains(where: { $0.id == seeded }) {
                nodeID = seeded
                return
            }
            #endif
            if nodeID == nil, let node = await store.createCaptureNode() {
                router.isCapturing = true
                router.captureNodeID = node.id
                router.captureDraftHasText = false
                nodeID = node.id
                #if DEBUG
                // Brief CD acceptance test — `-EntryQuikCapture` auto-focuses the note so an XCUITest's
                // typeText lands DETERMINISTICALLY (createCaptureNode opens "calm" by clearing autofocus;
                // the real user taps the note, which XCUITest can't do reliably). Everything else — the
                // enrichment pipeline, Done, promote, the save — is the real production path.
                if ProcessInfo.processInfo.arguments.contains("-EntryQuikCapture"),
                   let textID = node.items.first(where: { $0.type == .text })?.id {
                    store.pendingAutoFocusItemID = textID
                }
                #endif
            }
        }
    }

    // MARK: - Main content

    private func content(node: Node) -> some View {
        // GeometryReader reads the top safe-area inset so the hero slot
        // can be sized to `200 + topInset` — that's what keeps the title
        // anchored at its original safe-area-relative position while the
        // gradient bleeds all the way up to y=0 of the screen.
        GeometryReader { proxy in
        let topInset = proxy.safeAreaInsets.top
        ZStack(alignment: .top) {
        ScrollView {
            VStack(spacing: 0) {
                heroZone(node: node, topInset: topInset, width: proxy.size.width)
                    .measureHeaderBound("hero")
                VStack(alignment: .leading, spacing: 0) {
                // Header region — the SHARED `CaptureHeader` (title · summary · lever
                // + chip lanes · ATTRIBUTES). ONE component + ONE metrics source
                // (`EntryVisualSettings`) with NodeDetailView, so the rhythm can't
                // drift. `showAttributes: true` — the "+" is the first-field entry
                // point on the capture surface, so it's always shown.
                //
                // Brief CD — QuikCapture is ALWAYS a fresh capture, so it offers ghost configs
                // unconditionally (gated only on the field being empty + a surfaced proposal). The
                // SHARED header renders them, so the detail-view capture path gets the same ghosts.
                let tGhostText = editedTitle.isEmpty ? node.surfacedProposal(kind: .title)?.text : nil
                let sGhostText = editedSummary.isEmpty ? node.surfacedProposal(kind: .summary)?.text : nil
                CaptureHeader(
                    nodeID: node.id,
                    showSummary: !editedSummary.isEmpty || node.summary.isEmpty,
                    showAttributes: true,
                    // rule 6 — the inline ghost plays the lever shimmer for title/summary here, so the
                    // feather must NOT also shimmer for the same offer (no double signal).
                    suppressLeverShimmer: true,
                    titleGhost: tGhostText.map {
                        GhostFieldConfig(text: $0, font: appFont.titleFont(size: visualSettings.nodeTitle.size),
                                         hidden: focusedField == .title, shimmerTrigger: titleShimmer, opacity: ghostOpacity)
                    },
                    summaryGhost: sGhostText.map {
                        GhostFieldConfig(text: $0, font: appFont.font(size: visualSettings.nodeSummary.size),
                                         hidden: focusedField == .summary, shimmerTrigger: summaryShimmer,
                                         opacity: ghostOpacity * 0.85)   // summary sits at 0.75 ink; keep it quieter than the title
                    },
                    onLeverTap: {
                        // SITE 2 (commit-before-fire) — capture is the FIRST surface a new
                        // user hits, where "the AI does nothing" gets formed. Commit the
                        // header (title/summary) AND the note body before presenting: both
                        // bind live but only persist on end-editing, so firing without
                        // dismissing the keyboard would read a stale/empty node. Awaited —
                        // a fire-and-forget save races the tray.
                        focusedField = nil
                        Task {
                            await commitEditsIfChanged()
                            await store.commitPendingItemEdits(forNodeID: node.id)
                            showLeverTray = true
                        }
                    }
                ) {
                    // The gray "Title" placeholder is suppressed while the ghost shows (rule 7 — the
                    // ghost IS the fill, in app-ink); it returns on focus (tap-in) or when there's no
                    // suggestion. The ghost itself is drawn by the shared `CaptureHeader` (one place →
                    // every capture surface gets it); the shimmer trigger bumps on a NEW proposal.
                    TextField(tGhostText != nil && focusedField != .title ? "" : "Title",
                              text: $editedTitle, axis: .vertical)
                        .font(appFont.titleFont(size: visualSettings.nodeTitle.size))
                        .foregroundStyle(AppearancePalette.ink)
                        .tint(AppearancePalette.ink)
                        .focused($focusedField, equals: .title)
                        .accessibilityIdentifier("titleField")
                        .accessibilityValue(editedTitle)   // Brief CD — lets XCUITest read the committed title
                        .onChange(of: node.surfacedProposal(kind: .title)?.text) { _, newValue in
                            if newValue != nil { titleShimmer += 1 }
                        }
                        .firstRunCalloutTarget(FirstRunCalloutTargetID.captureTitleField)   // CD4 — the ghost tip rings this
                } summary: {
                    TextField(sGhostText != nil && focusedField != .summary ? "" : "Summary",
                              text: $editedSummary, axis: .vertical)
                        .font(appFont.font(size: visualSettings.nodeSummary.size))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                        .tint(AppearancePalette.ink)
                        .focused($focusedField, equals: .summary)
                        .accessibilityIdentifier("summaryField")
                        .accessibilityValue(editedSummary)
                        .onChange(of: node.surfacedProposal(kind: .summary)?.text) { _, newValue in
                            if newValue != nil { summaryShimmer += 1 }
                        }
                } collections: {
                    collectionsRow(node: node)
                } tags: {
                    tagsRow
                } attributes: {
                    CaptureAttributesSection(nodeID: node.id, showFieldSheet: $showFieldSheet, measured: true)
                }

                // Brief CD5 (BP5) — Apple Intelligence refused this capture AND no on-device model is
                // installed to recover with. A non-modal one-line note (the SAME LeverRefusalBanner the
                // tray uses), once per capture; "Set up the private model" opens Settings → Models.
                if node.embeddingFailureReason == "guardrail_refused",
                   LocalModelService.shared.state != .ready, !refusalNoteDismissed {
                    LeverRefusalBanner(
                        message: "Apple Intelligence declined to name this one. AirPad's optional private model handles a wider range of subjects.",
                        onSetUp: { showRefusalSettings = true },
                        onDismiss: { withAnimation(.easeInOut(duration: 0.2)) { refusalNoteDismissed = true } }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 8)
                }

                // Items — every entry is rendered as an `EntryCard`. Each
                // card needs its index + a snapshot of sibling IDs so the
                // reorder controller can do its parting math without
                // re-reading the store mid-drag.
                let payloadEntries = Array(node.items.enumerated()).filter { !$1.type.isAtomic }
                let payloadSnapshot = payloadEntries.map { $0.element.id }
                // Images inserted inline into a note render inside that note's
                // flowing document; hide them from the standalone list below.
                let inlineImageIDs = Set(
                    node.items.compactMap { $0.type == .text ? $0.content : nil }
                        .flatMap { MarkdownCodec.referencedImageItemIDs(in: $0) }
                )

                VStack(alignment: .leading, spacing: visualSettings.interCardSpacing) {
                    ForEach(payloadEntries, id: \.element.id) { pair in
                        let rawIndex = pair.offset
                        let item = pair.element
                        if inlineImageIDs.contains(item.id) {
                            // Rendered inline in its note; hidden here so it
                            // doesn't also show as a standalone gallery card.
                            EmptyView()
                        } else {
                        EntryCard(item: item, nodeID: node.id, index: rawIndex, snapshotIDs: payloadSnapshot)
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
                // #4 — ATTRIBUTES→first entry: the symmetric gap (≈ hairline→ATTRIBUTES
                // text, confirmed by measurement). `measureHeaderBound` before the
                // padding so it reports the first card's top for the parity table.
                .measureHeaderBound("firstEntry")
                .padding(.top, CaptureHeaderMetrics.attributesToEntries)

                // Paste Pad wired to per-type routing.
                PastePadView(onPaste: handlePastedContent)
                    .padding(.top, 24)

                // Trailing spacer so the last entry isn't tucked under the
                // capture chrome.
                Spacer(minLength: 80)

                // Invisible sentinel that introspects up to the enclosing
                // UIScrollView and drives auto-scroll while a reorder card
                // is lifted near the top/bottom edge zones.
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
            }
            .padding(20)
            .dismissKeyboardOnTapOutside()
            }
            // Header parity measurement (DEBUG, `-HeaderMeasure`): collect rendered
            // boundary frames spanning hero → header → first entry.
            .collectHeaderMeasurements(surface: "QuikCapture")
        }
        // Item 1 — reserve the pinned bar's MEASURED height so scroll content never
        // sits under it (keyboard DOWN). Keyboard UP → reserve only a small caret
        // margin (item 2), NOT the bar height: content already avoids the keyboard
        // and the bar is behind it, so adding the bar height too would double-count.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardVisible ? CaptureChromeMetrics.caretBottomMargin : barHeight)
        }
        // Matched-gray detail surface: same warm tone as the note panel.
        .background { AppearancePalette.bgBase.ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
        } // close ZStack
        } // close GeometryReader
        // Capture chrome — SHARED `CaptureChromeBar`, applied to the OUTERMOST
        // GeometryReader (NOT the inner ScrollView): the GeometryReader is what
        // shrinks under the keyboard, so `.pinnedCaptureBar` (which ignores the
        // keyboard safe area) must wrap IT to keep the surface full-height and the
        // bar docked at the bottom while the keyboard passes over. The four
        // primitives are QuikCapture-specific and passed as the leading slot.
        .pinnedCaptureBar(height: $barHeight) {
            CaptureChromeBar(
                hasContent: hasCaptured(node) || router.captureDraftHasText,
                onDone: { doneCapture() },
                onDiscard: { cancelCapture() }
            ) {
                // The primitives — and ONLY the primitives — sit inside the muted
                // pill (`.capturePrimitivesContainer`). The action pills stay bare in
                // the shared bar. The detail surface passes nothing here, so it gets
                // no container at all.
                HStack(spacing: CaptureChromeMetrics.primitiveSpacing) {
                    captureTypeButton(symbol: "waveform", label: "Voice") { captureMode = .voice }
                    captureTypeButton(symbol: "camera.fill", label: "Camera") { captureMode = .camera }
                    captureTypeButton(symbol: "doc.fill", label: "Document") { showDocumentPicker = true }
                    captureTypeButton(symbol: "link", label: "Link") {
                        linkDraft = ""
                        showLinkAddAlert = true
                    }
                }
                .capturePrimitivesContainer()
            }
        }
    }

    // MARK: - Capture primitives

    /// A capture-type primitive: a plain glyph inside the shared primitives pill.
    /// Its tap-frame + symbol size DERIVE from `CaptureChromeMetrics.barHeight` (the
    /// one shared height), not an independent value — the frame fills the pill height,
    /// the symbol sits inside with breathing room.
    private func captureTypeButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CaptureChromeMetrics.primitiveGlyphSize, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: CaptureChromeMetrics.primitiveWidth, height: CaptureChromeMetrics.barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Exit

    /// "Done" exit: the node is already persisted; leave capture mode and
    /// route to Recents where the freshly-captured node sits on top.
    private func doneCapture() {
        // ws-card-catalog Change B — flush the live editor BEFORE teardown.
        // The note body only reaches the store on the editor's end-of-editing;
        // Done previously tore the view down before that fired, so a body typed
        // and immediately Done-ed was never persisted. Resigning first responder
        // fires `textViewDidEndEditing` synchronously → `updateTextItem` (via
        // mutateNode) commits the body; then we route.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // Brief BI — Done on a quick capture delegates naming. The flush above committed the
        // body synchronously, so `enrichIfNeeded(.committed)` reads the final content: it
        // PROMOTES a matching proposal from the eager pass (no model call) or generates
        // under the delegate posture. Previously QuikCapture never enriched at Done, so an
        // unnamed capture stayed untitled — the exact set-and-forget gap BI closes.
        if let id = nodeID { Task { await store.enrichIfNeeded(nodeID: id) } }
        router.isCapturing = false
        router.captureNodeID = nil
        router.captureDraftHasText = false
        router.entryMode = .recents
    }

    /// Cancel exit: discard the blank node (nothing was captured) and route
    /// to Recents. QuikCapture is a root screen, so we set entry mode
    /// directly rather than dismissing a pushed detail.
    private func cancelCapture() {
        router.isCapturing = false
        router.captureNodeID = nil
        router.captureDraftHasText = false
        let id = nodeID
        router.entryMode = .recents
        if let id { Task { await store.deleteNode(id: id) } }
    }

    // MARK: - Hero zone

    @ViewBuilder
    private func heroZone(node: Node, topInset: CGFloat, width: CGFloat) -> some View {
        // Compact banner — top full-bleeds under the status bar (y=0),
        // bottom is a defined edge via rounded corners.
        if node.coverImageRelativePath == nil {
            let totalHeight: CGFloat = 200 + topInset
            NodeGradientLayer(node: node, circleScale: 1.3, undulation: 1.0, blobSet: .hero,
                              glassSurface: .entry)
                .frame(height: totalHeight)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: 30,
                        bottomTrailingRadius: 30,
                        style: .continuous
                    )
                )
        } else {
            QuikCaptureHeroImageBanner(node: node, topInset: topInset, width: width)
                .id(node.coverImageRelativePath)
        }
    }

    // MARK: - Collections row

    @ViewBuilder
    private func collectionsRow(node: Node) -> some View {
        let membershipIDs = collectionMembershipIDs(node: node)
        // Brief U — the sample's collections are hidden from EVERY picker centrally
        // in `CollectionPickerMenuContent`, so a user's note can't be filed into one.
        let excludeIDs: Set<String> = Set(membershipIDs).union([NodeCollection.corpusID])
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(membershipIDs, id: \.self) { id in
                    QuikCaptureCollectionChip(name: collectionDisplayName(for: id)) {
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
            guard let id = nodeID else { return }
            // ws-card-catalog Change A — mutateNode so toggling Journal membership
            // can't clobber a concurrent body/title write with a stale snapshot.
            Task {
                await store.mutateNode(id: id) { n in
                    n.journalDate = Calendar.current.startOfDay(for: Date())
                    n.updatedAt = Date()
                }
            }
        } else if let id = nodeID {
            Task { await store.addNodes(ids: [id], toCollection: collectionID) }
        }
        store.markCollectionUsed(collectionID)
    }

    private func removeMembership(id: String) {
        if id == NodeCollection.journalID {
            guard let nid = nodeID else { return }
            Task {
                await store.mutateNode(id: nid) { n in
                    n.journalDate = nil
                    n.updatedAt = Date()
                }
            }
        } else if let nodeID {
            Task { await store.removeNodes(ids: [nodeID], fromCollection: id) }
        }
    }

    // MARK: - Tags row

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(editedTags, id: \.self) { name in
                    QuikCaptureTagChip(name: name, store: store) {
                        editedTags.removeAll { $0 == name }
                    }
                }
                // Add from vocabulary (searchable — prevents near-duplicate tags)
                TagPickerButton(
                    tags: store.tags,
                    excludeNames: Set(editedTags),
                    store: store,
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

    // MARK: - Document capture helpers

    private func mostRecentDocumentEntryID() -> String? {
        node?.items
            .filter { $0.type == .document }
            .max(by: { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) })?
            .id
    }

    // MARK: - Link add

    private func saveLink() {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = nodeID else { return }
        Task { await store.appendLinkItem(nodeID: id, urlString: trimmed) }
    }

    // MARK: - Paste Pad handlers

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
        guard let id = nodeID else { return }
        Task { await store.appendLinkItem(nodeID: id, urlString: url.absoluteString) }
    }

    private func handlePastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = nodeID else { return }
        // #2/#3 — FILL an existing EMPTY note (the capture scaffold) instead of stacking a new note
        // ABOVE it; only create a new note when none is empty. `meaningfulText == nil` is the shared
        // "this note holds nothing" test (so whitespace counts as empty too). Routing through
        // updateTextItem also feeds the enrichment pipeline → the ghost appears on paste.
        if let empty = node?.items.first(where: { $0.type == .text && AIService.meaningfulText($0.content) == nil }) {
            let itemID = empty.id
            Task { await store.updateTextItem(itemID: itemID, newContent: text, nodeID: id) }
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
        Task { await store.appendItemToNode(nodeID: id, item: item) }
    }

    /// Appends the pasted image to the most-recently-updated `.imageVideo`
    /// entry on this node, or creates a fresh gallery entry when none exists.
    private func handlePastedImage(_ image: UIImage) {
        guard let pending = makePendingImageItem(from: image), let targetNodeID = nodeID else { return }
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

    private func handlePastedVideo(_ url: URL) {
        guard let pending = makePendingVideoItem(from: url), let targetNodeID = nodeID else { return }
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

    private func handlePastedFile(_ url: URL, fileType: String) {
        _ = fileType  // reserved for future per-extension routing
        guard let targetNodeID = nodeID else { return }
        if let n = node, n.items.contains(where: { $0.type == .document }) {
            pendingDocumentURLs = [url]
            showDocumentAppendModal = true
        } else {
            Task { await store.addDocumentEntry(nodeID: targetNodeID, sourceURLs: [url]) }
        }
    }

    private func handlePastedMulti(_ items: [ClipboardContent]) {
        guard let targetNodeID = nodeID else { return }
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
                continue
            }
        }

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

        // Links — serialized inside one Task so clipboard order is preserved.
        if !urlTargets.isEmpty {
            let urls = urlTargets
            Task {
                for urlString in urls {
                    await store.appendLinkItem(nodeID: targetNodeID, urlString: urlString)
                }
            }
        }

        // Text — serialized inside one Task for the same ordering reason.
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

        // Files — single modal decision for the whole batch when a
        // `.document` entry already exists; otherwise direct add.
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

    private func mostRecentMediaEntryID() -> String? {
        node?.items
            .filter { $0.type == .imageVideo }
            .max(by: { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) })?
            .id
    }

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

    /// Fire-and-forget commit — for teardown paths (`onDisappear`) where nothing
    /// downstream reads the node in the same turn.
    private func saveIfChanged() {
        Task { await commitEditsIfChanged() }
    }

    /// AWAITABLE header commit — mirrors `NodeDetailView.commitEditsIfChanged` (item 1).
    /// The lever fire path awaits this BEFORE presenting the tray so the tray reads the
    /// committed title/summary, not the stale node — the same defect the detail view had,
    /// and higher-impact here since capture is the first surface a new user hits.
    private func commitEditsIfChanged() async {
        guard let node else { return }
        let nodeID = node.id
        let newTitle = editedTitle, newSummary = editedSummary, newTags = editedTags
        // Compare against the FRESHEST node so an unedited close stays a no-op.
        guard let fresh = store.nodes.first(where: { $0.id == nodeID }) else { return }
        // Brief CD NO-OVERWRITE RULE — commit a header field ONLY when the user actually edited it.
        // An empty, never-edited mirror must never overwrite the title/summary the model promoted at
        // Done (the teardown race that blanked the title + locked it `.user`); an edited field DOES
        // commit even when empty, so a user-cleared field stays cleared. `titleSource = .user` is thus
        // stamped only on genuine user authorship.
        let titleChanged = titleEdited
        let summaryChanged = summaryEdited
        let tagsChanged = fresh.tags != newTags
        guard titleChanged || summaryChanged || tagsChanged else { return }
        // ws-card-catalog Change A — write via mutateNode (fresh read-modify-write)
        // so this title/summary/tags save can't blind-overwrite `.items` with a
        // stale snapshot and erase the note body typed just before Done.
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

// MARK: - Collection chip (copied from NodeDetailView; private there)

/// Membership chip for the Collections row. Rounded-rect shape + neutral
/// fill so it reads distinct from the capsule tag pills.
private struct QuikCaptureCollectionChip: View {
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

// MARK: - Tag chip (copied from NodeDetailView; private there)

private struct QuikCaptureTagChip: View {
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

// MARK: - Hero image banner (copied from NodeDetailView; private there)

/// Cover-cropped hero banner. Copied from NodeDetailView (private there).
/// Only rendered when the node has a chosen cover image — never for a fresh
/// capture node — but copied to keep `heroZone` a faithful copy.
private struct QuikCaptureHeroImageBanner: View {

    let node: Node
    let topInset: CGFloat
    let width: CGFloat

    @Environment(CorpusStore.self) private var store

    @State private var image: UIImage? = nil
    @State private var aspect: CGFloat? = nil

    var body: some View {
        Group {
            if let image, let aspect {
                let visibleHeight = max(200, min(420, width / max(aspect, 0.01)))
                let totalHeight = visibleHeight + topInset
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: totalHeight)
                    .clipped()
                    .clipShape(
                        UnevenRoundedRectangle(
                            bottomLeadingRadius: 30,
                            bottomTrailingRadius: 30,
                            style: .continuous
                        )
                    )
            } else {
                let totalHeight: CGFloat = 200 + topInset
                NodeGradientLayer(node: node, circleScale: 1.3, undulation: 1.0, blobSet: .hero,
                              glassSurface: .entry)
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
        .task(id: node.coverImageRelativePath) {
            image = nil
            aspect = nil
            guard node.coverImageRelativePath != nil,
                  let url = await store.coverImageURL(for: node) else { return }
            let scale = UIScreen.main.scale
            let maxPixel = Int(max(width, 420) * scale)
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
}

// MARK: - Brief CD — the ghost suggestion overlay
// MOVED (Brief CG): `GhostFieldOverlay` now lives in `Views/Shared/GhostFieldOverlay.swift` so the
// AirPadShare extension's lighter share editor compiles the same dependency-free component. Pure move.

#if DEBUG
/// `-GhostGallery` — Brief CD1 look-options screenshot harness. Renders the ghost in the capture
/// Title/Summary idiom at 2 fonts × 3 opacities, on a capture-like ground, + a placeholder-vs-ghost
/// comparison (rule 7) + an auto-replaying shimmer (for the screen recording). Store-free.
struct GhostGalleryView: View {
    @State private var trigger = 0
    private let opacities: [Double] = [0.35, 0.45, 0.55]
    private let faces: [(String, EntryBodyFont)] = [("Lato (default)", .lato), ("Source Serif 4", .sourceSerif4)]
    private var titleSize: CGFloat { EntryVisualSettings.shared.nodeTitle.size }
    private var summarySize: CGFloat { EntryVisualSettings.shared.nodeSummary.size }
    private let ghostTitle = "Team Rocket Halloween costume"
    private let ghostSummary = "Notes on building the Jessie & James look for the party."

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Ghost suggestions — CD1 · opacity 35 / 45 / 55% · Lato + Source Serif 4")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Placeholder vs ghost — must read as different (rule 7)")
                            .font(.system(size: 10)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                        Text("Title").font(faces[0].1.titleFont(size: titleSize)).foregroundStyle(Color(uiColor: .placeholderText))
                        GhostFieldOverlay(text: ghostTitle, font: faces[0].1.titleFont(size: titleSize), ink: AppearancePalette.ink, opacity: 0.45, shimmerTrigger: trigger, demoLoop: true)
                    }
                    Divider().overlay(AppearancePalette.ink.opacity(0.1))
                    ForEach(Array(faces.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(f.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            ForEach(opacities, id: \.self) { op in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(Int(op * 100))% \(op == 0.45 ? "· recommended default" : "")")
                                        .font(.system(size: 9)).foregroundStyle(AppearancePalette.ink.opacity(op == 0.45 ? 0.7 : 0.4))
                                    GhostFieldOverlay(text: ghostTitle, font: f.1.titleFont(size: titleSize), ink: AppearancePalette.ink, opacity: op, shimmerTrigger: trigger, demoLoop: true)
                                    GhostFieldOverlay(text: ghostSummary, font: f.1.font(size: summarySize), ink: AppearancePalette.ink, opacity: op, shimmerTrigger: trigger, demoLoop: true)
                                }
                                .padding(.bottom, 6)
                            }
                            Divider().overlay(AppearancePalette.ink.opacity(0.08))
                        }
                    }
                }
                .padding(20)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                trigger += 1   // replay the shimmer every ~3s for the recording
            }
        }
    }
}
#endif
