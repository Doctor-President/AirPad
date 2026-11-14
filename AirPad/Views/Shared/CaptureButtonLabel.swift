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
    /// live-26 (3d) — the floating pair's role when "Floating buttons" is Glass: the "+" is prominent glass (the primary
    /// action), the view switcher regular glass like the top bar. nil (node detail's "+") = always the ink disc.
    var glassRole: FloatingButtonsStyle.Role? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = PointerHover<Circle>.forced

    /// The disc's own fill is ink: the "+" glass and the solid discs (not the switcher's clear glass).
    private var inkFilled: Bool { glassRole != .secondary || !FloatingButtonsStyle.isOn(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased) }

    var body: some View {
        Group {
            // Mac D0.12 (T R-SMALL) — no glass disc on the Mac: in light mode its ink tint drew pale grey under a cream
            // glyph. The solid ink disc reads in both modes (the toolbar's + is the main one there now).
            if let role = glassRole, !RunningOnMac.isMac,
               FloatingButtonsStyle.isOn(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased) {
                glass(role)
            } else {
                disc
            }
        }
        // Mac batch C5 hover. Mac fix-up X3: no wash shows on the "+" (its own fill is ink, and on the Mac its glass draws
        // over any overlay and ignores a tint change, measured), so the ink-filled discs lift a little (6%) instead; the
        // switcher keeps the 5% ink wash. Mac D0.6 (T N3): the lift grows the disc's OWN frame inside a fixed 60 pt box,
        // so it grows around its centre (a scaleEffect on the glass grew from a corner: the + drifted up-left).
        .frame(width: 60, height: 60)
        .modifier(PointerHover(shape: Circle(), opacity: inkFilled ? 0 : 0.05))
        .onHover { if !PointerHover<Circle>.forced { hovering = $0 } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// The hover lift (D0.6): 6% on the ink-filled discs.
    private var lift: CGFloat { hovering && inkFilled ? 1.06 : 1 }

    @ViewBuilder private func glass(_ role: FloatingButtonsStyle.Role) -> some View {
        let glyph = Image(systemName: systemName).font(.system(size: glyphSize * lift, weight: .semibold))
            .frame(width: 60 * lift, height: 60 * lift)
        switch role {
        case .primary:     // ink-tinted glass, its glyph cut in onInk — the brightest disc in dark, the darkest in light
            glyph.foregroundStyle(AppearancePalette.onInk)
                .glassEffect(.regular.tint(AppearancePalette.ink).interactive(), in: Circle())
        case .secondary:   // the top bar's glass (`chromeSurface`), its glyph in ink
            glyph.foregroundStyle(AppearancePalette.ink)
                .glassEffect(.regular.interactive(), in: Circle())
        }
    }

    private var disc: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize * lift, weight: .semibold))
            // Dark: onInk `#000000` glyph on ink `#FFFFFF` circle. Light: a cream glyph cut out of
            // a dark ink circle so it reads on cream. T art-directs via the tokens (surface 6).
            .foregroundStyle(AppearancePalette.onInk)
            .frame(width: 60 * lift, height: 60 * lift)
            .background(AppearancePalette.ink)
            .clipShape(Circle())
            .shadow(color: AppearancePalette.panelShadow, radius: 12, y: 4)
    }
}

/// live-26 (3d) — which floating buttons render. An App Store build renders Glass (`bakedGlass`, T's call 2026-10-18 (b),
/// live-27 (0)); DEBUG / TestFlight read the tuner's "Floating buttons" switch (and DEBUG `-FloatingButtons glass|today`, for
/// the stills). Reduce Transparency and Increase Contrast always get Today's solid discs.
enum FloatingButtonsStyle {
    enum Role { case primary, secondary }
    static let bakedGlass = true
    static var glassChosen: Bool {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "FloatingButtons") { return forced == "glass" }
        #endif
        #if DEBUG || TESTFLIGHT
        if AppearanceTuning.isLive { return AppearanceTuner.shared.state.floatingButtons == .glass }
        #endif
        return bakedGlass
    }
    /// Pure: glass when chosen and the person hasn't asked for less transparency or more contrast.
    static func isOn(chosen: Bool = glassChosen, reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        chosen && !reduceTransparency && !increaseContrast
    }
}
