#if DEBUG || TESTFLIGHT
import SwiftUI
import UIKit

/// live-22 (2) — the Librarian panel as the on-device appearance tuner sets it (TestFlight only; `AppearanceTuning`).
/// Frost = passes of the system ultra-thin material's blur (0…3; see `TunedBackdrop`) · the backdrop's
/// saturation pulled down · a warm-neutral tint at an opacity · today's stroke and shadow. At blur 1, saturation 1,
/// tint 0.35 it is today's light panel. Liquid Glass = the whole panel as `.glassEffect(.regular)`.
struct LibrarianTunedMaterial: View {
    let values: AppearanceTuningValues
    let dark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        let tint = dark ? Color(hexString: "141414") : Color(hexString: AppearancePalette.light.panelTint)
        let stroke = dark ? Color.white.opacity(0.10) : Color(hexString: AppearancePalette.light.panelStroke)
        Group {
            if values.panel == .liquidGlass {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                ZStack {
                    ZStack {
                        TunedBackdrop(blur: values.blur, saturation: values.saturation)
                            .clipShape(shape)
                        shape.fill(tint.opacity(values.tintOpacity))
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
#endif
