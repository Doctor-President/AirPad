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
    @FocusState private var isInputFocused: Bool

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
            case .expanded:
                expandedBody(librarian: librarian)
            }
        }
        .frame(height: librarian.surfaceMode == .collapsed ? 52 : 452)
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
            // Header: mode icon (tap → dropdown) + chevron (tap → collapse)
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

                Button {
                    librarian.surfaceMode = .collapsed
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            scopeChipRow(librarian: librarian)
                .padding(.bottom, 8)

            // Input row
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
            .padding(.horizontal, 12)

            // Response / suggestion area
            ScrollView {
                responseContent(librarian: librarian)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

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

    @ViewBuilder
    private func responseContent(librarian: LibrarianState) -> some View {
        if librarian.isLoading {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if let response = librarian.response {
            switch response {
            case .insight(let text):
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .retrieval(let nodeIDs):
                retrievalList(nodeIDs: nodeIDs)

            case .ask(let text, let citations, let provider):
                askResponse(text: text, citations: citations, provider: provider)

            case .error(let message):
                Text(message)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hexString: "E8820A"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            suggestionsList(librarian: librarian)
        }
    }

    /// Ask-mode response — markdown body via `AttributedString`, citation
    /// chips stacked below. Tapping a chip drops the user into the cited
    /// node's detail view; the citation sheet (multi-citation pull
    /// quotes) lands in c5c.
    ///
    /// Chips are deduplicated by `nodeID` — one chip per source node even
    /// when multiple blocks from the same note ranked into the top-K. The
    /// numbered `[N]` markers stay in the model's prose (one per block,
    /// driven by prompt construction in `LibrarianState`), but the chip
    /// row reads as "source notes" rather than "passages." Pull quotes
    /// per node land with the citation sheet (c5c).
    @ViewBuilder
    private func askResponse(text: String, citations: [BlockMatch], provider: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(attributedMarkdown(text))
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            let uniqueNodeIDs = dedupedNodeIDs(citations: citations)
            if !uniqueNodeIDs.isEmpty {
                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .textCase(.uppercase)

                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(uniqueNodeIDs, id: \.self) { nodeID in
                            citationChip(nodeID: nodeID, allCitations: citations)
                        }
                    }
                }
            }

            Text(provider)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    /// Returns node IDs in order of first appearance in `citations`,
    /// dropping later duplicates. Order matters — first-appearance
    /// roughly tracks "strongest match" since `findRelevantBlockMatches`
    /// returns matches sorted by score.
    private func dedupedNodeIDs(citations: [BlockMatch]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for match in citations {
            if seen.insert(match.nodeID).inserted {
                ordered.append(match.nodeID)
            }
        }
        return ordered
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
