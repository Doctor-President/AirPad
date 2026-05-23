import SwiftUI

struct ContentView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(QuarantineStore.self) private var quarantineStore
    @Environment(SelectionService.self) private var selection
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFilterPanel = false
    @State private var showSettings = false
    @State private var showQuarantineReview = false
    @State private var fanExpanded = false
    @State private var showBatchDeleteConfirmation = false
    @State private var showBatchAddTagSheet = false

    var body: some View {
        Group {
            switch router.entryMode {
            case .dashboard:
                DashboardView()
            case .quikCapture(let forcedCollectionID):
                QuikCaptureView(forcedCollectionID: forcedCollectionID)
            case .canvas:
                canvasBody
            }
        }
        // Stage 4.4 — global dev-panel summon button. Mounted at the root
        // so it's reachable from canvas, list, detail (pushed inside the
        // canvas's NavigationStack), and QuikCapture. Self-deletes in
        // commit 3 of Stage 4.4 along with `EntryVisualDevPanel` and
        // `EntryVisualSettings`.
        .overlay(alignment: .topTrailing) {
            EntryVisualDevPanelHost()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                router.entryMode = .dashboard
            }
        }
    }

    private var canvasBody: some View {
        ZStack {
            // Main content — switches between graph and list mode.
            // CanvasView/NodeListView handle their own internal blur for the
            // non-fan layers when fanExpanded; the fan stays sharp inside them.
            Group {
                if store.filterState.viewMode == .graph {
                    CanvasView(fanExpanded: $fanExpanded)
                } else {
                    NodeListView(fanExpanded: $fanExpanded)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.filterState.viewMode)

            // Overlays that live above the canvas but behind the fan — these all
            // blur uniformly when the fan is expanded so the focal effect is
            // consistent across the full screen, not just the canvas area.
            ZStack {
                if store.iCloudUnavailable {
                    VStack {
                        iCloudUnavailableBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                if !store.isInDetailView {
                    VStack(spacing: 0) {
                        if selection.isActive {
                            SelectionHeader(count: selection.count) {
                                selection.exit()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        } else {
                            HStack(alignment: .center, spacing: 8) {
                                DashboardBackButton {
                                    router.entryMode = .dashboard
                                }
                                ViewTogglePill(viewMode: store.filterState.viewMode) { mode in
                                    var s = store.filterState
                                    s.viewMode = mode
                                    store.filterState = s
                                }
                                Spacer()
                                HStack(spacing: 10) {
                                    if quarantineStore.entries.count > 0 {
                                        QuarantineWarningIcon(count: quarantineStore.entries.count) {
                                            showQuarantineReview = true
                                        }
                                    }
                                    SelectButton { selection.enter() }
                                    SettingsButton { showSettings = true }
                                    FilterButton(activeCount: store.filterState.activeFilterCount) {
                                        showFilterPanel = true
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }

                if selection.isActive && !selection.isEmpty && !store.isInDetailView {
                    VStack {
                        Spacer()
                        BatchActionBar(
                            count: selection.count,
                            tags: store.tags,
                            onDelete: { showBatchDeleteConfirmation = true },
                            onPickExistingTag: { tagName in
                                let ids = selection.selected
                                Task {
                                    await store.addTag(tagName, toNodes: ids)
                                    await MainActor.run { selection.exit() }
                                }
                            },
                            onAddNewTag: { showBatchAddTagSheet = true }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let progress = store.importBatchProgress {
                    VStack {
                        Spacer()
                        ImportProgressBanner(current: progress.current, total: progress.total)
                            .padding(.bottom, 108)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.35), value: store.importBatchProgress != nil)
                }

            }
            .blur(radius: fanExpanded ? 12 : 0)
            .animation(.easeInOut(duration: 0.22), value: fanExpanded)
        }
        .animation(.spring(response: 0.35), value: store.iCloudUnavailable)
        .sheet(isPresented: $showFilterPanel) {
            FilterPanelView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showQuarantineReview) {
            QuarantineReviewSheet()
        }
        .sheet(isPresented: $showBatchAddTagSheet) {
            TagEditorSheet(existing: nil) { createdName in
                let ids = selection.selected
                Task {
                    await store.addTag(createdName, toNodes: ids)
                    await MainActor.run { selection.exit() }
                }
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) \(selection.count == 1 ? "item" : "items")?",
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = selection.selected
                Task {
                    await store.deleteNodes(ids: ids)
                    await MainActor.run {
                        selection.exit()
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
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

// MARK: - Dashboard back button

private struct DashboardBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.18))
                .clipShape(Circle())
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

// MARK: - Selection mode controls

private struct SelectButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.18))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectionHeader: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(count == 0 ? "Select items" : "\(count) selected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.18))
                .clipShape(Capsule())
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BatchActionBar: View {
    let count: Int
    let tags: [Tag]
    let onDelete: () -> Void
    let onPickExistingTag: (String) -> Void
    let onAddNewTag: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                TagPickerMenuContent(
                    tags: tags,
                    excludeNames: [],
                    onPickExisting: onPickExistingTag,
                    onAddNew: onAddNewTag
                )
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Tag (\(count))")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.18))
                .clipShape(Capsule())
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)

            Button(action: onDelete) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Delete (\(count))")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.85))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)
        }
    }
}
