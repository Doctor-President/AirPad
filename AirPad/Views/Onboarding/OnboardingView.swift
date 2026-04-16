import SwiftUI

/// First-launch welcome screen. Shown exactly once — when the corpus is empty and
/// the onboarding flag has not been set. Tapping anywhere sets the flag and dismisses.
struct OnboardingView: View {

    let onDismiss: () -> Void

    private let kleinBlue = Color(red: 0, green: 0.184, blue: 0.655)

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Very faint graph paper grid — same grid as the empty state, even fainter
            Canvas { context, size in
                let spacing: CGFloat = 28
                let color = GraphicsContext.Shading.color(Color(red: 0, green: 0.184, blue: 0.655).opacity(0.09))
                let thin = StrokeStyle(lineWidth: 0.5)
                var x: CGFloat = 0
                while x <= size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: color, style: thin)
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: color, style: thin)
                    y += spacing
                }
            }
            .ignoresSafeArea()

            // Content
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 20) {
                    Text("AirPad")
                        .font(.system(size: 52, weight: .bold, design: .default))
                        .foregroundStyle(.white)

                    Text("Your ideas, landing somewhere.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)

                Spacer()

                Text("Start by adding your first idea →")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 56)
                    .opacity(appeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.2)) {
                appeared = true
            }
        }
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        onDismiss()
    }
}

#Preview {
    OnboardingView(onDismiss: {})
}
