import SwiftUI

struct GhostQueryField: View {

    @Environment(CorpusStore.self) private var store
    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0
    @State private var showQuerySheet = false
    @State private var querySheetInitialText = ""
    @State private var sheetDetent: PresentationDetent = .medium

    private var activeWhispers: [String] {
        store.ghostQuerySuggestions
    }

    private var displayText: String {
        guard !activeWhispers.isEmpty else { return "" }
        return activeWhispers[currentWhisperIndex % activeWhispers.count]
    }

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
            Text(displayText)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 20)
        }
        .frame(height: 52)
        .onTapGesture {
            querySheetInitialText = displayText
            showQuerySheet = true
        }
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
        }
        .sheet(isPresented: $showQuerySheet) {
            CorpusQuerySheet(isPresented: $showQuerySheet, initialQuery: querySheetInitialText)
                .presentationDetents([.medium, .large], selection: $sheetDetent)
                .presentationBackground(Color(red: 0.04, green: 0.04, blue: 0.06))
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
            let count = activeWhispers.count
            guard count > 0 else { return }
            currentWhisperIndex = (currentWhisperIndex + 1) % count

            // Fade in
            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }
}
