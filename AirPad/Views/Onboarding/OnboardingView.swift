import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Faint graph paper grid — ambient texture only
            GraphPaperEmptyView()
                .ignoresSafeArea()
                .opacity(0.25)

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    Text("AirPad")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Your ideas, landing somewhere.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }

                Spacer()

                Text("Start by adding your first idea →")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 60)
            }
            .padding(.horizontal, 40)
        }
        .onTapGesture {
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            onDismiss()
        }
    }
}
