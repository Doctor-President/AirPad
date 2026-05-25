import SwiftUI

/// Slow-blinking evolving-gradient pill that signals "the model is thinking."
/// Mounted top-center in `CanvasChrome` (C4) and shown only when
/// `CorpusStore.isAnyModelProcessing` is true — the OR of substrate fit,
/// embedding backfill, and AI reprocess. Per-call AI and neighborhood
/// refreshes intentionally aren't surfaced (too short-lived to register).
///
/// Two simultaneous animations: a gradient phase that sweeps across the pill
/// over ~4s, and an opacity pulse from 0.65 → 1.0 over ~1.8s. The pill is
/// informational only — non-tappable, doesn't block the canvas.
struct ModelProcessingIndicator: View {

    @State private var phase: CGFloat = 0
    @State private var pulse: CGFloat = 0.65

    private static let palette: [Color] = [
        Color(hex: "#7AB7FF")!,  // soft blue
        Color(hex: "#B58CFF")!,  // violet
        Color(hex: "#5FE0C5")!,  // teal
        Color(hex: "#7AB7FF")!   // wrap
    ]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
            Text("Thinking")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(
                LinearGradient(
                    colors: Self.palette,
                    startPoint: UnitPoint(x: phase - 1, y: 0.5),
                    endPoint:   UnitPoint(x: phase,     y: 0.5)
                )
            )
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .opacity(pulse)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                phase = 2
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}
