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
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.06))

            RoundedRectangle(cornerRadius: 28)
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
        .frame(height: surfaceFrameHeight(for: librarian.surfaceMode))
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: librarian.surfaceMode)
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
            return max(560, screenH - 160)
        }
    }

    /// Top-edge drag grabber. Vertical drag commits on release to the
    /// next/previous surface mode (collapsed ↔ expanded ↔ fullScreen).
    /// Threshold-based rather than live-tracked so the spring
    /// animation owns the transition — a partial drag snaps back
    /// rather than leaving the surface at a half-state height.
    @ViewBuilder
    private func dragGrabber(librarian: LibrarianState) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onEnded { value in
                        let dy = value.translation.height
                        if dy < -40 {
                            advanceSurface(librarian: librarian, direction: .up)
                        } else if dy > 40 {
                            advanceSurface(librarian: librarian, direction: .down)
                        }
                    }
            )
            .accessibilityLabel("Drag to resize Librarian")
    }

    private enum SurfaceDragDirection { case up, down }

    /// State machine for drag transitions. Up grows the surface
    /// (collapsed→expanded→fullScreen, fullScreen stays); down
    /// shrinks (fullScreen→expanded→collapsed, collapsed stays).
    private func advanceSurface(librarian: LibrarianState, direction: SurfaceDragDirection) {
        switch (librarian.surfaceMode, direction) {
        case (.collapsed, .up):    librarian.surfaceMode = .expanded
        case (.expanded, .up):     librarian.surfaceMode = .fullScreen
        case (.fullScreen, .down): librarian.surfaceMode = .expanded
        case (.expanded, .down):   librarian.surfaceMode = .collapsed
        default: break
        }
    }

    // MARK: - Collapsed

    @ViewBuilder
    private func collapsedBody(librarian: LibrarianState) -> some View {
        ZStack {
            Text(displayText)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 56)
                .frame(maxWidth: .infinity)

            HStack {
                modeIconWithRing(librarian: librarian)
                    .padding(.leading, 16)
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
    /// outside the 32pt icon frame; tap inside the ring still triggers
    /// the parent action.
    @ViewBuilder
    private func modeIconWithRing(librarian: LibrarianState) -> some View {
        ZStack {
            ContextRing(fraction: librarian.contextFillFraction)
            Image(systemName: librarian.activeMode.sfSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .frame(width: 38, height: 38)
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedBody(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            dragGrabber(librarian: librarian)
                .padding(.top, 6)

            // Header: mode icon (tap → dropdown) + chevron (tap → step down)
            HStack {
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
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 6)

            scopeChipRow(librarian: librarian)
                .padding(.bottom, 8)

            if librarian.activeMode == .research {
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
            }

            endSessionFooter(librarian: librarian)
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
            }
        } else {
            ScrollView {
                suggestionsList(librarian: librarian)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
