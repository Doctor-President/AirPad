import SwiftUI

/// Recents — cold-launch landing surface. The recency list previously
/// lived inside `HistoryPanel` (a sheet summoned from the dashboard clock
/// button); promoted to a top-level entry mode so launch lands on
/// chronological nodes rather than collection chrome. Dashboard sits one
/// level up via the leading hub button.
///
/// Mirrors `DashboardView`'s navigation shape: owns a `NavigationStack`
/// + `.navigationDestination(for: Node.self)` so a row tap pushes the
/// node's detail onto its own path (inner stack — Recents is a top-level
/// surface, not a pushed child of dashboard).
///
/// Time-bucketed: Today / Previous 7 Days / Previous 30 Days / month
/// labels (year appended for months older than the current year). Bucket
/// + sort key are coupled — flipping the sort menu re-buckets on the
/// same active date (updatedAt by default, createdAt as the alternate).
struct RecentsView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store

    @State private var path = NavigationPath()
    @State private var sortKey: SortKey = .modified

    enum SortKey: Hashable {
        case modified
        case created
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()
                DashboardLavaLamp()

                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 12)

                    if store.nodes.isEmpty {
                        emptyState
                    } else {
                        bucketList
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar) // own glass-chrome header
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
            }
            // Honour the in-app capture overlay's navigation handoff while
            // Recents is the active surface (parity with DashboardView /
            // CanvasView / NodeListView).
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                path.append(node)
                router.pendingNodeNavigationID = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            // Hub control — goes UP to the Dashboard (browse layer).
            // Grid glyph signals "browse collections", explicitly NOT a
            // back chevron.
            glassCircleButton(systemName: "square.grid.2x2") {
                router.entryMode = .dashboard
            }

            Spacer()

            Text("Recents")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            sortMenu
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortKey) {
                Label("Last Modified", systemImage: "clock.arrow.circlepath")
                    .tag(SortKey.modified)
                Label("Date Created", systemImage: "calendar")
                    .tag(SortKey.created)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.14))
                .clipShape(Circle())
        }
    }

    private func glassCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.14))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bucket list

    private var bucketList: some View {
        List {
            ForEach(buckets, id: \.label) { bucket in
                Section {
                    ForEach(bucket.nodes) { node in
                        Button {
                            path.append(node)
                        } label: {
                            RecentNodeRow(node: node, timestamp: date(for: node))
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                } header: {
                    Text(bucket.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(0.8)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Nothing yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text("Capture something to get started.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bucketing

    private struct Bucket {
        let label: String
        let nodes: [Node]
    }

    private func date(for node: Node) -> Date {
        switch sortKey {
        case .modified: return node.updatedAt
        case .created: return node.createdAt
        }
    }

    private var buckets: [Bucket] {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)
        else { return [] }
        let currentYear = calendar.component(.year, from: now)

        let sorted = store.nodes.sorted { date(for: $0) > date(for: $1) }

        var today: [Node] = []
        var prev7: [Node] = []
        var prev30: [Node] = []
        // Ordered groups by month — preserves the descending date order
        // since `sorted` is already descending and we walk it linearly.
        var monthOrder: [String] = []
        var monthGroups: [String: [Node]] = [:]

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL"
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "LLLL yyyy"

        for node in sorted {
            let d = date(for: node)
            if d >= startOfToday {
                today.append(node)
            } else if d >= sevenDaysAgo {
                prev7.append(node)
            } else if d >= thirtyDaysAgo {
                prev30.append(node)
            } else {
                let year = calendar.component(.year, from: d)
                let label = year == currentYear
                    ? monthFormatter.string(from: d)
                    : monthYearFormatter.string(from: d)
                if monthGroups[label] == nil {
                    monthOrder.append(label)
                    monthGroups[label] = []
                }
                monthGroups[label]?.append(node)
            }
        }

        var result: [Bucket] = []
        if !today.isEmpty { result.append(Bucket(label: "Today", nodes: today)) }
        if !prev7.isEmpty { result.append(Bucket(label: "Previous 7 Days", nodes: prev7)) }
        if !prev30.isEmpty { result.append(Bucket(label: "Previous 30 Days", nodes: prev30)) }
        for label in monthOrder {
            if let nodes = monthGroups[label] {
                result.append(Bucket(label: label, nodes: nodes))
            }
        }
        return result
    }
}

/// Shared row used by both `RecentsView` (sectioned list) and
/// `HistoryPanel` (flat list). Owns the color-dot + title + relative
/// timestamp layout so the two surfaces can't drift visually. Caller
/// passes the timestamp explicitly because Recents tracks an active
/// sort key (updatedAt ⇄ createdAt) and the row should reflect it.
struct RecentNodeRow: View {
    let node: Node
    let timestamp: Date

    @Environment(CorpusStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(nodeColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                + Text(" ago")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
    }

    private var nodeColor: Color {
        guard let tag = node.tags.first,
              let storeTag = store.tags.first(where: { $0.name == tag })
        else { return .gray }
        return Color(hex: storeTag.colorHex) ?? .gray
    }
}
