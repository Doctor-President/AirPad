import SwiftUI

/// Empty-state overlay shown when the corpus has no nodes.
/// Renders centered prompt + animated arrow over the global isometric grid.
struct EmptyStateOverlay: View {

    private let kleinBlue = Color(red: 0, green: 0.184, blue: 0.655)

    var body: some View {
        VStack(spacing: 10) {
            Text("I haven't any idea(s).")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.45))
            Text("Add one!")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.35))

            ArrowToAddButton(color: kleinBlue.opacity(0.55))
                .frame(width: 72, height: 72)
                .offset(x: 16, y: 8)
        }
    }
}

// MARK: - Curved arrow

private struct ArrowToAddButton: View {
    let color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            var path = Path()
            path.move(to: CGPoint(x: w * 0.08, y: h * 0.08))
            path.addCurve(
                to: CGPoint(x: w * 0.88, y: h * 0.88),
                control1: CGPoint(x: w * 0.08, y: h * 0.75),
                control2: CGPoint(x: w * 0.60, y: h * 0.88)
            )
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round,
                                              dash: [6, 4], dashPhase: phase))

            var arrow = Path()
            arrow.move(to: CGPoint(x: w * 0.72, y: h * 0.84))
            arrow.addLine(to: CGPoint(x: w * 0.88, y: h * 0.88))
            arrow.addLine(to: CGPoint(x: w * 0.84, y: h * 0.72))
            context.stroke(arrow, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = -20
            }
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.027, green: 0.027, blue: 0.039)
        EmptyStateOverlay()
    }
    .ignoresSafeArea()
}
