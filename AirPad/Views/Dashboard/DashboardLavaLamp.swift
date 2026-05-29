import SwiftUI

/// Animated lavalamp background for the Dashboard. Four soft blobs in
/// Klein Blue + Electric Cyan drift slowly via sin/cos offset; the whole
/// canvas is then blurred so blobs read as ambient color washes, not
/// sharp circles. Pure-Swift Canvas + TimelineView — no Metal.
struct DashboardLavaLamp: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                drawBlobs(context: context, size: size, t: t)
            }
        }
        .blur(radius: 26)
        .ignoresSafeArea()
    }

    private func drawBlobs(context: GraphicsContext, size: CGSize, t: Double) {
        let kleinBlue = Color(hexString: "1B59C2")
        let electricCyan = Color(hexString: "00BFFF")

        let blobs: [(ox: Double, oy: Double, r: Double, spx: Double, spy: Double, phase: Double, color: Color, peak: Double)] = [
            (0.22, 0.30, 0.56, 0.00020, 0.00014, 0.0, kleinBlue,    0.85),
            (0.78, 0.22, 0.50, 0.00016, 0.00026, 1.2, electricCyan, 0.55),
            (0.50, 0.74, 0.62, 0.00024, 0.00018, 2.4, kleinBlue,    0.85),
            (0.16, 0.80, 0.46, 0.00013, 0.00022, 3.8, electricCyan, 0.50),
        ]

        let tScaled = t * 8.0
        for blob in blobs {
            let cx = (sin(tScaled * blob.spx + blob.phase) * 0.28 + blob.ox) * size.width
            let cy = (cos(tScaled * blob.spy + blob.phase * 0.7) * 0.28 + blob.oy) * size.height
            let r  = blob.r * min(size.width, size.height)
            let gradient = Gradient(stops: [
                .init(color: blob.color.opacity(blob.peak),        location: 0.00),
                .init(color: blob.color.opacity(blob.peak * 0.73), location: 0.40),
                .init(color: blob.color.opacity(blob.peak * 0.33), location: 0.75),
                .init(color: blob.color.opacity(0.0),              location: 1.00),
            ])
            context.drawLayer { ctx in
                ctx.fill(
                    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(gradient, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r)
                )
            }
        }
    }
}
