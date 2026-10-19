import SwiftUI
import UIKit

/// live-23 (1) — the Librarian panel surface as numbers: frost (blur passes, backdrop saturation, a tint at an
/// opacity), whether the search pill + Ask bar are real Liquid Glass, and how much the content behind dims while
/// the panel is up. Baked from T's on-device tuning (2026-10-16, Ops `reference/appearance-tuning-2026-10-16.md`).
struct LibrarianSurfaceSpec: Equatable, CustomStringConvertible {
    var tint: Double
    var blur: Double            // passes of the system ultra-thin material (see `TunedBackdrop`)
    var saturation: Double      // 1 = the backdrop as it is · 0 = grey
    var glassControls: Bool
    var dim: Double             // 0…0.20 black over the content behind, × how far the panel is up
    var wholePanelGlass = false // the tuner's "Liquid Glass" preset

    /// ★ live-26 (1) — T's 2026-10-18 values. Both panels ship on Liquid Glass (`LibrarianGlassLook.shipped(dark:)`), so
    /// the frost numbers here are kept as T left them but don't render; what does: the glass controls, and the content
    /// behind dimmed 10.5% in light, not at all in dark.
    static let light = LibrarianSurfaceSpec(tint: 0.51, blur: 0.58, saturation: 0.4, glassControls: true, dim: 0.105)
    static let dark = LibrarianSurfaceSpec(tint: 0.5, blur: 1.53, saturation: 0.4, glassControls: true, dim: 0)
    static func baked(dark: Bool) -> LibrarianSurfaceSpec { dark ? .dark : .light }

    /// What renders: in DEBUG / TestFlight the on-device tuner's values when it's live (nil = its "Before" preset —
    /// the pre-live-23 panel), else the baked spec. An App Store build always renders the baked spec.
    static func current(dark: Bool) -> LibrarianSurfaceSpec? {
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { return v.panel == .today ? nil : v.librarianSpec }
        #endif
        return baked(dark: dark)
    }
    /// The search pill + Ask bar as real Liquid Glass.
    static func glassControls(dark: Bool) -> Bool {
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { return v.glassControls }
        #endif
        return baked(dark: dark).glassControls
    }
    /// Black over the content behind the panel at full height (× how far it is up).
    static func dimAmount(dark: Bool) -> Double {
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { return v.librarianSpec.dim }
        #endif
        return baked(dark: dark).dim
    }

    var description: String {
        String(format: "tint %.2f blur %.2f sat %.2f glass %@ dim %.2f%@", tint, blur, saturation,
               glassControls ? "on" : "off", dim, wholePanelGlass ? " whole-panel glass" : "")
    }
}

/// The Librarian panel surface for a spec (live-22 (2) as the tuner's; live-23 (1) the shipped one).
/// Frost = passes of the system ultra-thin material's blur (0…3; see `TunedBackdrop`) · the backdrop's
/// saturation pulled down · a warm-neutral tint at an opacity · the light panel's stroke and shadow. At blur 1,
/// saturation 1, tint 0.35 it is the pre-live-23 light panel. Whole-panel glass = `.glassEffect(.regular)`.
struct LibrarianTunedMaterial: View {
    let spec: LibrarianSurfaceSpec
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        let tint = dark ? Color(hexString: "141414") : Color(hexString: AppearancePalette.light.panelTint)
        let stroke = dark ? Color.white.opacity(0.10) : Color(hexString: AppearancePalette.light.panelStroke)
        Group {
            if spec.wholePanelGlass {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                ZStack {
                    ZStack {
                        TunedBackdrop(blur: spec.blur, saturation: spec.saturation)
                            .clipShape(shape)
                        shape.fill(tint.opacity(spec.tint))
                    }
                    // Today's light shadow (Brown @ 0.150, radius 24, offset (3, 2)); dark has none.
                    .shadow(color: dark ? .clear : Color(hexString: "43372A").opacity(0.15), radius: 24, x: 3, y: 2)
                    shape.strokeBorder(stroke, lineWidth: dark ? 0.5 : 1.2)
                }
            }
        }
        .padding(.bottom, -150)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// The blurred, desaturated backdrop. UIKit has no public blur radius, and on iOS 27 the old paused-animator trick
/// (`fractionComplete` on an effect change) no longer renders a partial blur, so the blur is built from whole passes
/// of the system ultra-thin material: 1 = one pass (today's panel), 2 and 3 = a second and third pass over the
/// first, each blurring the last. Between whole steps the top pass fades in by its opacity. Saturation is a grey
/// layer in the saturation blend mode over the blur, at (1 − saturation).
struct TunedBackdrop: UIViewRepresentable {
    let blur: Double
    let saturation: Double

    func makeUIView(context: Context) -> TunedBackdropView { TunedBackdropView() }
    func updateUIView(_ v: TunedBackdropView, context: Context) {
        v.set(blur: CGFloat(min(max(blur, 0), CGFloat(TunedBackdropView.maxPasses))),
              desaturation: CGFloat(1 - min(max(saturation, 0), 1)))
    }
}

final class TunedBackdropView: UIView {
    static let maxPasses = 3
    private let passes = (0..<TunedBackdropView.maxPasses).map { _ in
        UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    }
    private let desaturate = UIView()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for p in passes {
            p.frame = bounds; p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(p)
        }
        desaturate.frame = bounds; desaturate.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        desaturate.backgroundColor = UIColor(white: 0.5, alpha: 1)
        desaturate.layer.compositingFilter = "saturationBlendMode"
        desaturate.alpha = 0
        addSubview(desaturate)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(blur: CGFloat, desaturation: CGFloat) {
        desaturate.alpha = desaturation
        for (i, p) in passes.enumerated() {
            let a = min(max(blur - CGFloat(i), 0), 1)
            p.isHidden = a == 0
            p.alpha = a
        }
    }
}
