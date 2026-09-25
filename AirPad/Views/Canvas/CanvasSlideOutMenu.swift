import SwiftUI

/// Right-edge slide-out menu mounted by `CanvasChrome`. Holds the secondary chrome actions —
/// Analyze, Filter, Settings, and (when non-empty) Quarantine review.
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

    @Binding var isPresented: Bool

    let filterActiveCount: Int
    let quarantineCount: Int

    let onAnalyze: () -> Void
    let onFilter: () -> Void
    let onSettings: () -> Void
    let onQuarantineReview: () -> Void

    private let panelWidth: CGFloat = 280
    @State private var dragOffset: CGFloat = 0
    // Brief AT5 — Appearance override (shared with Settings via one @AppStorage key).
    @AppStorage(AppearanceOverride.storageKey) private var appearanceRaw = AppearanceOverride.system.rawValue

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
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isPresented)
    }

    // MARK: - Panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                section("Tools") {
                    actionRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        label: "Analyze",
                        action: { dismiss(then: onAnalyze) }
                    )
                    actionRow(
                        icon: "slider.horizontal.3",
                        label: "Filter",
                        badge: filterActiveCount > 0 ? "\(filterActiveCount)" : nil,
                        badgeColor: .blue,
                        action: { dismiss(then: onFilter) }
                    )
                    actionRow(
                        icon: "gearshape.fill",
                        label: "Settings",
                        action: { dismiss(then: onSettings) }
                    )
                    if quarantineCount > 0 {
                        actionRow(
                            icon: "exclamationmark.triangle.fill",
                            label: "Quarantine",
                            badge: "\(quarantineCount)",
                            badgeColor: .orange,
                            action: { dismiss(then: onQuarantineReview) }
                        )
                    }
                }

                section("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { AppearanceOverride(rawValue: appearanceRaw) ?? .system },
                        set: { appearanceRaw = $0.rawValue }
                    )) {
                        ForEach(AppearanceOverride.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
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
