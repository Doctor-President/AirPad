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
    /// E fix-up 5 (L5) — the old "widen for long reading" mode went; the drag edge goes wider instead: up to about half
    /// the window (never below 520), and a column never past the content's minimum. Remembered widths are kept up to this.
    static let librarianWidthCeiling: CGFloat = 1_200
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
    static let settingsWidthKey = "mac.layout.settingsWidth.v1"
    static let settingsWidthDefault: CGFloat = 420

    /// The panels' widths: during an edge drag they follow the pointer (only the panel frames read them live).
    var sidebarWidth: CGFloat { didSet { widthsMoved() } }
    var librarianWidth: CGFloat { didSet { widthsMoved() } }
    /// E fix-up 3 (H4) — Settings' own width in the same slot (the Librarian's range), remembered.
    var settingsWidth: CGFloat { didSet { widthsMoved() } }

    /// E fix-up G2 — the widths the heavy layout uses (the content: Map camera/regions, List/Cards reflow; the
    /// Librarian's text; the toolbar's spacing). Outside a drag they ARE the widths; during one they follow at most
    /// ~10×/s and on release, so a drag moves only the panel frames (the content keeps its layout, clipped or with a
    /// strip of ground for the moment). Saved on release, not per pointer event (a defaults write wakes every
    /// @AppStorage reader in the app).
    private(set) var settledSidebarWidth: CGFloat = 0
    private(set) var settledLibrarianWidth: CGFloat = 0
    private(set) var settledSettingsWidth: CGFloat = 0
    private(set) var columnDragging = false
    private var settleTask: Task<Void, Never>?
    static let dragSettleInterval: Double = 0.1

    /// E fix-up 5 (L5, T ruled 2026-11-17) — the header's switch: the right panel (Librarian or Settings) as its own
    /// COLUMN or FLOATING over the content, which then gets the full width beneath. Remembered. It's a choice for a wide
    /// window only: when a column would push the content under its minimum the panel floats anyway (and the switch
    /// hides); widening the window again brings back the choice.
    var floatChosen: Bool { didSet { UserDefaults.standard.set(floatChosen, forKey: Self.floatKey) } }
    private static let floatKey = "mac.layout.librarianFloat.v1"
    /// ⌘L and the toolbar's Librarian button: open / close the column (the panel model reads `librarianAtPeek`). With
    /// Settings in the slot, it closes Settings and shows the Librarian.
    func toggleLibrarian(_ router: AppRouter) {
        if settingsOpen { settingsOpen = false; librarianOpen = true } else { librarianOpen.toggle() }
        router.librarianAtPeek = !librarianOpen
    }

    // MARK: E fix-up 3 (H4) — Settings as a right slide-out (T ruled 2026-11-15 night)

    /// Settings in the Librarian's slot: it replaces the Librarian while open; `librarianOpen` is left alone, so the
    /// Librarian comes back on close (or stays closed). Not remembered across launches.
    var settingsOpen = false
    /// The section Settings opens on (a deep link: Web search, Models) and a serial that re-seeds the panel per open.
    private(set) var settingsAnchor: SettingsView.Anchor?
    private(set) var settingsSerial = 0
    func openSettings(_ anchor: SettingsView.Anchor? = nil) {
        if settingsOpen, anchor == nil { return }   // ⌘, / the gear again: it's already there, keep its place
        settingsAnchor = anchor
        settingsSerial += 1
        settingsOpen = true
    }
    func closeSettings() { settingsOpen = false }
    /// Something sits in the right slot (Settings or the Librarian), and the Librarian is the one showing.
    var rightPanelOpen: Bool { settingsOpen || librarianOpen }
    var librarianShowing: Bool { librarianOpen && !settingsOpen }
    /// The slot's width: Settings' while it's there, else the Librarian's.
    var rightWidth: CGFloat { settingsOpen ? settingsWidth : librarianWidth }
    var settledRightWidth: CGFloat { settingsOpen ? settledSettingsWidth : settledLibrarianWidth }

    /// L5 — the right panel's drag range at this window: 300 up to about half the window (at least 520). A column stops
    /// where the content would go under its minimum (a drag never flips it to floating); floating, it keeps the strip
    /// for the open entry's + beside it.
    var rightWidthRange: ClosedRange<CGFloat> {
        let room = librarianFloats
            ? contentWidth - Self.entryPlusStrip - 10
            : windowWidth - (sidebarVisible ? settledSidebarWidth + 1 : 0) - Self.contentMinWidth - 1
        let upper = max(Self.librarianWidthRange.upperBound, min((windowWidth / 2).rounded(), room.rounded()))
        return Self.librarianWidthRange.lowerBound...max(Self.librarianWidthRange.lowerBound, min(upper, Self.librarianWidthCeiling))
    }

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
            self.settledSettingsWidth = self.settingsWidth
            self.settleTask = nil
        }
    }

    private func settleWidths() {
        if settledSidebarWidth != sidebarWidth { settledSidebarWidth = sidebarWidth }
        if settledLibrarianWidth != librarianWidth { settledLibrarianWidth = librarianWidth }
        if settledSettingsWidth != settingsWidth { settledSettingsWidth = settingsWidth }
        let d = UserDefaults.standard
        if d.double(forKey: Self.settingsWidthKey) != Double(settingsWidth) { d.set(Double(settingsWidth), forKey: Self.settingsWidthKey) }
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
    /// F5 — a column fits: the content keeps `contentMinWidth` beside it. (G2: from the settled widths — the same
    /// outside a drag; during one the frame doesn't re-read per pointer event.)
    var columnFits: Bool {
        windowWidth - (sidebarVisible ? settledSidebarWidth + 1 : 0) - (settledRightWidth + 1) >= Self.contentMinWidth
    }
    /// L5 — floating by choice (the header's switch) or because a column wouldn't fit.
    var librarianFloats: Bool { floatChosen || !columnFits }
    /// The content column's width (window minus the sidebar), the floating Librarian's room.
    var contentWidth: CGFloat { windowWidth - (sidebarVisible ? settledSidebarWidth + 1 : 0) }
    /// E5 — floating, the Librarian always leaves a strip beside it for the open entry's own + (56 pt and its gaps):
    /// at the smallest window with both panels widest it draws a little narrower (the remembered width is untouched).
    var floatingLibrarianWidth: CGFloat { max(MacLayout.librarianWidthRange.lowerBound - 40, min(rightWidth, contentWidth - Self.entryPlusStrip - 10)) }
    static let entryPlusStrip: CGFloat = 84
    var settledFloatingLibrarianWidth: CGFloat {
        max(MacLayout.librarianWidthRange.lowerBound - 40, min(settledRightWidth, contentWidth - Self.entryPlusStrip - 10))
    }
    /// E5 — the open entry's floating + : 24 pt from the content's corner, or just left of a floating Librarian (or
    /// Settings, H4).
    var entryPlusTrailing: CGFloat { rightPanelOpen && librarianFloats ? floatingLibrarianWidth + 10 + 14 : 24 }
    /// E fix-up 4 (K6) — what a floating right panel covers of the content, from its trailing edge (its width and its
    /// 10 pt margins); 0 when the panel is docked or closed.
    var floatingPanelFootprint: CGFloat { rightPanelOpen && librarianFloats ? floatingLibrarianWidth + 20 : 0 }

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
            .map { min(max($0, Self.librarianWidthRange.lowerBound), Self.librarianWidthCeiling) } ?? Self.librarianWidthDefault
        settingsWidth = (d.object(forKey: Self.settingsWidthKey) == nil ? nil : CGFloat(d.double(forKey: Self.settingsWidthKey)))
            .map { min(max($0, Self.librarianWidthRange.lowerBound), Self.librarianWidthCeiling) } ?? Self.settingsWidthDefault
        floatChosen = d.bool(forKey: Self.floatKey)
        settledSidebarWidth = sidebarWidth
        settledLibrarianWidth = librarianWidth
        settledSettingsWidth = settingsWidth
        #if DEBUG
        // Stills: `-MacSidebar on|off`, `-MacLibrarian open|closed` (not remembered).
        if let s = d.string(forKey: "MacSidebar") { sidebarVisible = s == "on" }
        if let s = d.string(forKey: "MacLibrarian") { librarianOpen = s == "open" }
        if let s = d.string(forKey: "MacPanelFloat") { floatChosen = s == "on" }   // L5 stills
        #endif
    }
}

/// D2/D3 — sidebar | content | Librarian. The content takes what's left; below 1,210 pt the open Librarian floats over
/// its trailing edge instead of narrowing it.
/// D7 — the three regions Tab / ⇧Tab move between.
enum MacRegion: Hashable { case sidebar, content, librarian }

enum MacDesktopFrameDebug {
    /// K3 bench — starts the frame log in DEBUG or a `-D PERFLOG` Release (a no-op in the shipping build).
    @MainActor static func startBench() {
        #if DEBUG || PERFLOG
        MacFrameLog.shared.start()
        #endif
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MacFocusLog") { MacFocusProbe.start() }
        #endif
    }
    static var edgeEffectHidden: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "MacScrollEdgeEffect") == "shown" { return false }
        #endif
        return true
    }
}

#if DEBUG
/// E fix-up 5 (L3) — `-MacFocusLog YES`: every UIKit focus move, with what took focus and its frame in the window, so a
/// focus ring on the whole window can be traced to the item that drew it.
@MainActor enum MacFocusProbe {
    private static var token: NSObjectProtocol?
    static func start() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            MainActor.assumeIsolated {
                func describe(_ item: UIFocusItem?) -> String {
                    guard let item else { return "nil" }
                    var r = item.frame
                    if let v = item as? UIView, let w = v.window { r = v.convert(v.bounds, to: w) }
                    let win = (item as? UIView)?.window?.bounds.size ?? .zero
                    var chain = String(describing: type(of: item))
                    if let v = item as? UIView {
                        var s = v.superview; var n = 0
                        while let x = s, n < 4 { chain += " < " + String(describing: type(of: x)); s = x.superview; n += 1 }
                    }
                    return "\(chain) frame=\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)) window=\(Int(win.width))x\(Int(win.height)) effect=\(item.focusEffect.map { String(describing: type(of: $0)) } ?? "nil")"
                }
                NSLog("[FOCUS] next=%@ prev=%@ heading=%lu", describe(ctx?.nextFocusedItem), describe(ctx?.previouslyFocusedItem),
                      ctx?.focusHeading.rawValue ?? 0)
            }
        }
        NSLog("[FOCUS] probe on")
    }
}
#endif

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
        (layout.sidebarVisible ? [.sidebar] : []) + [.content] + (layout.librarianShowing ? [.librarian] : [])
    }

    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
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
        // E fix-up 2 — the controls in the bar itself (the overlay ignores the top safe area with the rest).
        .overlay(alignment: .top) {
            if MacToolbarController.controlsInWindow { MacToolbarInWindow(height: toolbarInset) }
        }
        .ignoresSafeArea(.container, edges: .top)
        // E fix-up 4 (K1) — no top scroll-edge effect on the Mac. iOS 26 lays a touch-passthrough ScrollEdgeEffectView
        // over the top of every scroll view (Settings' list, the List view, the sidebar) that reaches up into the
        // title-bar band; a press on a toolbar control above one, made just after the pointer arrives, never became a
        // UIKit touch (AppKit and Catalyst's translator got it; UIKit cancelled it at the release). Real clicks with
        // Settings open, Librarian pressed 0.12 s after arriving: 4/4 lost with the effect, 0/4 without. Our bar is
        // drawn by us, so the effect had nothing to blend under. DEBUG `-MacScrollEdgeEffect shown` = the A/B.
        .scrollEdgeEffectHidden(MacDesktopFrameDebug.edgeEffectHidden, for: .top)
        .onAppear { MacDesktopFrameDebug.startBench() }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: {
            if $0 > 0 { toolbarInset = MacToolbarController.route == .none ? 52 : $0 }
        }
        .animation(.easeOut(duration: 0.2), value: layout.sidebarVisible)
        .animation(.easeOut(duration: 0.2), value: layout.librarianOpen)
        .animation(.easeOut(duration: 0.2), value: layout.settingsOpen)
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
            if layout.rightPanelOpen && !layout.librarianFloats {
                // G2 — the Librarian's slot follows the settled width; the panel and its hairline are drawn over it at the
                // live width (as the sidebar's). H4 — Settings takes the same slot at its own width.
                Color.clear
                    .frame(width: layout.settledRightWidth + 1)
                    .transition(.move(edge: .trailing))
            }
        }
        // E fix-up 5 (L5) — ONE panel over the row, docked over its slot or floating over the content: the header's
        // column / floating switch restyles it in place, so an open chat (and the panel's scroll) stays where it was.
        // (Two branches made a new Librarian on every switch: an open chat dropped back to the panel's home.)
        .overlay(alignment: .trailing) {
            if layout.rightPanelOpen {
                MacRightPanel(hostScope: hostScope)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
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

/// L5 — the right slot's panel, docked (K4: flush in its column, a hairline where it meets the content) or floating
/// (K4: one soft corner all round, inset 10 pt, a shadow). The same view either way: only its styling follows
/// `librarianFloats`, never its structure, so the Librarian or Settings inside keeps its state across the switch.
private struct MacRightPanel: View {
    let hostScope: CanvasScope
    @State private var layout = MacLayout.shared

    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        let floats = layout.librarianFloats
        let shape = RoundedRectangle(cornerRadius: floats ? LibrarianPanelShape.corner : 0, style: .continuous)
        HStack(spacing: 0) {
            MacHairline()
                .opacity(floats ? 0 : 1)
                .frame(width: floats ? 0 : 1)
            MacRightSlotContent(hostScope: hostScope)
                // text reflows ≤ 10×/s during an edge drag
                .frame(width: layout.columnDragging ? (floats ? layout.settledFloatingLibrarianWidth : layout.settledRightWidth) : nil)
                .frame(width: floats ? layout.floatingLibrarianWidth : layout.rightWidth, alignment: .trailing)
                .clipped()
                .environment(\.librarianPanelShape, floats ? .macFloating : .macDocked)
        }
        .overlay(alignment: .leading) { MacRightSlotResizeHandle().offset(x: floats ? 0 : -3.5) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(AppearancePalette.ink.opacity(floats ? 0.10 : 0), lineWidth: 1))
        .shadow(color: .black.opacity(floats ? 0.22 : 0), radius: 18, y: 6)
        .padding(floats ? 10 : 0)
    }
}

/// H4 — the right slot's content: Settings while it's open, else the Librarian.
private struct MacRightSlotContent: View {
    let hostScope: CanvasScope
    @State private var layout = MacLayout.shared
    var body: some View {
        if layout.settingsOpen {
            MacSettingsColumn()
        } else {
            MacLibrarianColumn(hostScope: hostScope)
        }
    }
}

/// The right slot's edge: drags the width of whichever panel is in it (each remembers its own, in the same range).
private struct MacRightSlotResizeHandle: View {
    @State private var layout = MacLayout.shared
    var body: some View {
        if layout.settingsOpen {
            MacResizeHandle(id: "resize.settings") { dx, start in
                layout.settingsWidth = MacLayout.clamp(start - dx, layout.rightWidthRange)
            } startValue: { layout.settingsWidth }
        } else {
            MacResizeHandle(id: "resize.librarian") { dx, start in
                layout.librarianWidth = MacLayout.clamp(start - dx, layout.rightWidthRange)
            } startValue: { layout.librarianWidth }
        }
    }
}

/// E fix-up 3 (H4) — Settings in the right slot: the same screens as the iPhone's sheet (each section pushes with a
/// ‹ back to the panel's home), beside the live view; Done closes it.
struct MacSettingsColumn: View {
    @State private var layout = MacLayout.shared
    var body: some View {
        SettingsView(initialAnchor: layout.settingsAnchor, inPanel: { layout.closeSettings() })
            .id(layout.settingsSerial)   // a deep link (Web search, Models) re-seeds the panel's path
            .background(AppearancePalette.bgBase)
            .accessibilityIdentifier("macSettingsPanel")
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

/// E fix-up 5 (L5, T ruled 2026-11-17) — the right panel's header switch between a COLUMN and FLOATING over the content
/// (the Librarian's ⤢ was "widen for reading", which T found did nothing meaningful). The icon and tooltip say what a
/// click does. Sweep 1 · N7 [T ruled "yes"]: shown at ANY width. Choosing Column on a window too narrow for one widens
/// the window by what the column needs (animated, as Pages' sidebar does), as far as the screen allows; with no room on
/// the screen it stays floating and says "Widen the window to dock". Narrowing the window by hand still floats the
/// panel (content ≥ 616 pt) and the choice comes back when it's wide again (`floatChosen` is untouched by that).
struct MacPanelFloatSwitch: View {
    @State private var layout = MacLayout.shared
    var body: some View {
        let floating = layout.librarianFloats
        let noRoom = floating && !layout.floatChosen && MacWindowFrame.widthNeededForColumn(layout) > MacWindowFrame.roomToWiden()
        let tip = noRoom ? "Widen the window to dock" : (floating ? "Show as column" : "Float over content")
        Button { toggle() } label: {
            Image(systemName: floating ? "sidebar.right" : "rectangle.on.rectangle")
                .font(.system(size: 13, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppearancePalette.ink.opacity(noRoom ? 0.35 : 0.7))
        .help(tip)
        .accessibilityLabel(tip)
        .accessibilityIdentifier("macPanelFloatSwitch")
    }

    private func toggle() {
        guard layout.librarianFloats else { layout.floatChosen = true; return }
        let need = MacWindowFrame.widthNeededForColumn(layout)
        if need > 0 {
            guard need <= MacWindowFrame.roomToWiden() else { return }   // no room: stays floating (the tooltip says so)
            MacWindowFrame.widen(by: need)
        }
        layout.floatChosen = false
    }
}

/// Sweep 1 · N7 — the window's frame through AppKit (Catalyst's scene geometry request doesn't animate).
@MainActor
enum MacWindowFrame {
    /// Points the window must grow for the right panel to fit as a column (0 = it fits).
    static func widthNeededForColumn(_ l: MacLayout) -> CGFloat {
        let content = l.windowWidth - (l.sidebarVisible ? l.settledSidebarWidth + 1 : 0) - (l.settledRightWidth + 1)
        return max(0, (MacLayout.contentMinWidth - content).rounded(.up))
    }
    private static func rect(_ o: NSObject?, _ key: String) -> CGRect? { (o?.value(forKey: key) as? NSValue)?.cgRectValue }
    /// How much wider the window can get on its screen (the visible frame: no menu bar, no Dock).
    static func roomToWiden() -> CGFloat {
        let w = MacWindowChrome.nsWindow
        guard let f = rect(w, "frame"), let v = rect(w?.value(forKey: "screen") as? NSObject, "visibleFrame") else { return 0 }
        return max(0, v.width - f.width)
    }
    /// Grow the window by `dx` (animated), keeping its left edge unless that would push it off the screen's right edge.
    static func widen(by dx: CGFloat) {
        let w = MacWindowChrome.nsWindow
        guard let w, var f = rect(w, "frame"), let v = rect(w.value(forKey: "screen") as? NSObject, "visibleFrame") else { return }
        f.size.width = min(f.width + dx, v.width)
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        let sel = NSSelectorFromString("setFrame:display:animate:")
        guard let m = class_getInstanceMethod(type(of: w), sel) else { return }
        typealias SetFrame = @convention(c) (AnyObject, Selector, CGRect, Bool, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: SetFrame.self)(w, sel, f, true, true)
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
/// it. The controls are drawn over it in the same window (`MacToolbarInWindow`; the title bar is transparent).
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

/// E fix-up 2 — the toolbar's controls drawn in the main window, across its top (the window buttons' strip, then the
/// band): leading controls from the window buttons, trailing ones at the right edge. The empty parts drag the window.
struct MacToolbarInWindow: View {
    let height: CGFloat
    @State private var layout = MacLayout.shared
    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        HStack(spacing: 0) {
            MacToolbarLeading().padding(.leading, layout.toolbarLeadingX)
            Spacer(minLength: 0)
            MacToolbarTrailing().padding(.trailing, 8)
        }
        .frame(height: height)
        .background(MacWindowDragArea())
    }
}

/// The bar's empty parts: a press drags the window (AppKit's `performWindowDragWithEvent:` with the press), a double
/// click does what the title bar's double click does in System Settings (zoom, minimise or nothing).
struct MacWindowDragArea: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { DragView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class DragView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            let g = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            g.minimumPressDuration = 0
            addGestureRecognizer(g)
        }
        required init?(coder: NSCoder) { fatalError() }
        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            MacWindowChrome.dragOrZoomWithCurrentEvent()
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
                .contextMenu { analyzeMenuItem }   // K5
                if !store.sampleNodeIDs.isEmpty {
                    row("Sample Library", icon: "sparkles.rectangle.stack",
                        count: store.hidingPrivate(store.nodes).filter { store.isSample($0.id) }.count,
                        selected: router.entryMode == .sampleCanvas, id: "sidebar.sample") {
                        router.entryMode = .sampleCanvas
                    }
                    .contextMenu { analyzeMenuItem }
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
                    if !CollectionColors.retired {
                        Button { colorTarget = CollectionColorTarget(id: NodeCollection.journalID, name: "Journal") } label: { Label("Colour…", systemImage: "paintpalette") }
                    }
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
                            if !CollectionColors.retired {
                                Button { colorTarget = CollectionColorTarget(id: c.id, name: c.name) } label: { Label("Colour…", systemImage: "paintpalette") }
                            }
                            Button(role: .destructive) { deleteTarget = c } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("macSidebar")
        // E fix-up 3 (H4) — Settings: a gear at the sidebar's foot, always there (the list scrolls above it). After the
        // sidebar's identifier, which would otherwise name the gear too.
        .safeAreaInset(edge: .bottom, spacing: 0) { MacSidebarSettingsButton() }
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
    private func dotColor(_ id: String) -> Color? {   // sweep 1 · N16: retired → no dot (collections go by name)
        CollectionColors.retired ? nil : CollectionDot.color(id, light: scheme == .light, chosen: store.collectionColorHex(id))
    }

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

    /// E fix-up 4 (K5, T ruled) — Analyze on a library's right-click menu (the same run as the Map's button).
    private var analyzeMenuItem: some View {
        Button { MacAnalyze.shared.run(store) } label: { Label("Analyze Library", systemImage: "point.3.connected.trianglepath.dotted") }
            .disabled(MacAnalyze.shared.running)
    }

    private func row(_ title: String, icon: String? = nil, dot: Color? = nil, count: Int? = nil, selected: Bool, id: String,
                     action: @escaping () -> Void) -> some View {
        MacSidebarRow(title: title, icon: icon, dot: dot, count: count, selected: selected, action: action)
            .accessibilityIdentifier(id)
    }
}

/// E fix-up 4 (K5, T ruled 2026-11-16 "Map") — Analyze where people look for it: a small button in the Map's bottom-left
/// corner (clear of the floating Librarian on the right), naming each step while it runs. The same run backs View ›
/// Analyze Library and a library's right-click menu. The steps are the real ones: grouping (clusters + neighbourhoods,
/// on the main thread), the Map re-forming its regions, then naming any new region (Foundation Models, when it runs).
@MainActor @Observable
final class MacAnalyze {
    static let shared = MacAnalyze()
    enum Phase: Equatable { case grouping, forming, naming, done }
    private(set) var phase: Phase?
    var running: Bool { phase != nil && phase != .done }

    var label: String {
        switch phase {
        case .grouping: "Grouping entries…"
        case .forming: "Forming regions…"
        case .naming: "Naming regions…"
        case .done: "Map updated"
        case nil: "Analyze"
        }
    }

    func run(_ store: CorpusStore) {
        guard !running else { return }
        Task { @MainActor in
            phase = .grouping
            try? await Task.sleep(for: .milliseconds(60))   // the label reaches the screen before the main-thread pass
            store.runCorpusAnalysis(trigger: .manual)        // clusters + neighbourhoods, then asks the Map to re-form
            phase = .forming
            try? await Task.sleep(for: .milliseconds(900))  // the Map's re-form and its settle
            var waited = 0.0
            while SubstrateClusterLabelService.shared.isLabeling, waited < 60 {
                phase = .naming
                try? await Task.sleep(for: .milliseconds(250)); waited += 0.25
            }
            phase = .done
            try? await Task.sleep(for: .seconds(1.6))
            if phase == .done { phase = nil }
        }
    }
}

struct MacAnalyzeButton: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont
    @State private var analyze = MacAnalyze.shared
    @State private var hovering = false

    var body: some View {
        Button { analyze.run(store) } label: {
            HStack(spacing: 6) {
                if analyze.running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: analyze.phase == .done ? "checkmark" : "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(analyze.label).font(appFont.font(size: 12, weight: .medium, relativeTo: .caption1))
            }
            .foregroundStyle(AppearancePalette.ink.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(AppearancePalette.ink.opacity(hovering ? 0.24 : 0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(analyze.running)
        .onHover { hovering = $0 }
        .help("Analyze the library: regroup entries and re-form the Map's regions")
        .accessibilityIdentifier("map.analyze")
        .accessibilityValue(analyze.label)
    }
}

/// H4 — the sidebar's gear: opens Settings in the right slot (again: closes it). Lit while Settings is open.
private struct MacSidebarSettingsButton: View {
    @State private var layout = MacLayout.shared
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack {
            Button { layout.settingsOpen ? layout.closeSettings() : layout.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(layout.settingsOpen ? 0.95 : 0.7))
                    .frame(width: 32, height: 30)
                    .background(Capsule().fill(AppearancePalette.ink.opacity(layout.settingsOpen ? 0.13 : (hovering ? 0.07 : 0))))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityValue(layout.settingsOpen ? "Open" : "Closed")
            .accessibilityIdentifier("sidebar.settings")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background { MacSidebar.ground(scheme) }   // the list scrolls under the foot, not through it
        .overlay(alignment: .top) { Rectangle().fill(AppearancePalette.ink.opacity(0.08)).frame(height: 1) }
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
/// Cards, then search (⌘F) · Librarian (⌘L) · + New Entry (⌘N). A real NSToolbar (the bar's height, the traffic lights,
/// full-screen behave as on any Mac app). E fix-up 2: it holds NO items: under E1's transparent bar Catalyst delivered
/// every click on a hosted item to the main window beneath it (the item never saw one), so the controls are drawn in the
/// main window itself (`MacToolbarInWindow`), which is where the clicks arrive.
@MainActor
final class MacToolbarController: NSObject, NSToolbarDelegate {
    static let shared = MacToolbarController()
    static let leadingID = NSToolbarItem.Identifier("airpad.toolbar.leading")
    static let trailingID = NSToolbarItem.Identifier("airpad.toolbar.trailing")

    /// E fix-up 2 — where the toolbar's controls live. `.items`: AppKit toolbar items hosting SwiftUI (D1/E1, dead to
    /// the mouse under E1's transparent bar). `.empty`: an NSToolbar with no items (bar height, window buttons) and the
    /// controls drawn in the main window. `.none`: no NSToolbar, controls in the main window. (Observation switch.)
    enum Route: String { case items, empty, none }
    static let route: Route = {
        #if DEBUG
        if let r = UserDefaults.standard.string(forKey: "MacToolbarRoute").flatMap(Route.init(rawValue:)) { return r }
        #endif
        return .empty
    }()
    static var controlsInWindow: Bool { route != .items }

    private var makeEnvironment: ((AnyView) -> AnyView)?
    /// The hosted item views (kept alive; the stills draw them too — the toolbar is AppKit, outside the UIWindow).
    private(set) var hosts: [NSToolbarItem.Identifier: UIHostingController<AnyView>] = [:]

    /// Puts the toolbar on the window's title bar once (`environment` adds the app's environment to the hosted views).
    func install(environment: @escaping (AnyView) -> AnyView) {
        makeEnvironment = environment
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let titlebar = scene.titlebar, titlebar.toolbar?.identifier != "AirPadMain" else { return }
        if Self.route == .none {
            titlebar.toolbar = nil
            titlebar.titleVisibility = .hidden
            titlebar.separatorStyle = .none
            MacLayout.shared.toolbarLeadingX = 96
            MacWindowChrome.settle()
            return
        }
        let toolbar = NSToolbar(identifier: "AirPadMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if Self.controlsInWindow { MacLayout.shared.toolbarLeadingX = 96 }
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
        Self.route == .items ? [Self.leadingID, .flexibleSpace, Self.trailingID] : []
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
            // E fix-up 3 (H1) — the button's own look changes at once; only the column slides (the frame's 0.2 s ease).
            .animation(nil, value: open)
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

    /// The app's current AppKit event (a press on the bar's empty part): a double click zooms / minimises as the user's
    /// title-bar setting says, a single press starts AppKit's own window drag.
    static func dragOrZoomWithCurrentEvent() {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject,
              let event = app.value(forKey: "currentEvent") as? NSObject, let w = nsWindow else { return }
        #if DEBUG
        NSLog("[MacChrome] bar press: event type %@, clicks %@", "\(event.value(forKey: "type") ?? "?")",
              "\(event.value(forKey: "clickCount") ?? "?")")
        #endif
        guard (event.value(forKey: "type") as? UInt) == 1 else { return }   // NSEventTypeLeftMouseDown
        if (event.value(forKey: "clickCount") as? Int ?? 1) >= 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "None": return
            case "Minimize": w.perform(NSSelectorFromString("performMiniaturize:"), with: nil)
            default: w.perform(NSSelectorFromString("performZoom:"), with: nil)
            }
            return
        }
        w.perform(NSSelectorFromString("performWindowDragWithEvent:"), with: event)
    }

    /// E fix-up 2 — while the pointer is over a toolbar control, AppKit's own title-bar drag is off (`isMovable` false),
    /// so a press that wanders a few points stays the control's (real clicks: a 3 / 8 pt wander on Map dragged the window
    /// 3 / 8 pt). The bar's empty part keeps AppKit's drag. Only while over a control: the system doesn't move a
    /// non-movable window on a display change (Apple's `isMovable` doc).
    static func setPointerOverControl(_ id: String, _ over: Bool) {
        if over { controlsUnderPointer.insert(id) } else { controlsUnderPointer.remove(id) }
        var movable = controlsUnderPointer.isEmpty
        #if DEBUG
        if UserDefaults.standard.string(forKey: "MacWindowMovable") == "yes" { movable = true }   // A/B
        #endif
        guard let w = nsWindow, (w.value(forKey: "movable") as? Bool) != movable else { return }
        w.setValue(movable, forKey: "movable")
        #if DEBUG
        NSLog("[MacChrome] movable %@ (%@)", movable ? "yes" : "no", id)
        #endif
    }
    private static var controlsUnderPointer: Set<String> = []

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
                if MacToolbarController.controlsInWindow { return }
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

    /// E fix-up 3 (H1) — the segment just clicked, lit at once; the view itself follows a frame later (building the Map or
    /// the List takes 100–200 ms, and the switch's look would otherwise wait for it).
    @State private var pending: ViewMode?

    var body: some View {
        let current = pending ?? store.filterState(for: scope).viewMode
        HStack(spacing: 2) {
            ForEach(ViewSwitchMenuContent.macDestinations, id: \.mode) { dest in
                let on = dest.mode == current || (dest.mode == .grid && current != .list && current != .systemGraph)
                Button {
                    MacClickTrace.mark("view.\(dest.label)")
                    guard !on else { return }
                    pending = dest.mode
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                        var s = store.filterState(for: scope)
                        s.viewMode = dest.mode
                        store.setFilterState(s, for: scope)
                        pending = nil
                    }
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
                                 id: "toolbar.sidebar") { MacClickTrace.mark("sidebar"); layout.sidebarVisible.toggle() }
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
    /// E fix-up 2 — each control's frame in the main window (the controls live there now; tests turn it into window points).
    @MainActor static var windowRect: [String: CGRect] = [:]
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

#if DEBUG || PERFLOG
/// E fix-up 4 (K3) — the performance bench (DEBUG, or a Release built with `-D PERFLOG`; never the shipping build).
/// `-MacFrameLog`: every display-link interval on the main thread, 120 to a line ("[FrameLog] t=<wall ms> dt=<ms,…>"), so
/// a scroll's frame times read against rperf's steps (scripts/mac/perf/k3frames.py). `-MacPerfAB <name>`: switch one
/// suspect off for an A/B (read by the views that name it).
@MainActor final class MacFrameLog: NSObject {
    static let shared = MacFrameLog()
    static let ab = UserDefaults.standard.string(forKey: "MacPerfAB") ?? ""
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var buf: [Double] = []
    private var bufStart: Double = 0
    func start() {
        guard ProcessInfo.processInfo.arguments.contains("-MacFrameLog"), link == nil else { return }
        NSLog("[FrameLog] screen max %d fps · A/B %@", UIScreen.main.maximumFramesPerSecond, Self.ab.isEmpty ? "none" : Self.ab)
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 {
            if buf.isEmpty { bufStart = Date().timeIntervalSince1970 * 1000 }
            buf.append((now - last) * 1000)
            if buf.count >= 120 {
                NSLog("[FrameLog] t=%.0f dt=%@", bufStart, buf.map { String(format: "%.1f", $0) }.joined(separator: ","))
                buf.removeAll()
            }
        }
        last = now
    }
}
#endif

/// E fix-up 3 (H1) — DEBUG `-MacClickTrace`: when each toolbar action runs, how old its click is (the AppKit event's
/// timestamp), and every main-thread frame gap over 40 ms, all on the wall clock `rlat` prints, so a click's
/// latency splits into delivery · action · render. Release: no-op.
@MainActor enum MacClickTrace {
    static func mark(_ label: String) {
        #if DEBUG
        guard on else { return }
        let ev = (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue().value(forKey: "currentEvent") as? NSObject
        let age = (ev?.value(forKey: "timestamp") as? Double).map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 } ?? -1
        NSLog("[ClickTrace] action %@ t=%.0f eventAge=%.0f type=%@", label, CFAbsoluteTimeGetCurrent() * 1000, age,
              "\(ev?.value(forKey: "type") ?? "-")")
        #endif
    }
    #if DEBUG
    static let on = ProcessInfo.processInfo.arguments.contains("-MacClickTrace")
    private static var link: CADisplayLink?
    private static var last: CFTimeInterval = 0
    static var inPress = false
    static func start() {
        guard on, link == nil else { return }
        let l = CADisplayLink(target: Ticker.shared, selector: #selector(Ticker.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        if ProcessInfo.processInfo.arguments.contains("-MacClickTraceAppKit") { MacClick.traceWindowMethods() }
        if ProcessInfo.processInfo.arguments.contains("-MacClickTraceCancel") { traceCancels() }
        // E fix-up 4 (K1): the CA context id the Catalyst translator routes each mouse event to, beside the UIKit
        // windows' own context ids (a press routed to a stale context would never become a touch).
        if let cls = NSClassFromString("UINSMouseEventTranslator"),
           let m = class_getInstanceMethod(cls, NSSelectorFromString("_handleMouseEvent:contextId:")),
           let enc = method_getTypeEncoding(m) {
            let e = String(cString: enc)
            NSLog("[ClickTrace] translator _handleMouseEvent:contextId: encoding %@", e)
            if e.hasPrefix("v28@0:8@16I24") || e.hasPrefix("v32@0:8@16I24") || e.hasPrefix("v32@0:8@16Q24") || e.hasPrefix("v28@0:8@16i24") {
                typealias O = @convention(c) (NSObject, Selector, NSObject, UInt32) -> Void
                let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                let sel = method_getName(m)
                let b: @convention(block) (NSObject, NSObject, UInt32) -> Void = { o, ev, ctx in
                    let kind = (ev.value(forKey: "type") as? UInt) ?? 0
                    if kind == 1 || kind == 2 {
                        let wins = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                            .map { w in "\(String(describing: type(of: w)).prefix(22))=\((w.value(forKey: "_contextId") as? UInt32).map(String.init) ?? "?")\(w.isHidden ? "h" : "")" }
                            .joined(separator: ",")
                        let ign = UIApplication.shared.isIgnoringInteractionEvents
                        NSLog("[ClickTrace] translator %@ ctx %u · ignoring %@ · windows [%@] t=%.0f", kind == 1 ? "down" : "up", ctx,
                              ign ? "YES" : "no", wins, CFAbsoluteTimeGetCurrent() * 1000)
                    }
                    MacClickTrace.inPress = true
                    orig(o, sel, ev, ctx)
                    MacClickTrace.inPress = false
                }
                method_setImplementation(m, imp_implementationWithBlock(b))
            }
        }
        // K1: every view hit-test made while the translator handles a press (UIView.hitTest, inherited by every view).
        if let m = class_getInstanceMethod(UIWindow.self, #selector(UIView.hitTest(_:with:))) {
            typealias O = @convention(c) (UIWindow, Selector, CGPoint, UIEvent?) -> UIView?
            let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
            let b: @convention(block) (UIWindow, CGPoint, UIEvent?) -> UIView? = { w, p, e in
                let v = orig(w, #selector(UIView.hitTest(_:with:)), p, e)
                if inPress {
                    let chain = sequence(first: v, next: { $0?.superview }).prefix(3)
                        .map { $0.map { String(describing: type(of: $0)).prefix(30) } ?? "nil" }.joined(separator: "<")
                    NSLog("[ClickTrace] hitTest (%.0f,%.0f) ev %@ → %@", p.x, p.y, e.map { "\($0.type.rawValue)" } ?? "nil", chain)
                }
                return v
            }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
        // AppKit: every left mouse down / up the window receives (before UIKit sees it).
        if let cls = NSClassFromString("NSWindow"), let m = class_getInstanceMethod(cls, NSSelectorFromString("sendEvent:")) {
            typealias O = @convention(c) (NSObject, Selector, NSObject) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
            let sel = method_getName(m)
            let b: @convention(block) (NSObject, NSObject) -> Void = { w, e in
                let type = (e.value(forKey: "type") as? UInt) ?? 0
                if type == 1 || type == 2 {
                    let p = (e.value(forKey: "locationInWindow") as? CGPoint) ?? .zero
                    NSLog("[ClickTrace] nsevent %@ (%.0f,%.0f) clicks %@ t=%.0f", type == 1 ? "down" : "up", p.x, p.y,
                          "\(e.value(forKey: "clickCount") ?? "-")", CFAbsoluteTimeGetCurrent() * 1000)
                }
                orig(w, sel, e)
            }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
        // UIKit's application: every event with its touches' windows (a began sent to another window would show here).
        if let m = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))) {
            typealias O = @convention(c) (UIApplication, Selector, UIEvent) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
            let b: @convention(block) (UIApplication, UIEvent) -> Void = { a, e in
                if e.type == .hover {
                    let t = e.allTouches?.first
                    NSLog("[ClickTrace] hover phase %d at %@ t=%.0f", t?.phase.rawValue ?? -1, t.map { "\($0.location(in: nil))" } ?? "-",
                          CFAbsoluteTimeGetCurrent() * 1000)
                } else {
                    let ts = (e.allTouches ?? []).map { t in
                        "\(t.phase.rawValue)/\(t.type.rawValue)@\(t.window.map { String(describing: type(of: $0)).prefix(18) } ?? "nil")"
                    }.joined(separator: ",")
                    NSLog("[ClickTrace] app event type %d sub %d touches [%@] t=%.0f", e.type.rawValue, e.subtype.rawValue, ts,
                          CFAbsoluteTimeGetCurrent() * 1000)
                }
                orig(a, #selector(UIApplication.sendEvent(_:)), e)
            }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
        // Every touch phase UIKit's window receives: where it lands and which view the hit-test chose.
        if let m = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))) {
            typealias Orig = @convention(c) (UIWindow, Selector, UIEvent) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: Orig.self)
            let block: @convention(block) (UIWindow, UIEvent) -> Void = { w, e in
                for t in e.allTouches ?? [] where t.phase == .began || t.phase == .ended || t.phase == .cancelled {
                    let p = t.location(in: w)
                    let chain = "w \(String(describing: type(of: w)).prefix(20))@\(String(UInt(bitPattern: ObjectIdentifier(w).hashValue) % 100000)) " + sequence(first: t.view as UIView?, next: { $0?.superview }).prefix(3)
                        .map { $0.map { "\(String(describing: type(of: $0)).prefix(24))@\(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 100000)" } ?? "nil" }.joined(separator: "<")
                    let grs = (t.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ",")
                    let fr = (w.value(forKey: "firstResponder") as AnyObject?).map { String(describing: type(of: $0)).prefix(60) } ?? "nil"
                    NSLog("[ClickTrace] touch %@ (%.0f,%.0f) t=%.0f fr %@ view %@ · gr [%@]", t.phase == .began ? "began" : t.phase == .ended ? "ended" : "cancelled",
                          p.x, p.y, CFAbsoluteTimeGetCurrent() * 1000, String(fr), chain, grs)
                    // E fix-up 4 (K1): who delivers a cancelled touch (a lost press reaches the window only as a cancel).
                    if t.phase == .cancelled {
                        NSLog("[ClickTrace] cancelled-from %@", Thread.callStackSymbols.dropFirst(1).prefix(16)
                            .map { l in let p = l.split(separator: " ", omittingEmptySubsequences: true)
                                return p.count > 3 ? String(p[3...].joined(separator: " ").prefix(90)) : String(l.prefix(90)) }
                            .joined(separator: " ← "))
                    }
                }
                orig(w, #selector(UIWindow.sendEvent(_:)), e)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
    /// Every UIKit method named *cancel* / *ignor* on the app, its windows and the gesture environment, with its callers.
    static func traceCancels() {
        for name in ["UIApplication", "UIWindow", "UIGestureEnvironment", "_UIGestureEnvironment", "UIGestureRecognizer",
                     "UIEventDispatcher", "UITouchesEvent", "UIEventEnvironment", "UIScene", "UIWindowScene"] {
            guard let cls = NSClassFromString(name) else { continue }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { continue }
            for i in 0..<Int(count) {
                let m = list[i]; let sel = method_getName(m); let sname = NSStringFromSelector(sel); let low = sname.lowercased()
                guard low.contains("cancel") || low.contains("ignoringinteraction") || low.contains("ignoreinteraction"),
                      let enc = method_getTypeEncoding(m) else { continue }
                let e = String(cString: enc)
                func log() {
                    let callers = Thread.callStackSymbols.dropFirst(2).prefix(6).map { line -> String in
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        return parts.count > 3 ? String(parts[3...].joined(separator: " ").prefix(70)) : String(line.prefix(70)) }
                    NSLog("[ClickTrace] cancel %@ -%@ t=%.0f ← %@", name, sname, CFAbsoluteTimeGetCurrent() * 1000, callers.joined(separator: " ← "))
                }
                if e.hasPrefix("v16@0:8") {
                    typealias O = @convention(c) (NSObject, Selector) -> Void
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject) -> Void = { o in log(); orig(o, sel) }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                } else if e.hasPrefix("v24@0:8@16") {
                    typealias O = @convention(c) (NSObject, Selector, NSObject?) -> Void
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject, NSObject?) -> Void = { o, a in log(); orig(o, sel, a) }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                } else if e.hasPrefix("v20@0:8B16") || e.hasPrefix("v20@0:8c16") {
                    typealias O = @convention(c) (NSObject, Selector, Bool) -> Void
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject, Bool) -> Void = { o, f in log(); orig(o, sel, f) }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                }
            }
            free(list)
        }
    }

    @MainActor final class Ticker: NSObject {
        static let shared = Ticker()
        @objc func tick(_ l: CADisplayLink) {
            let now = CACurrentMediaTime()
            if !MacClick.touchLog.isEmpty {
                for line in MacClick.touchLog { NSLog("[ClickTrace] appkit %@ t=%.0f", line, CFAbsoluteTimeGetCurrent() * 1000) }
                MacClick.touchLog.removeAll()
            }
            if MacClickTrace.last > 0, now - MacClickTrace.last > 0.040 {
                NSLog("[ClickTrace] gap %.0f ms ending t=%.0f", (now - MacClickTrace.last) * 1000, CFAbsoluteTimeGetCurrent() * 1000)
            }
            MacClickTrace.last = now
        }
    }
    #endif
}

extension View {
    func macToolbarProbe(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacToolbarProbe.space)) } action: {
            MacToolbarProbe.x[id] = $0.minX; MacToolbarProbe.rect[id] = $0
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { MacToolbarProbe.windowRect[id] = $0 }
        .onHover { MacWindowChrome.setPointerOverControl(id, $0) }
        .onDisappear { MacWindowChrome.setPointerOverControl(id, false) }
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
                    // E fix-up 6 (M8) — no autocorrect suggestion under a search query (its bubble also took the first Esc).
                    .autocorrectionDisabled()
                    // E fix-up 6 (M8) — Esc leaves search (clears the field, as a Mac search field does): the panel
                    // goes back to Ask, no mango fade.
                    .onKeyPress(.escape) { librarian.searchText = ""; searchFocused = false; return .handled }
                    .onChange(of: searchFocused) { _, focused in
                        MacSearchEscape.active = focused
                        MacSearchEscape.leave = focused ? { [librarian] in
                            librarian.searchText = ""
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        } : nil
                    }
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
                    .help("Clear search")
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
            // E fix-up 3 (H1) — straight to the column, not through `router.perform` (its command hop cost a SwiftUI pass over
            // every view that watches commands, ~70 ms, before the column moved).
            MacLibrarianToolbarButton(open: layout.librarianShowing) { MacClickTrace.mark("librarian"); layout.toggleLibrarian(router) }
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
            if !text.isEmpty, !layout.librarianShowing { layout.closeSettings(); layout.librarianOpen = true; router.librarianAtPeek = false }
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// E fix-up 6 (M8) — Esc in the toolbar's Search field leaves search. The field never sees Esc itself: the system's
/// text input takes it (logged: neither SwiftUI's onKeyPress, the View menu's Esc nor a priority UIKeyCommand fired).
/// An AppKit local key monitor (through the runtime) sees it first; it acts only while that field is focused, so every
/// other Esc (sheets, Close Preview) is untouched.
/// Sweep 1 · N3 — Esc ends selection mode (Catalyst delivers Esc to no SwiftUI handler here; taken where AppKit sees it,
/// as `MacSearchEscape`). Not while text is being edited (Esc belongs to the field there).
@MainActor enum MacSelectionEscape {
    static var exit: (() -> Void)? { didSet { if exit != nil { install() } } }
    private static var monitor: AnyObject?
    private static func install() {
        guard monitor == nil, let cls: AnyClass = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        guard let m = class_getClassMethod(cls, sel) else { return }
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping @convention(block) (AnyObject) -> AnyObject?) -> AnyObject?
        let handler: @convention(block) (AnyObject) -> AnyObject? = { event in
            guard (event.value(forKey: "keyCode") as? NSNumber)?.intValue == 53 else { return event }   // Esc
            return MainActor.assumeIsolated {
                guard let exit, !MacSearchEscape.active else { return event }
                FirstResponderProbe.current = nil
                UIApplication.shared.sendAction(#selector(UIResponder.airpadCaptureFirstResponder), to: nil, from: nil, for: nil)
                if FirstResponderProbe.current is UITextInput { return event }
                exit()
                return nil
            }
        }
        monitor = unsafeBitCast(method_getImplementation(m), to: Add.self)(cls, sel, 1 << 10, handler)
    }
}

@MainActor enum MacSearchEscape {
    static var active = false { didSet { if active { installMonitor() } } }
    static var leave: (() -> Void)?
    private static var monitor: AnyObject?

    private static func installMonitor() {
        guard monitor == nil, let cls: AnyClass = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        guard let m = class_getClassMethod(cls, sel) else { return }
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping @convention(block) (AnyObject) -> AnyObject?) -> AnyObject?
        let handler: @convention(block) (AnyObject) -> AnyObject? = { event in
            guard (event.value(forKey: "keyCode") as? NSNumber)?.intValue == 53 else { return event }   // Esc
            return MainActor.assumeIsolated {
                guard active, let leave else { return event }
                leave()
                return nil
            }
        }
        monitor = unsafeBitCast(method_getImplementation(m), to: Add.self)(cls, sel, 1 << 10, handler)   // key down
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
        let inWindow = MacToolbarController.controlsInWindow
        if inWindow {
            // E fix-up 2 — the NSToolbar holds no items (it gives the bar its height); the controls are in the main window.
            row("items: none (controls in the window)", ids.isEmpty, "\(ids)")
            let all = ["toolbar.sidebar", "toolbar.back", "toolbar.forward", "toolbar.search", "toolbar.librarian", "toolbar.newEntry"]
            let rs = all.map { MacToolbarProbe.windowRect[$0] }
            row("controls drawn in the main window, inside the bar", rs.allSatisfy { $0.map { $0.minY >= 0 && $0.maxY <= 52 && $0.width > 0 } == true },
                all.indices.map { "\(all[$0].dropFirst(8)) \(rs[$0].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil")" }.joined(separator: " · "))
        } else {
            row("items: leading · flexible space · trailing", ids == ["airpad.toolbar.leading", "NSToolbarFlexibleSpaceItem", "airpad.toolbar.trailing"], "\(ids)")
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        row("unified title bar, title hidden", scene?.titlebar?.toolbarStyle == .unified && scene?.titlebar?.titleVisibility == .hidden)
        for (name, id) in inWindow ? [] : [("leading", MacToolbarController.leadingID), ("trailing", MacToolbarController.trailingID)] {
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
        let field = toolbarSearchResponder()
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
        if !inWindow {
            let ax = MacWindowChrome.leadingItemX()
            row("E1 leading item measured (AppKit)", ax != nil && abs((ax ?? 0) - layout.toolbarLeadingX) < 1,
                "AppKit x \(ax.map { String(format: "%.1f", $0) } ?? "nil") · layout \(layout.toolbarLeadingX)")
        }
        func hostX(_ id: String) -> CGFloat? {
            inWindow ? MacToolbarProbe.windowRect[id]?.minX
                     : MacToolbarProbe.x[id].map { $0 + (MacWindowChrome.leadingItemX() ?? layout.toolbarLeadingX) }
        }
        /// In the window: every control whole and on screen, the leading run clear of the trailing one.
        func allOnScreen() -> Bool {
            let r = MacToolbarProbe.windowRect
            guard let fwd = r["toolbar.forward"], let search = r["toolbar.search"], let plus = r["toolbar.newEntry"] else { return false }
            let lastLeading = [r["toolbar.view.Cards"], r["toolbar.forward"]].compactMap { $0 }.map(\.maxX).max() ?? fwd.maxX
            return lastLeading < search.minX && plus.maxX <= layout.windowWidth
        }
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
                    let ok = (inWindow ? allOnScreen() : ids.contains(MacToolbarController.leadingID.rawValue) && ids.contains(MacToolbarController.trailingID.rawValue))
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

    /// The toolbar search field when it's first responder: in the toolbar item's host, or (E fix-up 2) in the main
    /// window at the field's frame.
    static func toolbarSearchResponder() -> UIView? {
        guard MacToolbarController.controlsInWindow else {
            return MacToolbarController.shared.hosts[MacToolbarController.trailingID]?.view.flatMap { firstResponder(in: $0) }
        }
        guard let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow),
              let f = firstResponder(in: win), let r = MacToolbarProbe.windowRect["toolbar.search"] else { return nil }
        let b = f.convert(f.bounds, to: nil)
        return r.insetBy(dx: -4, dy: -4).contains(CGPoint(x: b.midX, y: b.midY)) ? f : nil
    }

    static func firstResponder(in v: UIView) -> UIView? {
        if v.isFirstResponder { return v }
        for s in v.subviews { if let r = firstResponder(in: s) { return r } }
        return nil
    }
}
#endif
