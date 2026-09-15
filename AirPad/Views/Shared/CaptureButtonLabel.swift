import SwiftUI

/// The floating capture "+" button VISUAL — ONE source for the circular ink button that appears
/// over the map / list / card views (a capture trigger) AND inside node detail (a Menu). The two
/// used to be separate lookalikes: detail hardcoded `.white`/`.black`, so in light mode it stayed
/// white and under-contrasted the cream ground while the shared button read as tasteful dark grey
/// (`AppearancePalette.ink` = light `#232A2E`). The ACTION differs per site (a capture trigger vs a
/// Menu of entry kinds), so this is just the LABEL; each caller wraps it in its own Button/Menu.
/// Unified here so the appearance can never drift again — restyle once, both surfaces follow.
struct CaptureButtonLabel: View {
    var body: some View { CanvasCircleButtonLabel(systemName: "plus") }
}

/// The circular ink chrome those floating canvas buttons share — ONE source for size, fill, clip
/// and shadow, so the capture "+" and the view switcher stacked directly above it read as a stack
/// and cannot drift apart. Only the glyph (and its optical size) differs per caller.
struct CanvasCircleButtonLabel: View {
    let systemName: String
    /// Optical size of the glyph. "+" is a thin form and carries 24; the view-mode symbols are
    /// denser (a 2×2 grid, a hex cluster), so they sit slightly smaller at the same weight.
    var glyphSize: CGFloat = 24

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .semibold))
            // Dark: onInk `#000000` glyph on ink `#FFFFFF` circle. Light: a cream glyph cut out of
            // a dark ink circle so it reads on cream. T art-directs via the tokens (surface 6).
            .foregroundStyle(AppearancePalette.onInk)
            .frame(width: 60, height: 60)
            .background(AppearancePalette.ink)
            .clipShape(Circle())
            .shadow(color: AppearancePalette.panelShadow, radius: 12, y: 4)
    }
}
