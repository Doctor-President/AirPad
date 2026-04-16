import SwiftUI

/// Ephemeral floating card shown at the bottom of the canvas when a thread is detected.
/// One card at a time — the store queues the rest.
struct ThreadSuggestionCard: View {

    let suggestion: ThreadSuggestion
    let nodeTitles: [String]
    let onPull: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("Thread detected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }

            Text(suggestion.description)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !nodeTitles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(nodeTitles, id: \.self) { title in
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onPull) {
                    Text("Pull ✦")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.purple.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 4)
    }
}
