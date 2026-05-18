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

/// Stage 4.2 commit 3 — the in-card chrome strip rendered below the media in
/// both single and gallery presentations. The "+" button on the left appends
/// more media to this entry (calls `CorpusStore.appendMediaItems`, turning a
/// single-item entry into a gallery, or growing an existing gallery). The
/// trailing slot is empty in commit 3 and will host the Carousel/Bento
/// view-mode toggle in commit 4 — sized to fit within
/// `MediaEntryChromeMetrics.height` without resizing.
struct MediaEntryChrome<Trailing: View>: View {
    let onAddMore: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAddMore) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add more media")

            Spacer(minLength: 0)

            trailing()
        }
        .frame(height: MediaEntryChromeMetrics.height)
    }
}
