import SwiftUI

/// Stage 4.2 commit 4 — Carousel ↔ Bento switcher hosted in the trailing slot
/// of `MediaEntryChrome` inside `GalleryBody`. Two-icon-row design (T's
/// "Option I"): both icons always visible, the active mode is filled and
/// brighter, the inactive is hairline and muted. Tapping the inactive icon
/// switches the mode (taps on the already-active icon are no-ops).
///
/// Why two icons and not a segmented control / single eye-and-label:
///   - At-a-glance state: a user can read the current mode without first
///     tapping to see options, matching Apple Photos' grid/list affordance.
///   - Fits the chrome height contract (`MediaEntryChromeMetrics.height =
///     44pt`) at a 32pt visual size with the chrome's vertical padding;
///     a segmented control would crowd the row.
///   - No label text means no localization seam.
///
/// SF Symbols chosen:
///   - Carousel: `rectangle.stack` — reads as "deck of cards / scroll one
///     at a time," matching the horizontal-strip-with-snap behavior commit
///     5 lands. (Tried `square.stack` — visually identical but `rectangle`
///     keeps the wider, gallery-photo feel.)
///   - Bento: `square.grid.2x2` — unambiguous 4-cell grid, matches what the
///     commit-6 bento renderer will actually draw at small counts (≥4 items).
struct ViewModeToggle: View {

    let active: GalleryViewMode
    let onChange: (GalleryViewMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            iconButton(
                systemName: active == .carousel ? "rectangle.stack.fill" : "rectangle.stack",
                isActive: active == .carousel,
                accessibilityLabel: "Carousel view",
                action: { if active != .carousel { onChange(.carousel) } }
            )
            iconButton(
                systemName: active == .bento ? "square.grid.2x2.fill" : "square.grid.2x2",
                isActive: active == .bento,
                accessibilityLabel: "Bento view",
                action: { if active != .bento { onChange(.bento) } }
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
