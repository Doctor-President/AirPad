import SwiftUI

/// Endpoint-failure banner — amber, the error's message, Retry + dismiss. ★ ONE
/// failure vocabulary for the chat transcript and THE LEVER's tray (F4): a failed
/// model call reads the SAME on both surfaces and never masquerades as success (a
/// failed chat send never becomes an assistant bubble; a failed generate never
/// looks like "nothing happened"). Extracted from `ChatTranscript.errorBanner`
/// so the two can't drift.
///
/// `message` is shown verbatim — for framework throws it is the SDK's own text
/// (e.g. "Exceeded model context window size"), carried through rather than
/// re-classified. Retry and dismiss are the caller's (the chat re-sends the
/// trailing turn; the tray re-runs generate).
struct FMFailureBanner: View {
    let message: String
    var retryDisabled: Bool = false
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hexString: "E8820A"))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: onRetry)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hexString: "00BFFF"))
                .buttonStyle(.plain)
                .disabled(retryDisabled)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hexString: "E8820A").opacity(0.12))
    }
}
