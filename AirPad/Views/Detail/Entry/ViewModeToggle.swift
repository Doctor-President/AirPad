import SwiftUI

/// Strip ↔ Horizontal-bento ↔ Vertical-bento switcher, in the trailing slot of
/// `MediaEntryChrome` inside `GalleryBody`. THREE-icon direct-select row (the
/// two-icon design extended for the 3-mode restore): all three icons always
/// visible, the active mode is filled + bold + brighter, the inactive are
/// hairline + muted. Tapping an inactive icon switches; tapping the active one
/// is a no-op. Kept a single control (an icon row), NOT a segmented picker or a
/// menu.
///
/// ★ T IS COLORBLIND. The active state is signalled by SHAPE (`.fill` variant),
/// WEIGHT (`.bold` vs `.semibold`), and BRIGHTNESS (ink 0.95 vs 0.4) — NEVER by
/// hue. The only colour is `AppearancePalette.ink` (adaptive ink, not a hue
/// accent), so there's no hue channel carrying meaning.
///
/// SF Symbols (three distinct shapes):
///   - Strip:            `rectangle.stack` — a deck / one-across scroll.
///   - Horizontal bento: `rectangle.grid.1x2` — a stacked pair, the atomic
///     column of the horizontal packer (2-deep columns marching across).
///   - Vertical bento:   `square.grid.2x2` — an unambiguous 4-cell grid.
struct ViewModeToggle: View {

    let active: GalleryViewMode
    let onChange: (GalleryViewMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            iconButton(base: "rectangle.stack",   mode: .carousel,
                       accessibilityLabel: "Strip view")
            iconButton(base: "rectangle.grid.1x2", mode: .horizontalBento,
                       accessibilityLabel: "Horizontal bento view")
            iconButton(base: "square.grid.2x2",   mode: .bento,
                       accessibilityLabel: "Vertical bento view")
        }
    }

    @ViewBuilder
    private func iconButton(base: String, mode: GalleryViewMode, accessibilityLabel: String) -> some View {
        let isActive = active == mode
        Button(action: { if active != mode { onChange(mode) } }) {
            Image(systemName: isActive ? "\(base).fill" : base)
                .font(.subheadline.weight(isActive ? .bold : .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(isActive ? 0.95 : 0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
