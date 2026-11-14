#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import FloatingPanel

/// Mac batch D — the desktop layout, T's picks (Ops `reference/mac-layout-2026-11-07.json`): one toolbar (D1), a sidebar
/// at 232 pt (D2), the content, and the Librarian as a push-in panel at 360 pt that floats over the content below a
/// 1,210 pt window (D3). Mac only: iPhone and iPad keep their layout.
@MainActor @Observable
final class MacLayout {
    static let shared = MacLayout()

    static let sidebarWidth: CGFloat = 232
    static let librarianWidth: CGFloat = 360
    /// Below this window width the Librarian floats over the content (rounded, glass, inset 10 pt) instead of pushing it.
    static let librarianFloatsBelow: CGFloat = 1210

    private static let sidebarKey = "mac.layout.sidebar.v1"
    private static let librarianKey = "mac.layout.librarian.v1"

    /// Shown / hidden (⌃⌘S, the toolbar button); remembered.
    var sidebarVisible: Bool { didSet { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarKey) } }
    /// Open / closed (⌘L, the toolbar button); open by default; remembered.
    var librarianOpen: Bool { didSet { UserDefaults.standard.set(librarianOpen, forKey: Self.librarianKey) } }
    /// The window's width in points (the frame measures it).
    var windowWidth: CGFloat = 1350
    /// D7 — the region Tab last moved to (for the self-test and the sidebar's arrow keys).
    var focusedRegion: MacRegion?
    var librarianFloats: Bool { windowWidth < Self.librarianFloatsBelow }

    /// The Librarian column's panel state: always fully open — there is no FloatingPanel on the Mac, so its moves are
    /// no-ops and the surface lays out as its expanded self.
    let panelModel: LibrarianPanelStateModel = {
        let m = LibrarianPanelStateModel()
        m.state = .full
        m.progress.peekProgress = 1
        m.contentRevealed = true
        return m
    }()

    private init() {
        let d = UserDefaults.standard
        sidebarVisible = d.object(forKey: Self.sidebarKey) as? Bool ?? true
        librarianOpen = d.object(forKey: Self.librarianKey) as? Bool ?? true
        #if DEBUG
        // Stills: `-MacSidebar on|off`, `-MacLibrarian open|closed` (not remembered).
        if let s = d.string(forKey: "MacSidebar") { sidebarVisible = s == "on" }
        if let s = d.string(forKey: "MacLibrarian") { librarianOpen = s == "open" }
        #endif
    }
}

/// D2/D3 — sidebar | content | Librarian. The content takes what's left; below 1,210 pt the open Librarian floats over
/// its trailing edge instead of narrowing it.
/// D7 — the three regions Tab / ⇧Tab move between.
enum MacRegion: Hashable { case sidebar, content, librarian }

struct MacDesktopFrame<Content: View>: View {
    let hostScope: CanvasScope
    @ViewBuilder var content: Content
    @State private var layout = MacLayout.shared
    @FocusState private var region: MacRegion?

    /// The regions on screen, in Tab order.
    private var regions: [MacRegion] {
        (layout.sidebarVisible ? [.sidebar] : []) + [.content] + (layout.librarianOpen ? [.librarian] : [])
    }

    var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarVisible {
                MacSidebar()
                    .frame(width: MacLayout.sidebarWidth)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($region, equals: .sidebar)
                    .overlay(alignment: .leading) { regionMark(.sidebar) }
                    .transition(.move(edge: .leading))
                MacHairline()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .focused($region, equals: .content)
                .overlay(alignment: .trailing) {
                    if layout.librarianOpen && layout.librarianFloats {
                        MacLibrarianColumn(hostScope: hostScope)
                            .frame(width: MacLayout.librarianWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(AppearancePalette.ink.opacity(0.10), lineWidth: 1))
                            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
                            .padding(10)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            if layout.librarianOpen && !layout.librarianFloats {
                MacHairline()
                MacLibrarianColumn(hostScope: hostScope)
                    .frame(width: MacLayout.librarianWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { layout.windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in layout.windowWidth = w }
        })
        .animation(.easeOut(duration: 0.2), value: layout.sidebarVisible)
        .animation(.easeOut(duration: 0.2), value: layout.librarianOpen)
        .animation(.easeOut(duration: 0.2), value: layout.librarianFloats)
        // D7 — Tab / ⇧Tab: sidebar → content → Librarian (a text field keeps its own Tab: indent, next field).
        .onKeyPress(keys: [.tab]) { press in
            let list = regions
            let i = region.flatMap { list.firstIndex(of: $0) } ?? (press.modifiers.contains(.shift) ? 0 : list.count - 1)
            let next = list[(i + (press.modifiers.contains(.shift) ? list.count - 1 : 1)) % list.count]
            focus(next)
            return .handled
        }
    }

    private func focus(_ r: MacRegion) {
        if r == .librarian {
            region = nil
            NotificationCenter.default.post(name: .macFocusLibrarianAsk, object: nil)
        } else {
            region = r
        }
        MacLayout.shared.focusedRegion = r
    }

    /// A slim accent bar on the focused region's leading edge (the focus is otherwise invisible on a pane).
    @ViewBuilder private func regionMark(_ r: MacRegion) -> some View {
        if region == r {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3).padding(.vertical, 8)
        }
    }
}

/// A 1 pt divider between the columns, in the app's ink.
struct MacHairline: View {
    var body: some View {
        Rectangle().fill(AppearancePalette.ink.opacity(0.10)).frame(width: 1).ignoresSafeArea()
    }
}

/// D3 — the Librarian as a column: the same surface the phone's panel shows, laid out open.
struct MacLibrarianColumn: View {
    let hostScope: CanvasScope
    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    /// The place the Librarian reads (its scope line follows it): the open entry, else the library / collection.
    private var scope: CanvasScope {
        if store.isInDetailView, let id = router.openEntryID, !router.isCapturing { return .nodeIDs([id]) }
        return hostScope
    }
    var body: some View {
        LibrarianSurface(hostScope: scope, panelModel: MacLayout.shared.panelModel, proxy: nil)
            .background(AppearancePalette.bgBase)
            .accessibilityIdentifier("macLibrarianColumn")
    }
}

/// D2 — the sidebar (232 pt): AIRPAD (Today, Recents, Chats), LIBRARIES, COLLECTIONS, JOURNALS, each with its count.
/// A click goes there; the current place is highlighted; right-click on a collection offers what its Today menu does.
struct MacSidebar: View {
    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @State private var renameTarget: NodeCollection?
    @State private var deleteTarget: NodeCollection?

    private var userNodes: [Node] { store.userNodes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("AirPad")
                row("Today", icon: "sun.max", selected: router.entryMode == .dashboard, id: "sidebar.today") {
                    router.entryMode = .dashboard
                }
                row("Recents", icon: "clock", count: userNodes.count, selected: router.entryMode == .recents, id: "sidebar.recents") {
                    router.entryMode = .recents
                }
                row("Chats", icon: "bubble.left.and.bubble.right", count: router.chatStore.chats.count, selected: false, id: "sidebar.chats") {
                    router.showChatsList = true
                }

                header("Libraries")
                row("Library", icon: "books.vertical", count: userNodes.count, selected: router.entryMode == .canvas, id: "sidebar.library") {
                    router.entryMode = .canvas
                }
                if !store.sampleNodeIDs.isEmpty {
                    row("Sample Library", icon: "sparkles.rectangle.stack",
                        count: store.hidingPrivate(store.nodes).filter { store.isSample($0.id) }.count,
                        selected: router.entryMode == .sampleCanvas, id: "sidebar.sample") {
                        router.entryMode = .sampleCanvas
                    }
                }

                let collections = store.collections.filter { !$0.isSystem }
                if !collections.isEmpty {
                    header("Collections")
                    ForEach(collections) { c in
                        row(c.name, dot: Self.dotColor(c.id, light: scheme == .light), count: count(in: c.id),
                            selected: router.entryMode == .collectionCanvas(id: c.id), id: "sidebar.collection") {
                            router.entryMode = .collectionCanvas(id: c.id)
                        }
                        .contextMenu {
                            Button { router.entryMode = .collectionCanvas(id: c.id) } label: { Label("Open", systemImage: "arrow.right.circle") }
                            Button { renameTarget = c } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deleteTarget = c } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }

                header("Journals")
                row("Journal", dot: Self.dotColor(NodeCollection.journalID, light: scheme == .light),
                    count: userNodes.filter { $0.journalDate != nil }.count,
                    selected: router.entryMode == .collectionCanvas(id: NodeCollection.journalID), id: "sidebar.journal") {
                    router.entryMode = .collectionCanvas(id: NodeCollection.journalID)
                }
                .contextMenu {
                    Button { router.entryMode = .collectionCanvas(id: NodeCollection.journalID) } label: { Label("Open", systemImage: "arrow.right.circle") }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .background(AppearancePalette.ink.opacity(scheme == .dark ? 0.03 : 0.035))
        .background(AppearancePalette.bgBase)
        .accessibilityIdentifier("macSidebar")
        // D7 — with the sidebar focused, ↑ / ↓ go to the previous / next place.
        .onKeyPress(.downArrow) { step(+1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .sheet(item: $renameTarget) { c in
            RenameCollectionSheet(collectionID: c.id, currentName: c.name)
        }
        .confirmationDialog(deleteTarget.map { "Delete \"\($0.name)\"?" } ?? "Delete collection?",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { c in
            Button("Delete", role: .destructive) {
                if router.entryMode == .collectionCanvas(id: c.id) { router.entryMode = .dashboard }
                Task { await store.deleteCollection(id: c.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The entries stay in your library.")
        }
    }

    /// Entries in a collection (the Sample Library's collections hold sample entries).
    /// The places in sidebar order (Chats opens a sheet, so the arrows skip it).
    private var places: [AppRouter.EntryMode] {
        var p: [AppRouter.EntryMode] = [.dashboard, .recents, .canvas]
        if !store.sampleNodeIDs.isEmpty { p.append(.sampleCanvas) }
        p += store.collections.filter { !$0.isSystem }.map { .collectionCanvas(id: $0.id) }
        p.append(.collectionCanvas(id: NodeCollection.journalID))
        return p
    }

    private func step(_ d: Int) {
        let p = places
        let i = p.firstIndex(of: router.entryMode) ?? 0
        router.entryMode = p[min(max(i + d, 0), p.count - 1)]
    }

    private func count(in id: String) -> Int { store.hidingPrivate(store.nodes).filter { $0.collectionIDs.contains(id) }.count }

    /// A collection has no colour of its own: a stable slot of the region palette, from its id.
    static func dotColor(_ id: String, light: Bool) -> Color {
        let slots = RegionPalette.currentHex(isLight: light).count
        let h = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(uiColor: RegionPalette.color(isLight: light, slot: Int(h % UInt32(max(slots, 1)))))
    }

    /// Section header in AirPad's small caps style.
    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(appFont.font(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ title: String, icon: String? = nil, dot: Color? = nil, count: Int? = nil, selected: Bool, id: String,
                     action: @escaping () -> Void) -> some View {
        MacSidebarRow(title: title, icon: icon, dot: dot, count: count, selected: selected, action: action)
            .accessibilityIdentifier(id)
    }
}

private struct MacSidebarRow: View {
    let title: String
    let icon: String?
    let dot: Color?
    let count: Int?
    let selected: Bool
    let action: () -> Void
    @Environment(\.appBodyFont) private var appFont
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(selected ? 0.9 : 0.6))
                        .frame(width: 18)
                } else if let dot {
                    Circle().fill(dot).frame(width: 9, height: 9).frame(width: 18)
                }
                Text(title)
                    .font(appFont.font(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(AppearancePalette.ink.opacity(selected ? 0.95 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(appFont.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppearancePalette.ink.opacity(selected ? 0.12 : (hovering ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif

#if targetEnvironment(macCatalyst)
// MARK: - D1 — the toolbar

/// D1 — ONE toolbar in the unified title bar (~52 pt): sidebar toggle · Back / Forward · the place's title · Map | List |
/// Cards, then search (⌘F) · Librarian (⌘L) · + New Entry (⌘N). A real NSToolbar (window dragging, the traffic lights,
/// full-screen behave as on any Mac app) whose two items host SwiftUI in AirPad's own styling (`NSUIViewToolbarItem`).
@MainActor
final class MacToolbarController: NSObject, NSToolbarDelegate {
    static let shared = MacToolbarController()
    static let leadingID = NSToolbarItem.Identifier("airpad.toolbar.leading")
    static let trailingID = NSToolbarItem.Identifier("airpad.toolbar.trailing")

    private var makeEnvironment: ((AnyView) -> AnyView)?
    /// The hosted item views (kept alive; the stills draw them too — the toolbar is AppKit, outside the UIWindow).
    private(set) var hosts: [NSToolbarItem.Identifier: UIHostingController<AnyView>] = [:]

    /// Puts the toolbar on the window's title bar once (`environment` adds the app's environment to the hosted views).
    func install(environment: @escaping (AnyView) -> AnyView) {
        makeEnvironment = environment
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let titlebar = scene.titlebar, titlebar.toolbar?.identifier != "AirPadMain" else { return }
        let toolbar = NSToolbar(identifier: "AirPadMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        titlebar.toolbar = toolbar
        titlebar.toolbarStyle = .unified
        titlebar.titleVisibility = .hidden
        titlebar.separatorStyle = .line
    }

    /// The Appearance override reaches the hosted items too (they aren't in the app's windows).
    func applyStyle(_ style: UIUserInterfaceStyle) {
        for host in hosts.values { host.overrideUserInterfaceStyle = style }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leadingID, .flexibleSpace, Self.trailingID]
    }
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leadingID, .flexibleSpace, Self.trailingID]
    }
    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            let root: AnyView
            switch id {
            case Self.leadingID: root = AnyView(MacToolbarLeading())
            case Self.trailingID: root = AnyView(MacToolbarTrailing())
            default: return nil
            }
            let host = UIHostingController(rootView: makeEnvironment?(root) ?? root)
            host.sizingOptions = .intrinsicContentSize
            host.view.backgroundColor = .clear
            host.overrideUserInterfaceStyle = AppearanceOverride.current().uiStyle
            hosts[id] = host
            let item = NSUIViewToolbarItem(itemIdentifier: id, uiView: host.view)
            item.label = id == Self.leadingID ? "Navigation" : "Search and actions"
            return item
        }
    }
}

/// The current place's scope for the view switch: the library, a collection, the Sample Library — nil elsewhere.
@MainActor func macViewScope(_ router: AppRouter, _ store: CorpusStore) -> CanvasScope? {
    switch router.entryMode {
    case .canvas: return .corpus
    case .collectionCanvas(let id): return .collection(id)
    case .sampleCanvas: return .nodeIDs(store.sampleNodeIDs)
    case .dashboard, .recents, .quikCapture: return nil
    }
}

/// The current place's title: the library or collection name, "AirPad" on Today.
@MainActor func macPlaceTitle(_ router: AppRouter, _ store: CorpusStore) -> String {
    switch router.entryMode {
    case .dashboard, .quikCapture: return "AirPad"
    case .recents: return "Recents"
    case .canvas: return "Library"
    case .sampleCanvas: return "Sample Library"
    case .collectionCanvas(let id):
        if id == NodeCollection.journalID { return "Journal" }
        return store.collections.first { $0.id == id }?.name ?? "Collection"
    }
}

/// A toolbar button: an SF Symbol in ink on a 30 pt round target, a light wash on hover, a stronger one when active.
struct MacToolbarIconButton: View {
    let systemName: String
    let help: String
    var active = false
    var id: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppearancePalette.ink.opacity(enabled ? (active ? 0.95 : 0.75) : 0.3))
                .frame(width: 32, height: 30)
                .background(Capsule().fill(AppearancePalette.ink.opacity(active ? 0.13 : (hovering && enabled ? 0.07 : 0))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }
}

/// D1 — Map | List | Cards as AirPad's segmented pill (the toolbar's view switch).
struct MacViewSwitch: View {
    let scope: CanvasScope
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        let current = store.filterState(for: scope).viewMode
        HStack(spacing: 2) {
            ForEach(ViewSwitchMenuContent.macDestinations, id: \.mode) { dest in
                let on = dest.mode == current || (dest.mode == .grid && current != .list && current != .systemGraph)
                Button {
                    guard !on else { return }
                    var s = store.filterState(for: scope)
                    s.viewMode = dest.mode
                    store.setFilterState(s, for: scope)
                } label: {
                    Text(dest.label)
                        .font(appFont.font(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(AppearancePalette.ink.opacity(on ? 0.95 : 0.65))
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(AppearancePalette.ink.opacity(on ? 0.14 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dest.label)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("toolbar.view.\(dest.label)")
            }
        }
        .padding(3)
        .background(Capsule().fill(AppearancePalette.ink.opacity(0.06)))
    }
}

struct MacToolbarLeading: View {
    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont
    @State private var layout = MacLayout.shared

    var body: some View {
        HStack(spacing: 4) {
            MacToolbarIconButton(systemName: "sidebar.left", help: layout.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                                 id: "toolbar.sidebar") { layout.sidebarVisible.toggle() }
            MacToolbarIconButton(systemName: "chevron.left", help: "Back", id: "toolbar.back") { router.perform(.back) }
                .disabled(!router.canGoBack)
            MacToolbarIconButton(systemName: "chevron.right", help: "Forward", id: "toolbar.forward") { router.perform(.forward) }
                .disabled(!router.canGoForward)
            Text(macPlaceTitle(router, store))
                .font(appFont.font(size: 15, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, 14)
                .accessibilityIdentifier("toolbar.title")
            if let scope = macViewScope(router, store), !store.isInDetailView {
                MacViewSwitch(scope: scope)
            }
        }
        .frame(height: 36)
        .fixedSize()
    }
}

struct MacToolbarTrailing: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.appBodyFont) private var appFont
    @State private var layout = MacLayout.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var librarian = router.librarian
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                TextField("Search", text: $librarian.searchText)
                    .textFieldStyle(.plain)
                    .font(appFont.font(size: 14))
                    .foregroundStyle(AppearancePalette.ink)
                    .focused($searchFocused)
                    .onKeyPress(.escape) { searchFocused = false; return .handled }
                    .accessibilityIdentifier("toolbar.search")
                if librarian.searchText.isEmpty {
                    Text("⌘F")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).stroke(AppearancePalette.ink.opacity(0.2)))
                } else {
                    Button { librarian.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(Capsule().fill(AppearancePalette.ink.opacity(searchFocused ? 0.10 : 0.06)))
            .overlay(Capsule().stroke(AppearancePalette.ink.opacity(searchFocused ? 0.25 : 0), lineWidth: 1))
            .padding(.trailing, 4)
            MacToolbarIconButton(systemName: "sidebar.right", help: layout.librarianOpen ? "Hide Librarian" : "Show Librarian",
                                 active: layout.librarianOpen, id: "toolbar.librarian") { router.perform(.librarian) }
            MacToolbarIconButton(systemName: "plus", help: "New Entry", id: "toolbar.newEntry") { router.perform(.newEntry) }
        }
        .frame(height: 36)
        .fixedSize()
        // ⌘F focuses the search; typing shows the results in the Librarian (it opens if closed).
        .onChange(of: router.commandRequest) { _, request in
            if request?.command == .find { searchFocused = true }
        }
        .onChange(of: librarian.searchText) { _, text in
            if !text.isEmpty, !layout.librarianOpen { layout.librarianOpen = true; router.librarianAtPeek = false }
        }
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
// MARK: - Self-test

/// Mac batch D — `-MacLayoutSelfTest` (with `-OpenMap`): the real NSToolbar (through the runtime), its hosted items,
/// ⌘F focusing the toolbar's search, ⌘L and ⌃⌘S, the column widths, and the overlay below 1,210 pt. Writes the hosted
/// toolbar items to `<tmp>/macshots/toolbar-leading.png` / `-trailing.png` (AppKit draws the toolbar, outside the window).
@MainActor
enum MacLayoutSelfTest {
    static var nsWindow: NSObject? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return nil }
        return (app.value(forKey: "windows") as? [NSObject])?.first { String(describing: type(of: $0)).contains("UINSWindow") }
    }

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let layout = MacLayout.shared
        let tc = MacToolbarController.shared

        // 1. The toolbar.
        let toolbar = nsWindow?.value(forKey: "toolbar") as? NSObject
        let ident = toolbar?.value(forKey: "identifier") as? String
        let items = (toolbar?.value(forKey: "items") as? [NSObject]) ?? []
        let ids = items.compactMap { $0.value(forKey: "itemIdentifier") as? String }
        row("window toolbar is AirPad's", ident == "AirPadMain", "identifier=\(ident ?? "nil")")
        row("items: leading · flexible space · trailing", ids == ["airpad.toolbar.leading", "NSToolbarFlexibleSpaceItem", "airpad.toolbar.trailing"], "\(ids)")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        row("unified title bar, title hidden", scene?.titlebar?.toolbarStyle == .unified && scene?.titlebar?.titleVisibility == .hidden)
        for (name, id) in [("leading", MacToolbarController.leadingID), ("trailing", MacToolbarController.trailingID)] {
            guard let v = tc.hosts[id]?.view else { row("\(name) item hosted", false); continue }
            row("\(name) item hosted and sized", v.bounds.width > 100 && v.bounds.height >= 30 && v.window != nil,
                "size \(v.bounds.size) window=\(v.window.map { String(describing: type(of: $0)) } ?? "nil")")
            let img = UIGraphicsImageRenderer(bounds: v.bounds).image { _ in v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? img.pngData()?.write(to: dir.appendingPathComponent("toolbar-\(name).png"))
        }
        if let w = nsWindow, let frame = w.value(forKey: "frame") as? CGRect,
           let content = (w.value(forKey: "contentLayoutRect") as? CGRect) {
            let bar = frame.height - content.height
            row("title bar + toolbar ~52 pt", bar >= 44 && bar <= 60, String(format: "%.0f pt", bar))
        }

        // 2. ⌘F focuses the toolbar search; typing opens the Librarian.
        layout.librarianOpen = false; await settle(0.6)
        router.perform(.find); await settle(1.0)
        let field = tc.hosts[MacToolbarController.trailingID]?.view.flatMap { firstResponder(in: $0) }
        row("⌘F focuses the toolbar's search", field != nil, "first responder \(field.map { String(describing: type(of: $0)) } ?? "none")")
        row("⌘F opens the Librarian (results show there)", layout.librarianOpen)
        router.librarian.searchText = "coffee"; await settle(1.0)
        row("search text reaches the Librarian", router.librarian.searchText == "coffee")
        router.librarian.searchText = ""; field?.resignFirstResponder(); await settle(0.5)

        // 3. ⌘L and ⌃⌘S.
        let open = layout.librarianOpen
        router.perform(.librarian); await settle(0.6)
        row("⌘L toggles the Librarian", layout.librarianOpen == !open)
        router.perform(.librarian); await settle(0.6)
        let side = layout.sidebarVisible
        layout.sidebarVisible.toggle(); await settle(0.6)
        row("sidebar toggles and is remembered", UserDefaults.standard.object(forKey: "mac.layout.sidebar.v1") as? Bool == !side)
        layout.sidebarVisible = side; await settle(0.6)

        // 4. Widths: sidebar 232, Librarian 360 (push-in at ≥ 1,210 pt), content takes the rest.
        if let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            func frameOf(_ id: String) -> CGRect? {
                func walk(_ v: UIView) -> UIView? {
                    if v.accessibilityIdentifier == id { return v }
                    for s in v.subviews { if let r = walk(s) { return r } }
                    return nil
                }
                return walk(win).map { $0.convert($0.bounds, to: win) }
            }
            row("window width measured", abs(layout.windowWidth - win.bounds.width) < 2, "layout \(layout.windowWidth) window \(win.bounds.width)")
            row("Librarian push-in at this width", layout.librarianFloats == (win.bounds.width < 1210), "floats=\(layout.librarianFloats)")
            _ = frameOf
        }
        // 4b. D7 — Tab into the Librarian focuses its Ask field; View › Hide Sidebar (⌃⌘S) toggles the sidebar.
        layout.librarianOpen = true; await settle(0.5)
        NotificationCenter.default.post(name: .macFocusLibrarianAsk, object: nil); await settle(1.0)
        let keyWin = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let ask = keyWin.flatMap { firstResponder(in: $0) }
        row("Tab into the Librarian focuses its Ask field", ask is UITextField || ask is UITextView, "first responder \(ask.map { String(describing: type(of: $0)) } ?? "none")")
        ask?.resignFirstResponder()
        let before = layout.sidebarVisible
        router.perform(.toggleSidebar); await settle(0.6)
        row("⌃⌘S (View › Hide Sidebar) toggles the sidebar", layout.sidebarVisible == !before)
        router.perform(.toggleSidebar); await settle(0.6)

        // 5. A citation (the transcript's openNode = pendingNodeNavigationID) opens the entry in the centre; the
        //    Librarian stays open beside it and reads that entry.
        layout.librarianOpen = true
        if let entry = store.nodes.first(where: { !$0.isPrivate && !$0.title.isEmpty }) {
            router.pendingNodeNavigationID = entry.id
            await settle(2.0)
            row("a cited entry opens in the centre, the Librarian beside it", store.isInDetailView && router.openEntryID == entry.id && layout.librarianOpen,
                "detail=\(store.isInDetailView) open=\(layout.librarianOpen)")
            row("the Librarian reads the open entry", router.librarian.selectedScope == .nodeIDs([entry.id]), "\(router.librarian.selectedScope)")
            router.perform(.back); await settle(1.2)
            row("back: the Librarian reads the library again", router.librarian.selectedScope == .corpus, "\(router.librarian.selectedScope)")
        }
        // 6. Floating chrome gone (D1): no view button / + / view pill / back button over the content.
        if let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
            var labels: [String] = []
            func walk(_ o: NSObject, _ d: Int) {
                guard d < 60 else { return }
                if let l = o.accessibilityLabel { labels.append(l) }
                if let i = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier, i == "captureButton" { labels.append("#captureButton") }
                if let v = o as? UIView { v.subviews.forEach { walk($0, d + 1) } }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, d + 1) } } }
            }
            walk(win, 0)
            let floats = labels.filter { $0.hasPrefix("View: ") || $0.hasSuffix(" View") || $0 == "#captureButton" }
            row("no floating view button / + / back over the content", floats.isEmpty, "found \(floats)")
        }
        return "[MacLayoutSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }

    static func firstResponder(in v: UIView) -> UIView? {
        if v.isFirstResponder { return v }
        for s in v.subviews { if let r = firstResponder(in: s) { return r } }
        return nil
    }
}
#endif
