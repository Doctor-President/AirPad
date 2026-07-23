import SwiftUI
import UIKit

/// Animated lavalamp background for the Dashboard (GPU `BlobField.metal`).
///
/// - **DARK** (unchanged): four additive Klein Blue + Electric Cyan blobs
///   drifting over the `Color.black` ground behind it. The shipped look.
/// - **LIGHT** (#3): mango-family blobs on parchment, using the SAME light path
///   the node cards use — the shared `.pigmentOnParchment()` recipe (source-over
///   field composited `.plusDarker` over parchment, so saturated colour reads as
///   pigment darkening the paper, never a white smear). Card-STYLE (source-over)
///   blobs, NOT the additive lava, because additive overlaps blow out under
///   `.plusDarker`. A slight low-frequency noise domain-warp adds irregularity.
///   All light values are dialable via `DashLavaTuningPanel` (bake-and-delete).
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

    static let `default` = DashLavaLight(
        colors: [
            DashLavaRGB(r: 0.91, g: 0.51, b: 0.04),   // Mango  #E8820A
            DashLavaRGB(r: 0.95, g: 0.66, b: 0.23),   // Amber  #F2A93B
            DashLavaRGB(r: 0.89, g: 0.42, b: 0.30),   // Coral  #E36B4E
        ],
        peak: 0.90,
        radiusScale: 0.55,
        blurScale: 0.20,
        driftScale: 0.05,
        noiseAmount: 8.0,
        noiseScale: 0.9
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

#if DEBUG
/// Floating tuner for the LIGHT dashboard lava lamp (mango colours + irregularity
/// + canvas scale). Dark is fixed (shipped), so this dials light only. Bake T's
/// values into `DashLavaLight.default` then delete this + the CopyRow.
struct DashLavaTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize
    @AppStorage(DashLavaKey.light) private var lightJSON: String = DashLavaLight.defaultJSON
    @State private var dragStart: CGSize? = nil

    private static let palette: [(String, DashLavaRGB)] = [
        ("Mango", DashLavaRGB(r: 0.91, g: 0.51, b: 0.04)),
        ("Amber", DashLavaRGB(r: 0.95, g: 0.66, b: 0.23)),
        ("Coral", DashLavaRGB(r: 0.89, g: 0.42, b: 0.30)),
        ("Gold",  DashLavaRGB(r: 0.98, g: 0.80, b: 0.28)),
        ("Rust",  DashLavaRGB(r: 0.72, g: 0.30, b: 0.10)),
    ]

    private var style: Binding<DashLavaLight> {
        Binding(
            get: { DashLavaLight.decode(lightJSON) ?? .default },
            set: { lightJSON = $0.encoded() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<style.wrappedValue.colors.count, id: \.self) { i in
                        colorRow("BLOB \(i + 1)", style.colors[i])
                    }
                    Divider().overlay(Color.white.opacity(0.15))
                    slider("Peak", style.peak, 0...1)
                    slider("Radius", style.radiusScale, 0.2...1.0)
                    slider("Blur", style.blurScale, 0.02...0.5)
                    slider("Drift", style.driftScale, 0...0.2)
                    slider("Noise amt", style.noiseAmount, 0...40)
                    slider("Noise scale", style.noiseScale, 0.1...4)
                    copyRow
                }.padding(12)
            }.frame(maxHeight: 420)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
        .offset(position)
    }

    private var header: some View {
        HStack {
            Text("Dash Lava · LIGHT").font(.system(size: 13, weight: .bold, design: .monospaced))
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 12).contentShape(Rectangle())
        .gesture(DragGesture()
            .onChanged { v in
                let base = dragStart ?? position
                if dragStart == nil { dragStart = position }
                position = CGSize(width: base.width + v.translation.width,
                                  height: base.height + v.translation.height)
            }
            .onEnded { _ in dragStart = nil })
    }

    private func colorRow(_ title: String, _ c: Binding<DashLavaRGB>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.6)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(c.wrappedValue.color)
                    .frame(width: 26, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.palette, id: \.0) { name, rgb in
                        Button { c.wrappedValue = rgb } label: {
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3).fill(rgb.color).frame(width: 20, height: 12)
                                Text(name).font(.system(size: 7)).opacity(0.6)
                            }.frame(width: 32)
                        }.buttonStyle(.plain)
                    }
                }
            }
            slider("R", c.r, 0...1); slider("G", c.g, 0...1); slider("B", c.b, 0...1)
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, design: .monospaced)).frame(width: 62, alignment: .leading).opacity(0.7)
            Slider(value: v, in: range)
            Text(String(format: "%.2f", v.wrappedValue)).font(.system(size: 9, design: .monospaced))
                .frame(width: 34, alignment: .trailing).opacity(0.7)
        }
    }

    private var copyRow: some View {
        Button {
            UIPasteboard.general.string = lightJSON
            print("DASHLAVA>\n\(lightJSON)")
        } label: {
            Label("Copy LIGHT values", systemImage: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }.buttonStyle(.plain)
    }
}
#endif
