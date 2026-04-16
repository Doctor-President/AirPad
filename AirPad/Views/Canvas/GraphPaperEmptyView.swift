import SwiftUI

/// Graph paper empty state shown when the corpus has no nodes.
/// Klein Blue grid + centered text + animated curved arrow toward the + button.
struct GraphPaperEmptyView: View {

    private let kleinBlue = Color(red: 0, green: 0.184, blue: 0.655)

    var body: some View {
        ZStack {
            // Graph paper grid
            Canvas { context, size in
                let spacing: CGFloat = 28
                let color = GraphicsContext.Shading.color(kleinBlue.opacity(0.18))
                let thin = StrokeStyle(lineWidth: 0.5)

                var x: CGFloat = 0
                while x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: color, style: thin)
                    x += spacing
                }

                var y: CGFloat = 0
                while y <= size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: color, style: thin)
                    y += spacing
                }
            }
            .ignoresSafeArea()

            // Center content
            VStack(spacing: 10) {
                Text("I haven't any idea(s).")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.45))
                Text("Add one!")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.35))

                // Arrow pointing toward bottom-right + button
                ArrowToAddButton(color: kleinBlue.opacity(0.55))
                    .frame(width: 72, height: 72)
                    .offset(x: 16, y: 8)
            }
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

            // Curved path from top-left toward bottom-right
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

            // Arrowhead
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
    GraphPaperEmptyView()
        .background(Color.black)
}
