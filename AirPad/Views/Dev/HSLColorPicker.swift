#if DEBUG
import SwiftUI

/// A native HSL picker (DEBUG): a 2-D saturation×lightness field, a hue strip, a lightness strip,
/// numeric H/S/L fields, and an editable/copyable HEX field — all bound to one hex string, live.
/// T is colourblind, so the HEX field is first-class (he reads/types/copies hex, not swatches).
struct HSLColorPicker: View {
    @Binding var hex: String
    var onCommit: () -> Void = {}

    @State private var h: Double = 0   // 0…360
    @State private var s: Double = 0   // 0…1
    @State private var l: Double = 0   // 0…1
    @State private var hexField: String = ""

    var body: some View {
        VStack(spacing: 12) {
            slField.frame(height: 180)
            hueStrip.frame(height: 22)
            lightnessStrip.frame(height: 22)
            numericRow
            hexRow
        }
        .onAppear { derive(from: hex) }
        .onChange(of: hex) { _, new in
            if PaletteColor.hslHex(CGFloat(h), CGFloat(s), CGFloat(l)).uppercased() != new.uppercased() {
                derive(from: new)
            }
        }
    }

    private func derive(from hexStr: String) {
        let (hh, ss, ll) = PaletteColor.hexToHSL(hexStr)
        h = Double(hh); s = Double(ss); l = Double(ll)
        hexField = hexStr.uppercased()
    }
    private func push() {
        let out = PaletteColor.hslHex(CGFloat(h), CGFloat(s), CGFloat(l))
        hexField = out
        hex = out
        onCommit()
    }

    // 2-D field: x = saturation, y = lightness (top = 1). Background redraws only when hue changes.
    private var slField: some View {
        GeometryReader { geo in
            let w = geo.size.width, ht = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let cols = 36, rows = 24
                    let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
                    for i in 0..<cols {
                        for j in 0..<rows {
                            let sv = CGFloat(i) / CGFloat(cols - 1)
                            let lv = 1 - CGFloat(j) / CGFloat(rows - 1)
                            let (r, g, b) = PaletteColor.hslToRGB(CGFloat(h), sv, lv)
                            ctx.fill(Path(CGRect(x: CGFloat(i) * cw - 0.5, y: CGFloat(j) * ch - 0.5, width: cw + 1, height: ch + 1)),
                                     with: .color(Color(red: r, green: g, blue: b)))
                        }
                    }
                }
                marker.position(x: CGFloat(s) * w, y: (1 - CGFloat(l)) * ht)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                s = Double(min(max(v.location.x / w, 0), 1))
                l = Double(min(max(1 - v.location.y / ht, 0), 1))
                push()
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
    }

    private var hueStrip: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                    let (r, g, b) = PaletteColor.hslToRGB(CGFloat($0), 1, 0.5); return Color(red: r, green: g, blue: b)
                }, startPoint: .leading, endPoint: .trailing)
                marker.position(x: CGFloat(h / 360) * w, y: geo.size.height / 2)
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                h = Double(min(max(v.location.x / w, 0), 1)) * 360; push()
            })
        }
    }

    private var lightnessStrip: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
                    let (r, g, b) = PaletteColor.hslToRGB(CGFloat(h), CGFloat(s), CGFloat($0)); return Color(red: r, green: g, blue: b)
                }, startPoint: .leading, endPoint: .trailing)
                marker.position(x: CGFloat(l) * w, y: geo.size.height / 2)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                l = Double(min(max(v.location.x / w, 0), 1)); push()
            })
        }
    }

    private var marker: some View {
        Circle().fill(.clear)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 3.5).padding(0.5))
            .shadow(radius: 1)
    }

    private var numericRow: some View {
        HStack(spacing: 8) {
            numField("H", value: $h, range: 0...360, fmt: "%.0f")
            numField("S", value: $s, range: 0...1, fmt: "%.2f")
            numField("L", value: $l, range: 0...1, fmt: "%.2f")
        }
    }
    private func numField(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { String(format: fmt, value.wrappedValue) },
                set: { if let v = Double($0) { value.wrappedValue = min(max(v, range.lowerBound), range.upperBound); push() } }
            ))
            .keyboardType(.decimalPad).multilineTextAlignment(.center)
            .font(.system(size: 13, design: .monospaced))
            .padding(.vertical, 5).background(.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var hexRow: some View {
        HStack(spacing: 8) {
            Text("#").font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            TextField("HEX", text: $hexField)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .onSubmit { commitHexField() }
            Button { commitHexField() } label: { Image(systemName: "checkmark.circle.fill") }
            Button { UIPasteboard.general.string = "#" + hexField } label: { Image(systemName: "doc.on.doc") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func commitHexField() {
        let clean = hexField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "").uppercased()
        guard clean.count == 6, UInt64(clean, radix: 16) != nil else { hexField = hex.uppercased(); return }
        hex = clean; derive(from: clean); onCommit()
    }
}
#endif
