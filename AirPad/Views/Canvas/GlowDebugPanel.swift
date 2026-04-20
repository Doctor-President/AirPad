import SwiftUI
import simd

struct GlowDebugPanel: View {
    @Binding var isVisible: Bool

    @State private var glowReach: Float = 12.0
    @State private var glowIntensity: Float = 0.5
    @State private var glowFalloff: Float = 3.0
    @State private var glowTintR: Float = 1.0
    @State private var glowTintG: Float = 0.95
    @State private var glowTintB: Float = 0.9

    let onGlowReachChange: (Float) -> Void
    let onGlowIntensityChange: (Float) -> Void
    let onGlowFalloffChange: (Float) -> Void
    let onGlowTintChange: (vector_float3) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inner Glow Debug")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { withAnimation { isVisible = false } }) {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sliderRow(
                    label: "Reach",
                    value: $glowReach,
                    range: 0...40,
                    step: 1,
                    format: "%.0fpx",
                    onChange: onGlowReachChange
                )

                sliderRow(
                    label: "Intensity",
                    value: $glowIntensity,
                    range: 0...2,
                    step: 0.1,
                    format: "%.1f",
                    onChange: onGlowIntensityChange
                )

                sliderRow(
                    label: "Falloff",
                    value: $glowFalloff,
                    range: 0.5...10,
                    step: 0.5,
                    format: "%.1f",
                    onChange: onGlowFalloffChange
                )

                Text("Tint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 8) {
                    colorSlider(label: "R", value: $glowTintR)
                    colorSlider(label: "G", value: $glowTintG)
                    colorSlider(label: "B", value: $glowTintB)
                }
                .onChange(of: glowTintR) { _, _ in updateTint() }
                .onChange(of: glowTintG) { _, _ in updateTint() }
                .onChange(of: glowTintB) { _, _ in updateTint() }
            }

            Button(action: { withAnimation { isVisible = false } }) {
                Text("Lock & Hide")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 20)
    }

    private func sliderRow(
        label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        format: String,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(value: value, in: range, step: step)
                .tint(.white.opacity(0.4))
                .onChange(of: value.wrappedValue) { _, new in
                    onChange(new)
                }
        }
    }

    private func colorSlider(label: String, value: Binding<Float>) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
            Slider(value: value, in: 0...1, step: 0.05)
                .tint(.white.opacity(0.4))
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private func updateTint() {
        onGlowTintChange(vector_float3(glowTintR, glowTintG, glowTintB))
    }
}
