import SwiftUI
import UIKit

/// Mac batch E6 (T ruled 2026-11-14) — a colour the user chose for a collection (or the Journal). "Automatic" (no entry)
/// stays the default: the palette-derived colour each place already shows. Kept in its OWN library file,
/// `collection-colors.json` (`{"version": 1, "colors": {"<collection id>": "#RRGGBB"}}`): the shipped 1.0 and 1.0.6
/// rewrite `collections.json` keeping only `id` + `name` (proved in the Simulator, Ops design-refs/mac-e/e6), so a
/// field there would be wiped by an older build; this file is one they never read or write. Synced like the other
/// library files: merged by key (`AggregateMerge`), watched, conflict versions united.
enum CollectionColors {
    static let fileName = "collection-colors.json"
    static let currentVersion = 1

    struct File: Codable, Equatable {
        var version: Int = CollectionColors.currentVersion
        var colors: [String: String] = [:]
    }

    /// The offered swatches, named (the names are what the picker reads out; the hex is the value stored).
    struct Swatch: Identifiable, Hashable {
        let name: String
        let hex: String
        var id: String { hex }
    }
    static let swatches: [Swatch] = [
        Swatch(name: "Klein", hex: "#1B59C2"),
        Swatch(name: "Cyan", hex: "#00BFFF"),
        Swatch(name: "Teal", hex: "#14A098"),
        Swatch(name: "Green", hex: "#3FA34D"),
        Swatch(name: "Lime", hex: "#A4C639"),
        Swatch(name: "Yellow", hex: "#F2C94C"),
        Swatch(name: "Mango", hex: "#E8820A"),
        Swatch(name: "Coral", hex: "#F2545B"),
        Swatch(name: "Red", hex: "#D7263D"),
        Swatch(name: "Magenta", hex: "#D6249F"),
        Swatch(name: "Violet", hex: "#7B2FF7"),
        Swatch(name: "Graphite", hex: "#6B7280"),
    ]

    /// "#RRGGBB" (upper case) from any "#rgb" / "rrggbb" form; nil if it isn't a colour.
    static func normalized(_ s: String) -> String? {
        var h = s.trimmingCharacters(in: .whitespaces).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, UInt32(h, radix: 16) != nil else { return nil }
        return "#" + h
    }

    static func uiColor(_ hex: String) -> UIColor? {
        guard let n = normalized(hex), let v = UInt32(n.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c255(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c255(r), c255(g), c255(b))
    }

    /// The swatch's name for a stored hex, or the hex itself (a custom colour).
    static func name(_ hex: String) -> String { swatches.first { $0.hex == normalized(hex) }?.name ?? (normalized(hex) ?? hex) }

    /// The collection id a Map territory key stands for ("col:<id>"), nil for tag territories.
    static func collectionID(territoryKey key: String) -> String? { key.hasPrefix("col:") ? String(key.dropFirst(4)) : nil }
}
