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

    @AppStorage(DashLavaKey.light) private var lightJSON: String = DashLavaLight.defaultJSON
    @AppStorage(DashLavaKey.dark)  private var darkJSON: String = DashLavaDark.defaultJSON

    private var light: DashLavaLight { DashLavaLight.decode(lightJSON) ?? .default }
    private var dark:  DashLavaDark  { DashLavaDark.decode(darkJSON) ?? .default }

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

    // MARK: - Dark (additive lava; parameterized, same look)

    private var darkLava: some View {
        let d = dark
        return BlobFieldView(parameters: .init(
            blobs: d.blobs.map {
                .init(origin: CGPoint(x: $0.originX, y: $0.originY), radius: CGFloat($0.radius),
                      speed: CGSize(width: $0.speedX, height: $0.speedY),
                      phase: CGFloat($0.phase), color: $0.color.color, peak: CGFloat($0.peak))
            },
            sharedField: d.sharedField
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

enum DashLavaKey {
    static let light = "dashlava.light"
    static let dark  = "dashlava.dark"
}

// MARK: - Dark style (parameterized for tuning; STEP 1 = no look change)

/// One dark additive lava blob (Codable mirror of `BlobFieldView.Blob`; CGPoint/
/// CGSize flattened to Doubles for JSON).
struct DashLavaDarkBlob: Codable, Equatable {
    var originX: Double, originY: Double
    var radius: Double
    var speedX: Double, speedY: Double
    var phase: Double
    var color: DashLavaRGB
    var peak: Double
}

/// Mirrors `DashLavaLight` for the DARK additive lava. `.default` holds the CURRENT
/// hardcoded values BYTE-FOR-BYTE (colors are the Klein Blue / Electric Cyan hex
/// as RGB); dark keeps its additive path — do NOT converge it onto the light
/// pigment recipe. Dialable via `DashLavaDarkTuningPanel` (bake → delete).
struct DashLavaDark: Codable, Equatable {
    var blobs: [DashLavaDarkBlob]
    var sharedField: Bool

    static let `default` = DashLavaDark(
        blobs: [
            DashLavaDarkBlob(originX: 0.22, originY: 0.30, radius: 0.56, speedX: 0.00020, speedY: 0.00014,
                             phase: 0.0, color: DashLavaRGB(r: 27.0/255.0, g: 89.0/255.0, b: 194.0/255.0), peak: 0.85),  // Klein Blue #1B59C2
            DashLavaDarkBlob(originX: 0.78, originY: 0.22, radius: 0.50, speedX: 0.00016, speedY: 0.00026,
                             phase: 1.2, color: DashLavaRGB(r: 0.0, g: 191.0/255.0, b: 1.0), peak: 0.55),                // Electric Cyan #00BFFF
            DashLavaDarkBlob(originX: 0.50, originY: 0.74, radius: 0.62, speedX: 0.00024, speedY: 0.00018,
                             phase: 2.4, color: DashLavaRGB(r: 27.0/255.0, g: 89.0/255.0, b: 194.0/255.0), peak: 0.85),
            DashLavaDarkBlob(originX: 0.16, originY: 0.80, radius: 0.46, speedX: 0.00013, speedY: 0.00022,
                             phase: 3.8, color: DashLavaRGB(r: 0.0, g: 191.0/255.0, b: 1.0), peak: 0.50),
        ],
        sharedField: false
    )

    static func decode(_ json: String) -> DashLavaDark? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DashLavaDark.self, from: d)
    }
    func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static let defaultJSON = DashLavaDark.default.encoded()
}

#if DEBUG
/// DEBUG tuner for the DARK dashboard lava — per-blob colour/radius/peak/origin/
/// speed/phase + the additive path's `sharedField`. Bake T's values into
/// `DashLavaDark.default` then delete this. (Mirrors the retired light tuner.)
struct DashLavaDarkTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize
    @AppStorage(DashLavaKey.dark) private var darkJSON: String = DashLavaDark.defaultJSON
    @State private var dragStart: CGSize? = nil

    private static let palette: [(String, DashLavaRGB)] = [
        ("Klein", DashLavaRGB(r: 27.0/255.0, g: 89.0/255.0, b: 194.0/255.0)),
        ("Cyan",  DashLavaRGB(r: 0, g: 191.0/255.0, b: 1.0)),
        ("Mango", DashLavaRGB(r: 0.91, g: 0.51, b: 0.04)),
        ("Gold",  DashLavaRGB(r: 0.98, g: 0.80, b: 0.28)),
        ("Rust",  DashLavaRGB(r: 0.72, g: 0.30, b: 0.10)),
    ]

    private var style: Binding<DashLavaDark> {
        Binding(get: { DashLavaDark.decode(darkJSON) ?? .default },
                set: { darkJSON = $0.encoded() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<style.wrappedValue.blobs.count, id: \.self) { i in
                        blobSection(i)
                    }
                    Toggle("Shared field", isOn: style.sharedField)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    copyRow
                }.padding(12)
            }.frame(maxHeight: 460)
        }
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
        .offset(position)
    }

    private var header: some View {
        HStack {
            Text("Dash Lava · DARK").font(.system(size: 13, weight: .bold, design: .monospaced))
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

    private func blobSection(_ i: Int) -> some View {
        let b = style.blobs[i]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BLOB \(i + 1)").font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.7)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(b.wrappedValue.color.color)
                    .frame(width: 26, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.palette, id: \.0) { name, rgb in
                        Button { b.color.wrappedValue = rgb } label: {
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 3).fill(rgb.color).frame(width: 20, height: 12)
                                Text(name).font(.system(size: 7)).opacity(0.6)
                            }.frame(width: 32)
                        }.buttonStyle(.plain)
                    }
                }
            }
            slider("R", b.color.r, 0...1); slider("G", b.color.g, 0...1); slider("B", b.color.b, 0...1)
            slider("Peak", b.peak, 0...1)
            slider("Radius", b.radius, 0.1...1.2)
            slider("Origin X", b.originX, 0...1); slider("Origin Y", b.originY, 0...1)
            slider("Speed X", b.speedX, 0...0.001, "%.5f"); slider("Speed Y", b.speedY, 0...0.001, "%.5f")
            slider("Phase", b.phase, 0...6.283)
            Divider().overlay(Color.white.opacity(0.15))
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String = "%.2f") -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, design: .monospaced)).frame(width: 62, alignment: .leading).opacity(0.7)
            Slider(value: v, in: range)
            Text(String(format: fmt, v.wrappedValue)).font(.system(size: 9, design: .monospaced))
                .frame(width: 44, alignment: .trailing).opacity(0.7)
        }
    }

    private var copyRow: some View {
        Button {
            UIPasteboard.general.string = darkJSON
            print("DASHLAVA·DARK>\n\(darkJSON)")
        } label: {
            Label("Copy DARK values", systemImage: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        }.buttonStyle(.plain)
    }
}
#endif

