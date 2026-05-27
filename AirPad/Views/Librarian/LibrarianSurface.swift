import SwiftUI

/// Collapsed-pill state of the Librarian morphing surface. Visually
/// identical to the pre-Librarian `GhostQueryField` for commit 1 — same
/// dark fill, rotating angular-gradient border, cycling ghost whispers.
/// Tapping opens `CorpusQuerySheet` (today's typing affordance) until
/// in-place morphing lands in a subsequent commit. Session state (sheet
/// presentation, pending query text) lives on `AppRouter.librarian` so
/// future mounts at the ContentView root can drive the same surface.
struct LibrarianSurface: View {

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0
    @State private var sheetDetent: PresentationDetent = .medium

    private var activeWhispers: [String] {
        store.ghostQuerySuggestions
    }

    private var displayText: String {
        guard !activeWhispers.isEmpty else { return "" }
        return activeWhispers[currentWhisperIndex % activeWhispers.count]
    }

    var body: some View {
        @Bindable var librarian = router.librarian

        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.06))

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

            Text(displayText)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 20)
        }
        .frame(height: 52)
        .onTapGesture {
            librarian.pendingQueryText = displayText
            librarian.isPresentingQuerySheet = true
        }
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
        }
        .sheet(isPresented: $librarian.isPresentingQuerySheet) {
            CorpusQuerySheet(
                isPresented: $librarian.isPresentingQuerySheet,
                initialQuery: librarian.pendingQueryText
            )
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
        withAnimation(.easeInOut(duration: 0.6)) {
            textOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let count = activeWhispers.count
            guard count > 0 else { return }
            currentWhisperIndex = (currentWhisperIndex + 1) % count

            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }
}
