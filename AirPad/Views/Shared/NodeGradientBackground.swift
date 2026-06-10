import SwiftUI

/// Shared compositing recipe used by every node-surface visual: dark
/// base + three drifting tag-palette circles + a radial inner-glow
/// composited with `.blendMode(.overlay)`. The overlay blend is what
/// keeps overlapping circles vivid instead of muddying them to grey —
/// it preserves the centre (overlay against black is a no-op) and
/// brightens the rim (overlay against white screens the underlying).
/// No outer stroke rim here — that chrome lives on the consumer
/// (`NodeGradientBackground` adds it for cards; the hero omits it).
///
/// Used verbatim by `NodeGradientBackground` and `NodeDetailView.heroZone`
/// so the two surfaces are guaranteed identical by construction.
struct NodeGradientLayer: View {
    let node: Node
    /// Multiplier on circle DIAMETER (not blur). `1.0` (the default)
    /// matches the card geometry — `NodeGradientBackground` consumers
    /// inherit it untouched. `NodeDetailView.heroZone` passes a larger
    /// value so palette colour reaches close to all edges of the wider
    /// band without regressing the card. Blur radius is held constant
    /// at 40pt regardless of scale — scaling blur with size washes the
    /// pools into mud and erases the chroma the card design depends on.
    /// Offsets are NOT scaled either — circles spread out more by
    /// virtue of being bigger.
    var circleScale: CGFloat = 1.0

    @State private var phase: Double = Double.random(in: 0...100)

    private static let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    private var paletteIndex: Int {
        guard let tagName = node.primaryTag else { return 0 }
        switch tagName {
        case "pal0": return 0
        case "pal1": return 1
        case "pal2": return 2
        case "pal3": return 3
        case "pal4": return 4
        case "pal5": return 5
        case "pal6": return 6
        default: return abs(tagName.hashValue) % 7
        }
    }

    var body: some View {
        ZStack {
            gradientFill
            radialGlow.blendMode(.overlay)
        }
    }

    private var gradientFill: some View {
        let colors = Self.circleColors[paletteIndex % Self.circleColors.count]
        let size: CGFloat = 180 * circleScale
        return TimelineView(.animation) { timeline in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(Color(hexString: colors.0))
                    .frame(width: size, height: size)
                    .blur(radius: 40)
                    .offset(x: -80 + sin(time * 0.3 + phase * 1.3) * 30,
                            y: cos(time * 0.25 + phase * 0.9) * 30)
                Circle()
                    .fill(Color(hexString: colors.1))
                    .frame(width: size, height: size)
                    .blur(radius: 40)
                    .offset(x: sin(time * 0.35 + phase * 1.7) * 30,
                            y: cos(time * 0.3 + phase * 1.1) * 30)
                Circle()
                    .fill(Color(hexString: colors.2))
                    .frame(width: size, height: size)
                    .blur(radius: 40)
                    .offset(x: 80 + sin(time * 0.4 + phase * 2.1) * 30,
                            y: cos(time * 0.35 + phase * 0.7) * 30)
            }
        }
    }

    private var radialGlow: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [.black, Color.white.opacity(0.85)],
                center: .center,
                startRadius: geo.size.width * 0.15,
                endRadius: geo.size.width * 0.72
            )
        }
    }
}

/// Card-surface variant: the shared `NodeGradientLayer` plus the white
/// outline rim that frames every list/canvas/overlay card. The rim is
/// also overlay-blended so it picks up the underlying palette colour at
/// the edges instead of looking pasted on.
///
/// The view fills its container; consumers control sizing via `.frame`
/// and corner shape via `.clipShape`. The stroke rim follows `cornerRadius`.
struct NodeGradientBackground: View {
    let node: Node
    var cornerRadius: CGFloat = 36

    var body: some View {
        ZStack {
            NodeGradientLayer(node: node)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                .blendMode(.overlay)
        }
    }
}
