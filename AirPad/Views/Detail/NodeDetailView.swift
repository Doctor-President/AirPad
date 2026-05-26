import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// Full node detail view. Entered via NavigationStack zoom transition from the canvas.
/// All edits auto-save on disappear.
struct NodeDetailView: View {

    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Editable fields (mirrored from node, written back on disappear)
    @State private var editedTitle = ""
    @State private var editedSummary = ""
    @State private var editedTags: [String] = []

    @FocusState private var focusedField: Bool

    // "Add entry" floating "+" state. Stage 3.1a commit (c) replaced the
    // inline bottom composer triad with a single floating Menu button that
    // routes to one of six entry types.
    @State private var captureMode: CaptureMode? = nil
    @State private var showPromoteConfirmation = false
    @State private var showingNewTagSheet = false
    @State private var showDeleteConfirmation = false
    @State private var keyboardVisible = false
    @State private var showLinkAddAlert = false
    @State private var linkDraft = ""
    @State private var showDocumentPicker = false

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

    @State private var bgPhase: Double = 0

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

    private let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    private var paletteIndex: Int {
        guard let tagName = node?.primaryTag else { return 0 }
        return abs(tagName.hashValue) % 7
    }

    @ViewBuilder
    private var animatedBackground: some View {
        let colors = circleColors[paletteIndex % circleColors.count]
        TimelineView(.animation) { timeline in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(Color(hexString: colors.0))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(x: -80 + sin(time * 0.2 + bgPhase * 1.3) * 40,
                            y: -200 + cos(time * 0.15 + bgPhase * 0.9) * 40)
                Circle()
                    .fill(Color(hexString: colors.1))
                    .frame(width: 280, height: 280)
                    .blur(radius: 80)
                    .offset(x: 60 + sin(time * 0.25 + bgPhase * 1.7) * 40,
                            y: 100 + cos(time * 0.2 + bgPhase * 1.1) * 40)
                Circle()
                    .fill(Color(hexString: colors.2))
                    .frame(width: 240, height: 240)
                    .blur(radius: 80)
                    .offset(x: sin(time * 0.3 + bgPhase * 2.1) * 40,
                            y: 350 + cos(time * 0.25 + bgPhase * 0.7) * 40)
            }
        }
        .ignoresSafeArea()
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
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .onAppear {
            store.isInDetailView = true
            if let node {
                editedTitle   = node.title
                editedSummary = node.summary
                editedTags    = node.tags
            }
            bgPhase = Double.random(in: 0...100)
            // Stage 3.1a — first-open lazy migration to the entry-primitive
            // schema. No-op once the node's entrySchemaVersion is current.
            Task { await store.ensureEntrySchema(forNodeID: nodeID) }
        }
        .onDisappear {
            store.isInDetailView = false
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
        .sheet(isPresented: $showingNewTagSheet) {
            TagEditorSheet(existing: nil) { createdName in
                if !editedTags.contains(createdName) {
                    editedTags.append(createdName)
                }
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title — Stage 4.4 addendum 1a-i: font sourced from the
                // Node Title role in the dev-panel type scale. Default
                // mirrors the prior `.title2.weight(.bold)` exactly.
                TextField("Title", text: $editedTitle, axis: .vertical)
                    .font(visualSettings.nodeTitle.resolvedFont())
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($focusedField)

                // Summary — Stage 4.4 addendum 1a-i: Node Summary role.
                // Default mirrors the prior `.body` exactly.
                if !editedSummary.isEmpty || node.summary.isEmpty {
                    TextField("Summary", text: $editedSummary, axis: .vertical)
                        .font(visualSettings.nodeSummary.resolvedFont())
                        .foregroundStyle(.white.opacity(0.75))
                        .tint(.white)
                        .focused($focusedField)
                }

                // Tags
                tagsRow

                Divider().background(Color.white.opacity(0.12))

                // Items — Stage 3.1a commit (b): every entry is rendered as
                // an `EntryCard` regardless of type. Per-type rendering lives
                // in `Views/Detail/Entry/*EntryBody.swift`. Stage 3.1b: each
                // card needs its index + a snapshot of sibling IDs so the
                // reorder controller can do its parting math without
                // re-reading the store mid-drag.
                //
                // Stage 4.4 — cards live in their own nested VStack so the
                // dev panel's "inter-card spacing" slider only affects
                // card-to-card distance, leaving the outer 24pt rhythm
                // (title / summary / tags / divider) untouched. Regular
                // VStack (not LazyVStack) so every card stays mounted —
                // the reorder controller's lift/drag/release depends on
                // all cards being present in the view tree.
                let itemIDSnapshot = node.items.map(\.id)
                VStack(alignment: .leading, spacing: visualSettings.interCardSpacing) {
                    ForEach(Array(node.items.enumerated()), id: \.element.id) { offset, item in
                        EntryCard(item: item, nodeID: nodeID, index: offset, snapshotIDs: itemIDSnapshot)
                    }
                }

                // Domain suggestion card
                if let domain = node.domain, !node.domainConfirmed {
                    DomainSuggestionCard(domain: domain, nodeID: nodeID)
                }

                // Meta-node provenance + promotion
                if node.isMeta {
                    MetaNodeBanner(nodeID: nodeID, showPromoteConfirmation: $showPromoteConfirmation)
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
                PastePadView(onPaste: handlePastedContent)

                // Trailing spacer so the last entry isn't tucked under the
                // floating "+" button. 80pt clears the 56pt button + 24pt
                // bottom inset with a small breathing margin.
                Spacer(minLength: 80)

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
            }
            .padding(20)
            .dismissKeyboardOnTapOutside()
        }
        .overlay(alignment: .bottomTrailing) {
            // Stage 3.1a commit (c) — floating "+" replaces the inline
            // composer triad. Hidden whenever the keyboard is visible so
            // it doesn't crowd active text input (title, summary, or any
            // RichTextEditor body via accessory toolbar). Stage 3.1b also
            // hides it during reorder mode — no new entries while
            // restructuring.
            if !keyboardVisible && !reorderController.isReorderActive {
                floatingAddButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .background { animatedBackground }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if reorderController.isReorderActive {
                    // Stage 3.1b — Done swaps in while reorder mode is
                    // active. Exits the controller cleanly with no
                    // commit; the long-press path's release-to-commit
                    // path is unchanged.
                    Button("Done") {
                        reorderController.exit()
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                } else {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .environment(reorderController)
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
                // Add from vocabulary
                Menu {
                    TagPickerMenuContent(
                        tags: store.tags,
                        excludeNames: Set(editedTags),
                        onPickExisting: { name in
                            if !editedTags.contains(name) {
                                editedTags.append(name)
                            }
                        },
                        onAddNew: { showingNewTagSheet = true }
                    )
                } label: {
                    Label("Add tag", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Floating "+" button (Stage 3.1a commit (c))

    /// Single entry point for adding entries. Bottom-right 56×56 white
    /// circle matching the canvas/list `ActionButtonFan` styling, but
    /// wired to a native SwiftUI `Menu` rather than the fan animation —
    /// the dropdown is the right grammar inside a detail view, the fan
    /// is the right grammar on the empty canvas. Order locked by brief:
    /// Text, Camera, Voice, Link, Document, More... (More... is a
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
            // Stage 3.1a stub — closure is intentionally empty. The menu
            // seat is reserved for a future full-screen entry-type picker
            // that ships when there are types beyond the basic six.
            Button {} label: {
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
        var updated = node
        var changed = false
        if updated.title != editedTitle { updated.title = editedTitle; changed = true }
        if updated.summary != editedSummary { updated.summary = editedSummary; changed = true }
        if updated.tags != editedTags {
            updated.tags = editedTags
            // User-edited tags carry .user provenance; drop sources for removed tags.
            let editedSet = Set(editedTags)
            for name in editedTags { updated.tagSources[name] = TagOrigin(source: .user) }
            for name in updated.tagSources.keys where !editedSet.contains(name) {
                updated.tagSources.removeValue(forKey: name)
            }
            changed = true
        }
        guard changed else { return }
        updated.updatedAt = Date()
        Task { await store.updateNode(updated) }
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
                .foregroundStyle(.white)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
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
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
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
                .fill(Color.white.opacity(0.18))
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
            let rest = Color.white.opacity(0.30)

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
        deactivateSession()
    }

    /// Seek to a fractional position in [0, 1]. Lazily creates the player if needed
    /// so scrubbing works before the user has ever pressed play. Does not start playback.
    func seek(toProgress progress: Double) {
        guard let url else { return }
        if player == nil {
            guard configureSessionForPlayback() else { return }
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
        guard configureSessionForPlayback() else { return }

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

    private func configureSessionForPlayback() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            return true
        } catch {
            print("[VoicePlayback] Audio session configure failed: \(error)")
            return false
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(ProgressView().tint(.white))
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

// MARK: - Domain suggestion card

private struct DomainSuggestionCard: View {
    let domain: String
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This looks like \(domain) content — want me to optimise how it's stored?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(spacing: 6) {
                    Button("Yes") {
                        Task {
                            guard var node = store.nodes.first(where: { $0.id == nodeID }) else { return }
                            node.domainConfirmed = true
                            await store.updateNode(node)
                        }
                        dismissed = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)

                    Button("No") { dismissed = true }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(14)
            .background(Color.yellow.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            let sources = provenanceNodes
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected from")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                    ForEach(sources) { source in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 5, height: 5)
                            Text(source.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.6))
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

