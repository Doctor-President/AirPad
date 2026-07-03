import SwiftUI

/// Animated lavalamp background for the Dashboard. Four soft blobs in
/// Klein Blue + Electric Cyan drift slowly via sin/cos offset, computed on
/// the GPU by `BlobFieldView` (Metal `BlobField.metal`). Previously a
/// pure-Swift `Canvas` + `.blur(radius: 26)` that re-rasterized the whole
/// fullscreen background in software every frame — the source of the
/// fullscreen freeze (ws-render-perf PERF FIX 3). The shader's radial
/// falloff replaces the blur; nothing rasterizes on the CPU anymore.
struct DashboardLavaLamp: View {
    private static let kleinBlue = Color(hexString: "1B59C2")
    private static let electricCyan = Color(hexString: "00BFFF")

    var body: some View {
        BlobFieldView(parameters: .init(
            blobs: [
                .init(origin: CGPoint(x: 0.22, y: 0.30), radius: 0.56,
                      speed: CGSize(width: 0.00020, height: 0.00014),
                      phase: 0.0, color: Self.kleinBlue,    peak: 0.85),
                .init(origin: CGPoint(x: 0.78, y: 0.22), radius: 0.50,
                      speed: CGSize(width: 0.00016, height: 0.00026),
                      phase: 1.2, color: Self.electricCyan, peak: 0.55),
                .init(origin: CGPoint(x: 0.50, y: 0.74), radius: 0.62,
                      speed: CGSize(width: 0.00024, height: 0.00018),
                      phase: 2.4, color: Self.kleinBlue,    peak: 0.85),
                .init(origin: CGPoint(x: 0.16, y: 0.80), radius: 0.46,
                      speed: CGSize(width: 0.00013, height: 0.00022),
                      phase: 3.8, color: Self.electricCyan, peak: 0.50),
            ],
            sharedField: false
        ))
        .ignoresSafeArea()
    }
}
