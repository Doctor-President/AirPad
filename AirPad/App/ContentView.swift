import SwiftUI

struct ContentView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var showFilterPanel = false
    @State private var showSettings = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")

    // Ghost query field
    @State private var ghostPromptIndex = 0
    @State private var ghostVisible = false
    @State private var ghostActive = false
    @State private var ghostText = ""

    // Prismatic border animation — shared phase for chips + ghost field
    @State private var prismaticPhase: Double = 0

    private let ghostPrompts = [
        "What have I been thinking about most lately?",
        "What ideas keep coming back that I haven't acted on?",
        "What was I worried about last week?",
        "What patterns show up in my work?"
    ]

    var body: some View {
        ZStack {
            // Main content
            Group {
                if store.filterState.viewMode == .graph {
                    CanvasView()
                } else {
                    NodeListView()
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.filterState.viewMode)

            // iCloud unavailable banner
            if store.iCloudUnavailable {
                VStack {
                    iCloudUnavailableBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                    Spacer()
                }
            }

            // Persistent top controls
            // CAMetalLayer rule: lives here in ContentView ZStack, never inside NavigationStack.
            if !store.isInDetailView {
                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        ViewTogglePill(viewMode: store.filterState.viewMode) { mode in
                            var s = store.filterState
                            s.viewMode = mode
                            store.filterState = s
                        }
                        Spacer()
                        HStack(spacing: 10) {
                            SettingsButton { showSettings = true }
                            FilterButton(activeCount: store.filterState.activeFilterCount) {
                                showFilterPanel = true
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 58)

                    // Canvas mode chip selector — graph mode only
                    if store.filterState.viewMode == .graph {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(CanvasViewMode.allCases, id: \.self) { mode in
                                    let isSelected = store.filterState.canvasViewMode == mode
                                    Button {
                                        var s = store.filterState
                                        s.canvasViewMode = mode
                                        store.filterState = s
                                    } label: {
                                        Text(mode.displayName)
                                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                            .foregroundStyle(Color.white.opacity(isSelected ? 1.0 : 0.65))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color.black.opacity(isSelected ? 0.50 : 0.30))
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule().stroke(
                                                    AngularGradient(
                                                        colors: solarPrismaticColors,
                                                        center: .center,
                                                        startAngle: .degrees(prismaticPhase * 360),
                                                        endAngle: .degrees(prismaticPhase * 360 + 360)
                                                    ).opacity(isSelected ? 1.0 : 0.38),
                                                    lineWidth: isSelected ? 1.5 : 1.0
                                                )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                    }

                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }

            // Filter state visibility pill — graph mode, when non-default filters active
            if store.filterState.activeFilterCount > 0
               && store.filterState.viewMode == .graph
               && !store.isInDetailView {
                VStack {
                    Color.clear.frame(height: store.filterState.viewMode == .graph ? 148 : 112)
                    filterStatePill
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Import progress banner
            if let progress = store.importBatchProgress {
                VStack {
                    Spacer()
                    ImportProgressBanner(current: progress.current, total: progress.total)
                        .padding(.bottom, 108)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.35), value: store.importBatchProgress != nil)
            }

            // Ghost Query Field — thumb zone, both graph and list views
            if !store.isInDetailView {
                VStack {
                    Spacer()
                    ghostQueryField
                        .padding(.horizontal, 24)
                        .padding(.bottom, 36)
                }
                .task {
                    withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                        prismaticPhase = 1
                    }
                    await runGhostCycle()
                }
            }

            // Thread suggestion card
            if let suggestion = store.pendingThreads.first {
                let titles = suggestion.nodeIDs.compactMap { id in
                    store.nodes.first { $0.id == id }?.title
                }
                VStack {
                    Spacer()
                    ThreadSuggestionCard(
                        suggestion: suggestion,
                        nodeTitles: titles,
                        onPull: {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            Task { await store.pullThread(suggestion) }
                        },
                        onDismiss: {
                            withAnimation(.spring(response: 0.3)) {
                                store.dismissThread(suggestion)
                            }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 108)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.pendingThreads.first?.id)
            }
        }
        .animation(.spring(response: 0.35), value: store.iCloudUnavailable)
        .sheet(isPresented: $showFilterPanel) {
            FilterPanelView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
    }

    // MARK: - Ghost Query Field

    private var ghostQueryField: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black.opacity(0.35))

            if ghostActive {
                TextField("", text: $ghostText)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .onSubmit { ghostActive = false; ghostText = "" }
                    .padding(.horizontal, 20)
            } else {
                Text(ghostPrompts[ghostPromptIndex])
                    .font(.body.italic())
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.48),
                                Color(
                                    hue: (prismaticPhase * 0.4 + 0.65).truncatingRemainder(dividingBy: 1),
                                    saturation: 0.55, brightness: 1.0
                                ).opacity(0.52)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .multilineTextAlignment(.center)
                    .opacity(ghostVisible ? 1 : 0)
                    .padding(.horizontal, 20)
                    .onTapGesture {
                        ghostText = ghostPrompts[ghostPromptIndex]
                        withAnimation(.easeInOut(duration: 0.2)) { ghostActive = true }
                    }
            }
        }
        .frame(height: 48)
        .overlay(
            RoundedRectangle(cornerRadius: 24).stroke(
                AngularGradient(
                    colors: solarPrismaticColors,
                    center: .center,
                    startAngle: .degrees(prismaticPhase * 360),
                    endAngle: .degrees(prismaticPhase * 360 + 360)
                ).opacity(ghostActive ? 1.0 : 0.55),
                lineWidth: ghostActive ? 1.5 : 1.0
            )
        )
    }

    private let solarPrismaticColors: [Color] = [
        Color(hue: 0.75, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.60, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.45, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.30, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.12, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.04, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.95, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.85, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.75, saturation: 0.85, brightness: 1.0),
    ]

    private func runGhostCycle() async {
        do {
            try await Task.sleep(for: .seconds(3))
            while true {
                withAnimation(.easeInOut(duration: 1.5)) { ghostVisible = true }
                try await Task.sleep(for: .seconds(Double.random(in: 8...12)))
                withAnimation(.easeInOut(duration: 1.5)) { ghostVisible = false }
                try await Task.sleep(for: .seconds(2.5))
                ghostPromptIndex = (ghostPromptIndex + 1) % ghostPrompts.count
            }
        } catch {}
    }

    // MARK: - Filter state pill

    private var filterStatePill: some View {
        HStack(spacing: 8) {
            Text(activeFilterLabel)
                .font(.caption.weight(.medium))
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: 12)
            Button("Clear") {
                var s = store.filterState
                s.itemType = .all
                s.tagName = nil
                s.threadStatus = .all
                store.filterState = s
            }
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private var activeFilterLabel: String {
        var parts: [String] = []
        if let tag = store.filterState.tagName    { parts.append(tag) }
        if store.filterState.itemType != .all      { parts.append(store.filterState.itemType.displayName) }
        if store.filterState.threadStatus != .all  { parts.append(store.filterState.threadStatus.displayName) }
        return parts.isEmpty ? "Filtered" : parts.joined(separator: " · ")
    }
}

// MARK: - View toggle pill

private struct ViewTogglePill: View {
    let viewMode: ViewMode
    let onSelect: (ViewMode) -> Void

    @State private var phase: Double = 0

    private let prismaticColors: [Color] = [
        Color(hue: 0.75, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.60, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.45, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.30, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.12, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.04, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.95, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.85, saturation: 0.85, brightness: 1.0),
        Color(hue: 0.75, saturation: 0.85, brightness: 1.0),
    ]

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.graph, icon: "circle.hexagongrid.fill", label: "Graph")
            modeButton(.list,  icon: "list.bullet",             label: "List")
        }
        .padding(4)
        .background(Color.black.opacity(0.25))
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(
                AngularGradient(
                    colors: prismaticColors,
                    center: .center,
                    startAngle: .degrees(phase * 360),
                    endAngle: .degrees(phase * 360 + 360)
                ),
                lineWidth: 1.5
            )
        )
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func modeButton(_ mode: ViewMode, icon: String, label: String) -> some View {
        Button { onSelect(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(viewMode == mode ? .white : .white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(viewMode == mode ? Color.white.opacity(0.15) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings button

private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.18))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter button

private struct FilterButton: View {
    let activeCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.18))
                    .clipShape(Circle())

                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.blue)
                        .clipShape(Circle())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter panel

struct FilterPanelView: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Sort (list mode) or Canvas Mode (graph mode)
                    if store.filterState.viewMode == .graph {
                        filterSection("Canvas Mode") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(CanvasViewMode.allCases, id: \.self) { mode in
                                        filterPill(mode.displayName,
                                                   isActive: store.filterState.canvasViewMode == mode) {
                                            mutate { $0.canvasViewMode = mode }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        filterSection("Sort") {
                            HStack(spacing: 8) {
                                filterPill("Recent",   isActive: store.filterState.sortOrder == .recency)  { mutate { $0.sortOrder = .recency } }
                                filterPill("Thematic", isActive: store.filterState.sortOrder == .thematic) { mutate { $0.sortOrder = .thematic } }
                            }
                        }
                    }

                    filterSection("Type") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ItemTypeFilter.allCases, id: \.self) { type in
                                    filterPill(
                                        type.displayName,
                                        icon: type.icon,
                                        isActive: store.filterState.itemType == type
                                    ) { mutate { $0.itemType = type } }
                                }
                            }
                        }
                    }

                    if !store.tags.isEmpty {
                        filterSection("Tag") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterPill("All", isActive: store.filterState.tagName == nil) {
                                        mutate { $0.tagName = nil }
                                    }
                                    ForEach(store.tags) { tag in
                                        filterPill(
                                            tag.name,
                                            color: Color(hex: tag.colorHex),
                                            isActive: store.filterState.tagName == tag.name
                                        ) { mutate { $0.tagName = tag.name } }
                                    }
                                }
                            }
                        }
                    }

                    filterSection("Threads") {
                        HStack(spacing: 8) {
                            ForEach(ThreadStatusFilter.allCases, id: \.self) { status in
                                filterPill(status.displayName, isActive: store.filterState.threadStatus == status) {
                                    mutate { $0.threadStatus = status }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                if store.filterState.activeFilterCount > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Clear all") { mutate {
                            $0.sortOrder = .recency
                            $0.itemType = .all
                            $0.tagName = nil
                            $0.threadStatus = .all
                        }}
                        .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
    }

    private func mutate(_ block: (inout FilterState) -> Void) {
        var s = store.filterState
        block(&s)
        store.filterState = s
    }

    @ViewBuilder
    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
            content()
        }
    }

    private func filterPill(
        _ label: String,
        icon: String? = nil,
        color: Color? = nil,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? (color ?? .white) : Color.white.opacity(0.09))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Import progress banner

private struct ImportProgressBanner: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .scaleEffect(0.75)
            Text("Importing \(total) ideas… (\(current)/\(total) processed)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - iCloud banner

private struct iCloudUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.caption)
            Text("iCloud unavailable — saving locally")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
