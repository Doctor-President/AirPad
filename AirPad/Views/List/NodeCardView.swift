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
    let paletteIndex: Int
    let selected: Bool
    let dist: Int

    @State private var phase: Double = 0

    private let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    private var palette: CardPalette {
        CardPalette.all[paletteIndex % CardPalette.all.count]
    }

    var body: some View {
        ZStack {
            gradientFill
            cardContent
            innerGlow.blendMode(.overlay)
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .onAppear { phase = Double.random(in: 0...100) }
        .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 4)
    }

    // GRADIENT FILL
    private var gradientFill: some View {
        let colors = circleColors[paletteIndex % circleColors.count]
        return TimelineView(.animation) { timeline in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(Color(hexString: colors.0))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: -80 + sin(time * 0.3 + phase * 1.3) * 30,
                            y: cos(time * 0.25 + phase * 0.9) * 30)
                Circle()
                    .fill(Color(hexString: colors.1))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: sin(time * 0.35 + phase * 1.7) * 30,
                            y: cos(time * 0.3 + phase * 1.1) * 30)
                Circle()
                    .fill(Color(hexString: colors.2))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: 80 + sin(time * 0.4 + phase * 2.1) * 30,
                            y: cos(time * 0.35 + phase * 0.7) * 30)
            }
        }
    }

    // INNER GLOW
    // Source: inner glow rim div, list_view.jsx
    // Translated from inset box-shadow 4 layers:
    // inset 0 0 0 1.5px rgba(255,248,235,0.6)
    // inset 0 0 18px 3px rgba(255,225,195,0.48)
    // inset 0 0 42px 6px rgba(255,195,160,0.32)
    // inset 0 0 72px 10px rgba(220,160,255,0.2)
    // mixBlendMode: color-dodge
    private var innerGlow: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: [.black, Color.white.opacity(0.85)],
                    center: .center,
                    startRadius: geo.size.width * 0.15,
                    endRadius: geo.size.width * 0.72
                )
                RoundedRectangle(cornerRadius: 36)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
            }
        }
    }

    // CARD CONTENT
    // Source: content div, list_view.jsx
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.title.isEmpty ? "Untitled" : node.title)
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
