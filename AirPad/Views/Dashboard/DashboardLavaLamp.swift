import SwiftUI
import UIKit

/// Animated lavalamp background for the Dashboard (GPU `BlobField.metal`).
///
/// - **DARK** (unchanged): four additive Klein Blue + Electric Cyan blobs
///   drifting over the `Color.black` ground behind it. The shipped look.
/// - **LIGHT**: cyan/gold/rust blobs (T's baked values) on parchment, using the
///   SAME light path the node cards use — the shared `.pigmentOnParchment()` recipe
///   (source-over field composited `.plusDarker` over parchment, so saturated colour
///   reads as pigment darkening the paper, never a white smear). Card-STYLE
///   (source-over) blobs, NOT the additive lava, because additive overlaps blow out
///   under `.plusDarker`. A slight low-frequency noise domain-warp adds irregularity.
///   Values baked into `DashLavaLight.default` (tuner retired).
struct DashboardLavaLamp: View {
    @Environment(\.colorScheme) private var colorScheme

    // Dark (unchanged).
    private static let kleinBlue = Color(hexString: "1B59C2")
    private static let electricCyan = Color(hexString: "00BFFF")

    @AppStorage(DashLavaKey.light) private var lightJSON: String = DashLavaLight.defaultJSON

    private var light: DashLavaLight {
        DashLavaLight.decode(lightJSON) ?? .default
    }

    var body: some View {
        Group {
            if colorScheme == .dark {
                darkLava
            } else {
                lightPigment
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Dark (shipped, untouched)

    private var darkLava: some View {
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
    }

    // MARK: - Light (#3 — mango pigment on parchment)

    private var lightPigment: some View {
        let s = light
        return GeometryReader { geo in
            BlobFieldView(cardBlobs: Self.mangoBlobs(size: geo.size, style: s),
                          animated: true,
                          noiseAmount: s.noiseAmount,
                          noiseScale: s.noiseScale)
                .pigmentOnParchment()
        }
    }

    /// Four mango card-style blobs sized as fractions of the live canvas (the
    /// dashboard is much larger than a card, so positions/radii scale with it).
    private static func mangoBlobs(size: CGSize, style s: DashLavaLight) -> [BlobFieldView.CardBlob] {
        let minDim = min(size.width, size.height)
        let r = s.radiusScale * minDim
        let blur = s.blurScale * minDim
        let drift = s.driftScale * minDim
        // (baseXfrac, baseYfrac, fx, fy, px, py, colorIndex)
        let layout: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [
            (-0.28, -0.22, 0.30, 0.25, 1.3, 0.9, 0),
            ( 0.30, -0.30, 0.35, 0.30, 1.7, 1.1, 1),
            ( 0.02,  0.26, 0.40, 0.35, 2.1, 0.7, 2),
            (-0.20,  0.34, 0.26, 0.22, 0.9, 1.4, 0),
        ]
        return layout.map { l in
            BlobFieldView.CardBlob(
                baseOffset: CGPoint(x: l.0 * size.width, y: l.1 * size.height),
                radius: r,
                driftFreq: CGSize(width: l.2, height: l.3),
                driftPhase: CGSize(width: l.4, height: l.5),
                driftAmp: drift,
                blurWidth: blur,
                color: s.colors[l.6 % s.colors.count].color,
                peak: s.peak
            )
        }
    }
}

// MARK: - Light style (dialable → bake → delete)

struct DashLavaRGB: Codable, Equatable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

struct DashLavaLight: Codable, Equatable {
    var colors: [DashLavaRGB]      // mango family
    var peak: Double
    var radiusScale: Double        // blob radius as fraction of minDim
    var blurScale: Double          // falloff half-width as fraction of minDim
    var driftScale: Double         // drift amplitude as fraction of minDim
    var noiseAmount: Double
    var noiseScale: Double

    /// ★ T's device-dialed values, baked 2026-08-11. Blob 1 is CYAN, not the
    /// mango-family default it replaced — intended.
    static let `default` = DashLavaLight(
        colors: [
            DashLavaRGB(r: 0,          g: 0.7843902, b: 1.0),        // Electric Cyan ~#00C8FF
            DashLavaRGB(r: 0.98,       g: 0.80,      b: 0.28),       // Gold          ~#FACC47
            DashLavaRGB(r: 0.7517886,  g: 0.3963415, b: 0.1016260),  // Rust          ~#C0651A
        ],
        peak: 0.90,
        radiusScale: 0.55,
        blurScale: 0.20,
        driftScale: 0.14512196,
        noiseAmount: 23.203251,
        noiseScale: 2.4536586
    )

    static func decode(_ json: String) -> DashLavaLight? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DashLavaLight.self, from: d)
    }
    func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static let defaultJSON = DashLavaLight.default.encoded()
}

enum DashLavaKey { static let light = "dashlava.light" }

