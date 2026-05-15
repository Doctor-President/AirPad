import SwiftUI

/// The persistent add-node button that expands into a three-bubble capture fan.
/// Place this in a ZStack aligned to .bottomTrailing.
struct ActionButtonFan: View {

    @Binding var isExpanded: Bool

    /// When true the button is centered (empty-canvas state).
    /// When false it fills available space so its bottomTrailing alignment pins it to the corner.
    var isEmpty: Bool = false

    let onVoice:         () -> Void
    let onCamera:        () -> Void
    let onText:          () -> Void
    let onNodePicker:    () -> Void    // opens the recent-node tray

    private let fanRadius: CGFloat = 100
    private let bubbleSize: CGFloat = 52

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // When nodes exist, fill all available space so bottomTrailing alignment
            // anchors the button to the corner. When empty, let the ZStack hug the
            // button so the parent ZStack centers it on screen.
            if !isEmpty { Color.clear }  // spacer that expands the ZStack to fill the canvas
            // Dimming scrim
            if isExpanded {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
                    .transition(.opacity)
            }

            // Recents circle — left of + button at the same vertical level when expanded
            if isExpanded {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            onNodePicker(); collapse()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                Text("Recents")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .padding(.leading, 28)
                        .padding(.bottom, 24)
                        .bubbleTransition(delay: 0.12)

                        Spacer()
                    }
                }
            }

            // Capture bubbles + main button, anchored to bottom-right.
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    // Arc: 90° (straight up), 130° (up-left), 180° (pure left).
                    // 40° gap between each bubble; Text sits directly left of + at R=90 → (-90, 0).
                    FanBubble(icon: "mic.fill", label: "Voice",
                              size: bubbleSize, action: { onVoice(); collapse() })
                        .offset(x: -(fanRadius * cos90), y: -(fanRadius * sin90))
                        .bubbleTransition(delay: 0.00)

                    FanBubble(icon: "camera.fill", label: "Camera",
                              size: bubbleSize, action: { onCamera(); collapse() })
                        .offset(x: -(fanRadius * cos130), y: -(fanRadius * sin130))
                        .bubbleTransition(delay: 0.05)

                    FanBubble(icon: "pencil", label: "Text",
                              size: bubbleSize, action: { onText(); collapse() })
                        .offset(x: -(fanRadius * cos180), y: -(fanRadius * sin180))
                        .bubbleTransition(delay: 0.10)
                }

                // Main + / × button
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "xmark" : "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(width: 56, height: 56)
                        .background(.white)
                        .clipShape(Circle())
                        .shadow(color: .white.opacity(0.15), radius: 8, y: 2)
                        .rotationEffect(.degrees(isExpanded ? 45 : 0))
                        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isExpanded)
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in
                            if !isExpanded {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                                    isExpanded = true
                                }
                            }
                        }
                )
            }
            .padding(.top, 24)
            .padding(.leading, 24)
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        }
    }

    private func collapse() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            isExpanded = false
        }
    }

    // Fan arc trig components. Angles are from the positive x-axis (CCW).
    // x-offset = -(R * |cos θ|), y-offset = -(R * sin θ)  [SwiftUI: negative y = upward]
    //   90°: straight up   — Voice
    //  130°: up-left       — Camera  (|cos 50°| = 0.6428, sin 50° = 0.7660)
    //  180°: pure left     — Text    — at R=90: (-90, 0), 40° clear of Camera
    private let cos90:  CGFloat = 0
    private let sin90:  CGFloat = 1
    private let cos130: CGFloat = 0.6428
    private let sin130: CGFloat = 0.7660
    private let cos180: CGFloat = 1
    private let sin180: CGFloat = 0
}

// MARK: - Individual bubble

private struct FanBubble: View {
    let icon: String
    let label: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: size, height: size)
                    .background(.white)
                    .clipShape(Circle())
                    .shadow(color: .white.opacity(0.15), radius: 6, y: 2)

                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Transition helper

private extension View {
    func bubbleTransition(delay: Double) -> some View {
        self
            .transition(
                .scale(scale: 0.1, anchor: .bottomTrailing)
                .combined(with: .opacity)
            )
            .animation(
                .spring(response: 0.38, dampingFraction: 0.62).delay(delay),
                value: true
            )
    }
}
