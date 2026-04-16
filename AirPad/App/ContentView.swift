import SwiftUI

struct ContentView: View {

    @Environment(CorpusStore.self) private var store

    @State private var showOnboarding: Bool = false
    @State private var showingFilter = false

    var body: some View {
        ZStack {
            // ── Layer 0: canvas (SpriteKit) or list ──────────────────────────
            CanvasView()
                .animation(.spring(response: 0.35), value: store.iCloudUnavailable)

            // ── Layer 1: iCloud banner ───────────────────────────────────────
            if store.iCloudUnavailable {
                VStack {
                    iCloudUnavailableBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                    Spacer()
                }
            }

            // ── Layer 1: Graph/List toggle + filter button ───────────────────
            // Lives here in ContentView's ZStack (UIHostingController root) so it
            // sits above CanvasView's UINavigationController and SpriteKit Metal layer.
            if !showOnboarding {
                VStack {
                    HStack {
                        Button {
                            showingFilter = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                if store.filterState.isActive {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                        .padding(.leading, 20)

                        Spacer()

                        ViewTogglePill()

                        Spacer()

                        Color.clear
                            .frame(width: 36, height: 36)
                            .padding(.trailing, 20)
                    }
                    .padding(.top, 60)
                    Spacer()
                }
            }

            // ── Layer 2: Onboarding (shown once, highest z) ──────────────────
            if showOnboarding {
                OnboardingView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showOnboarding = false
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.28), value: store.iCloudUnavailable)
        .sheet(isPresented: $showingFilter) {
            FilterPanel()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .onAppear {
            let completed = UserDefaults.standard.bool(forKey: "onboardingComplete")
            showOnboarding = !completed && store.nodes.isEmpty
        }
        .onChange(of: store.nodes) { _, nodes in
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
