import SwiftUI

struct GhostQueryField: View {

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0

    private let whispers = [
        "What have I been thinking about most lately?",
        "What ideas keep coming back that I haven't acted on?",
        "What was I worried about last week?",
        "What patterns show up in my work?",
        "Who was Jolene?"
    ]

    var body: some View {
        ZStack {
            // Dark fill
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.06))

            // Gradient border with rotation animation
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(hexString: "E36B4E"),
                            Color(hexString: "7A52FF"),
                            Color(hexString: "B857D4"),
                            Color(hexString: "E36B4E")
                        ],
                        center: .center,
                        startAngle: .degrees(gradientRotation),
                        endAngle: .degrees(gradientRotation + 360)
                    ),
                    lineWidth: 1.5
                )

            // Ghost text
            Text(whispers[currentWhisperIndex])
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 20)
        }
        .frame(height: 52)
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
        }
    }

    private func startGradientAnimation() {
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            gradientRotation = 360
        }
    }

    private func startWhisperCycle() {
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            cycleWhisper()
        }
    }

    private func cycleWhisper() {
        // Fade out
        withAnimation(.easeInOut(duration: 0.6)) {
            textOpacity = 0
        }

        // Swap text after fade out completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            currentWhisperIndex = (currentWhisperIndex + 1) % whispers.count

            // Fade in
            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }
}
