// NodeCardView.swift
// Translated line-for-line from list_view.jsx — BarrelCard component
// DO NOT modify values without explicit instruction

import SwiftUI

// Non-optional Color hex initializer for palette colors
extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else {
            self = .clear
            return
        }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// CARD PALETTES
// Source: CARD_PALETTES array in list_view.jsx
struct CardPalette {
    let a: Color
    let b: Color
    let c: Color
    let d: Color

    static let all: [CardPalette] = [
        // Deep violet / ember — cool left, hot right
        CardPalette(a: Color(hexString: "2D0A5E"), b: Color(hexString: "C43C2A"), c: Color(hexString: "7A52FF"), d: Color(hexString: "E36B4E")),
        // Ocean deep / coral — near-black teal left, warm coral right
        CardPalette(a: Color(hexString: "041E2A"), b: Color(hexString: "E36B4E"), c: Color(hexString: "0A4A5E"), d: Color(hexString: "FFD7C2")),
        // Forest night / amber — deep green left, warm gold right
        CardPalette(a: Color(hexString: "071A0A"), b: Color(hexString: "D4830A"), c: Color(hexString: "0A3A14"), d: Color(hexString: "E6A020")),
        // Midnight indigo / rose — near-black indigo left, deep rose right
        CardPalette(a: Color(hexString: "0A0520"), b: Color(hexString: "9D174D"), c: Color(hexString: "1A0A3D"), d: Color(hexString: "B857D4")),
        // Slate / electric magenta — dark slate left, vivid magenta right
        CardPalette(a: Color(hexString: "0A1020"), b: Color(hexString: "B857D4"), c: Color(hexString: "1A2A4A"), d: Color(hexString: "7A52FF")),
        // Deep teal / coral — dark teal left, warm coral right
        CardPalette(a: Color(hexString: "041A1A"), b: Color(hexString: "E36B4E"), c: Color(hexString: "0A3A3A"), d: Color(hexString: "C43C2A")),
        // Navy / amber gold — near-black navy left, warm amber right
        CardPalette(a: Color(hexString: "030A1A"), b: Color(hexString: "C47A0A"), c: Color(hexString: "0D1B5E"), d: Color(hexString: "E6A020")),
    ]
}

struct NodeCardView: View {
    let node: Node
    let selected: Bool
    let dist: Int

    var body: some View {
        ZStack {
            NodeGradientBackground(node: node, cornerRadius: 36)
            cardContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 4)
    }

    // CARD CONTENT
    // Source: content div, list_view.jsx
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.title.isEmpty ? (node.items.first?.content ?? "Untitled") : node.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                .lineLimit(1)

            if !node.summary.isEmpty {
                Text(node.summary)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .foregroundColor(.white.opacity(0.84))
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .lineLimit(2)
            }

            Spacer()

            HStack {
                Image(systemName: "doc")
                    .font(.system(size: 13))
                    .opacity(0.85)
                Spacer()
                Text(node.relativeTimestamp)
                    .font(.system(size: 11.5))
            }
            .foregroundColor(.white.opacity(0.75))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
