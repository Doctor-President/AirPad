import SwiftUI
import UIKit

struct CardBlurTest: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { container in
                ScrollView {
                    VStack(spacing: 16) {
                        CardItemView(id: 0, color1: "E36B4E", color2: "F5C5A3", color3: "B89FE8",
                                    title: "Emergence in Darkness",
                                    summary: "A group of individuals finds themselves in a dark, empty space, resolving to walk forward.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 1, color1: "7A52FF", color2: "0A9ECC", color3: "E36B4E",
                                    title: "Digital Horizons",
                                    summary: "When code becomes consciousness, the boundaries between human and machine blur.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 2, color1: "2ECC71", color2: "D4830A", color3: "1A8FE3",
                                    title: "The Garden Protocol",
                                    summary: "Nature's algorithms run deeper than any system we could design.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 3, color1: "E91E8C", color2: "7A52FF", color3: "FF6B35",
                                    title: "Neon Memories",
                                    summary: "In the city of light, shadows hold the stories we've forgotten.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 4, color1: "E36B4E", color2: "F5C5A3", color3: "B89FE8",
                                    title: "Silent Frequencies",
                                    summary: "Between the noise, there exists a signal only some can hear.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 5, color1: "7A52FF", color2: "0A9ECC", color3: "E36B4E",
                                    title: "Quantum Drift",
                                    summary: "Probability waves collapse into certainty, but only when observed.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 6, color1: "2ECC71", color2: "D4830A", color3: "1A8FE3",
                                    title: "Echoes of Tomorrow",
                                    summary: "The future remembers what we haven't yet forgotten.",
                                    containerHeight: container.size.height)
                        CardItemView(id: 7, color1: "E91E8C", color2: "7A52FF", color3: "FF6B35",
                                    title: "Liminal Spaces",
                                    summary: "Between states of being, transformation quietly unfolds.",
                                    containerHeight: container.size.height)
                    }
                    .frame(width: UIScreen.main.bounds.width, alignment: .center)
                    .padding(.vertical, 40)
                }
                .frame(width: UIScreen.main.bounds.width)
            }
        }
    }
}

struct CardItemView: View {
    let id: Int
    let color1: String
    let color2: String
    let color3: String
    let title: String
    let summary: String
    let containerHeight: CGFloat

    @State private var cachedGlow: UIImage? = nil

    var body: some View {
        GeometryReader { cardGeo in
            let cardCenter = cardGeo.frame(in: .global).midY
            let containerCenter = containerHeight / 2
            let distance = abs(cardCenter - containerCenter)
            let scale = max(0.75, 1.0 - distance / containerHeight * 1.5)
            let opacity = max(0.55, 1.0 - distance / containerHeight * 1.2)

            ZStack {
                TimelineView(.animation) { timeline in
                    ZStack {
                        Color(red: 0.027, green: 0.027, blue: 0.039)
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        Circle()
                            .fill(Color(hexString: color1))
                            .frame(width: 180, height: 180)
                            .blur(radius: 40)
                            .offset(x: -80 + sin(time * 0.3) * 30, y: cos(time * 0.25) * 30)
                        Circle()
                            .fill(Color(hexString: color2))
                            .frame(width: 180, height: 180)
                            .blur(radius: 40)
                            .offset(x: 0 + sin(time * 0.35) * 30, y: cos(time * 0.3) * 30)
                        Circle()
                            .fill(Color(hexString: color3))
                            .frame(width: 180, height: 180)
                            .blur(radius: 40)
                            .offset(x: 80 + sin(time * 0.4) * 30, y: cos(time * 0.35) * 30)
                    }
                }
                .frame(width: 360, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 36))

                if let glow = cachedGlow {
                    Image(uiImage: glow)
                        .resizable()
                        .frame(width: 560, height: 360)
                        .blendMode(.overlay)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                        .lineLimit(1)
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.84))
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .lineLimit(2)
                    Spacer()
                    HStack {
                        Image(systemName: "doc")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Text("2hrs ago")
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .padding(18)
                .frame(width: 360, height: 160)
            }
            .frame(width: 360, height: 160)
            .scaleEffect(scale)
            .opacity(opacity)
            .animation(.spring(response: 0.38, dampingFraction: 0.72), value: distance)
            .padding(.horizontal, (UIScreen.main.bounds.width - 360) / 2)
            .onAppear {
                if cachedGlow == nil {
                    cachedGlow = buildGlow()
                }
            }
        }
        .frame(height: 160)
    }

    private func buildGlow() -> UIImage {
        let padding: CGFloat = 100
        let w = 360 + padding * 2
        let h = 160 + padding * 2
        let rect = CGRect(x: padding, y: padding, width: 360, height: 160)

        let softImg = UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            let p = UIBezierPath(roundedRect: rect, cornerRadius: 36)
            UIColor.black.setFill(); p.fill()
            UIColor.white.withAlphaComponent(0.6).setStroke(); p.lineWidth = 20; p.stroke()
        }
        let crispImg = UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            let p = UIBezierPath(roundedRect: rect, cornerRadius: 36)
            UIColor.white.setStroke(); p.lineWidth = 3; p.stroke(); p.stroke(); p.stroke()
        }
        let ctx = CIContext()
        let softCI = CIImage(cgImage: softImg.cgImage!)
        let crispCI = CIImage(cgImage: crispImg.cgImage!)
        let softBlur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: softCI, kCIInputRadiusKey: 40])!
        let crispBlur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: crispCI, kCIInputRadiusKey: 4])!
        guard let softOut = softBlur.outputImage, let crispOut = crispBlur.outputImage,
              let softCG = ctx.createCGImage(softOut, from: softCI.extent),
              let crispCG = ctx.createCGImage(crispOut, from: crispCI.extent) else { return softImg }
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            UIImage(cgImage: softCG).draw(at: .zero)
            UIImage(cgImage: crispCG).draw(at: .zero)
        }
    }
}
