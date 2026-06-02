import SwiftUI

/// Librarian morphing surface — pill collapsed, full chrome expanded.
/// Tapping the collapsed pill springs the surface open in place; the
/// chevron in the expanded header collapses it back. Replaces the
/// pre-Librarian `CorpusQuerySheet` flow: the classify → respond
/// pipeline (single-mode today; modes land in c3+) runs in-surface
/// against `router.librarian`, so the input, the response, and the
/// surface state all survive view remounts.
///
/// Retrieval rows hand off navigation via `router.pendingNodeNavigationID`
/// so the host NavigationStack (CanvasView / NodeListView) owns the
/// detail-view push — mirroring the capture-overlay pattern.
struct LibrarianSurface: View {

    /// Scope of the host surface this Librarian is mounted on (Corpus
    /// canvas, Journal canvas, or a specific collection canvas/list).
    /// Used to seed `LibrarianState.selectedScope` on first appear in a
    /// new host so the Librarian defaults to the slice the user is
    /// already looking at. Defaults to `.corpus` for hosts that don't
    /// thread a scope through yet.
    let hostScope: CanvasScope

    init(hostScope: CanvasScope = .corpus) {
        self.hostScope = hostScope
    }

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0
    @State private var showModeDropdown = false
    @State private var presentedCitation: PresentedCitation? = nil
    @State private var showEndDialog = false
    @State private var isSavingSession = false
    @State private var researchExportCopied = false
    @FocusState private var isInputFocused: Bool

    /// Live keyboard height, observed via UIResponder notifications.
    /// Drives fullScreen frame compression so the surface stays
    /// anchored at the bottom and shrinks between screen top and
    /// keyboard top, rather than letting the default safe-area
    /// inset push the (taller-than-available) frame off the top.
    /// Stays 0 in collapsed / expanded modes — those frames are
    /// short enough that the natural keyboard push works fine.
    @State private var keyboardHeight: CGFloat = 0

    /// Live drag translation on the grabber. Positive = drag down,
    /// negative = drag up. Combined with the current discrete posture's
    /// base height to produce the real-time surface height during a
    /// drag; reset to 0 (animated) on release once the new posture is
    /// committed. Stays 0 outside of drags.
    @State private var dragLiveOffset: CGFloat = 0

    /// Nearest discrete posture given the current effective height
    /// during a drag. Updated continuously inside the drag handler so
    /// the haptic detent fires at each posture boundary the finger
    /// crosses, not only on release.
    @State private var dragNearestDetent: LibrarianState.SurfaceMode = .collapsed

    /// Live vertical content offset of whichever inner ScrollView is
    /// mounted (transcript / suggestions / search results / research
    /// import). 0 means scrolled to top. Read by `sheetDragGesture` to
    /// decide whether a new drag belongs to the sheet (offset ~0) or
    /// to the ScrollView (offset > 0). Written via
    /// `.onScrollGeometryChange`.
    @State private var scrollOffsetY: CGFloat = 0

    /// True for the duration of a drag the sheet has claimed. While
    /// true, inner ScrollViews are `.scrollDisabled` so the sheet and
    /// the scroll content don't both move under the same finger.
    /// Latched on first claim inside a drag and cleared on release.
    @State private var dragClaimedBySheet = false

    /// Bound to the same key Settings writes (c7). Drives the personal-voice
    /// indicator in the expanded header so toggling the prompt in Settings
    /// reflects here without dismount.
    @AppStorage("librarianPersonalPrompt") private var librarianPersonalPrompt = ""

    /// Identifiable wrapper so `.sheet(item:)` re-presents when the user
    /// taps a different chip without dismissing first. Carries the
    /// full citation list so the sheet can compute its bracket indices
    /// against the same numbering the model saw.
    private struct PresentedCitation: Identifiable {
        let nodeID: String
        let citations: [BlockMatch]
        var id: String { nodeID }
    }

    private var activeWhispers: [String] {
        store.ghostQuerySuggestions
    }

    private var hasPersonalVoice: Bool {
        !librarianPersonalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayText: String {
        guard !activeWhispers.isEmpty else { return "" }
        return activeWhispers[currentWhisperIndex % activeWhispers.count]
    }

    var body: some View {
        @Bindable var librarian = router.librarian

        ZStack {
            RoundedRectangle(cornerRadius: surfaceCornerRadius(for: librarian.surfaceMode))
                .fill(.thinMaterial)

            RoundedRectangle(cornerRadius: surfaceCornerRadius(for: librarian.surfaceMode))
                .fill(Color.black.opacity(0.35))

            // Inner glow: thick inset stroke, blurred, masked to the
            // surface so it can only bleed inward. Strokes the perimeter
            // and decays toward the center.
            RoundedRectangle(cornerRadius: surfaceCornerRadius(for: librarian.surfaceMode))
                .strokeBorder(Color(hexString: "1B59C2").opacity(0.4), lineWidth: 10)
                .blur(radius: 6)
                .mask(
                    RoundedRectangle(cornerRadius: surfaceCornerRadius(for: librarian.surfaceMode))
                )
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: surfaceCornerRadius(for: librarian.surfaceMode))
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(hexString: "E36B4E"),
                            Color(hexString: "7A52FF"),
                            Color(hexString: "B857D4"),
                            Color(hexString: "E36B4E")
                        ],
                        center: .center,
                        startAngle: .degrees(gradientRotation),
                        endAngle: .degrees(gradientRotation + 360)
                    ),
                    lineWidth: 1.5
                )

            switch librarian.surfaceMode {
            case .collapsed:
                collapsedBody(librarian: librarian)
            case .expanded, .fullScreen:
                expandedBody(librarian: librarian)
            }
        }
        .frame(height: effectiveFrameHeight(librarian: librarian))
        .animation(.snappy(duration: 0.32, extraBounce: 0.12), value: librarian.surfaceMode)
        .sensoryFeedback(.impact(weight: .medium), trigger: librarian.surfaceMode) { _, new in
            new == .expanded
        }
        .sensoryFeedback(.impact(weight: .light), trigger: dragNearestDetent)
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
            seedScopeFromHostIfNeeded(librarian: librarian)
        }
        .onChange(of: librarian.surfaceMode) { _, newMode in
            if newMode == .collapsed {
                isInputFocused = false
            }
        }
        .sheet(item: $presentedCitation) { context in
            CitationSheet(
                nodeID: context.nodeID,
                allCitations: context.citations,
                onOpenNote: { router.pendingNodeNavigationID = context.nodeID }
            )
            .environment(store)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { note in
            // willShow can fire repeatedly (frame change on language
            // switch, autofill bar appear, etc.) — always take the
            // latest end-frame height so the surface follows.
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // Adjust for the host VStack's bottom padding (24pt in
            // NodeListView / CanvasView): the keyboard overlaps that
            // padding, so the *effective* lift on the surface is
            // keyboard height minus the host's bottom inset. Without
            // this, we'd over-compress and leave a visible gap below
            // the surface.
            let lift = max(0, frame.height - 24)
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = lift
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
            }
        }
    }

    /// Frame height per surface mode. `.fullScreen` claims most of
    /// the device's vertical space — the parent VStack absorbs the
    /// rest via its `Spacer`, and the host's bottom padding keeps
    /// the surface off the home indicator. Capped at the visible
    /// screen height so a giant simulator size doesn't blow past
    /// the safe area; floored generously so the drag actually feels
    /// like it claimed the screen even on a compact device.
    private func surfaceFrameHeight(for mode: LibrarianState.SurfaceMode) -> CGFloat {
        switch mode {
        case .collapsed: return 78
        case .expanded:  return 452
        case .fullScreen:
            let screenH = UIScreen.main.bounds.height
            // Subtract observed keyboard height so the surface
            // compresses between the screen top and the keyboard top
            // when the input is focused. The floor stays generous
            // enough that the transcript pane still has usable space
            // even with the keyboard up on a compact device.
            let raw = screenH - 160 - keyboardHeight
            return max(keyboardHeight > 0 ? 280 : 560, raw)
        }
    }

    /// Corner radius. Unified at 39pt across all modes so the surface
    /// keeps the same roundness language as it morphs — collapsed pill
    /// arc reads as concentric with the 38pt mode icon ring, and
    /// expanded / fullScreen carry that same arc rather than flattening.
    private func surfaceCornerRadius(for mode: LibrarianState.SurfaceMode) -> CGFloat {
        return 39
    }

    /// Top-edge drag grabber. Live-tracks vertical drag: the surface
    /// height follows the finger between detents, with a light haptic
    /// pulse at each posture boundary crossed. On release the surface
    /// snaps to the nearest detent and the live offset is animated
    /// back to zero in the same spring as the mode change.
    @ViewBuilder
    private func dragGrabber(librarian: LibrarianState) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// Sheet-wide drag gesture. Attached as a `simultaneousGesture` to
    /// the whole expanded-body VStack so the user can drag the surface
    /// from anywhere — header, transcript, suggestions — not only the
    /// grabber strip. Coordinates with the inner ScrollView via a
    /// scroll-offset gate: a new drag is only "claimed" by the sheet
    /// when the active ScrollView is at top (offset ≤ 1pt) — otherwise
    /// the gesture passes through to scroll. Once claimed, the
    /// ScrollView is `.scrollDisabled` for the duration so the same
    /// finger doesn't move two things at once. This mirrors how the
    /// system sheet hands off between scroll and drag.
    ///
    /// `minimumDistance: 6` is the resolution trick that keeps the
    /// chevron / mode-icon / footer buttons tappable: a stationary tap
    /// stays under threshold and falls through to the button, while a
    /// real drag (≥6pt) enters this handler.
    ///
    /// Snap target on release uses `predictedEndTranslation` — SwiftUI's
    /// velocity-projected end position — rather than the raw translation,
    /// matching Apple's sheet pattern. From .expanded (452pt) the midpoint
    /// to fullScreen is ~124pt and to collapsed ~187pt; without velocity
    /// projection a flick that didn't physically cross the midpoint would
    /// snap back. With projection, a short flick at moderate speed adds
    /// hundreds of points of predicted translation and lands on the
    /// intended detent.
    private func sheetDragGesture(librarian: LibrarianState) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !dragClaimedBySheet {
                    let goingDown = value.translation.height > 0
                    let atTopOfScroll = scrollOffsetY <= 1
                    let canGrow = librarian.surfaceMode != .fullScreen
                    let claim = goingDown
                        ? atTopOfScroll
                        : (canGrow && atTopOfScroll)
                    guard claim else { return }
                    dragClaimedBySheet = true
                }
                dragLiveOffset = value.translation.height
                let h = effectiveFrameHeight(librarian: librarian)
                let near = nearestDetent(toHeight: h, librarian: librarian)
                if near != dragNearestDetent {
                    dragNearestDetent = near
                }
            }
            .onEnded { value in
                defer { dragClaimedBySheet = false }
                guard dragClaimedBySheet else { return }
                let base = surfaceFrameHeight(for: librarian.surfaceMode)
                let projectedH = base - value.predictedEndTranslation.height
                let clamped = min(
                    max(projectedH, surfaceFrameHeight(for: .collapsed)),
                    surfaceFrameHeight(for: .fullScreen)
                )
                let target = nearestDetent(toHeight: clamped, librarian: librarian)
                withAnimation(.snappy(duration: 0.32, extraBounce: 0.12)) {
                    librarian.surfaceMode = target
                    dragLiveOffset = 0
                }
            }
    }

    private enum SurfaceDragDirection { case up, down }

    /// State machine for tap/button-driven transitions (chevron, pill
    /// tap, etc.). Up grows the surface (collapsed→expanded→fullScreen,
    /// fullScreen stays); down shrinks (fullScreen→expanded→collapsed,
    /// collapsed stays). Real-time drag has its own snap logic inside
    /// `dragGrabber` — it goes straight to the nearest detent.
    ///
    /// Session-active hold: while `librarian.hasActiveSession` is true,
    /// `.expanded → .collapsed` is blocked so the chevron / drag-down
    /// can't hide an in-progress transcript behind the pill. The user
    /// must explicitly End Session (footer) to collapse.
    private func advanceSurface(librarian: LibrarianState, direction: SurfaceDragDirection) {
        switch (librarian.surfaceMode, direction) {
        case (.collapsed, .up):    librarian.surfaceMode = .expanded
        case (.expanded, .up):     librarian.surfaceMode = .fullScreen
        case (.fullScreen, .down): librarian.surfaceMode = .expanded
        case (.expanded, .down):
            if !librarian.hasActiveSession {
                librarian.surfaceMode = .collapsed
            }
        default: break
        }
    }

    /// Current effective frame height — the discrete posture's base
    /// height shifted by the live drag (drag up = negative dy = larger
    /// frame). Clamped between collapsed and fullScreen so overshooting
    /// the grabber doesn't grow the surface past its bounds.
    private func effectiveFrameHeight(librarian: LibrarianState) -> CGFloat {
        let base = surfaceFrameHeight(for: librarian.surfaceMode)
        let raw = base - dragLiveOffset
        let minH = surfaceFrameHeight(for: .collapsed)
        let maxH = surfaceFrameHeight(for: .fullScreen)
        return min(max(raw, minH), maxH)
    }

    /// Nearest discrete posture to the given height, used to pick the
    /// snap target on release and to drive the detent haptic during
    /// drag. Minimum-distance match against each posture's base height.
    ///
    /// Session-active hold: while `librarian.hasActiveSession` is true,
    /// `.collapsed` is dropped from the candidates so a drag-down past
    /// expanded snaps back to expanded rather than burying the
    /// transcript behind the pill.
    private func nearestDetent(toHeight h: CGFloat, librarian: LibrarianState) -> LibrarianState.SurfaceMode {
        var candidates: [(LibrarianState.SurfaceMode, CGFloat)] = [
            (.collapsed, surfaceFrameHeight(for: .collapsed)),
            (.expanded, surfaceFrameHeight(for: .expanded)),
            (.fullScreen, surfaceFrameHeight(for: .fullScreen))
        ]
        if librarian.hasActiveSession {
            candidates.removeAll { $0.0 == .collapsed }
        }
        return candidates.min(by: { abs($0.1 - h) < abs($1.1 - h) })?.0 ?? librarian.surfaceMode
    }

    // MARK: - Collapsed

    @ViewBuilder
    private func collapsedBody(librarian: LibrarianState) -> some View {
        ZStack {
            Text(displayText)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity)

            HStack {
                modeIconWithRing(librarian: librarian)
                    .padding(.leading, 10)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            librarian.surfaceMode = .expanded
        }
    }

    /// Mode icon + context ring composed as one unit so both surface
    /// states (collapsed pill, expanded header) share the same hit
    /// target and ring placement. Ring sits one pixel of breathing room
    /// outside the 48pt icon frame; tap inside the ring still triggers
    /// the parent action.
    @ViewBuilder
    private func modeIconWithRing(librarian: LibrarianState) -> some View {
        ZStack {
            ContextRing(fraction: librarian.contextFillFraction, diameter: 57)
            Image(systemName: librarian.activeMode.sfSymbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
        }
        .frame(width: 57, height: 57)
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedBody(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            // Header: grabber centered + mode icon top-leading + chevron
            // top-trailing, composed in a ZStack so the icon can anchor
            // to the surface corner with equidistant padding (14pt to
            // top, left, and pill rail) regardless of grabber height.
            ZStack(alignment: .top) {
                dragGrabber(librarian: librarian)
                    .padding(.top, 6)

                HStack(alignment: .top) {
                    Button {
                        showModeDropdown = true
                    } label: {
                        modeIconWithRing(librarian: librarian)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showModeDropdown, arrowEdge: .top) {
                        modeDropdown(librarian: librarian)
                            .presentationCompactAdaptation(.popover)
                    }

                    Spacer()

                    if hasPersonalVoice {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 22, height: 32)
                            .accessibilityLabel("Personal voice active")
                    }

                    Button {
                        advanceSurface(librarian: librarian, direction: .down)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            .padding(.bottom, 14)
            .contentShape(Rectangle())

            searchField(librarian: librarian)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            scopeChipRow(librarian: librarian)
                .padding(.bottom, 8)

            if !librarian.searchText.isEmpty {
                // Search takes over the main pane while the field has
                // content — instant MATCHES (C1) and RELATED (C2)
                // render in place of the mode pipeline's transcript.
                // Clearing the field restores the pipeline UI.
                searchResultsView(librarian: librarian)
                    .frame(maxHeight: .infinity)
            } else if librarian.activeMode == .research {
                researchPanel(librarian: librarian)
            } else {
                // Conversation transcript (flexes), input row beneath
                // it — chat-app convention so new messages land near
                // the typing area.
                transcriptView(librarian: librarian)
                    .frame(maxHeight: .infinity)

                inputRow(librarian: librarian)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
            }

            endSessionFooter(librarian: librarian)
        }
        .simultaneousGesture(sheetDragGesture(librarian: librarian))
        .onChange(of: librarian.searchText) { oldValue, newValue in
            librarian.updateSearchMatches(store: store)
            librarian.kickOffSemanticSearch(store: store)
            // First non-empty character → spring to fullScreen so the
            // results pane has the most room. Triggers on every
            // empty→non-empty transition (e.g. clear + retype) — a
            // user intentionally re-searching wants the same focused
            // posture as the first time.
            if oldValue.isEmpty && !newValue.isEmpty
                && librarian.surfaceMode != .fullScreen {
                withAnimation(.snappy(duration: 0.32, extraBounce: 0.12)) {
                    librarian.surfaceMode = .fullScreen
                }
            }
        }
        .confirmationDialog(
            "End session?",
            isPresented: $showEndDialog,
            titleVisibility: .visible
        ) {
            Button("Save to corpus") {
                Task { await saveSession(librarian: librarian) }
            }
            Button("Clear", role: .destructive) {
                librarian.clearSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save this session as a note, or clear it without saving.")
        }
    }

    /// Footer row holding the End button. Visible whenever the session
    /// has *anything* — either live turns or a compacted summary —
    /// since post-compaction the live history is empty but the session
    /// itself is very much in progress. Counter shows total turns
    /// (compacted + live) so the user's sense of "how much have I done
    /// this session" survives a compaction pass. Save is async
    /// (`addNode` writes JSON + recomputes layout) so the button shows
    /// a progress state while in flight.
    @ViewBuilder
    private func endSessionFooter(librarian: LibrarianState) -> some View {
        let liveCount = librarian.sessionHistory.count
        let totalCount = liveCount + librarian.compactedExchangeCount
        let hasSession = liveCount > 0 || librarian.compactedSummary != nil
        if hasSession {
            HStack {
                Spacer()
                Button {
                    showEndDialog = true
                } label: {
                    HStack(spacing: 6) {
                        if isSavingSession {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white.opacity(0.7))
                        } else {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(isSavingSession ? "Saving…" : "End session (\(totalCount))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSavingSession)
                Spacer()
            }
            .padding(.bottom, 10)
        }
    }

    private func saveSession(librarian: LibrarianState) async {
        isSavingSession = true
        _ = await librarian.saveSessionAsNode(store: store)
        librarian.clearSession()
        isSavingSession = false
    }

    private func sendIsEnabled(librarian: LibrarianState) -> Bool {
        !librarian.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !librarian.isLoading
    }

    // MARK: - Instant search (ws-instant-search C1)

    /// Persistent search field at the top of the Librarian. Independent
    /// of the mode pipeline's `inputText`; typing here drives the
    /// MATCHES + RELATED sections that take over the transcript pane
    /// while non-empty. Available regardless of `activeMode`.
    @ViewBuilder
    private func searchField(librarian: LibrarianState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            TextField("Search", text: Binding(
                get: { librarian.searchText },
                set: { librarian.searchText = $0 }
            ))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .tint(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !librarian.searchText.isEmpty {
                Button {
                    librarian.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }

    /// MATCHES (text) and RELATED (semantic) sections rendered when
    /// the search field is non-empty. Resolves node IDs against the
    /// live store at render time so renames/deletes between
    /// keystroke and frame don't surface stale rows.
    @ViewBuilder
    private func searchResultsView(librarian: LibrarianState) -> some View {
        let matchNodes: [Node] = librarian.searchMatches.compactMap { id in
            store.nodes.first(where: { $0.id == id })
        }
        let related = librarian.searchRelated
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if matchNodes.isEmpty && related.isEmpty && !librarian.searchSemanticInFlight {
                    Text("No matches")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 12)
                }

                if !matchNodes.isEmpty {
                    Text("MATCHES")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 4)
                    ForEach(matchNodes, id: \.id) { node in
                        Button {
                            openNode(node.id)
                        } label: {
                            SearchMatchRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    Text("RELATED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                    if librarian.searchSemanticInFlight {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white.opacity(0.45))
                    }
                }
                .padding(.top, !matchNodes.isEmpty ? 8 : 4)

                ForEach(related) { rel in
                    if let node = store.nodes.first(where: { $0.id == rel.nodeID }) {
                        Button {
                            openNode(rel.nodeID)
                        } label: {
                            SearchRelatedRow(node: node, snippet: rel.snippet)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }
    }

    /// Hand a search-result tap to the host NavigationStack via the
    /// router. Mirrors the `CitationSheet.onOpenNote` pattern so the
    /// detail-view push is owned by `CanvasView` / `NodeListView`,
    /// not the Librarian surface. v1 navigates to top of the detail;
    /// scroll-to-block + highlight is its own follow-on brief.
    private func openNode(_ nodeID: String) {
        router.pendingNodeNavigationID = nodeID
    }

    // MARK: - Chat layout (c14)

    /// Input row at the bottom of the chat pane. Lifted out of
    /// `expandedBody` so the transcript can sit above it as the
    /// flexing element — chat-app convention: history scrolls above,
    /// typing happens at the bottom near the keyboard.
    @ViewBuilder
    private func inputRow(librarian: LibrarianState) -> some View {
        HStack(spacing: 8) {
            TextField("Ask anything...", text: Binding(
                get: { librarian.inputText },
                set: { librarian.inputText = $0 }
            ), axis: .vertical)
                .focused($isInputFocused)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .lineLimit(1...4)

            // Keyboard is up + field is empty → swap send for a
            // dismiss-keyboard affordance. Sending is a no-op while
            // empty (button is disabled) so the slot doubles as the
            // most useful action available right now: get the
            // keyboard out of the way and let the surface go back
            // to full height. With text in the field, send wins —
            // sending naturally unfocuses and dismisses the
            // keyboard, so a separate dismiss is redundant.
            let showDismissButton = keyboardHeight > 0
                && librarian.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if showDismissButton {
                Button {
                    isInputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .accessibilityLabel("Dismiss keyboard")
                .transition(.opacity)
            } else {
                Button {
                    Task { await librarian.executeQuery(store: store) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(sendIsEnabled(librarian: librarian) ? .white : .white.opacity(0.2))
                }
                .buttonStyle(.plain)
                .disabled(!sendIsEnabled(librarian: librarian))
                .padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Stable id for the bottom anchor used by the scroll-to-latest
    /// behavior. Sentinel string, not a real exchange id.
    private static let transcriptBottomAnchor = "_transcript_bottom"

    /// The conversation pane. Renders compacted summary (if any) +
    /// each exchange in `sessionHistory` + any in-flight or error
    /// tail. When the session is empty *and* nothing is pending,
    /// falls through to the existing ghost-whisper suggestions so
    /// the surface still feels alive on first open.
    @ViewBuilder
    private func transcriptView(librarian: LibrarianState) -> some View {
        let isResponseError: Bool = {
            guard let response = librarian.response else { return false }
            if case .error = response { return true }
            return false
        }()
        let hasAny = !librarian.sessionHistory.isEmpty
            || librarian.compactedSummary != nil
            || librarian.pendingQuery != nil
            || librarian.isLoading
            || isResponseError

        if hasAny {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let summary = librarian.compactedSummary, !summary.isEmpty {
                            transcriptCompactedPreamble(summary: summary, turns: librarian.compactedExchangeCount)
                        }

                        ForEach(Array(librarian.sessionHistory.enumerated()), id: \.element.id) { idx, exchange in
                            let isLatest = (idx == librarian.sessionHistory.count - 1)
                            let liveCitations: [BlockMatch]? = {
                                guard isLatest else { return nil }
                                if case let .ask(_, citations, _)? = librarian.response {
                                    return citations
                                }
                                return nil
                            }()
                            transcriptExchange(
                                librarian: librarian,
                                exchange: exchange,
                                liveCitations: liveCitations
                            )
                        }

                        transcriptInflightTail(librarian: librarian)

                        Color.clear
                            .frame(height: 1)
                            .id(Self.transcriptBottomAnchor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: librarian.sessionHistory.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: librarian.isLoading) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(Self.transcriptBottomAnchor, anchor: .bottom)
                }
                .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }
            }
        } else {
            ScrollView {
                suggestionsList(librarian: librarian)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }
        }
    }

    /// Preamble pill for a session that has at least one compaction
    /// pass behind it. Sits above the live history so the user sees
    /// the conversation's full arc, not just the post-compaction tail.
    @ViewBuilder
    private func transcriptCompactedPreamble(summary: String, turns: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Earlier in session — \(turns) turn\(turns == 1 ? "" : "s") compacted")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.4)
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// One historical exchange. Renders as: right-aligned query
    /// bubble, then the response body (markdown / retrieval / plain
    /// text per the exchange's mode), then citation chips when
    /// applicable. `liveCitations` is non-nil only for the most
    /// recent exchange when it still matches `librarian.response`'s
    /// .ask citations — that lets the latest chips open the
    /// `CitationSheet` for block-level pull quotes, while older
    /// chips navigate direct (no live BlockMatch data to drive the
    /// sheet).
    @ViewBuilder
    private func transcriptExchange(
        librarian: LibrarianState,
        exchange: LibrarianState.LibrarianExchange,
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptQueryBubble(text: exchange.query)
            transcriptResponseBody(librarian: librarian, exchange: exchange, liveCitations: liveCitations)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func transcriptQueryBubble(text: String) -> some View {
        HStack {
            Spacer(minLength: 32)
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(hexString: "00BFFF").opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func transcriptResponseBody(
        librarian: LibrarianState,
        exchange: LibrarianState.LibrarianExchange,
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !exchange.responseText.isEmpty {
                Text(attributedMarkdown(exchange.responseText))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if !exchange.citationNodeIDs.isEmpty {
                // Retrieval-only turn (Navigate mode) — render the
                // matched nodes inline so the transcript shows the
                // actual answer (a list of notes), not an empty bubble.
                retrievalList(nodeIDs: exchange.citationNodeIDs)
            }

            if !exchange.citationNodeIDs.isEmpty && !exchange.responseText.isEmpty {
                transcriptCitationRow(
                    nodeIDs: exchange.citationNodeIDs,
                    liveCitations: liveCitations
                )
            }
        }
    }

    /// Citation chip row beneath an Ask response. Latest exchange
    /// gets the live-citation sheet (block-level pull quotes); older
    /// exchanges nav-direct to the source note since we no longer
    /// hold the BlockMatch data needed to power the sheet.
    @ViewBuilder
    private func transcriptCitationRow(
        nodeIDs: [String],
        liveCitations: [BlockMatch]?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(nodeIDs, id: \.self) { nodeID in
                    if let liveCitations {
                        citationChip(nodeID: nodeID, allCitations: liveCitations)
                    } else {
                        transcriptHistoricalChip(nodeID: nodeID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptHistoricalChip(nodeID: String) -> some View {
        let node = store.nodes.first { $0.id == nodeID }
        let title = node?.title ?? "Untitled"

        Button {
            router.pendingNodeNavigationID = nodeID
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(citationDotColor(node: node))
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// In-flight tail: the user's just-sent query as a bubble +
    /// thinking spinner, OR an error pill when the latest pipeline
    /// failed (errors aren't appended to history, so they only show
    /// here). Returns an empty view when neither is active.
    @ViewBuilder
    private func transcriptInflightTail(librarian: LibrarianState) -> some View {
        if let pending = librarian.pendingQuery, librarian.isLoading {
            VStack(alignment: .leading, spacing: 10) {
                transcriptQueryBubble(text: pending)
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                    Text("Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        } else if librarian.isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
                Text("Thinking…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
        } else if case let .error(message)? = librarian.response {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(hexString: "E8820A"))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(hexString: "E8820A").opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Single source chip — node color dot + node title. Tap opens
    /// `CitationSheet` so the user can read the actual passages that
    /// fed the prompt before deciding to jump into the note. The
    /// "Open" button in the sheet hands navigation off to the host
    /// NavigationStack (same pattern as retrieval rows).
    @ViewBuilder
    private func citationChip(nodeID: String, allCitations: [BlockMatch]) -> some View {
        let node = store.nodes.first { $0.id == nodeID }
        let title = node?.title ?? "Untitled"

        Button {
            presentedCitation = PresentedCitation(nodeID: nodeID, citations: allCitations)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(citationDotColor(node: node))
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func citationDotColor(node: Node?) -> Color {
        guard let primary = node?.primaryTag,
              let storeTag = store.tags.first(where: { $0.name == primary }),
              let color = Color(hex: storeTag.colorHex)
        else { return .gray.opacity(0.6) }
        return color
    }

    /// `AttributedString` markdown with a forgiving fallback — if the
    /// model emits something the parser chokes on, we still show the
    /// raw text rather than dropping the answer entirely.
    private func attributedMarkdown(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(text)
    }

    @ViewBuilder
    private func retrievalList(nodeIDs: [String]) -> some View {
        let nodes = nodeIDs.compactMap { id in
            store.nodes.first { $0.id == id }
        }

        if nodes.isEmpty {
            Text("No matches.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            LazyVStack(spacing: 10) {
                ForEach(nodes) { node in
                    Button {
                        router.pendingNodeNavigationID = node.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !node.summary.isEmpty {
                                Text(node.summary)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                            }

                            Text(node.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func modeDropdown(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LibrarianState.Mode.allCases, id: \.self) { mode in
                Button {
                    librarian.activeMode = mode
                    showModeDropdown = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 22)

                        Text(mode.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)

                        Spacer(minLength: 16)

                        if mode == librarian.activeMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Disabled affordance for a future "Research" mode — kept in
            // the dropdown so the concept stays visible to the user but
            // not yet selectable. No backing enum case: when it ships,
            // promote to a real Mode.
            HStack(spacing: 12) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 22)

                Text("Research")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))

                Spacer(minLength: 16)

                Text("Coming soon")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .accessibilityLabel("Research mode, coming soon")
        }
        .frame(minWidth: 180)
        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
    }

    @ViewBuilder
    private func suggestionsList(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.bottom, 2)

            ForEach([
                "What have I been thinking about most lately?",
                "What ideas keep coming back that I haven't acted on?",
                "What patterns show up in my work?"
            ], id: \.self) { whisper in
                Button {
                    librarian.inputText = whisper
                    isInputFocused = true
                } label: {
                    Text(whisper)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Research mode (c8)

    /// Replaces the Ask input + response area when `activeMode == .research`.
    /// Renders the four-stage stepper above and the per-stage content below.
    /// Stage 1 lights up in c8.2; Stages 2–4 are stub placeholders pointing
    /// at upcoming commits.
    @ViewBuilder
    private func researchPanel(librarian: LibrarianState) -> some View {
        VStack(spacing: 12) {
            researchStepper(librarian: librarian)
                .padding(.horizontal, 16)

            researchStageContent(librarian: librarian)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 2)
    }

    /// Four-dot stepper. Numbered chip + stage name + connector line.
    /// Tap a stage to jump there (no validation gates for c8 — Stage 1 is
    /// the only one with real content; later commits add per-stage
    /// `canAdvance` rules).
    @ViewBuilder
    private func researchStepper(librarian: LibrarianState) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(LibrarianState.ResearchStage.allCases.enumerated()), id: \.element) { idx, stage in
                researchStepperDot(stage: stage, librarian: librarian)
                if idx < LibrarianState.ResearchStage.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func researchStepperDot(stage: LibrarianState.ResearchStage, librarian: LibrarianState) -> some View {
        let isActive = librarian.researchStage == stage
        let isPast = stage.rawValue < librarian.researchStage.rawValue
        Button {
            librarian.researchStage = stage
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isActive || isPast ? Color.white.opacity(0.85) : Color.white.opacity(0.08))
                        .frame(width: 22, height: 22)
                    Text("\(stage.rawValue + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive || isPast ? .black : .white.opacity(0.5))
                }
                Text(stage.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.4))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func researchStageContent(librarian: LibrarianState) -> some View {
        switch librarian.researchStage {
        case .select:
            researchSelectStage(librarian: librarian)
        case .frame:
            researchFrameStage(librarian: librarian)
        case .export:
            researchExportStage(librarian: librarian)
        case .importReview:
            researchImportStage(librarian: librarian)
        }
    }

    // MARK: - Stage 4 (Import)

    /// Stage 4 — Import. User pastes the model's reply (either the
    /// raw transcript or the structured JSON Stage 2's toggle asked
    /// for). AirPad parses on text-change into review candidates;
    /// the user accepts or dismisses each one individually. Nothing
    /// enters the corpus until the user taps Accept.
    @ViewBuilder
    private func researchImportStage(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    researchImportPasteArea(librarian: librarian)
                    researchImportStatusRow(librarian: librarian)
                    if let error = librarian.researchImportError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hexString: "E8820A"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hexString: "E8820A").opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    researchImportCandidateList(librarian: librarian)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }

            researchImportFooter(librarian: librarian)
        }
    }

    @ViewBuilder
    private func researchImportPasteArea(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste the model's reply")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.4)
            ZStack(alignment: .topLeading) {
                if librarian.researchImportText.isEmpty {
                    Text("Paste here — JSON from a structured return, or the full transcript with `## headings` per candidate note.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { librarian.researchImportText },
                    set: { newValue in
                        librarian.researchImportText = newValue
                        librarian.parseImportPaste()
                    }
                ))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 110, maxHeight: 180)
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func researchImportStatusRow(librarian: LibrarianState) -> some View {
        HStack(spacing: 8) {
            researchImportModeBadge(mode: librarian.researchImportParseMode)
            Spacer()
            if librarian.researchImportAcceptedCount > 0 {
                Text("\(librarian.researchImportAcceptedCount) added to corpus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hexString: "00BFFF"))
            }
        }
    }

    @ViewBuilder
    private func researchImportModeBadge(mode: LibrarianState.ImportParseMode) -> some View {
        let (label, color): (String?, Color) = {
            switch mode {
            case .none:
                return (nil, .clear)
            case .structuredJSON:
                return ("Detected: structured JSON", Color(hexString: "00BFFF"))
            case .transcriptHeadingSplit:
                return ("Detected: transcript with headings", .white.opacity(0.6))
            case .transcriptSingle:
                return ("Detected: single block (no headings found)", .white.opacity(0.6))
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func researchImportCandidateList(librarian: LibrarianState) -> some View {
        if librarian.researchImportCandidates.isEmpty {
            if librarian.researchImportText.isEmpty {
                Text("Paste a model reply above to extract candidate notes. AirPad understands JSON from the structured-return toggle, or markdown with `## headings`.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            } else if librarian.researchImportAcceptedCount > 0 {
                Text("All candidates reviewed. Paste another reply to extract more, or head back.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 4)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(librarian.researchImportCandidates) { candidate in
                    researchImportCandidateCard(librarian: librarian, candidate: candidate)
                }
            }
        }
    }

    /// One candidate card. Title up top, body preview below (3-line
    /// clamp so a long imported note doesn't dominate the review
    /// surface), Accept + Dismiss in a row. Accept is the cyan-tinted
    /// affirmative; Dismiss is muted so the eye doesn't read it as
    /// the primary action.
    @ViewBuilder
    private func researchImportCandidateCard(
        librarian: LibrarianState,
        candidate: LibrarianState.ImportCandidate
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if !candidate.content.isEmpty {
                Text(candidate.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                Button {
                    Task { @MainActor in
                        await librarian.acceptImportCandidate(id: candidate.id, store: store)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Accept")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hexString: "00BFFF").opacity(0.22))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    librarian.dismissImportCandidate(id: candidate.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Stage 4 footer. Back goes to Export. There's no Next — Import
    /// is the terminal stage. Once the user has accepted what they
    /// wanted, they close the session via the surface-level End
    /// affordance (no per-stage Done needed).
    @ViewBuilder
    private func researchImportFooter(librarian: LibrarianState) -> some View {
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .export
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            let remaining = librarian.researchImportCandidates.count
            if remaining > 0 {
                Text("\(remaining) to review")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    // MARK: - Stage 3 (Export)

    /// Stage 3 — Export. Assembles the briefing text from the user's
    /// frame plus the selected nodes' titles and bodies, optionally
    /// appending a JSON-schema instruction when the Stage 2 toggle is
    /// on. Shows node / word / token-estimate metrics, a read-only
    /// preview, and Copy + Share actions. The user pastes the result
    /// into Claude, ChatGPT, or any other long-context model.
    @ViewBuilder
    private func researchExportStage(librarian: LibrarianState) -> some View {
        let briefing = researchBriefingText(librarian: librarian)
        let metrics = researchExportMetrics(text: briefing, librarian: librarian)

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    researchExportMetricsRow(metrics: metrics)

                    researchExportPreview(text: briefing)

                    researchExportActions(librarian: librarian, briefing: briefing)

                    Text("Works with Claude, ChatGPT, and other long-context models. Paste this briefing into a fresh conversation.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }

            researchExportFooter(librarian: librarian)
        }
    }

    private struct ResearchExportMetrics {
        let nodeCount: Int
        let wordCount: Int
        let tokenEstimate: Int
    }

    /// ~4 chars/token is the established English-text heuristic for both
    /// Anthropic and OpenAI tokenizers — close enough to size a briefing
    /// against a 200k-context Claude or 128k-context GPT without
    /// shipping a real tokenizer to the device.
    private static let researchTokenCharsPerToken: Double = 4.0

    private func researchExportMetrics(text: String, librarian: LibrarianState) -> ResearchExportMetrics {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        let tokens = Int((Double(text.count) / Self.researchTokenCharsPerToken).rounded())
        return ResearchExportMetrics(
            nodeCount: librarian.researchSelectedNodeIDs.count,
            wordCount: words,
            tokenEstimate: tokens
        )
    }

    @ViewBuilder
    private func researchExportMetricsRow(metrics: ResearchExportMetrics) -> some View {
        HStack(spacing: 16) {
            researchMetricChip(value: "\(metrics.nodeCount)", label: "nodes")
            researchMetricChip(value: researchAbbreviated(metrics.wordCount), label: "words")
            researchMetricChip(value: "~" + researchAbbreviated(metrics.tokenEstimate), label: "tokens")
            Spacer()
        }
    }

    @ViewBuilder
    private func researchMetricChip(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.4)
        }
    }

    /// Compact form for word/token counts so a 12,400-word briefing
    /// renders "12.4k" instead of blowing out the chip row.
    private func researchAbbreviated(_ value: Int) -> String {
        if value >= 1000 {
            let k = Double(value) / 1000.0
            return String(format: "%.1fk", k)
        }
        return "\(value)"
    }

    @ViewBuilder
    private func researchExportPreview(text: String) -> some View {
        Text(text.isEmpty ? "Nothing to export yet — pick at least one node in Stage 1." : text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(text.isEmpty ? 0.4 : 0.8))
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func researchExportActions(librarian: LibrarianState, briefing: String) -> some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = briefing
                researchExportCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    researchExportCopied = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: researchExportCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(researchExportCopied ? "Copied" : "Copy")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(briefing.isEmpty)

            ShareLink(item: briefing) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Share")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(briefing.isEmpty)
        }
    }

    @ViewBuilder
    private func researchExportFooter(librarian: LibrarianState) -> some View {
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .frame
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                librarian.researchStage = .importReview
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Build the full briefing text. Frame goes first (the user's
    /// instruction to the model), followed by the selected nodes as
    /// titled sections so the model can ground its reasoning in
    /// specific passages, optionally followed by a JSON-schema
    /// instruction when the Stage 2 toggle is on.
    ///
    /// Body fallbacks: `summary` first (AI-derived gist), else
    /// concatenated text-bearing items. Empty selection returns just
    /// the frame so the preview still reads sensibly while the user
    /// is iterating on Stage 2 wording.
    private func researchBriefingText(librarian: LibrarianState) -> String {
        let frame = librarian.researchFrameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIDs = librarian.researchSelectedNodeIDs
        let selectedNodes = store.nodes
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }

        var sections: [String] = []
        if !frame.isEmpty {
            sections.append(frame)
        }

        if !selectedNodes.isEmpty {
            sections.append("Here are \(selectedNodes.count) note\(selectedNodes.count == 1 ? "" : "s") from my corpus:")
            for node in selectedNodes {
                sections.append(researchBriefingSection(for: node))
            }
        }

        if librarian.researchRequestStructuredReturn {
            sections.append(Self.researchStructuredReturnInstruction)
        }

        return sections.joined(separator: "\n\n")
    }

    private func researchBriefingSection(for node: Node) -> String {
        let title = node.title.isEmpty ? "Untitled" : node.title
        var lines: [String] = ["## \(title)"]
        if !node.summary.isEmpty {
            lines.append(node.summary)
        } else {
            let bodies = node.items.compactMap { $0.content }.filter { !$0.isEmpty }
            if !bodies.isEmpty {
                lines.append(bodies.joined(separator: "\n\n"))
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Schema instruction appended when the user has flipped the
    /// Stage 2 structured-return toggle. Targeted at Stage 4's import
    /// parser — a flat JSON array of `{title, content}` objects keeps
    /// the model honest and the parser simple. Tags / metadata can
    /// land in a follow-up if the import flow grows richer.
    private static let researchStructuredReturnInstruction = """
    Return your response as JSON in this exact shape so AirPad can import the result:

    ```json
    [
      { "title": "Note title", "content": "Full note body in markdown" },
      …
    ]
    ```

    Include one object per distinct insight, pattern, or new note worth capturing. Use plain markdown inside `content`. Do not wrap the JSON in any extra commentary.
    """

    // MARK: - Stage 2 (Frame)

    /// Stage 2 — Frame. Multi-line text editor pre-populated with a
    /// suggestion derived from the user's Stage 1 selection. Carries a
    /// schema-aware-return toggle whose effect is realized when Stage 3
    /// (Export) assembles the briefing prompt; storing it here keeps
    /// the user's preference across stage navigation.
    @ViewBuilder
    private func researchFrameStage(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("What do you want from this conversation?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 4)

                    researchFrameEditor(librarian: librarian)

                    researchStructuredToggle(librarian: librarian)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }

            researchFrameFooter(librarian: librarian)
        }
        .onAppear { researchSeedFrameIfNeeded(librarian: librarian) }
    }

    @ViewBuilder
    private func researchFrameEditor(librarian: LibrarianState) -> some View {
        TextField(
            "Tell the model what you want from this session…",
            text: Binding(
                get: { librarian.researchFrameText },
                set: { librarian.researchFrameText = $0 }
            ),
            axis: .vertical
        )
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .tint(.white)
        .lineLimit(4...10)
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func researchStructuredToggle(librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { librarian.researchRequestStructuredReturn },
                set: { librarian.researchRequestStructuredReturn = $0 }
            )) {
                Text("Request schema-aware structured return")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .tint(Color(hexString: "00BFFF"))

            Text("Asks the model to reply in a JSON shape AirPad can import directly in Stage 4.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private func researchFrameFooter(librarian: LibrarianState) -> some View {
        let count = librarian.researchSelectedNodeIDs.count
        HStack(spacing: 12) {
            Button {
                librarian.researchStage = .select
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(count) node\(count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))

            Button {
                librarian.researchStage = .export
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Populate `researchFrameText` with a default suggestion on first
    /// entry to Stage 2. Re-entering the same session leaves the user's
    /// text alone (including deliberate clear-to-empty). The suggestion
    /// is intentionally simple — the brief's "AirPad suggests a frame"
    /// is satisfied by a sensible question seed that the user can keep,
    /// edit, or wipe; richer substrate-aware framing is a follow-up.
    private func researchSeedFrameIfNeeded(librarian: LibrarianState) {
        guard !librarian.researchFrameSeeded else { return }
        librarian.researchFrameSeeded = true
        guard librarian.researchFrameText.isEmpty else { return }
        let count = librarian.researchSelectedNodeIDs.count
        if count == 0 {
            librarian.researchFrameText = "What patterns or open questions emerge across this slice of the corpus?"
        } else {
            librarian.researchFrameText = "What patterns, tensions, or open questions emerge across these \(count) notes?"
        }
    }

    /// Stage 1 — Select. Scrollable list of candidate nodes from the
    /// active scope, grouped by substrate cluster when available.
    /// Tap-to-toggle selection; pre-seeded with the most recently
    /// updated nodes within the scope as a starting point. Each cluster
    /// section header offers a Select all affordance.
    ///
    /// Substrate ranking by cosine similarity to recent activity is the
    /// design target (per brief); recency seeding is the c8.2 proxy
    /// until the substrate-similarity service surfaces a public API.
    @ViewBuilder
    private func researchSelectStage(librarian: LibrarianState) -> some View {
        let candidates = researchCandidates(librarian: librarian)
        let groups = researchClusterGroups(candidates: candidates)

        VStack(spacing: 0) {
            if candidates.isEmpty {
                researchStubStage(
                    title: "No nodes in scope",
                    detail: "Switch scope above to pick nodes from a different slice of the corpus."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        ForEach(groups, id: \.label) { group in
                            researchClusterSection(group: group, librarian: librarian)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .sheetScrollCoordination(disabled: dragClaimedBySheet) { scrollOffsetY = $0 }

                researchSelectFooter(librarian: librarian)
            }
        }
        .onAppear { researchSeedSelectionIfNeeded(librarian: librarian, candidates: candidates) }
        .onChange(of: librarian.selectedScope) { _, _ in
            researchSeedSelectionIfNeeded(librarian: librarian, candidates: candidates)
        }
    }

    /// Source list for Stage 1 — every node in the active scope, sorted
    /// by `updatedAt` descending so the top of the list is what the user
    /// has been working on most recently.
    private func researchCandidates(librarian: LibrarianState) -> [Node] {
        store.nodes(in: librarian.selectedScope)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Section model — one per cluster (or one "Unclustered" bucket when
    /// substrate placements aren't available yet). `clusterID` is the
    /// raw HDBSCAN label or `nil` when substrate wasn't consulted; the
    /// label is what gets rendered.
    private struct ResearchClusterGroup {
        let label: String
        let clusterID: Int?
        let nodes: [Node]
    }

    /// Group candidates by substrate cluster. Falls back to a single
    /// "All notes" bucket when no placements exist (small corpus, pre-
    /// fit, or the substrate service isn't loaded). Noise nodes (cluster
    /// `-1`) land in their own "Outliers" bucket so the user can still
    /// reach them but the visual separation matches the canvas.
    private func researchClusterGroups(candidates: [Node]) -> [ResearchClusterGroup] {
        guard let placements = SubstrateLayoutService.shared.canvasPlacements(),
              !placements.isEmpty else {
            return [ResearchClusterGroup(label: "All notes", clusterID: nil, nodes: candidates)]
        }
        let clusterByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.nodeID, $0.clusterID) }
        )
        var buckets: [Int?: [Node]] = [:]
        for node in candidates {
            let cluster = clusterByID[node.id]
            buckets[cluster, default: []].append(node)
        }
        // Stable ordering: real clusters first (by ID asc), then noise (-1),
        // then "unplaced" (nodes the substrate hasn't seen yet) so the user's
        // most recent captures don't disappear into a trailing tail.
        let realClusters = buckets.keys.compactMap { $0 }.filter { $0 >= 0 }.sorted()
        var ordered: [ResearchClusterGroup] = []
        for id in realClusters {
            guard let nodes = buckets[id] else { continue }
            ordered.append(ResearchClusterGroup(label: "Cluster \(id + 1)", clusterID: id, nodes: nodes))
        }
        if let noise = buckets[-1] {
            ordered.append(ResearchClusterGroup(label: "Outliers", clusterID: -1, nodes: noise))
        }
        if let unplaced = buckets[nil] {
            ordered.append(ResearchClusterGroup(label: "Recently added", clusterID: nil, nodes: unplaced))
        }
        return ordered
    }

    @ViewBuilder
    private func researchClusterSection(group: ResearchClusterGroup, librarian: LibrarianState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(group.nodes.count)")
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Button {
                    toggleSelectAllInCluster(group: group, librarian: librarian)
                } label: {
                    Text(allSelected(in: group, librarian: librarian) ? "Deselect all" : "Select all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)

            ForEach(group.nodes, id: \.id) { node in
                researchCandidateRow(node: node, librarian: librarian)
            }
        }
    }

    @ViewBuilder
    private func researchCandidateRow(node: Node, librarian: LibrarianState) -> some View {
        let isSelected = librarian.researchSelectedNodeIDs.contains(node.id)
        Button {
            if isSelected {
                librarian.researchSelectedNodeIDs.remove(node.id)
            } else {
                librarian.researchSelectedNodeIDs.insert(node.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isSelected ? Color(hexString: "00BFFF") : .white.opacity(0.3))
                    .frame(width: 22, height: 22)

                Circle()
                    .fill(researchNodeColor(node))
                    .frame(width: 8, height: 8)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.8))
                        .lineLimit(1)
                    if let snippet = researchSnippet(node: node), !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func researchSelectFooter(librarian: LibrarianState) -> some View {
        let count = librarian.researchSelectedNodeIDs.count
        HStack(spacing: 12) {
            Text(count == 0 ? "No nodes selected" : "\(count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(count == 0 ? 0.4 : 0.85))
            Spacer()
            Button {
                librarian.researchStage = .frame
            } label: {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(count == 0 ? .white.opacity(0.3) : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(count == 0 ? Color.white.opacity(0.06) : Color.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.08)),
            alignment: .top
        )
    }

    /// Tag-derived color, mirroring `NodePickerSheet.nodeColor`. The
    /// substrate-color path (`SubstrateLayoutService.colorHSB`) is
    /// canvas-only — Stage 1 reads with the same primitive every other
    /// node-list surface uses so the dot doesn't drift between views.
    private func researchNodeColor(_ node: Node) -> Color {
        guard let tag = node.tags.first,
              let storeTag = store.tags.first(where: { $0.name == tag })
        else { return .gray.opacity(0.6) }
        return Color(hex: storeTag.colorHex) ?? .gray.opacity(0.6)
    }

    /// Two-line preview text. Pulls from `summary` first (the AI-derived
    /// gist), falling back to the first item carrying text content,
    /// falling back to nil. Pre-trimmed to keep the row light even on
    /// long notes.
    private func researchSnippet(node: Node) -> String? {
        if !node.summary.isEmpty { return node.summary }
        for item in node.items {
            if let content = item.content, !content.isEmpty {
                return String(content.prefix(240))
            }
        }
        return nil
    }

    private func allSelected(in group: ResearchClusterGroup, librarian: LibrarianState) -> Bool {
        guard !group.nodes.isEmpty else { return false }
        return group.nodes.allSatisfy { librarian.researchSelectedNodeIDs.contains($0.id) }
    }

    private func toggleSelectAllInCluster(group: ResearchClusterGroup, librarian: LibrarianState) {
        if allSelected(in: group, librarian: librarian) {
            for node in group.nodes {
                librarian.researchSelectedNodeIDs.remove(node.id)
            }
        } else {
            for node in group.nodes {
                librarian.researchSelectedNodeIDs.insert(node.id)
            }
        }
    }

    /// Seeds an initial selection when first entering Stage 1 (or when
    /// scope changes). Picks the top-5 most-recently-updated candidates
    /// as the substrate-recency proxy. Does nothing when the scope key
    /// already matches the last seeded key — preserving the user's
    /// explicit edits across collapse/expand and stage navigation.
    private static let researchSeedCount = 5
    private func researchSeedSelectionIfNeeded(librarian: LibrarianState, candidates: [Node]) {
        let key = librarian.selectedScope.key
        guard librarian.researchLastSeededScopeKey != key else { return }
        librarian.researchLastSeededScopeKey = key
        librarian.researchSelectedNodeIDs.removeAll()
        let seeds = candidates.prefix(Self.researchSeedCount)
        for node in seeds {
            librarian.researchSelectedNodeIDs.insert(node.id)
        }
    }

    @ViewBuilder
    private func researchStubStage(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "graduationcap")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scope chips

    /// Horizontal chip row above the input. Tap selects a scope; the
    /// selection is the source of truth for retrieval (Navigate + Ask).
    /// Order mirrors `CollectionPillRail`: Corpus and Journal first
    /// (system slices), then user collections most-recently-used first.
    @ViewBuilder
    private func scopeChipRow(librarian: LibrarianState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeChip(scope: .corpus, label: "Corpus", librarian: librarian)
                scopeChip(scope: .collection(NodeCollection.journalID), label: "Journal", librarian: librarian)
                ForEach(userCollectionsByLastUsed, id: \.id) { collection in
                    scopeChip(
                        scope: .collection(collection.id),
                        label: collection.name,
                        librarian: librarian
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var userCollectionsByLastUsed: [NodeCollection] {
        store.collections.sorted { a, b in
            let aDate = store.collectionLastUsedAt[a.id] ?? .distantPast
            let bDate = store.collectionLastUsedAt[b.id] ?? .distantPast
            return aDate > bDate
        }
    }

    @ViewBuilder
    private func scopeChip(scope: CanvasScope, label: String, librarian: LibrarianState) -> some View {
        let isSelected = librarian.selectedScope == scope
        Button {
            librarian.selectedScope = scope
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isSelected ? Color.white : Color.white.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Seeds `selectedScope` from the host the first time the surface
    /// appears in that host. Tracks the last-seeded host key on
    /// `LibrarianState` so within a single host the user's explicit
    /// chip selection survives remounts. Crossing into a different
    /// host (Corpus → Reading collection, say) re-seeds.
    private func seedScopeFromHostIfNeeded(librarian: LibrarianState) {
        let key = hostScope.key
        guard librarian.lastSeededHostKey != key else { return }
        librarian.selectedScope = hostScope
        librarian.lastSeededHostKey = key
    }

    // MARK: - Animations

    private func startGradientAnimation() {
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            gradientRotation = 360
        }
    }

    private func startWhisperCycle() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            cycleWhisper()
        }
    }

    private func cycleWhisper() {
        withAnimation(.easeInOut(duration: 0.6)) {
            textOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let count = activeWhispers.count
            guard count > 0 else { return }
            currentWhisperIndex = (currentWhisperIndex + 1) % count

            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }
}

// MARK: - Search result rows

/// MATCHES row — node title prominently, scope/tag hint underneath.
/// Tap-through wiring lands in C3; visual stub today renders title +
/// summary preview without navigation.
private struct SearchMatchRow: View {
    let node: Node

    private var snippet: String {
        if let s = node.substrateSummary, !s.isEmpty { return s }
        return node.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// RELATED row — node title above, NLTokenizer-extracted pull quote
/// from the matched block below. Pull quote is pre-trimmed and
/// length-capped at compute time so the row stays bounded.
private struct SearchRelatedRow: View {
    let node: Node
    let snippet: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// Couples an inner ScrollView to the sheet-wide drag gesture: writes
/// the current vertical content offset out to a binding (so the drag
/// handler can tell whether the scroll is at top) and freezes the
/// ScrollView while the sheet has claimed the drag (so the same finger
/// doesn't translate two things at once). Used by every ScrollView
/// inside `LibrarianSurface.expandedBody`.
fileprivate extension View {
    func sheetScrollCoordination(
        disabled: Bool,
        onOffsetChange: @escaping (CGFloat) -> Void
    ) -> some View {
        self
            .scrollDisabled(disabled)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, newValue in
                onOffsetChange(newValue)
            }
    }
}
