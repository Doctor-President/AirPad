import SwiftUI

/// 1.1-C (C3 / C4) — what an open entry shows when it is private and private entries are hidden (e.g. AirPad came back
/// from the background with it open): nothing of the entry — no title, no shape, no colour — and a way to show it.
struct PrivateEntryPlaceholder: View {
    @Environment(\.appBodyFont) private var appFont
    private var privateEntries: PrivateEntries { PrivateEntries.shared }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            Text("This entry is private.")
                .font(appFont.font(size: 17, relativeTo: .body))
                .foregroundStyle(AppearancePalette.ink.opacity(0.7))
            if privateEntries.available {
                Button("Show private") { Task { await privateEntries.reveal() } }
                    .font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("privatePlaceholder.show")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppearancePalette.bgBase)
        .accessibilityIdentifier("privatePlaceholder")
    }
}
