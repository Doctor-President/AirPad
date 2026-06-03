import SwiftUI

/// Sheet-perimeter chrome for `LibrarianSurface` when presented via
/// `UISheetPresentationController`. Applied through
/// `.presentationBackground { ... }` on the hosting controller's
/// rootView so the rainbow stroke traces the sheet's actual edges
/// instead of an inner RoundedRectangle that double-clips with the
/// system sheet's own rounded corners.
///
/// Three layers, back to front:
/// 1. Dark translucent fill over `.ultraThinMaterial` — the darkened
///    Liquid Glass base.
/// 2. Aurora glow — same angular gradient as the crisp edge, thick
///    (10pt) stroke at 0.45 opacity, blurred 6pt so the color bleeds
///    inward as a moving chromatic halo.
/// 3. Crisp 1.5pt rainbow edge — the perimeter line.
///
/// `cornerRadius: 44` must match
/// `sheet.preferredCornerRadius` in `LibrarianSheetPresenter`. If one
/// changes, change both — otherwise the rainbow drifts off the sheet's
/// real corner.
struct LibrarianSheetBackground: View {
    @State private var gradientRotation: Double = 0

    private let gradientColors: [Color] = [
        Color(hexString: "E36B4E"),
        Color(hexString: "7A52FF"),
        Color(hexString: "B857D4"),
        Color(hexString: "E36B4E")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .background(.thinMaterial)

            RoundedRectangle(cornerRadius: 44)
                .strokeBorder(
                    AngularGradient(
                        colors: gradientColors,
                        center: .center,
                        startAngle: .degrees(gradientRotation),
                        endAngle: .degrees(gradientRotation + 360)
                    ),
                    lineWidth: 9
                )
                .opacity(0.35)
                .blur(radius: 9)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 44)
                .strokeBorder(
                    AngularGradient(
                        colors: gradientColors,
                        center: .center,
                        startAngle: .degrees(gradientRotation),
                        endAngle: .degrees(gradientRotation + 360)
                    ),
                    lineWidth: 1.5
                )
                .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(
                .linear(duration: 4)
                .repeatForever(autoreverses: false)
            ) {
                gradientRotation = 360
            }
        }
    }
}
