import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
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

    /// hero-empty-picker (H1, revised) — drives the file-local
    /// `HeroImagePickerSheet`. Triggered from the `•••` menu's
    /// "Set / Change Hero Image…" item. Always enabled (a node with
    /// zero own-images can still pick from Photos).
    @State private var showHeroPicker = false

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
        ScrollView {
            VStack(spacing: 0) {
                heroZone(node: node, topInset: topInset, width: proxy.size.width)
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

                // Collections (membership chips above tags, mirrors
                // tags-row layout but uses rounded-rect chips to read
                // distinct from the capsule tag pills).
                collectionsRow(node: node)

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
                // Stage 4.8 — atomic types (rating; cook time / serving
                // size later) are presented in a pinned Attributes
                // section above the payload list (Commit B). For now
                // we split the rendering: payload entries flow through
                // this VStack; atomics live at the front of
                // `node.items` (normalized on load + insert) and are
                // omitted from this iteration entirely. The raw-index
                // pair `(rawIndex, item)` is preserved so EntryCard's
                // existing fold / promote / reorder math (which works
                // in raw `node.items` index space) keeps functioning
                // without translation at the card layer. The reorder
                // controller's snapshot is payload IDs only so
                // `slotPitch` (92) snap math operates over the payload
                // suffix; the card converts payload-relative
                // `(from, to)` back to raw indices via `atomicCount`
                // in its `onEnd` handler.
                let payloadEntries = Array(node.items.enumerated()).filter { !$1.type.isAtomic }
                let payloadSnapshot = payloadEntries.map { $0.element.id }
                let atomicCount = node.items.count - payloadEntries.count

                // Stage 4.8 Commit B — pinned Attributes section.
                // Renders only when the node has ≥1 atomic entry; zero
                // atomics → section absent entirely. Sits between the
                // tags hairline and the payload list (the "dead zone"
                // called out in the Commit A handoff §3 — the section
                // filling it is that fix). One hairline above (the
                // existing tags Divider) is enough; no extra rule
                // inside the section.
                if atomicCount > 0 {
                    AttributesSection(nodeID: nodeID)
                }

                VStack(alignment: .leading, spacing: visualSettings.interCardSpacing) {
                    ForEach(payloadEntries, id: \.element.id) { pair in
                        let rawIndex = pair.offset
                        let item = pair.element
                        // 1pt hairline as a bottom overlay on every row
                        // except the last so the gap between entries
                        // reads as a divider without adding layout
                        // height. The fold boundary is marked by an
                        // in-flow labeled divider rendered conditionally
                        // after the last above-fold payload entry (see
                        // `FoldDivider` below). The divider is
                        // suppressed during reorder so the list stays
                        // uniform; its appear/disappear is animated so
                        // the reflow doesn't snap. Single ForEach is
                        // preserved — the divider is a conditional
                        // adornment at the boundary, not a split.
                        EntryCard(item: item, nodeID: nodeID, index: rawIndex, snapshotIDs: payloadSnapshot)
                            .overlay(alignment: .bottom) {
                                if rawIndex < node.items.count - 1 {
                                    Rectangle()
                                        .fill(Color(hexString: "FFFFFF").opacity(0.08))
                                        .frame(height: 1)
                                        .allowsHitTesting(false)
                                }
                            }

                        if !reorderController.isReorderActive
                            && node.foldIndex > atomicCount
                            && rawIndex == node.foldIndex - 1 {
                            FoldDivider()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: reorderController.isReorderActive)
                .animation(.easeInOut(duration: 0.22), value: node.foldIndex)

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
                    // Lift above the persistent Librarian peek pill so the
                    // "+" isn't obscured at peek; same clearance the canvas
                    // capture trigger uses (peek detent + 24pt breathing
                    // room). At medium / large the sheet covers the button
                    // — intentional, mirrors canvas behavior.
                    .padding(.bottom, LibrarianPanelLayout.peekOverlayClearance)
                    .transition(.opacity)
            }
        }
        .background { Color(red: 0.027, green: 0.027, blue: 0.039).ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)

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
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 56, height: 56)
                    .modifier(InteractiveGlassCircle())
            }
            Spacer()
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 56)
                        .modifier(InteractiveGlassCapsule())
                }
            } else {
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
                            showHeroPicker = true
                        } label: {
                            Label("Change Hero Image…", systemImage: "photo.badge.plus")
                        }
                        Button {
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
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 56, height: 56)
                        .modifier(InteractiveGlassCircle())
                }
            }
        }
        .padding(.horizontal, 16)
        } // close GlassRowContainer
        } // close ZStack
        } // close GeometryReader
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
    private func heroZone(node: Node, topInset: CGFloat, width: CGFloat) -> some View {
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
        } else {
            HeroImageBanner(node: node, topInset: topInset, width: width)
                // Force a fresh view identity whenever the source path
                // flips so the `.task(id:)` inside actually re-fires.
                // Without this the banner's identity is reused across
                // hero changes and the keyed task — though re-keyed —
                // never restarts (Case A: heroZone re-evals with the
                // new path, but `task fired` never logs).
                .id(node.coverImageRelativePath)
        }
    }

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
                        onPick: { addMembership(collectionID: $0) }
                    )
                } label: {
                    Label("Add to collection", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
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
            guard let current = node else { return }
            var updated = current
            updated.journalDate = Calendar.current.startOfDay(for: Date())
            updated.updatedAt = Date()
            Task { await store.updateNode(updated) }
        } else {
            Task { await store.addNodes(ids: [nodeID], toCollection: collectionID) }
        }
        store.markCollectionUsed(collectionID)
    }

    private func removeMembership(id: String) {
        if id == NodeCollection.journalID {
            guard let current = node else { return }
            var updated = current
            updated.journalDate = nil
            updated.updatedAt = Date()
            Task { await store.updateNode(updated) }
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
            // Stage 4.8 — More… is now a submenu housing the typed-entry
            // catalog (Rating is the first). Earlier this was an empty-
            // closure stub seat; the submenu grows as new typed entries
            // land. Rating is gated by `hasRating` so the singleton
            // contract is enforced at the call site (the store also
            // bails on duplicate as a belt-and-braces guard).
            Menu {
                Button {
                    Task { await store.appendRatingItem(nodeID: nodeID) }
                } label: {
                    Label("Rating", systemImage: "star.fill")
                }
                .disabled(hasRating)
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

    // MARK: - Rating singleton gate

    /// Stage 4.8 — true when the node already has a `.rating` entry. The
    /// "+" → More… → Rating menu item is `.disabled(hasRating)` so the
    /// user can't stack a second one. The store's `appendRatingItem`
    /// also bails on duplicate for the race where the menu was opened
    /// on stale state.
    private var hasRating: Bool {
        node?.items.contains { $0.type == .rating } ?? false
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
        if updated.summary != editedSummary {
            updated.summary = editedSummary
            // entry-system-and-fold Commit 6 — user-stamp the summary
            // so the FM-respect gate in `processNodeWithAI` leaves it
            // alone on subsequent runs. Covers clearing too: emptying
            // is a deliberate state, so an empty `editedSummary`
            // arriving here also stamps `.user` (the outer `guard
            // changed` already short-circuits the no-op case).
            updated.summarySource = .user
            changed = true
        }
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
                .foregroundStyle(.white.opacity(0.6))
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
        .background(Color.white.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
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

// MARK: - Attributes section (Stage 4.8 Commit B)

/// Pinned block presenting atomic-typed entries (currently: Rating). Not
/// part of the fold scheme, not reorderable, no chevrons. Renders only
/// when at least one atomic item is present — zero atomics is absence,
/// not an empty header. Atomics are guaranteed to occupy a contiguous
/// prefix of `node.items` by `CorpusStore.normalizeAtomicsToFront`, so
/// iteration uses `node.items.prefix(atomicCount)` directly (cheaper
/// than re-filtering; invariant-guaranteed).
///
/// Per-type singleton: at most one row per atomic type. Add path for
/// the *first* atomic of any type stays on `floatingAddButton` →
/// More… (per T 2026-06-10, option 2 in the brief's open-decision
/// resolution). The section-local "+" handles *additional* atomic
/// types only — today the atomic catalog is just Rating, so the
/// section-local "+" has nothing to offer and is suppressed. The
/// floating-+'s More… → Rating seat therefore still owns Rating's
/// first-add today; **flag**: this is the duplication the brief asks
/// to surface — T to decide whether to remove the More… seat in a
/// follow-up or leave it as the canonical first-add path forever.
private struct AttributesSection: View {

    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem? = nil

    /// Reads the live node off the store inside body so the view
    /// registers a dependency on `store.nodes` and re-renders the
    /// moment `setRatingValue` lands a write. Passing `node` as an
    /// init parameter (as Commit B originally did) made the parent
    /// re-evaluate but didn't reliably propagate to this child's
    /// rows after a sheet-driven edit — direct store access is the
    /// pattern used by `EntryCard` for the same reason.
    private var node: Node? {
        store.nodes.first { $0.id == nodeID }
    }

    /// Normalized prefix slice. Equivalent to
    /// `node.items.filter { $0.type.isAtomic }` thanks to
    /// `normalizeAtomicsToFront`; using the prefix avoids a second
    /// pass and signals reliance on the invariant.
    private var atomicItems: [NodeItem] {
        guard let node else { return [] }
        let atomicCount = node.items.lazy.filter { $0.type.isAtomic }.count
        return Array(node.items.prefix(atomicCount))
    }

    /// Atomic types not yet present on this node. Drives the section-
    /// local "+" menu; empty → trigger hidden. Today the catalog is
    /// `[.rating]` only, so when the section is visible (which means
    /// rating is present) this is always empty.
    private var addable: [NodeItemType] {
        let present = Set(atomicItems.map { $0.type })
        return [NodeItemType.rating].filter { !present.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader
            VStack(alignment: .leading, spacing: 0) {
                ForEach(atomicItems) { item in
                    rowFor(item)
                }
            }
        }
        .sheet(item: $editingItem) { item in
            if item.type == .rating, let rating = item.rating {
                RatingEditSheet(
                    itemID: item.id,
                    nodeID: nodeID,
                    initialValue: rating.value,
                    scale: rating.scale
                )
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("ATTRIBUTES")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color(hexString: "FFFFFF").opacity(0.45))
            Spacer(minLength: 0)
            if !addable.isEmpty {
                Menu {
                    ForEach(addable, id: \.self) { type in
                        // Future per-type append routes here. With
                        // only Rating in the catalog today (and Rating
                        // owned by the floating-+'s first-add path),
                        // this loop body is never reached at runtime
                        // — the `if !addable.isEmpty` gate above hides
                        // the trigger. Wired so the next atomic type
                        // (cook time / servings) only needs to add a
                        // case below.
                        Button {} label: {
                            Label(type.defaultDisplayName, systemImage: "plus")
                        }
                        .disabled(true)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(hexString: "FFFFFF").opacity(0.55))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private func rowFor(_ item: NodeItem) -> some View {
        switch item.type {
        case .rating:
            RatingAttributeRow(
                item: item,
                onTap: { editingItem = item },
                onDelete: {
                    Task { await store.deleteEntry(itemID: item.id, nodeID: nodeID) }
                }
            )
        default:
            // No other atomic types yet. When cook time / servings
            // land, add their renderer cases here.
            EmptyView()
        }
    }
}

/// Compact, borderless row — no card background, no stroke, no clip.
/// Leading "Rating" label, trailing stars, then the same `•••`
/// affordance grammar as entry cards (Delete only — no reorder, no
/// promote, no fold actions). Tap anywhere on the row → edit sheet;
/// the Menu sits above the tap gesture in the view tree so taps on
/// the ellipsis open the menu and don't bleed through.
///
/// Meaning is carried by fill (`star.fill` vs `star`), never by hue
/// (T is colorblind) — color tints are polish. Hex literals via the
/// `Color(hexString:)` helper used elsewhere in the file.
private struct RatingAttributeRow: View {

    let item: NodeItem
    let onTap: () -> Void
    let onDelete: () -> Void

    private var rating: Rating { item.rating ?? Rating(value: 0) }

    var body: some View {
        HStack(spacing: 12) {
            Text(item.type.defaultDisplayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)

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
                    .foregroundStyle(.white.opacity(0.6))
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
                            : Color(hexString: "FFFFFF").opacity(0.25)
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
private struct RatingEditSheet: View {

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

// MARK: - Fold divider (Stage 4.8)

/// In-flow labeled rule rendered after the last above-fold entry. Replaces
/// the earlier "CARD VIEW" pill: a horizontal hairline broken in the
/// middle by a quiet caption ("↑ card-visible entries ↑") that points
/// upward at the entries promoted to the canvas card view. Quiet,
/// de-emphasized — its job is to read as a soft boundary marker, not a
/// header. Hex literals throughout.
///
/// This view appears only when `foldIndex > 0` and is suppressed during
/// reorder (handled by the call site so entry list stays uniform and
/// `slotPitch` (92) holds). The call site wraps the transition in
/// `.animation(:value: isReorderActive)` so the reflow when the divider
/// pops in/out animates smoothly instead of snapping.
private struct FoldDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(hexString: "FFFFFF").opacity(0.14))
                .frame(height: 1)
            Text("↑ card-visible entries ↑")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color(hexString: "FFFFFF").opacity(0.45))
                .fixedSize()
            Rectangle()
                .fill(Color(hexString: "FFFFFF").opacity(0.14))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .allowsHitTesting(false)
    }
}

/// Restores the interactive edge-swipe-to-pop gesture that iOS strips
/// when `.toolbar(.hidden, for: .navigationBar)` removes the system
/// back button. On iOS 26 NavigationStack, the SwiftUI host view's
/// `next` responder often does NOT expose the underlying
/// `UINavigationController` directly — so we walk the responder chain
/// AND the parent VC chain, and log which (if either) resolved it.
/// The delegate gates the gesture on `viewControllers.count > 1` so it
/// no-ops at the root.
private struct SwipeBackProxy: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.coordinator = context.coordinator
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navController?.viewControllers.count ?? 0) > 1
        }
    }

    final class ProbeView: UIView {
        var coordinator: Coordinator?
        private var didAttach = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !didAttach, let coordinator = coordinator else { return }
            DispatchQueue.main.async { [weak self] in
                self?.attach(coordinator: coordinator)
            }
        }

        private func attach(coordinator: Coordinator) {
            let directVC = next as? UIViewController
            let directNav = directVC?.navigationController
            let walkedNav = findNavigationController()
            print("[SwipeBackProxy] direct viewController.navigationController = \(directNav == nil ? "nil" : "non-nil"); walked-chain navigationController = \(walkedNav == nil ? "nil" : "non-nil")")
            guard let nav = directNav ?? walkedNav else {
                print("[SwipeBackProxy] could not resolve UINavigationController — swipe-back not restored.")
                return
            }
            coordinator.navController = nav
            nav.interactivePopGestureRecognizer?.delegate = coordinator
            nav.interactivePopGestureRecognizer?.isEnabled = true
            didAttach = true
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
        .task(id: node.coverImageRelativePath) {
            // Drop stale bytes the moment the source path changes so the
            // fallback gradient bridges the gap instead of the previous
            // image lingering during the new resolve.
            image = nil
            aspect = nil
            guard node.coverImageRelativePath != nil,
                  let url = await store.coverImageURL(for: node) else { return }
            let decoded: (UIImage, CGFloat)? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data),
                      img.size.height > 0 else { return nil }
                return (img, img.size.width / img.size.height)
            }.value
            guard let decoded else { return }
            image = decoded.0
            aspect = decoded.1
        }
    }
}

