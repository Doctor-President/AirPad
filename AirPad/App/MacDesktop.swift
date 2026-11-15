#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import FloatingPanel

/// Mac batch D — the desktop layout, T's picks (Ops `reference/mac-layout-2026-11-07.json`): one toolbar (D1), a sidebar
/// at 232 pt (D2), the content, and the Librarian as a push-in panel that floats over the content when the window is
/// too narrow for it (D3). Batch E (v3 picks, `reference/mac-layout-2026-11-14-v3.json`): the sidebar runs full height
/// with the window buttons at its top, the toolbar spans the content + Librarian (E1); the Librarian opens at 370 pt
/// (E2). Mac only: iPhone and iPad keep their layout.
@MainActor @Observable
final class MacLayout {
    static let shared = MacLayout()

    /// D fix-up F5 — both panels resize from their inner edge (drag the hairline); remembered.
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...300
    static let librarianWidthRange: ClosedRange<CGFloat> = 300...520
    static let sidebarWidthDefault: CGFloat = 232
    /// Batch E2 — T's v3 pick (was 360).
    static let librarianWidthDefault: CGFloat = 370
    /// The content column never gets narrower than this beside a pushed-in Librarian; when it would, the Librarian
    /// floats over the content instead (rounded, glass, inset 10 pt). 616 = batch D's 1,210 pt threshold at its default
    /// widths (1,210 − 232 − 360 − 2 hairlines); at E2's 370 pt the Librarian floats below a 1,220 pt window.
    static let contentMinWidth: CGFloat = 616

    private static let sidebarKey = "mac.layout.sidebar.v1"
    private static let librarianKey = "mac.layout.librarian.v1"
    static let sidebarWidthKey = "mac.layout.sidebarWidth.v1"
    static let librarianWidthKey = "mac.layout.librarianWidth.v1"

    /// The panels' widths: during an edge drag they follow the pointer (only the panel frames read them live).
    var sidebarWidth: CGFloat { didSet { widthsMoved() } }
    var librarianWidth: CGFloat { didSet { widthsMoved() } }

    /// E fix-up G2 — the widths the heavy layout uses (the content: Map camera/regions, List/Cards reflow; the
    /// Librarian's text; the toolbar's spacing). Outside a drag they ARE the widths; during one they follow at most
    /// ~10×/s and on release, so a drag moves only the panel frames (the content keeps its layout, clipped or with a
    /// strip of ground for the moment). Saved on release, not per pointer event (a defaults write wakes every
    /// @AppStorage reader in the app).
    private(set) var settledSidebarWidth: CGFloat = 0
    private(set) var settledLibrarianWidth: CGFloat = 0
    private(set) var columnDragging = false
    private var settleTask: Task<Void, Never>?
    static let dragSettleInterval: Double = 0.1

    func beginColumnDrag() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MacResizeUnfrozen") { return }   // G2 A/B: the old per-event layout
        #endif
        columnDragging = true
    }

    func endColumnDrag() {
        settleTask?.cancel(); settleTask = nil
        columnDragging = false
        settleWidths()
    }

    private func widthsMoved() {
        guard columnDragging else { settleWidths(); return }
        guard settleTask == nil else { return }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dragSettleInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.settledSidebarWidth = self.sidebarWidth
            self.settledLibrarianWidth = self.librarianWidth
            self.settleTask = nil
        }
    }

    private func settleWidths() {
        if settledSidebarWidth != sidebarWidth { settledSidebarWidth = sidebarWidth }
        if settledLibrarianWidth != librarianWidth { settledLibrarianWidth = librarianWidth }
        let d = UserDefaults.standard
        if d.double(forKey: Self.sidebarWidthKey) != Double(sidebarWidth) { d.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey) }
        if d.double(forKey: Self.librarianWidthKey) != Double(librarianWidth) { d.set(Double(librarianWidth), forKey: Self.librarianWidthKey) }
    }

    /// A panel's own layout width during a drag: the settled width while the panel is wider than it (a strip of its
    /// ground beside it), the live width when narrower — never wider than its frame (a view laid out wider than its
    /// slot made the Map's safe-area-ignoring SpriteView grow on every pass, to Metal's texture limit). The sidebar
    /// uses this; the Librarian (no SpriteKit, text that's costly to reflow) keeps the settled width, clipped.
    func panelLayoutWidth(live: CGFloat, settled: CGFloat) -> CGFloat? {
        columnDragging ? min(live, settled) : nil
    }

    /// Shown / hidden (⌃⌘S, the toolbar button); remembered.
    var sidebarVisible: Bool { didSet { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarKey) } }
    /// Open / closed (⌘L, the toolbar button); open by default; remembered.
    var librarianOpen: Bool { didSet { UserDefaults.standard.set(librarianOpen, forKey: Self.librarianKey) } }
    /// The window's width in points (the frame measures it).
    var windowWidth: CGFloat = 1350
    /// D7 — the region Tab last moved to (for the self-test and the sidebar's arrow keys).
    var focusedRegion: MacRegion?
    /// E1 — where AppKit puts the toolbar's first item (after the window buttons), in window points; measured from the
    /// toolbar once it's on screen (`MacWindowChrome.settle`), so the title starts at the content's edge.
    var toolbarLeadingX: CGFloat = 84
    /// F5 — follows from the widths: the content would drop below `contentMinWidth`. (G2: from the settled widths —
    /// the same outside a drag; during one the frame doesn't re-read per pointer event.)
    var librarianFloats: Bool {
        windowWidth - (sidebarVisible ? settledSidebarWidth + 1 : 0) - (settledLibrarianWidth + 1) < Self.contentMinWidth
    }
    /// The content column's width (window minus the sidebar), the floating Librarian's room.
    var contentWidth: CGFloat { windowWidth - (sidebarVisible ? settledSidebarWidth + 1 : 0) }
    /// E5 — floating, the Librarian always leaves a strip beside it for the open entry's own + (56 pt and its gaps):
    /// at the smallest window with both panels widest it draws a little narrower (the remembered width is untouched).
    var floatingLibrarianWidth: CGFloat { max(MacLayout.librarianWidthRange.lowerBound - 40, min(librarianWidth, contentWidth - Self.entryPlusStrip - 10)) }
    static let entryPlusStrip: CGFloat = 84
    var settledFloatingLibrarianWidth: CGFloat {
        max(MacLayout.librarianWidthRange.lowerBound - 40, min(settledLibrarianWidth, contentWidth - Self.entryPlusStrip - 10))
    }
    /// E5 — the open entry's floating + : 24 pt from the content's corner, or just left of a floating Librarian.
    var entryPlusTrailing: CGFloat { librarianOpen && librarianFloats ? floatingLibrarianWidth + 10 + 14 : 24 }

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
        sidebarWidth = (d.object(forKey: Self.sidebarWidthKey) == nil ? nil : CGFloat(d.double(forKey: Self.sidebarWidthKey)))
            .map { min(max($0, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound) } ?? Self.sidebarWidthDefault
        librarianWidth = (d.object(forKey: Self.librarianWidthKey) == nil ? nil : CGFloat(d.double(forKey: Self.librarianWidthKey)))
            .map { min(max($0, Self.librarianWidthRange.lowerBound), Self.librarianWidthRange.upperBound) } ?? Self.librarianWidthDefault
        settledSidebarWidth = sidebarWidth
        settledLibrarianWidth = librarianWidth
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
    /// F2 — the toolbar's height over the window's content (the UIWindow's top safe area, 52 pt).
    @State private var toolbarInset: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    /// The regions on screen, in Tab order.
    private var regions: [MacRegion] {
        (layout.sidebarVisible ? [.sidebar] : []) + [.content] + (layout.librarianOpen ? [.librarian] : [])
    }

    var body: some View {
        HStack(spacing: 0) {
            if layout.sidebarVisible {
                // G2 — the sidebar's SLOT in the row follows the settled width (the content beside it re-lays out ≤ 10×/s
                // during an edge drag); the sidebar and its hairline are drawn over the slot at the live width (over the
                // content's edge, or with a strip of ground, for the moment).
                Color.clear
                    .frame(width: layout.settledSidebarWidth + 1)
                    .overlay(alignment: .leading) { MacSidebarPanel(toolbarInset: toolbarInset, region: $region) }
                    .zIndex(1)
                    .transition(.move(edge: .leading))
            }
            // E1 — the toolbar spans the content + Librarian only: its band is drawn here (AppKit's title bar is made
            // transparent), with the hairline under it; the columns start below it (D fix-up F2).
            VStack(spacing: 0) {
                MacToolbarBand(height: toolbarInset).zIndex(1)
                // The Map's scene ignores the safe area and would draw up under the (now transparent) bar.
                columns.clipped()
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { layout.windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in layout.windowWidth = w }
        })
        .ignoresSafeArea(.container, edges: .top)
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if $0 > 0 { toolbarInset = $0 } }
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

    /// Content | Librarian, under the toolbar band.
    private var columns: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .focused($region, equals: .content)
                .overlay(alignment: .trailing) {
                    if layout.librarianOpen && layout.librarianFloats {
                        MacFloatingLibrarianPanel(hostScope: hostScope)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            if layout.librarianOpen && !layout.librarianFloats {
                // G2 — the Librarian's slot follows the settled width; the panel and its hairline are drawn over it at the
                // live width (as the sidebar's).
                Color.clear
                    .frame(width: layout.settledLibrarianWidth + 1)
                    .overlay(alignment: .trailing) { MacLibrarianPanel(hostScope: hostScope) }
                    .transition(.move(edge: .trailing))
            }
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

}

/// G2 — the panels at the pointer's (live) width, drawn over their settled slots. Only these read the live widths, so an
/// edge drag re-renders them and not the frame around the content.
private struct MacSidebarPanel: View {
    let toolbarInset: CGFloat
    var region: FocusState<MacRegion?>.Binding
    @State private var layout = MacLayout.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            // E1 — full height: its ground runs up under the (transparent) title bar, where the window buttons and the
            // sidebar toggle sit; the list starts below the bar.
            MacSidebar()
                .padding(.top, toolbarInset)
                .frame(width: layout.panelLayoutWidth(live: layout.sidebarWidth, settled: layout.settledSidebarWidth))
                .frame(width: layout.sidebarWidth, alignment: .leading)
                .clipped()
                .background { MacSidebar.ground(scheme).ignoresSafeArea() }
                .focusable()
                .focusEffectDisabled()
                .focused(region, equals: .sidebar)
                .overlay(alignment: .leading) {
                    // The focus is otherwise invisible on a pane: a slim accent bar on its leading edge.
                    if region.wrappedValue == .sidebar {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3).padding(.vertical, 8)
                    }
                }
            MacHairline()
                .overlay { MacResizeHandle(id: "resize.sidebar") { dx, start in
                    layout.sidebarWidth = MacLayout.clamp(start + dx, MacLayout.sidebarWidthRange)
                } startValue: { layout.sidebarWidth } }
        }
    }
}

private struct MacLibrarianPanel: View {
    let hostScope: CanvasScope
    @State private var layout = MacLayout.shared

    var body: some View {
        HStack(spacing: 0) {
            MacHairline()
                .overlay { MacResizeHandle(id: "resize.librarian") { dx, start in
                    layout.librarianWidth = MacLayout.clamp(start - dx, MacLayout.librarianWidthRange)
                } startValue: { layout.librarianWidth } }
            MacLibrarianColumn(hostScope: hostScope)
                .frame(width: layout.columnDragging ? layout.settledLibrarianWidth : nil)   // text reflows ≤ 10×/s
                .frame(width: layout.librarianWidth, alignment: .trailing)
                .clipped()
        }
    }
}

private struct MacFloatingLibrarianPanel: View {
    let hostScope: CanvasScope
    @State private var layout = MacLayout.shared

    var body: some View {
        MacLibrarianColumn(hostScope: hostScope)
            .frame(width: layout.columnDragging ? layout.settledFloatingLibrarianWidth : nil)
            .frame(width: layout.floatingLibrarianWidth, alignment: .trailing)
            .clipped()
            .overlay(alignment: .leading) {
                MacResizeHandle(id: "resize.librarian") { dx, start in
                    layout.librarianWidth = MacLayout.clamp(start - dx, MacLayout.librarianWidthRange)
                } startValue: { layout.librarianWidth }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppearancePalette.ink.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
            .padding(10)
    }
}

/// D fix-up F5 — an 8 pt grab zone over a column hairline: the left–right resize cursor on hover, a drag changes the
/// width (`apply(dx, widthAtStart)`).
struct MacResizeHandle: View {
    let id: String
    let apply: (_ dx: CGFloat, _ start: CGFloat) -> Void
    let startValue: () -> CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in MacCursor.resizeLeftRight(inside) }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if start == nil { MacLayout.shared.beginColumnDrag() }
                    let s = start ?? startValue()
                    start = s
                    apply(g.translation.width, s)
                }
                .onEnded { _ in start = nil; MacLayout.shared.endColumnDrag() })
            .accessibilityElement()
            .accessibilityLabel(id == "resize.sidebar" ? "Resize the sidebar" : "Resize the Librarian")
            .accessibilityIdentifier(id)
    }
}

/// The AppKit resize cursor, through the runtime (Catalyst has no SwiftUI pointer style for it).
enum MacCursor {
    static func resizeLeftRight(_ on: Bool) {
        guard let cls = NSClassFromString("NSCursor") as? NSObject.Type else { return }
        if on {
            (cls.perform(NSSelectorFromString("resizeLeftRightCursor"))?.takeUnretainedValue() as? NSObject)?
                .perform(NSSelectorFromString("push"))
        } else {
            _ = cls.perform(NSSelectorFromString("pop"))
        }
    }
}

extension MacLayout {
    static func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(v.rounded(), r.lowerBound), r.upperBound) }
}

/// E1 — the toolbar's band over the content + Librarian columns: the app's ground, a faint ink wash, a hairline under
/// it. AppKit draws the items over it (its title bar is transparent — `MacWindowChrome`).
struct MacToolbarBand: View {
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        AppearancePalette.ink.opacity(scheme == .dark ? 0.035 : 0.025)
            .background(AppearancePalette.bgBase)
            .frame(height: height)
            .overlay(alignment: .bottom) { Rectangle().fill(AppearancePalette.ink.opacity(0.10)).frame(height: 1) }
            .accessibilityHidden(true)
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

/// D2 — the sidebar (232 pt): AIRPAD (Today, Recents, Chats), LIBRARIES, JOURNALS, COLLECTIONS, each with its count.
/// A click goes there; the current place is highlighted; right-click on a collection offers what its Today menu does.
struct MacSidebar: View {
    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @State private var renameTarget: NodeCollection?
    @State private var deleteTarget: NodeCollection?
    @State private var colorTarget: CollectionColorTarget?   // E6

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

                // D fix-up B5 — Journals before the collections: last, it sat below a long collection list (off screen
                // at 840 pt with T's library, so the section looked missing).
                header("Journals")
                row("Journal", dot: dotColor(NodeCollection.journalID),
                    count: userNodes.filter { $0.journalDate != nil }.count,
                    selected: router.entryMode == .collectionCanvas(id: NodeCollection.journalID), id: "sidebar.journal") {
                    router.entryMode = .collectionCanvas(id: NodeCollection.journalID)
                }
                .contextMenu {
                    Button { router.entryMode = .collectionCanvas(id: NodeCollection.journalID) } label: { Label("Open", systemImage: "arrow.right.circle") }
                    Button { colorTarget = CollectionColorTarget(id: NodeCollection.journalID, name: "Journal") } label: { Label("Colour…", systemImage: "paintpalette") }
                }

                let collections = store.collections.filter { !$0.isSystem }
                if !collections.isEmpty {
                    header("Collections")
                    ForEach(collections) { c in
                        row(c.name, dot: dotColor(c.id), count: count(in: c.id),
                            selected: router.entryMode == .collectionCanvas(id: c.id), id: "sidebar.collection") {
                            router.entryMode = .collectionCanvas(id: c.id)
                        }
                        .contextMenu {
                            Button { router.entryMode = .collectionCanvas(id: c.id) } label: { Label("Open", systemImage: "arrow.right.circle") }
                            Button { renameTarget = c } label: { Label("Rename", systemImage: "pencil") }
                            Button { colorTarget = CollectionColorTarget(id: c.id, name: c.name) } label: { Label("Colour…", systemImage: "paintpalette") }
                            Button(role: .destructive) { deleteTarget = c } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("macSidebar")
        // D7 — with the sidebar focused, ↑ / ↓ go to the previous / next place.
        .onKeyPress(.downArrow) { step(+1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .appSheet(item: $renameTarget) { c in
            RenameCollectionSheet(collectionID: c.id, currentName: c.name)
        }
        .appSheet(item: $colorTarget) { t in   // E6 — right-click › Colour…
            CollectionColorSheet(collectionID: t.id, name: t.name)
        }
        #if DEBUG
        .task {   // E6 stills — `-OpenCollectionColor Film`
                guard let n = UserDefaults.standard.string(forKey: "OpenCollectionColor") else { return }
                for _ in 0..<80 where !store.collections.contains(where: { $0.name == n }) { try? await Task.sleep(nanoseconds: 250_000_000) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let c = store.collections.first(where: { $0.name == n }) { colorTarget = CollectionColorTarget(id: c.id, name: c.name) }
            }
            #endif
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
        p.append(.collectionCanvas(id: NodeCollection.journalID))
        p += store.collections.filter { !$0.isSystem }.map { .collectionCanvas(id: $0.id) }
        return p
    }

    private func step(_ d: Int) {
        let p = places
        let i = p.firstIndex(of: router.entryMode) ?? 0
        router.entryMode = p[min(max(i + d, 0), p.count - 1)]
    }

    private func count(in id: String) -> Int { store.hidingPrivate(store.nodes).filter { $0.collectionIDs.contains(id) }.count }

    /// E6 — the chosen colour, else Automatic.
    private func dotColor(_ id: String) -> Color { CollectionDot.color(id, light: scheme == .light, chosen: store.collectionColorHex(id)) }

    /// The sidebar's ground (full height, under the title bar too — E1).
    static func ground(_ scheme: ColorScheme) -> some View {
        AppearancePalette.ink.opacity(scheme == .dark ? 0.03 : 0.035).background(AppearancePalette.bgBase)
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
        // E1 — no AppKit separator or bar material: the sidebar's ground runs up under the window buttons and the band
        // over the content + Librarian (`MacToolbarBand`) carries the hairline.
        titlebar.separatorStyle = .none
        MacWindowChrome.settle()
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

/// The current place's title: the library or collection name, "Today" on Today (E3: the sidebar's name for it).
@MainActor func macPlaceTitle(_ router: AppRouter, _ store: CorpusStore) -> String {
    switch router.entryMode {
    case .dashboard: return "Today"
    case .quikCapture: return "AirPad"
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
        .onHover { hovering = $0; MacToolbarProbe.hovered(id, $0) }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }
}

/// E2 — the Librarian's toolbar button: its own glyph (the feather of the Ask field) and its name, highlighted while the
/// column is open (T's v3 pick "label").
struct MacLibrarianToolbarButton: View {
    let open: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image("AirPadLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(open ? LibrarianPillChrome.accent(scheme) : AnyShapeStyle(AppearancePalette.ink.opacity(0.75)))
                Text("Librarian")
                    .font(appFont.font(size: 13, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(open ? 0.95 : 0.75))
            }
            .padding(.leading, 6)
            .padding(.trailing, 11)
            .frame(height: 30)
            .background(Capsule().fill(AppearancePalette.ink.opacity(open ? 0.13 : (hovering ? 0.07 : 0))))
            .overlay(Capsule().strokeBorder(AppearancePalette.ink.opacity(open ? 0 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; MacToolbarProbe.hovered("toolbar.librarian", $0) }
        .help("Librarian (⌘L)")
        .macToolbarProbe("toolbar.librarian")
        .accessibilityLabel("Librarian")
        .accessibilityValue(open ? "Open" : "Closed")
        .accessibilityAddTraits(open ? .isSelected : [])
        .accessibilityIdentifier("toolbar.librarian")
    }
}

/// E1 — the window's title bar through AppKit (Catalyst has no API for these): transparent, so the sidebar's ground and
/// the toolbar band show under the window buttons and items; and where AppKit put the leading item.
@MainActor
enum MacWindowChrome {
    static var nsWindow: NSObject? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return nil }
        return (app.value(forKey: "windows") as? [NSObject])?.first { String(describing: type(of: $0)).contains("UINSWindow") }
    }

    /// Applies the transparent title bar and measures the leading item, now and once the toolbar has laid out.
    static func settle() {
        for delay in [0.0, 0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let w = nsWindow else { return }
                #if DEBUG
                // G1 observation: `-MacTitlebarProbe opaque` keeps D's opaque title bar (the A/B for the click test).
                if UserDefaults.standard.string(forKey: "MacTitlebarProbe") == "opaque" { return }
                #endif
                if (w.value(forKey: "titlebarAppearsTransparent") as? Bool) != true {
                    w.setValue(true, forKey: "titlebarAppearsTransparent")
                }
                #if DEBUG
                if UserDefaults.standard.string(forKey: "MacTitlebarProbe") != "unfixed" { keepToolbarClicks() }   // A/B
                #else
                keepToolbarClicks()
                #endif
                if let x = leadingItemX(), x > 20, x < 200, abs(x - MacLayout.shared.toolbarLeadingX) > 0.5 {
                    MacLayout.shared.toolbarLeadingX = x
                }
            }
        }
    }

    /// E fix-up G1 — with the title bar transparent, AppKit's frame view answers YES to `shouldStartWindowDragForEvent:`
    /// for a press anywhere in the bar, toolbar items included, so every click on the toolbar became a (zero-length)
    /// window drag and never reached the item (traced: `performWindowDragWithEvent:`, no `mouseDown:`; with D's opaque
    /// bar the same press answers NO and reaches the item). It now answers NO when the press lands on a toolbar control;
    /// everywhere else (the bar's empty part) keeps AppKit's answer, so the window still drags from the bar.
    static func keepToolbarClicks() {
        guard !toolbarClicksKept, let cls = NSClassFromString("NSThemeFrame"),
              let m = class_getInstanceMethod(cls, NSSelectorFromString("shouldStartWindowDragForEvent:")) else { return }
        toolbarClicksKept = true
        typealias Orig = @convention(c) (NSObject, Selector, NSObject) -> Bool
        let orig = unsafeBitCast(method_getImplementation(m), to: Orig.self)
        let sel = method_getName(m)
        let block: @convention(block) (NSObject, NSObject) -> Bool = { frame, event in
            pressIsOnToolbarControl(frame, event) ? false : orig(frame, sel, event)
        }
        // Only NSThemeFrame's own answer (an inherited one is added to it, not replaced in its superclass).
        if !class_addMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m)) {
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
    private static var toolbarClicksKept = false

    /// The press lands on one of the toolbar's controls: the frame view's hit-test finds one of AirPad's two items, and
    /// the point, in that item's hosted root, falls on a control's frame (2 pt slack). The items' empty runs — the strip
    /// beside the window buttons, around the title — stay draggable.
    private static func pressIsOnToolbarControl(_ frame: NSObject, _ event: NSObject) -> Bool {
        guard let p = event.value(forKey: "locationInWindow") as? CGPoint else { return false }
        typealias Hit = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
        let hitSel = NSSelectorFromString("hitTest:")
        let hit = unsafeBitCast(frame.method(for: hitSel), to: Hit.self)(frame, hitSel, p) as? NSObject
        for (id, trailing) in [(MacToolbarController.leadingID, false), (MacToolbarController.trailingID, true)] {
            guard let v = itemView(id), isDescendant(hit, of: v), let b = v.value(forKey: "bounds") as? CGRect else { continue }
            typealias Conv = @convention(c) (AnyObject, Selector, CGPoint, AnyObject?) -> CGPoint
            let sel = NSSelectorFromString("convertPoint:fromView:")
            let local = unsafeBitCast(v.method(for: sel), to: Conv.self)(v, sel, p, nil)
            let flipped = (v.value(forKey: "isFlipped") as? Bool) ?? false
            let q = CGPoint(x: local.x - b.minX, y: flipped ? local.y - b.minY : b.maxY - local.y)
            return MacToolbarProbe.rect.contains { key, r in
                MacToolbarProbe.trailingIDs.contains(key) == trailing && r.insetBy(dx: -2, dy: -2).contains(q)
            }
        }
        return false
    }

    static func itemView(_ id: NSToolbarItem.Identifier) -> NSObject? {
        guard let toolbar = nsWindow?.value(forKey: "toolbar") as? NSObject,
              let items = toolbar.value(forKey: "items") as? [NSObject],
              let item = items.first(where: { ($0.value(forKey: "itemIdentifier") as? String) == id.rawValue }) else { return nil }
        return item.value(forKey: "view") as? NSObject
    }

    private static func isDescendant(_ v: NSObject?, of ancestor: NSObject) -> Bool {
        var cur = v
        for _ in 0..<20 { guard let c = cur else { return false }; if c === ancestor { return true }; cur = c.value(forKey: "superview") as? NSObject }
        return false
    }

    /// The leading item's left edge in window points (its NSView's frame, summed up the view chain).
    static func leadingItemX() -> CGFloat? {
        guard let toolbar = nsWindow?.value(forKey: "toolbar") as? NSObject,
              let items = toolbar.value(forKey: "items") as? [NSObject],
              let item = items.first(where: { ($0.value(forKey: "itemIdentifier") as? String) == MacToolbarController.leadingID.rawValue }),
              var v = item.value(forKey: "view") as? NSObject else { return nil }
        var x: CGFloat = 0
        for _ in 0..<40 {
            x += (v.value(forKey: "frame") as? CGRect)?.minX ?? 0
            guard let up = v.value(forKey: "superview") as? NSObject else { break }
            v = up
        }
        return x
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
                .macToolbarProbe("toolbar.view.\(dest.label)")
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

    /// E1 — with the sidebar shown, the toggle sits at the trailing end of the sidebar's top (beside the window buttons)
    /// and ‹ › start at the content's edge; hidden, they follow the window buttons.
    /// G2 — from the settled sidebar width (the toolbar re-lays out ≤ 10×/s during an edge drag, not per event).
    private var toggleLead: CGFloat {
        layout.sidebarVisible ? max(0, layout.settledSidebarWidth - 6 - MacToolbarMetrics.toggleWidth - layout.toolbarLeadingX) : 0
    }
    private var afterToggle: CGFloat {
        layout.sidebarVisible
            ? max(4, layout.settledSidebarWidth + 1 + 8 - (layout.toolbarLeadingX + toggleLead + MacToolbarMetrics.toggleWidth))
            : 4
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: toggleLead, height: 1)
            MacToolbarIconButton(systemName: "sidebar.left", help: layout.sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)",
                                 id: "toolbar.sidebar") { layout.sidebarVisible.toggle() }
                .macToolbarProbe("toolbar.sidebar")
            Color.clear.frame(width: afterToggle, height: 1)
            HStack(spacing: 4) {
                MacToolbarIconButton(systemName: "chevron.left", help: "Back", id: "toolbar.back") { router.perform(.back) }
                    .disabled(!router.canGoBack)
                    .macToolbarProbe("toolbar.back")
                MacToolbarIconButton(systemName: "chevron.right", help: "Forward", id: "toolbar.forward") { router.perform(.forward) }
                    .disabled(!router.canGoForward)
                    .macToolbarProbe("toolbar.forward")
                Text(macPlaceTitle(router, store))
                    .font(appFont.font(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: MacToolbarMetrics.titleMax(layout), alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.trailing, 14)
                    .accessibilityIdentifier("toolbar.title")
                if let scope = macViewScope(router, store), !store.isInDetailView {
                    MacViewSwitch(scope: scope)
                }
            }
        }
        .frame(height: 36)
        .fixedSize()
        .coordinateSpace(.named(MacToolbarProbe.space))
        .animation(.easeOut(duration: 0.2), value: layout.sidebarVisible)
    }
}

/// Where each toolbar control sits inside its item (its hosted root's coordinates). E fix-up G1: the title bar uses it
/// to tell a press on a control (a click) from a press on the bar around them (a window drag); the self-tests turn it
/// into window points.
enum MacToolbarProbe {
    static let space = "macToolbarItem"
    @MainActor static var x: [String: CGFloat] = [:]
    @MainActor static var rect: [String: CGRect] = [:]
    /// The controls in the trailing item (the rest are in the leading one).
    static let trailingIDs: Set<String> = ["toolbar.search", "toolbar.librarian", "toolbar.newEntry"]
    /// The control the pointer is over (its hover state), for the real-click test.
    @MainActor static var hover: String?
    @MainActor static func hovered(_ id: String, _ inside: Bool) {
        #if DEBUG
        if inside { hover = id } else if hover == id { hover = nil }
        #endif
    }
}

extension View {
    func macToolbarProbe(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacToolbarProbe.space)) } action: {
            MacToolbarProbe.x[id] = $0.minX; MacToolbarProbe.rect[id] = $0
        }
    }
}

/// E1 — the toolbar's fixed sizes, and what the title / search may take at a given window width so the trailing item
/// never spills into AppKit's overflow menu (the minimum window is 900 pt).
@MainActor enum MacToolbarMetrics {
    static let toggleWidth: CGFloat = 32
    /// Search: 240 pt at a roomy window, narrower below.
    static func searchWidth(_ l: MacLayout) -> CGFloat {
        let room = l.windowWidth - (l.sidebarVisible ? l.settledSidebarWidth : 0)
        return room >= 1000 ? 240 : (room >= 860 ? 200 : 150)
    }
    /// The place's title truncates first (the sidebar shows the place too).
    static func titleMax(_ l: MacLayout) -> CGFloat {
        let start = l.sidebarVisible ? l.settledSidebarWidth + 9 : l.toolbarLeadingX + toggleWidth + 4
        // ‹ › 68 · title padding 22 · view switch ~205 · trailing (search + Librarian + + + gaps) · margins 40
        let rest = start + 68 + 22 + 205 + searchWidth(l) + 170 + 40
        return max(40, min(260, l.windowWidth - rest))
    }
}

struct MacToolbarTrailing: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.appBodyFont) private var appFont
    @State private var layout = MacLayout.shared
    @FocusState private var searchFocused: Bool
    @State private var searchHover = false

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
            .frame(width: MacToolbarMetrics.searchWidth(layout), height: 30)
            .background(Capsule().fill(AppearancePalette.ink.opacity(searchFocused ? 0.10 : (searchHover ? 0.09 : 0.06))))
            .overlay(Capsule().stroke(AppearancePalette.ink.opacity(searchFocused ? 0.25 : 0), lineWidth: 1))
            // G8 — a click anywhere on the capsule (the glass, the ⌘F hint) focuses the field.
            .contentShape(Capsule())
            .onTapGesture { searchFocused = true }
            .onHover { searchHover = $0; MacToolbarProbe.hovered("toolbar.search", $0) }
            .macToolbarProbe("toolbar.search")
            .padding(.trailing, 4)
            MacLibrarianToolbarButton(open: layout.librarianOpen) { router.perform(.librarian) }
            MacToolbarIconButton(systemName: "plus", help: "New Entry", id: "toolbar.newEntry") { router.perform(.newEntry) }
                .macToolbarProbe("toolbar.newEntry")
        }
        .frame(height: 36)
        .fixedSize()
        .coordinateSpace(.named(MacToolbarProbe.space))
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
            // Where the UIWindow sits: under the toolbar (full-size content) or below it, and its top safe area.
            if let uiw = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
                let topPad = uiw.safeAreaInsets.top
                row("measure: window \(Int(frame.width))×\(Int(frame.height)) · content \(Int(content.height)) · UIWindow \(Int(uiw.bounds.height)) · safe top \(Int(topPad))", true)
            }
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
            row("Librarian push-in at this width", layout.librarianFloats == (win.bounds.width - (layout.sidebarVisible ? layout.sidebarWidth + 1 : 0) - layout.librarianWidth - 1 < MacLayout.contentMinWidth), "floats=\(layout.librarianFloats)")
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
        // 7. Batch E1 — the sidebar runs full height: a transparent title bar, no AppKit separator, ‹ › start at the
        //    content's edge (sidebar shown) or after the toggle (hidden), and the toolbar never overflows at 900–1,920 pt.
        row("E1 title bar transparent", (nsWindow?.value(forKey: "titlebarAppearsTransparent") as? Bool) == true)
        row("E1 no AppKit separator", scene?.titlebar?.separatorStyle == UITitlebarSeparatorStyle.none)
        let ax = MacWindowChrome.leadingItemX()
        row("E1 leading item measured (AppKit)", ax != nil && abs((ax ?? 0) - layout.toolbarLeadingX) < 1,
            "AppKit x \(ax.map { String(format: "%.1f", $0) } ?? "nil") · layout \(layout.toolbarLeadingX)")
        func hostX(_ id: String) -> CGFloat? { MacToolbarProbe.x[id].map { $0 + (MacWindowChrome.leadingItemX() ?? layout.toolbarLeadingX) } }
        func visibleIDs() -> [String] {
            ((nsWindow?.value(forKey: "toolbar") as? NSObject)?.value(forKey: "visibleItems") as? [NSObject] ?? [])
                .compactMap { $0.value(forKey: "itemIdentifier") as? String }
        }
        let sidebarWas = layout.sidebarVisible, libWas = layout.librarianOpen
        if let r = scene?.sizeRestrictions, let ws = scene {
            let (minWas, maxWas) = (r.minimumSize, r.maximumSize)
            for width in [1350, 1180, 900, 1920] as [CGFloat] {
                let size = CGSize(width: width, height: 840)
                r.minimumSize = size; r.maximumSize = size
                var origin = ws.effectiveGeometry.systemFrame.origin; origin.x = max(0, min(origin.x, ws.screen.bounds.width - width))
                ws.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: origin, size: size)))
                await settle(1.2)
                for side in [true, false] {
                    layout.sidebarVisible = side; layout.librarianOpen = true; await settle(0.9)
                    let ids = visibleIDs()
                    let back = hostX("toolbar.back"), toggle = hostX("toolbar.sidebar")
                    let want = side ? layout.sidebarWidth + 9 : layout.toolbarLeadingX + MacToolbarMetrics.toggleWidth + 4
                    let ok = ids.contains(MacToolbarController.leadingID.rawValue) && ids.contains(MacToolbarController.trailingID.rawValue)
                        && back.map { abs($0 - want) <= 3 } == true
                        && (!side || toggle.map { $0 + MacToolbarMetrics.toggleWidth <= layout.sidebarWidth } == true)
                    row("E1 \(Int(layout.windowWidth)) pt, sidebar \(side ? "on" : "off"): both items visible, ‹ at \(side ? "the content's edge" : "the toggle")", ok,
                        "visible \(ids.count) · ‹ x \(back.map { String(format: "%.0f", $0) } ?? "nil") want \(Int(want)) · toggle x \(toggle.map { String(format: "%.0f", $0) } ?? "nil") · title max \(Int(MacToolbarMetrics.titleMax(layout))) · search \(Int(MacToolbarMetrics.searchWidth(layout)))")
                }
            }
            r.minimumSize = minWas; r.maximumSize = maxWas
        }
        layout.sidebarVisible = sidebarWas; layout.librarianOpen = libWas; await settle(0.6)

        return "[MacLayoutSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }

    static func firstResponder(in v: UIView) -> UIView? {
        if v.isFirstResponder { return v }
        for s in v.subviews { if let r = firstResponder(in: s) { return r } }
        return nil
    }
}
#endif
