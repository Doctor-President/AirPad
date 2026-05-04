import SwiftUI

/// Single source of truth for the animated tag-colored gradient + inner glow used
/// to render a node across surfaces: list cards, the focal engagement overlay, and
/// the zoomed detail overlay. Three drifting circles in the node's tag palette,
/// over the canvas background color, with a radial inner-glow rim.
///
/// The view fills its container; consumers control sizing via .frame and corner
/// shape via .clipShape. The stroke rim follows `cornerRadius`.
struct NodeGradientBackground: View {
    let node: Node
    var cornerRadius: CGFloat = 36

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
            innerGlow.blendMode(.overlay)
        }
    }

    private var gradientFill: some View {
        let colors = Self.circleColors[paletteIndex % Self.circleColors.count]
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

    private var innerGlow: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: [.black, Color.white.opacity(0.85)],
                    center: .center,
                    startRadius: geo.size.width * 0.15,
                    endRadius: geo.size.width * 0.72
                )
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}
