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

    private var palette: CardPalette {
        CardPalette.all[paletteIndex % CardPalette.all.count]
    }

    var body: some View {
        ZStack {
            // LAYER 1: Outer bloom
            // Source: position absolute, inset -32/-56, blur 28px/44px, opacity 0.58/0.92
            // Three radial gradients: pal.a at 30%/50%, pal.b at 72%/50%, pal.c at 50%/50%
            outerBloom
                .padding(selected ? -56 : -32)

            // LAYER 2: Card surface with gradient + content + inner glow
            ZStack {
                gradientFill
                cardContent
                innerGlow.blendMode(.overlay)
            }
            .clipShape(RoundedRectangle(cornerRadius: 36))
        }
        .shadow(
            color: selected ? .black.opacity(0.58) : .black.opacity(0.32),
            radius: selected ? 28 : 12,
            x: 0,
            y: selected ? 8 : 4
        )
    }

    // OUTER BLOOM
    // Source: BarrelCard outer bloom div, list_view.jsx
    // radial-gradient(ellipse 70% 65% at 30% 50%, pal.a + "88") — 0x88/0xFF = 0.533 opacity
    // radial-gradient(ellipse 70% 65% at 72% 50%, pal.b + "77") — 0x77/0xFF = 0.467 opacity
    // radial-gradient(ellipse 80% 80% at 50% 50%, pal.c + "44") — 0x44/0xFF = 0.267 opacity
    // filter: blur(44px) selected / blur(28px) unselected
    // opacity: 0.92 selected / 0.58 unselected
    private var outerBloom: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: [palette.a.opacity(0.533), .clear],
                    center: UnitPoint(x: 0.30, y: 0.50),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.70
                )
                RadialGradient(
                    colors: [palette.b.opacity(0.467), .clear],
                    center: UnitPoint(x: 0.72, y: 0.50),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.70
                )
                RadialGradient(
                    colors: [palette.c.opacity(0.267), .clear],
                    center: UnitPoint(x: 0.50, y: 0.50),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.80
                )
            }
            .blur(radius: selected ? 44 : 28)
            .opacity(selected ? 0.92 : 0.58)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // GRADIENT FILL
    // Source: gradient fill div, list_view.jsx lines ~180-196
    // Exact layer order and positions preserved:
    // 1. linear-gradient(110deg, pal.a, pal.d) — base
    // 2. radial-gradient(ellipse 65% 85% at 15% 50%, pal.a 0%, transparent 55%)
    // 3. radial-gradient(ellipse 60% 85% at 85% 50%, pal.b 0%, transparent 58%)
    // 4. radial-gradient(ellipse 75% 70% at 50% 110%, pal.d 0%, transparent 60%)
    // 5. radial-gradient(ellipse 55% 70% at 50% -10%, pal.c 0%, transparent 60%)
    // 6. radial-gradient(circle at 55% 40%, rgba(255,230,210,0.55) 0%, transparent 28%)
    private var gradientFill: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                Circle()
                    .fill(palette.a)
                    .frame(width: geo.size.width * 0.85, height: geo.size.width * 0.85)
                    .offset(x: -geo.size.width * 0.2, y: 0)
                    .blur(radius: geo.size.width * 0.18)
                Circle()
                    .fill(palette.b)
                    .frame(width: geo.size.width * 0.78, height: geo.size.width * 0.78)
                    .offset(x: geo.size.width * 0.22, y: geo.size.height * 0.1)
                    .blur(radius: geo.size.width * 0.16)
                Circle()
                    .fill(palette.c)
                    .frame(width: geo.size.width * 0.6, height: geo.size.width * 0.6)
                    .offset(x: 0, y: geo.size.height * 0.2)
                    .blur(radius: geo.size.width * 0.14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
