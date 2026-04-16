import SwiftUI

struct ContentView: View {

    @Environment(CorpusStore.self) private var store

    @State private var showOnboarding: Bool = false

    var body: some View {
        ZStack {
            CanvasView()
                .overlay(alignment: .top) {
                    if store.iCloudUnavailable {
                        iCloudUnavailableBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, 8)
                    }
                }
                .animation(.spring(response: 0.35), value: store.iCloudUnavailable)

            if showOnboarding {
                OnboardingView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showOnboarding = false
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .onAppear {
            let completed = UserDefaults.standard.bool(forKey: "onboardingComplete")
            showOnboarding = !completed && store.nodes.isEmpty
        }
        .onChange(of: store.nodes) { _, nodes in
            // If user somehow lands nodes while onboarding is showing, dismiss it
            if showOnboarding && !nodes.isEmpty {
                withAnimation(.easeOut(duration: 0.4)) {
                    showOnboarding = false
                }
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
            }
        }
    }
}

private struct iCloudUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.caption)
            Text("iCloud unavailable — saving locally")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
