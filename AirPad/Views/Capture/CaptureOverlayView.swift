import SwiftUI

/// In-app capture overlay. Replaces the canvas fan + in-app QuikCapture
/// view (see `ws-in-app-capture-overlay.md`). Presented above the active
/// entry mode via `AppRouter.captureOverlay`; the user stays in their
/// current context — the overlay rises from the bottom-right "+" anchor
/// over a blur backdrop. Tap-outside or swipe-down dismisses.
///
/// Self-contained for sheet presentation (Voice/Camera/Text/Document
/// sheets, Link alert, NodePickerSheet, CollectionCreationSheet). Defers
/// navigation back to the parent via `onNavigateToNode` — the parent
/// (ContentView wiring lands in C5) knows which scope's NavigationStack
/// to push onto.
///
/// Scope behavior:
/// - `.corpus`: full `CollectionPillRail`, defaults to `lastUsedCollectionID`
/// - `.collection(id)`: rail collapses to a single fixed pin (visual anchor
///   only) — capture lands in that collection, full stop.
struct CaptureOverlayView: View {

    let context: CaptureOverlayContext
    let onDismiss: () -> Void
    let onNavigateToNode: (String) -> Void

    @Environment(CorpusStore.self) private var store

    @State private var selectedCollectionID: String? = nil

    @State private var showVoiceCapture = false
    @State private var showCameraCapture = false
    @State private var showTextCapture = false
    @State private var showDocumentPicker = false
    @State private var showLinkAlert = false
    @State private var showCollectionCreation = false
    @State private var showNodePicker = false

    @State private var linkDraft: String = ""

    /// Set when the user taps an entry-type circle that creates a new node
    /// (Text/Voice/Camera). The capture sheet's `addNode` runs in an inner
    /// `Task` and fires AFTER the sheet calls `dismiss()`, so a
    /// sheet-onDismiss snapshot would miss the new node. We watch
    /// `store.nodes.count` reactively and navigate when the diff surfaces.
    /// A 3s timeout self-cleans the snapshot if no node arrives (covers
    /// cancelled capture / save failure / user backed out).
    @State private var pendingCaptureSnapshot: Set<String>? = nil
    @State private var captureTimeoutTask: Task<Void, Never>? = nil

    /// Drives the entry animation (content slides up + fades in) and the
    /// exit animation (reverse). Set true onAppear, false on dismiss; the
    /// actual unmount is deferred ~180ms so the fade-out plays cleanly
    /// before `onDismiss` clears `router.captureOverlay`.
    @State private var presented: Bool = false

    private var lockedCollectionID: String? {
        switch context.scope {
        case .corpus: return nil
        case .collection(let id): return id
        }
    }

    private var effectiveCollectionID: String? {
        lockedCollectionID ?? selectedCollectionID
    }

    var body: some View {
        ZStack {
            backdrop
            contentStack
        }
        .onAppear(perform: handleAppear)
        .onChange(of: store.nodes.count) { _, _ in
            handlePotentialNewNode()
        }
        .sheet(isPresented: $showVoiceCapture) {
            VoiceCaptureSheet(targetCollectionID: effectiveCollectionID)
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureView(targetCollectionID: effectiveCollectionID)
        }
        .sheet(isPresented: $showTextCapture) {
            TextCaptureSheet(targetCollectionID: effectiveCollectionID)
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                guard !urls.isEmpty else { return }
                createDocumentNode(urls: urls)
            }
        }
        .sheet(isPresented: $showCollectionCreation) {
            CollectionCreationSheet { newCollection in
                store.markCollectionUsed(newCollection.id)
                selectedCollectionID = newCollection.id
            }
        }
        .sheet(isPresented: $showNodePicker) {
            NodePickerSheet { node in
                dismissAndNavigate(to: node.id)
            }
        }
        .alert("Add link", isPresented: $showLinkAlert) {
            TextField("https://example.com", text: $linkDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { linkDraft = "" }
            Button("Add") { commitLink() }
        } message: {
            Text("Paste or type a URL to add it as a link node.")
        }
    }

    // MARK: - Backdrop & content stack

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
            .opacity(presented ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
    }

    private var contentStack: some View {
        VStack(spacing: 20) {
            Spacer()
            addToNodeButton
            collectionRail
            entryTypeRow
                .padding(.bottom, 32)
        }
        .opacity(presented ? 1 : 0)
        .offset(y: presented ? 0 : 60)
        .allowsHitTesting(presented)
        .gesture(swipeDownDismiss)
    }

    // MARK: - Layout pieces

    private var addToNodeButton: some View {
        Button { showNodePicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add to Node")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(white: 0.18))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var collectionRail: some View {
        if let lockedID = lockedCollectionID {
            // Collection-canvas scope: single fixed pin as a visual anchor
            // of where the capture will land. Not tappable / not scrollable.
            fixedCollectionPin(forID: lockedID)
        } else {
            CollectionPillRail(
                selectedCollectionID: $selectedCollectionID,
                lockedID: nil,
                onCreateNew: { showCollectionCreation = true }
            )
        }
    }

    private func fixedCollectionPin(forID id: String) -> some View {
        let name: String = {
            if id == NodeCollection.journalID { return "Journal" }
            return store.collections.first(where: { $0.id == id })?.name ?? "Collection"
        }()
        return Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(
                Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var entryTypeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                entryCircle(symbol: "pencil", label: "Text") {
                    armNewNodeCapture()
                    showTextCapture = true
                }
                entryCircle(symbol: "mic.fill", label: "Voice") {
                    armNewNodeCapture()
                    showVoiceCapture = true
                }
                entryCircle(symbol: "camera.fill", label: "Camera") {
                    armNewNodeCapture()
                    showCameraCapture = true
                }
                entryCircle(symbol: "link", label: "Link") {
                    linkDraft = ""
                    showLinkAlert = true
                }
                entryCircle(symbol: "doc.fill", label: "Document") {
                    showDocumentPicker = true
                }
                // "More" — placeholder for future entry types. Visually
                // dimmed so it doesn't read as primary, no-op on tap.
                entryCircle(symbol: "ellipsis", label: "More", isDimmed: true) {
                    // Intentionally empty.
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func entryCircle(symbol: String, label: String, isDimmed: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isDimmed ? .white.opacity(0.6) : .black)
                    .frame(width: 64, height: 64)
                    .background(isDimmed ? Color.white.opacity(0.18) : Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Lifecycle

    private func handleAppear() {
        // Hydrate last-used collection in corpus scope. Collection scope
        // leaves `selectedCollectionID` nil — the fixed pin handles display
        // via `lockedCollectionID`.
        if lockedCollectionID == nil, selectedCollectionID == nil {
            selectedCollectionID = store.lastUsedCollectionID
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            presented = true
        }
    }

    // MARK: - Dismiss

    private var swipeDownDismiss: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.height > 80 {
                    dismiss()
                }
            }
    }

    private func dismiss() {
        clearPendingCapture()
        withAnimation(.easeIn(duration: 0.18)) {
            presented = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss()
        }
    }

    private func dismissAndNavigate(to nodeID: String) {
        clearPendingCapture()
        withAnimation(.easeIn(duration: 0.18)) {
            presented = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss()
            onNavigateToNode(nodeID)
        }
    }

    // MARK: - New-node capture detection

    private func armNewNodeCapture() {
        pendingCaptureSnapshot = Set(store.nodes.map(\.id))
        captureTimeoutTask?.cancel()
        captureTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pendingCaptureSnapshot = nil
        }
    }

    private func handlePotentialNewNode() {
        guard let snapshot = pendingCaptureSnapshot,
              let newID = store.nodes.first(where: { !snapshot.contains($0.id) })?.id
        else { return }
        dismissAndNavigate(to: newID)
    }

    private func clearPendingCapture() {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        pendingCaptureSnapshot = nil
    }

    // MARK: - Link (synchronous URL → store.addLinkNode)

    private func commitLink() {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        linkDraft = ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
        Task {
            let (nodeID, _) = await store.addLinkNode(
                url: url,
                targetCollectionID: effectiveCollectionID
            )
            dismissAndNavigate(to: nodeID)
        }
    }

    // MARK: - Document (placeholder node + addDocumentEntry)

    /// Two-step creation: empty placeholder Node first, then
    /// `store.addDocumentEntry` populates it. User is navigated into the
    /// detail view immediately after the second step lands, so the brief
    /// empty intermediate state never surfaces in the canvas (the user is
    /// already in detail by then).
    private func createDocumentNode(urls: [URL]) {
        let now = Date()
        let stamp = NodeCollection.captureStamp(forCollectionID: effectiveCollectionID)
        let nodeID = UUID().uuidString
        let placeholder = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: "",
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true,
            journalDate: stamp.journalDate,
            collectionIDs: stamp.collectionIDs
        )
        let position = CGPoint(
            x: Double.random(in: -80...80),
            y: Double.random(in: -80...80)
        )
        Task {
            await store.addNode(placeholder, position: position)
            if let cid = effectiveCollectionID {
                store.markCollectionUsed(cid)
            }
            _ = await store.addDocumentEntry(nodeID: nodeID, sourceURLs: urls)
            dismissAndNavigate(to: nodeID)
        }
    }
}
