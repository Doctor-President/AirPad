import SwiftUI

/// Stage 4.5 commit 3 — Carousel ↔ Grid switcher hosted in the trailing
/// slot of `LinkEntryChrome` inside `LinkGalleryBody`. Same two-icon-row
/// design as `ViewModeToggle` (media gallery's Carousel/Bento switcher):
/// both icons always visible, the active mode is filled and brighter,
/// the inactive is hairline and muted. Tapping the inactive icon
/// switches the mode (taps on the already-active icon are no-ops).
///
/// SF Symbols chosen:
///   - Carousel: `rectangle.stack` — matches the media gallery's
///     carousel icon so a user reading both galleries side-by-side
///     sees the same affordance for the same mode.
///   - Grid: `square.grid.2x2` — unambiguous 4-cell grid; the link
///     gallery's grid renderer is a 2-column uniform layout (no bento),
///     and this icon reads exactly that.
struct LinkViewModeToggle: View {

    let active: LinkViewMode
    let onChange: (LinkViewMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            iconButton(
                systemName: active == .carousel ? "rectangle.stack.fill" : "rectangle.stack",
                isActive: active == .carousel,
                accessibilityLabel: "Carousel view",
                action: { if active != .carousel { onChange(.carousel) } }
            )
            iconButton(
                systemName: active == .grid ? "square.grid.2x2.fill" : "square.grid.2x2",
                isActive: active == .grid,
                accessibilityLabel: "Grid view",
                action: { if active != .grid { onChange(.grid) } }
            )
        }
    }

    @ViewBuilder
    private func iconButton(systemName: String, isActive: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
