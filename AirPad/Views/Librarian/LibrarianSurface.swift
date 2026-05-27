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

                if hasPersonalVoice {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 22, height: 32)
                        .accessibilityLabel("Personal voice active")
                }

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

            if librarian.activeMode == .research {
                researchPanel(librarian: librarian)
            } else {
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
            researchStubStage(
                title: "Frame the session",
                detail: "Tell the model what you want from this conversation. Lands next."
            )
        case .export:
            researchStubStage(
                title: "Export the briefing",
                detail: "Copy or share the selected nodes + frame as a single prompt. Lands next."
            )
        case .importReview:
            researchStubStage(
                title: "Import the response",
                detail: "Paste the model's reply; review candidate nodes before they enter the corpus. Lands next."
            )
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
