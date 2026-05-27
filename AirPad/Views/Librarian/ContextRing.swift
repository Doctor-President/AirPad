import SwiftUI

/// Circular progress ring around the Librarian mode icon. Communicates
/// context-window budget consumption visually — fills clockwise as the
/// estimated bytes-to-send grow, color shifts from `#00BFFF` (Electric
/// Cyan) at low fill to `#E8820A` (Mango) approaching the model's
/// window.
///
/// Pure presentation — the fill estimator lives on `LibrarianState`
/// (`contextFillFraction`). This view is dumb on purpose so we can
/// drop it into both the collapsed pill and the expanded header
/// without coupling either site to the budget math.
///
/// `diameter` is the ring's *outer* size. The stroke draws inward so
/// the inner clearance matches `diameter - 2 * lineWidth` — sized to
/// fit a 32pt icon at the default 38pt outer / 2pt stroke.
struct ContextRing: View {

    /// 0…1 clamped at the call site (`LibrarianState.contextFillFraction`
    /// already clamps, but we re-clamp here so the view is safe to drive
    /// from any source).
    let fraction: Double

    /// Outer diameter. Default 38 fits a 32pt SF Symbol with 3pt of
    /// breathing room.
    var diameter: CGFloat = 38

    /// Stroke width. The track and the progress arc both use this so
    /// the two read as one ring with different intensities.
    var lineWidth: CGFloat = 2

    /// Animation hook — bumped 0.45s so input typing produces a fluid
    /// ring growth rather than per-keystroke pops.
    var animationDuration: Double = 0.45

    private var clamped: Double {
        min(1.0, max(0.0, fraction))
    }

    /// Cyan at 0, mango at 1.0. Linear interpolation in sRGB through
    /// the channel values — close enough for a 2pt ring that the user
    /// reads color as a gradient signal, not a precise mapping.
    private var ringColor: Color {
        let cyan = (r: 0.0, g: 0.749, b: 1.0)        // #00BFFF
        let mango = (r: 0.910, g: 0.510, b: 0.039)   // #E8820A
        let t = clamped
        return Color(
            red: cyan.r + (mango.r - cyan.r) * t,
            green: cyan.g + (mango.g - cyan.g) * t,
            blue: cyan.b + (mango.b - cyan.b) * t
        )
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: animationDuration), value: clamped)
        }
        .frame(width: diameter, height: diameter)
    }
}
