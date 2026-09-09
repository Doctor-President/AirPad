#if DEBUG
import SwiftUI

/// Colour math for the palette tuner (DEBUG). Hex ↔ sRGB ↔ HSL, so the HSL picker and the token
/// resolvers speak the same language. Hex is 6-digit, no `#`. H in 0…360, S/L in 0…1.
enum PaletteColor {

    /// Parse a 6-digit sRGB hex (with or without `#`) into 0…1 components. Bad input → black.
    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return (0, 0, 0) }
        return (CGFloat((v >> 16) & 0xFF) / 255.0,
                CGFloat((v >> 8) & 0xFF) / 255.0,
                CGFloat(v & 0xFF) / 255.0)
    }

    static func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    static func color(_ hex: String) -> Color {
        let (r, g, b) = rgb(hex); return Color(red: r, green: g, blue: b)
    }

    /// sRGB → HSL. H 0…360, S/L 0…1.
    static func rgbToHSL(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }   // achromatic
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: CGFloat
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    /// HSL → sRGB. H 0…360, S/L 0…1.
    static func hslToRGB(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard s != 0 else { return (l, l, l) }     // achromatic
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hk = h / 360
        func hue(_ t0: CGFloat) -> CGFloat {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return (hue(hk + 1/3), hue(hk), hue(hk - 1/3))
    }

    static func hslHex(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> String {
        let (r, g, b) = hslToRGB(h, s, l); return hex(r, g, b)
    }
    static func hexToHSL(_ hexStr: String) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
        let (r, g, b) = rgb(hexStr); return rgbToHSL(r, g, b)
    }
}
#endif
