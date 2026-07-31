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

    /// The capture node's id, created on appear. Nil until
    /// `createCaptureNode()` returns.
    @State private var nodeID: String? = nil

    // MARK: - Capture-chrome layout dials

    /// Capture-chrome layout dials (T's eye is the spec — nudge these).
    private enum CaptureChrome {
        static let buttonSize: CGFloat = 48
        static let buttonSpacing: CGFloat = 10   // tightened so the pill fits the row
        static let barHPadding: CGFloat = 20
        static let barBottomPadding: CGFloat = 10
        /// Extra lift for the pill while the keyboard is up, so it clears the
        /// rich-text formatting toolbar (a 56pt `inputAccessoryView`).
        static let keyboardToolbarClearance: CGFloat = 56
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

    // MARK: - Editable fields (mirrored from node, written back on disappear)

    @State private var editedTitle = ""
    @State private var editedSummary = ""
    @State private var editedTags: [String] = []

    @FocusState private var focusedField: Bool

    @State private var captureMode: CaptureMode? = nil
    @State private var showingNewTagSheet = false
    @State private var showingNewCollectionSheet = false
    @State private var keyboardVisible = false
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
                VStack(alignment: .leading, spacing: 24) {
                // Title
                TextField("Title", text: $editedTitle, axis: .vertical)
                    .font(visualSettings.nodeTitle.resolvedFont())
                    .foregroundStyle(AppearancePalette.ink)
                    .tint(AppearancePalette.ink)
                    .focused($focusedField)

                // Summary
                if !editedSummary.isEmpty || node.summary.isEmpty {
                    TextField("Summary", text: $editedSummary, axis: .vertical)
                        .font(visualSettings.nodeSummary.resolvedFont())
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                        .tint(AppearancePalette.ink)
                        .focused($focusedField)
                }

                // Collections (membership chips above tags)
                collectionsRow(node: node)

                // Tags
                tagsRow

                Divider().background(AppearancePalette.ink.opacity(0.12))

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

                // Stage 5.2 C10 — Attributes section ALWAYS shown in QuickCapture
                // so its "+" (field creation) is available whether or not the
                // node already has atomics; empty → just the header + "+".
                QuikCaptureAttributesSection(nodeID: node.id)

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

                // Paste Pad wired to per-type routing.
                PastePadView(onPaste: handlePastedContent)

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
        }
        // Capture chrome — the four entry-type circles + the Cancel/Done
        // pill, always shown. `safeAreaInset` gets keyboard avoidance so the
        // bar rides above the keyboard with the note live.
        .safeAreaInset(edge: .bottom) {
            captureChrome(node: node)
        }
        // Matched-gray detail surface: same warm tone as the note panel.
        .background { AppearancePalette.bgBase.ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
        } // close ZStack
        } // close GeometryReader
    }

    // MARK: - Capture chrome

    /// The capture bar: the four primitive-type circles (Voice / Camera /
    /// Document / Link) in thumb reach, plus a state-driven Cancel/Done pill
    /// at the far right. The note itself (tap for text) and the PastePad
    /// live in the scroll content.
    ///
    /// Pill: one button, two truths. Empty session → **Cancel** (bail,
    /// discard the blank node). Any content → **Done** (exit to Recents,
    /// node already persisted).
    @ViewBuilder
    private func captureChrome(node: Node) -> some View {
        let hasContent = hasCaptured(node) || router.captureDraftHasText
        HStack(spacing: CaptureChrome.buttonSpacing) {
            captureTypeButton(symbol: "waveform", label: "Voice") { captureMode = .voice }
            captureTypeButton(symbol: "camera.fill", label: "Camera") { captureMode = .camera }
            captureTypeButton(symbol: "doc.fill", label: "Document") { showDocumentPicker = true }
            captureTypeButton(symbol: "link", label: "Link") {
                linkDraft = ""
                showLinkAddAlert = true
            }
            Spacer(minLength: 8)
            Button {
                if hasContent { doneCapture() } else { cancelCapture() }
            } label: {
                Text(hasContent ? "Done" : "Cancel")
                    .font(.headline)
                    .foregroundStyle(hasContent ? AppearancePalette.onInk : AppearancePalette.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(hasContent ? AppearancePalette.ink : AppearancePalette.ink.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: hasContent)
        }
        .padding(.horizontal, CaptureChrome.barHPadding)
        // Lift above the rich-text toolbar while writing; sit at the normal
        // bottom on the launchpad (keyboard down).
        .padding(.bottom, CaptureChrome.barBottomPadding
            + (keyboardVisible ? CaptureChrome.keyboardToolbarClearance : 0))
        .animation(.easeInOut(duration: 0.2), value: keyboardVisible)
    }

    private func captureTypeButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: CaptureChrome.buttonSize, height: CaptureChrome.buttonSize)
                .background(AppearancePalette.ink.opacity(0.12), in: Circle())
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
            NodeGradientLayer(node: node, circleScale: 1.3, undulation: 1.0)
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
        // so this title/summary/tags save can't blind-overwrite `.items` with a
        // stale snapshot and erase the note body typed just before Done.
        // titleSource/summarySource stamps unchanged from step 1.
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

// MARK: - Fold divider (copied from NodeDetailView; private there)

// MARK: - Attributes section (copied from NodeDetailView; private there)

/// Pinned Attributes section for atomic entries (Rating today). Renders
/// only when the node has ≥1 atomic entry; a fresh capture node never does,
/// so this is effectively dead on this surface — copied verbatim to keep
/// the payload-list layout faithful.
private struct QuikCaptureAttributesSection: View {

    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem? = nil
    @State private var showFieldSheet = false   // Stage 5.2 C10 — the "+"

    private var node: Node? {
        store.nodes.first { $0.id == nodeID }
    }

    private var atomicItems: [NodeItem] {
        guard let node else { return [] }
        let atomicCount = node.items.lazy.filter { $0.type.isAtomic }.count
        return Array(node.items.prefix(atomicCount))
    }

    /// Stage 5.2 C10 — `.field` atomics (rendered via the shared FieldPairsGrid)
    /// vs non-field atomics (legacy `.rating`, its own row + edit sheet).
    private var fieldItems: [NodeItem] { atomicItems.filter { $0.type == .field } }
    private var nonFieldAtomics: [NodeItem] { atomicItems.filter { $0.type != .field } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            // Stage 5.2 C10 — QuickCapture renders `.field` atomics through the
            // SAME FieldPairsGrid as the detail view (one component; the narrower
            // QuickCapture width just yields fewer columns — that IS the
            // one-primitive property). Legacy `.rating` keeps its own full-width
            // row + edit sheet.
            if !fieldItems.isEmpty {
                FieldPairsGrid(nodeID: nodeID, fieldItems: fieldItems)
            }
            if !nonFieldAtomics.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(nonFieldAtomics) { item in
                        rowFor(item)
                    }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            if item.type == .rating, let rating = item.rating {
                QuikCaptureRatingEditSheet(
                    itemID: item.id,
                    nodeID: nodeID,
                    initialValue: rating.value,
                    scale: rating.scale
                )
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showFieldSheet) {
            FieldCreationSheet(nodeID: nodeID)
        }
    }

    private var sectionHeader: some View {
        // Stage 5.2 C10 — QuickCapture DOES get field creation (T's call,
        // overriding CC's C9 recommendation): the "+" opens the SAME
        // FieldCreationSheet as the detail view — same component, same
        // @AppStorage remembered section, same resolvePreset reuse-by-id, not a
        // trimmed variant. The section is ungated in the parent, so this "+"
        // shows whether or not the node already has attributes — it is the
        // first-field entry point on the capture surface.
        HStack(spacing: 8) {
            Text("ATTRIBUTES")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            Spacer(minLength: 0)
            Button {
                showFieldSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private func rowFor(_ item: NodeItem) -> some View {
        switch item.type {
        case .rating:
            QuikCaptureRatingAttributeRow(
                item: item,
                onTap: { editingItem = item },
                onDelete: {
                    Task { await store.deleteEntry(itemID: item.id, nodeID: nodeID) }
                }
            )
        default:
            EmptyView()
        }
    }
}

/// Compact, borderless rating row. Copied from NodeDetailView (private there).
private struct QuikCaptureRatingAttributeRow: View {

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

/// Minimal rating editor. Copied from NodeDetailView (private there).
private struct QuikCaptureRatingEditSheet: View {

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
