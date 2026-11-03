import SwiftUI

/// Right-edge slide-out menu mounted by `CanvasChrome` and (1.1-A) the Dashboard — one menu behind the
/// same `line.3.horizontal` glyph everywhere. Holds the secondary chrome actions — Analyze, Filter (canvas only),
/// Quarantine review (when non-empty), the Appearance quick controls (1.1-B fix-up (E): Theme · Map look · Strength ·
/// Gravity inline, "More appearance…" opens `AppearancePanel`) and, at the bottom, Settings.
///
/// ★ 2026-09-15: the VIEW-MODE PICKER was REMOVED from here. The bottom view switcher (and the
/// top pill) own mode switching now, via one shared `ViewSwitchMenuContent`. Removing it also
/// retired the two "Coming soon" rows (User Graph, Timeline) — V1 does not announce unbuilt
/// features to users. What is left is real, working chrome, which is why the drawer survives
/// rather than collapsing into a direct Settings button.
///
/// Mechanics: custom overlay (NOT `.sheet`) so the panel slides in from
/// the trailing edge. 280pt wide. Backdrop tap dismisses. Pan the panel
/// right past one-third its width to drag-dismiss; lift earlier and it
/// springs back.
///
/// Callback-based on purpose: the chrome owns all sheet/route state, this
/// component is state-pure except for the local drag offset and isn't
/// coupled to `CorpusStore` / `QuarantineStore` directly.
struct CanvasSlideOutMenu: View {

    /// Brief BG — the ≡ menu is a CUSTOM view, so its section headers + action labels
    /// follow the app-wide Font (icons + badges stay SF chrome).
    @Environment(\.appBodyFont) private var appFont
    @Environment(AppRouter.self) private var router

    @Binding var isPresented: Bool

    let filterActiveCount: Int
    let quarantineCount: Int

    let onAnalyze: () -> Void
    /// nil hides the Filter row (the Dashboard has no canvas to filter).
    let onFilter: (() -> Void)?
    let onSettings: () -> Void
    let onQuarantineReview: () -> Void
    /// 1.1-A (A3) — opens the half-height Appearance panel over the current view.
    let onAppearance: () -> Void
    /// Room under the bottom Settings row. The Librarian fades out and takes no touches while the menu is open
    /// (`ContentView.applyLibrarianInteraction`), so no room is kept for it.
    var bottomInset: CGFloat = 12

    private let panelWidth: CGFloat = 280
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .transition(.opacity)

                panel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    // Light-mode convergence — adaptive frosted material (was a
                    // solid `Color(white:0.12)` dark drawer). `.thinMaterial` keeps
                    // the full-height square drawer shape (dashboardPaneSurface's
                    // radius-22 would wrongly round a full-height edge drawer);
                    // dark = frosted dark, light = frosted parchment.
                    .background(.thinMaterial)
                    .offset(x: max(0, dragOffset))
                    .gesture(dragGesture)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(Self.slide, value: isPresented)
        // 1.1-B fix-up (F) — the Librarian pills fade with this same spring (`LibrarianSurface`).
        .onChange(of: isPresented, initial: true) { _, open in
            withAnimation(Self.slide) { router.slideOutMenuOpen = open }
        }
        .onDisappear { router.slideOutMenuOpen = false }
    }

    /// The menu's slide; the Librarian pills' fade uses it too.
    static let slide = Animation.spring(response: 0.32, dampingFraction: 0.86)

    private var privateEntries: PrivateEntries { PrivateEntries.shared }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    section("Tools") {
                        actionRow(
                            icon: "point.3.connected.trianglepath.dotted",
                            label: "Analyze",
                            action: { dismiss(then: onAnalyze) }
                        )
                        .accessibilityIdentifier("menu.analyze")
                        if let onFilter {
                            actionRow(
                                icon: "slider.horizontal.3",
                                label: "Filter",
                                badge: filterActiveCount > 0 ? "\(filterActiveCount)" : nil,
                                badgeColor: .blue,
                                action: { dismiss(then: onFilter) }
                            )
                            .accessibilityIdentifier("menu.filter")
                        }
                        if quarantineCount > 0 {
                            actionRow(
                                icon: "exclamationmark.triangle.fill",
                                label: "Quarantine",
                                badge: "\(quarantineCount)",
                                badgeColor: .orange,
                                action: { dismiss(then: onQuarantineReview) }
                            )
                        }
                        // 1.1-C (C3) — always listed (whether or not anything is private, so the menu itself never
                        // says there is); Face ID / the passcode to show, one tap to hide. Hidden again on background.
                        if privateEntries.available {
                            actionRow(
                                icon: privateEntries.revealed ? "lock.open" : "lock",
                                label: privateEntries.revealed ? "Hide private" : "Show private",
                                action: {
                                    if privateEntries.revealed { privateEntries.hide() }
                                    else { Task { await privateEntries.reveal() } }
                                }
                            )
                            .accessibilityIdentifier("menu.showPrivate")
                        }
                    }
                    // 1.1-B fix-up (E) — the Appearance quick controls, inline, applying live with the view beside the
                    // menu (was a row opening the sheet); "More appearance…" opens the sheet for the rest.
                    section("Appearance") {
                        MenuAppearanceSection()
                            .padding(.horizontal, 20)
                        actionRow(
                            icon: "circle.righthalf.filled",
                            label: "More appearance…",
                            action: { dismiss(then: onAppearance) }
                        )
                        .accessibilityIdentifier("menu.appearance")
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            // 1.1-A (A2) — Settings sits at the bottom of the menu.
            Divider().overlay(AppearancePalette.ink.opacity(0.1))
            actionRow(
                icon: "gearshape.fill",
                label: "Settings",
                action: { dismiss(then: onSettings) }
            )
            .accessibilityIdentifier("menu.settings")
            .padding(.bottom, bottomInset)
        }
    }

    /// Just the close affordance. The "CANVAS" title was dropped 2026-09-15 — "TOOLS" already says
    /// what the drawer is, so the title was a label for a label. Bottom padding goes to 0 because
    /// the section header below carries its own 18pt top inset; keeping 12 here would leave the gap
    /// the title used to fill.
    private var header: some View {
        HStack {
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(AppearancePalette.ink.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu.close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            content()
        }
    }

    // MARK: - Rows

    private func actionRow(
        icon: String,
        label: String,
        badge: String? = nil,
        badgeColor: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                    .frame(width: 24)
                Text(label)
                    .font(appFont.font(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(appFont.font(size: 11, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gestures + dismiss

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width > panelWidth / 3 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func dismiss(then action: (() -> Void)? = nil) {
        withAnimation(Self.slide) {
            isPresented = false
        }
        dragOffset = 0
        if let action {
            // Defer the chrome action until after the dismiss animation
            // starts so the user sees the menu retreat before a new sheet
            // pops on top of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                action()
            }
        }
    }
}

/// 1.1-B fix-up (E) — the ≡ menu's Appearance quick controls: Theme · the Map look of the appearance showing now (a swatch
/// row; Pro looks locked → the Pro sheet) · Strength (Pro, looks that have strengths) · Gravity. The same state as the
/// sheet and Settings (`AppearanceOverride`, `MapLookChoice`, `MapLookStrength`, `MapWells`).
private struct MenuAppearanceSection: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @State private var picked = MapLookChoice.picked
    @State private var strength = MapLookStrength.picked(MapLookChoice.picked)
    @State private var showPro = false
    private var store: ProStore { ProStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThemePicker()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(scheme == .light ? "Light Map" : "Dark Map").foregroundStyle(AppearancePalette.ink.opacity(0.95))
                    Spacer()
                    Text(MapLookChoice.name(store.isPro ? picked : .flat, light: scheme == .light))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                }
                .font(appFont.font(size: 14, weight: .medium, relativeTo: .subheadline))
                MapLookQuickRow(picked: $picked, onPick: { strength = MapLookStrength.picked($0) }, onLocked: { showPro = true })
            }
            if store.isPro && MapLookStrength.has(picked) {
                LookStrengthPicker(look: picked, strength: $strength)
            }
            GravityWellsToggle(detailed: false)
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $showPro) { ProSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .proEntitlementChanged)) { _ in picked = MapLookChoice.picked }
    }
}

/// 1.1-A (A3) — Appearance from the ≡ menu: Theme (Light / Dark / System) · Map look (the Settings picker,
/// `MapLookSection`: the same `MapLookChoice`, Pro looks locked → Pro sheet) · fluted glass · tilt. 1.1-B fix-up (E):
/// tabs (Look · Background · Dashboard) in one ~55 % detent, the view behind it undimmed and live. Settings → Appearance
/// reads and writes the same state (`AppearanceOverride.storageKey`, `MapLookChoice`, `FlutedGlass.shared`).
struct AppearancePanel: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.dismiss) private var dismiss

    /// 1.1-B fix-up (E) — tabs inside ONE ~55 % detent: the sheet never grows, so its grabber never reaches the top edge
    /// (dragging it down from there triggered the system search gesture). Each tab's content scrolls inside.
    enum Tab: String, CaseIterable, Identifiable {
        case look = "Look", background = "Background", dashboard = "Dashboard"
        var id: String { rawValue }
    }
    @State private var tab: Tab = {
        #if DEBUG
        if let t = UserDefaults.standard.string(forKey: "AppearanceTab").flatMap({ Tab(rawValue: $0.capitalized) }) { return t }
        #endif
        return .look
    }()
    static let detent = PresentationDetent.fraction(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Appearance")
                    .font(appFont.font(size: 20, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(AppearancePalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .font(appFont.font(size: 17, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(AppearancePalette.ink)
                    .accessibilityIdentifier("appearancePanel.done")
            }
            .padding(.horizontal, 20)
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("appearancePanel.tabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch tab {
                    case .look:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Theme").font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                                .foregroundStyle(AppearancePalette.ink)
                            ThemePicker()
                        }
                        MapLookSection()
                        GravityWellsToggle(detailed: true)   // 1.1-A fix-up (1); 1.1-B fix-up (G): the Sheen rides it
                    case .background:
                        MapGroundSection()                   // 1.1-B — Pro: the background + dots, per appearance
                    case .dashboard:
                        DashboardSurfaceSection()            // 1.1-B fix-up (C): per appearance
                        GlassAppearanceToggles(detailed: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .id(tab)
        }
        .padding(.top, 20)
        .presentationDetents([Self.detent])
        .presentationBackgroundInteraction(.enabled(upThrough: Self.detent))
        .presentationBackground(.thinMaterial)
        .presentationDragIndicator(.visible)
    }
}
