import SwiftUI

/// Right-edge slide-out menu mounted by `CanvasChrome` in C3. Owns the
/// view-mode picker (5 modes — `.systemGraph`, `.userGraph`, `.list`,
/// `.grid`, `.timeline`) plus the secondary chrome actions (Filter,
/// Settings, Quarantine review). Built in C2 with no chrome wire-up yet
/// — C3 swaps the existing top-row cluster for a single ellipsis trigger
/// that toggles this menu.
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

    let currentMode: ViewMode
    let filterActiveCount: Int
    let quarantineCount: Int

    let onSelectMode: (ViewMode) -> Void
    let onFilter: () -> Void
    let onSettings: () -> Void
    let onQuarantineReview: () -> Void

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
                    .background(Color(white: 0.12))
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

                section("View") {
                    ForEach(ViewMode.menuOrder, id: \.self) { mode in
                        modeRow(mode)
                    }
                }

                section("Tools") {
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
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack {
            Text("Canvas")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            content()
        }
    }

    // MARK: - Rows

    private func modeRow(_ mode: ViewMode) -> some View {
        let isActive = (mode == currentMode)
        return Button(action: { dismiss(then: { onSelectMode(mode) }) }) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(mode.isAvailable ? 0.95 : 0.45))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(mode.isAvailable ? 0.95 : 0.45))
                    if !mode.isAvailable {
                        Text("Coming soon")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(isActive ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

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
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
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
