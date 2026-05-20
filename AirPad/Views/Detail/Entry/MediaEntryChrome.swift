import SwiftUI

/// Stage 4.2 commit 3 — fixed-height metrics for the media-entry chrome strip
/// that sits inside the EntryCard body, below the media. Pinned here (not on
/// the chrome view itself) so commits 3 and 4 reference a single source of
/// truth: `SingleMediaBody`'s chrome (this commit) and `GalleryBody`'s chrome
/// (commit 4) must be the SAME height so the strip doesn't grow/shrink when
/// an entry transitions from single → gallery presentation. The brief's
/// option (b) was chosen specifically for that continuity.
enum MediaEntryChromeMetrics {
    /// Total vertical extent of the chrome row. 44pt is the iOS HIG minimum
    /// tappable area and comfortably accommodates a 32pt segmented control
    /// (commit 4's view-mode toggle) with vertical padding.
    static let height: CGFloat = 44
}

/// Stage 4.2 commit 3 — the in-card chrome strip rendered below the body
/// content in single and gallery presentations. The "+" button on the
/// left appends to the entry (media items for `.imageVideo`, link items
/// for `.link`); the trailing slot hosts a view-mode toggle when there
/// are multiple items.
///
/// Stage 4.5 commit 3 — generalized for link entries via the
/// `accessibilityLabel` parameter. The struct keeps its `Media`-prefixed
/// name (and the `MediaEntryChromeMetrics` enum it pins to) because the
/// 44pt height contract was first established in the media gallery and
/// continues to be the source of truth — link surfaces follow that
/// contract so a mixed feed reads with one rhythm.
struct MediaEntryChrome<Trailing: View>: View {
    let onAdd: () -> Void
    /// VoiceOver label for the "+" button. Required so each call site
    /// names what's actually being added ("Add more media", "Add link"),
    /// rather than every chrome row reading the same generic label.
    let accessibilityLabel: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)

            Spacer(minLength: 0)

            trailing()
        }
        .frame(height: MediaEntryChromeMetrics.height)
    }
}
