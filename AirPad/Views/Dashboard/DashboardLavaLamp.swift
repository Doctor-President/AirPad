import SwiftUI
import UIKit

/// Animated lavalamp background for the Dashboard (GPU `BlobField.metal`).
///
/// - **DARK**: T's baked additive lava — dialed cyan/blue blobs over the
///   `Color.black` ground, `sharedField` on. Values in `DashLavaDark.default`.
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

    // MARK: - Dark (additive lava; T's baked values)

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

// MARK: - Dark style (T's baked values; tuner retired)

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

/// Mirrors `DashLavaLight` for the DARK additive lava. `.default` holds T's baked
/// device-dialed values; dark keeps its ADDITIVE path — do NOT converge it onto
/// the light pigment recipe (different grounds, different compositing).
struct DashLavaDark: Codable, Equatable {
    var blobs: [DashLavaDarkBlob]
    var sharedField: Bool

    /// ★ T's device-dialed DARK values, baked 2026-08-12. sharedField ON; blob 2
    /// dialed to peak 0 (removed). Values are the copy-dump verbatim.
    static let `default` = DashLavaDark(
        blobs: [
            DashLavaDarkBlob(originX: 0.22, originY: 0.3, radius: 0.569047611951828, speedX: 0.001, speedY: 0.001,
                             phase: 0, color: DashLavaRGB(r: 0, g: 0.21770860254764557, b: 1), peak: 1),
            DashLavaDarkBlob(originX: 0.78, originY: 0.22, radius: 0.9047618865966796, speedX: 0.00016, speedY: 0.00026,
                             phase: 0, color: DashLavaRGB(r: 0, g: 0.19471164047718048, b: 0.7630341053009033), peak: 0),
            DashLavaDarkBlob(originX: 0.04347684606909752, originY: 0.9418398141860962, radius: 0.6557142615318298, speedX: 0.00024, speedY: 0.0005346380472183227,
                             phase: 5.277698114454746, color: DashLavaRGB(r: 0.10588235294117647, g: 0.34901960784313724, b: 0.7607843137254902), peak: 1),
            DashLavaDarkBlob(originX: 1, originY: 1, radius: 0.59874729514122, speedX: 0.00013, speedY: 0.00022,
                             phase: 3.8, color: DashLavaRGB(r: 0.10588235294117647, g: 0.018795641139149666, b: 0.6282270550727844), peak: 1),
        ],
        sharedField: true
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
/// Brief AT4 — RESTORED dark Dashboard lava tuner (from git `02f1314`; deleted in `bb7f2fa`). DARK only,
/// TestFlight DEBUG-in-Release. Per-blob ColorPicker + hex (T verifies with a picker) + palette swatches +
/// peak/radius/origin/speed/phase, shared-field toggle, Copy. Reads/writes the same `@AppStorage(DashLavaKey
/// .dark)` the lava renders from → live preview. T dials → Copy → bake into `DashLavaDark.default` → delete.
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
                    ForEach(0..<style.wrappedValue.blobs.count, id: \.self) { i in blobSection(i) }
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
                Text("#\(Self.hex(b.wrappedValue.color.color))").font(.system(size: 9, design: .monospaced)).opacity(0.7)
            }
            ColorPicker("Colour", selection: colorBinding(b.color), supportsOpacity: false)
                .font(.system(size: 11, design: .monospaced))
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
            slider("Peak", b.peak, 0...1)
            slider("Radius", b.radius, 0.1...1.2)
            slider("Origin X", b.originX, 0...1); slider("Origin Y", b.originY, 0...1)
            slider("Speed X", b.speedX, 0...0.001, "%.5f"); slider("Speed Y", b.speedY, 0...0.001, "%.5f")
            slider("Phase", b.phase, 0...6.283)
            Divider().overlay(Color.white.opacity(0.15))
        }
    }

    private func colorBinding(_ rgb: Binding<DashLavaRGB>) -> Binding<Color> {
        Binding(get: { rgb.wrappedValue.color },
                set: { c in
                    var r: CGFloat = 0, g: CGFloat = 0, bb: CGFloat = 0, a: CGFloat = 0
                    UIColor(c).getRed(&r, green: &g, blue: &bb, alpha: &a)
                    rgb.wrappedValue = DashLavaRGB(r: Double(r), g: Double(g), b: Double(bb))
                })
    }
    static func hex(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
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
