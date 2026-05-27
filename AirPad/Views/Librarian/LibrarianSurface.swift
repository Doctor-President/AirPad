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

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0
    @State private var showModeDropdown = false
    @FocusState private var isInputFocused: Bool

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
        .frame(height: librarian.surfaceMode == .collapsed ? 52 : 420)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: librarian.surfaceMode)
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
        }
        .onChange(of: librarian.surfaceMode) { _, newMode in
            if newMode == .collapsed {
                isInputFocused = false
            }
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
                Image(systemName: librarian.activeMode.sfSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
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

    // MARK: - Expanded

    @ViewBuilder
    private func expandedBody(librarian: LibrarianState) -> some View {
        VStack(spacing: 0) {
            // Header: mode icon (tap → dropdown) + chevron (tap → collapse)
            HStack {
                Button {
                    showModeDropdown = true
                } label: {
                    Image(systemName: librarian.activeMode.sfSymbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
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
            .padding(.bottom, 10)

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
