import SwiftUI
import FoundationModels

struct GhostQueryField: View {

    @Environment(CorpusStore.self) private var store
    @State private var currentWhisperIndex = 0
    @State private var textOpacity: Double = 0.55
    @State private var gradientRotation: Double = 0
    @State private var corpusWhispers: [String] = []
    @State private var isGeneratingWhispers = false
    @State private var showQuerySheet = false
    @State private var querySheetInitialText = ""
    @State private var sheetDetent: PresentationDetent = .medium

    private let whispers = [
        "What have I been thinking about most lately?",
        "What ideas keep coming back that I haven't acted on?",
        "What was I worried about last week?",
        "What patterns show up in my work?",
        "Who was Jolene?"
    ]

    private var activeWhispers: [String] {
        corpusWhispers.isEmpty ? whispers : corpusWhispers + whispers
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
            Text(activeWhispers[currentWhisperIndex])
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white)
                .opacity(textOpacity)
                .padding(.horizontal, 20)
        }
        .frame(height: 52)
        .onTapGesture {
            querySheetInitialText = activeWhispers[currentWhisperIndex]
            showQuerySheet = true
        }
        .onAppear {
            startGradientAnimation()
            startWhisperCycle()
            Task { await generateCorpusWhispers() }
        }
        .onChange(of: store.nodes.count) { _, count in
            if count >= 10 && corpusWhispers.isEmpty {
                Task { await generateCorpusWhispers() }
            }
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
            currentWhisperIndex = (currentWhisperIndex + 1) % activeWhispers.count

            // Fade in
            withAnimation(.easeInOut(duration: 0.6)) {
                textOpacity = 0.55
            }
        }
    }

    private func generateCorpusWhispers() async {
        guard store.nodes.count >= 10, !isGeneratingWhispers else { return }
        isGeneratingWhispers = true
        defer { isGeneratingWhispers = false }

        // Build corpus summary for the model
        let tagFrequency = Dictionary(grouping: store.nodes.flatMap { $0.tags }, by: { $0 })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")

        let domains = store.nodes.compactMap { $0.domain }
        let domainFrequency = Dictionary(grouping: domains, by: { $0 })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
            .joined(separator: ", ")

        let nodeCount = store.nodes.count

        let prompt = """
        You are analyzing a personal idea corpus with \(nodeCount) nodes.
        Top tags by frequency: \(tagFrequency.isEmpty ? "none yet" : tagFrequency)
        Top domains: \(domainFrequency.isEmpty ? "none yet" : domainFrequency)

        Generate 3 short, reflective questions (under 10 words each) that invite the person to reflect on patterns in their thinking. These are "Whispers" — gentle invitations, not search queries. Make them specific to the tags and domains above.

        Respond with exactly 3 questions, one per line, no numbering, no punctuation at the end.
        """

        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return }

            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let responseText = response.content
                let lines: [String] = responseText
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(3)
                    .map { String($0) }

                if !lines.isEmpty {
                    await MainActor.run {
                        corpusWhispers = Array(lines)
                    }
                }
            } catch {
                // Gracefully fail — generic whispers continue cycling
                return
            }
        }
    }
}
