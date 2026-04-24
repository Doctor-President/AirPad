import SwiftUI

struct ContentView: View {

    @Environment(CorpusStore.self) private var store
    @State private var showFilterPanel = false
    @State private var showSettings = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")

    var body: some View {
        ZStack {
            // Main content — switches between graph and list mode
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

            // Persistent top controls — CAMetalLayer rule: lives here in ContentView ZStack,
            // never inside NavigationStack or SpriteKit hierarchy.
            // Hidden while NodeDetailView is on screen to avoid overlap with node title.
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
                    .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.18)))
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

            // Thread suggestion card — bottom of screen, above the action button
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

            // Ghost Query Field — persistent bottom pill, visible in both graph and list views
            if !store.isInDetailView {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        GhostQueryField()
                            .frame(maxWidth: .infinity)
                        Spacer()
                            .frame(width: 56) // reserve space for ActionButtonFan + button
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
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
}

// MARK: - View toggle pill

private struct ViewTogglePill: View {
    let viewMode: ViewMode
    let onSelect: (ViewMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.graph, icon: "circle.hexagongrid.fill", label: "Graph")
            modeButton(.list,  icon: "list.bullet",             label: "List")
        }
        .padding(4)
        .background(Color(white: 0.18))   // deliberately opaque — NOT opacity(0.08) which vanishes on black
        .clipShape(Capsule())
    }

    private func modeButton(_ mode: ViewMode, icon: String, label: String) -> some View {
        Button { onSelect(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(viewMode == mode ? .black : .white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(viewMode == mode ? Color.white : Color.clear)
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
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
                    filterSection("Sort") {
                        HStack(spacing: 8) {
                            filterPill("Recent",   isActive: store.filterState.sortOrder == .recency)  { mutate { $0.sortOrder = .recency } }
                            filterPill("Thematic", isActive: store.filterState.sortOrder == .thematic) { mutate { $0.sortOrder = .thematic } }
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
