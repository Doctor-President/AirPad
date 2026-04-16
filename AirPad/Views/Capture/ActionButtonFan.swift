import SwiftUI

/// The persistent add-node button that expands into a three-bubble capture fan.
/// Place this in a ZStack aligned to .bottomTrailing.
struct ActionButtonFan: View {

    @Binding var isExpanded: Bool

    let onVoice:         () -> Void
    let onCamera:        () -> Void
    let onText:          () -> Void
    let onNodePicker:    () -> Void    // opens the recent-node tray
    let onAddToRecent:   () -> Void    // immediately targets the most-recent node

    private let fanRadius: CGFloat = 80
    private let bubbleSize: CGFloat = 52

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Dimming scrim
            if isExpanded {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
                    .transition(.opacity)
            }

            // Bottom strip: Add to Recent | New Node — appears when expanded
            if isExpanded {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        StripButton(label: "Add to Recent", icon: "arrow.up.circle") {
                            onAddToRecent(); collapse()
                        }
                        StripButton(label: "New Node", icon: "plus.circle.fill", isPrimary: true) {
                            collapse()  // default behavior — fan capture goes to new node
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 100)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Node picker circle — bottom-left, appears when expanded
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
                        .padding(.bottom, 28)
                        .bubbleTransition(delay: 0.12)

                        Spacer()
                    }
                }
            }

            // Capture bubbles + main button, anchored to bottom-right
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    // Arc: 90° (up), 135° (up-left), 180° (left)
                    FanBubble(icon: "mic.fill", label: "Voice",
                              size: bubbleSize, action: { onVoice(); collapse() })
                        .offset(x: -(fanRadius * cos90), y: -(fanRadius * sin90))
                        .bubbleTransition(delay: 0.00)

                    FanBubble(icon: "camera.fill", label: "Camera",
                              size: bubbleSize, action: { onCamera(); collapse() })
                        .offset(x: -(fanRadius * cos135), y: -(fanRadius * sin135))
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
            .padding(24)
        }
    }

    private func collapse() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            isExpanded = false
        }
    }

    // Fan arc angles (positive x-axis, CCW; SwiftUI y-down so sin is negated for upward motion)
    private let cos90:  CGFloat = 0
    private let sin90:  CGFloat = 1
    private let cos135: CGFloat = 0.7071
    private let sin135: CGFloat = 0.7071
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

// MARK: - Bottom strip button

private struct StripButton: View {
    let label: String
    let icon: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isPrimary ? .black : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isPrimary ? .white : .white.opacity(0.15))
            .clipShape(Capsule())
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
