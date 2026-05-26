import SwiftUI

/// Horizontal pill rail for tag selection inside the capture overlay
/// (brief: ~/Desktop/Ops/briefs/capture-tag-rail.md). Sibling to
/// `CollectionPillRail` — shares the visual language (capsule pills,
/// white-on-charcoal unselected, black-on-white selected) so the two
/// rails read as one stack inside the overlay.
///
/// Differences from `CollectionPillRail`:
/// - **Multi-select** via `Binding<Set<String>>` (collection rail is
///   single-select via `Binding<String?>`).
/// - **Capped display**: only the top 5 tags by `tagLastUsedAt` desc
///   appear; the "More..." pill opens a full-list sheet (built in C3)
///   for everything beyond the top 5.
/// - **No recency bump on tap**: the rail's order is stable across the
///   multi-select session; recency only bumps when tags are actually
///   applied to a node at capture commit (via `applyTags`). Toggling a
///   pill mid-session must not reshuffle the rail.
/// - **No locked mode**: tags are always interactive at capture time.
struct TagPillRail: View {

    @Binding var selectedTagNames: Set<String>
    var onMore: () -> Void

    @Environment(CorpusStore.self) private var store

    private static let maxVisibleTags = 5

    /// Top-N tag names by `tagLastUsedAt` desc. Tags without a timestamp
    /// fall to `.distantPast` and surface only after the user has fewer
    /// than N tagged tags total. First-launch state is an empty rail
    /// with just the "More..." pill — honest about the lack of history.
    private var railTagNames: [String] {
        let scored: [(name: String, date: Date)] = store.tags.map { tag in
            (tag.name, store.tagLastUsedAt[tag.name] ?? .distantPast)
        }
        return scored
            .sorted { $0.date > $1.date }
            .prefix(Self.maxVisibleTags)
            .map(\.name)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(railTagNames, id: \.self) { name in
                    pill(for: name)
                }
                morePill
            }
            .padding(.horizontal, 16)
        }
    }

    /// Resolves the tag's stored color, falling back to gray when the tag
    /// is missing from the vocabulary or its hex doesn't parse — matches
    /// `TagChip` in `NodeDetailView` so capture-time and node-detail
    /// surfaces read as the same tag.
    private func color(for tagName: String) -> Color {
        guard let tag = store.tags.first(where: { $0.name == tagName }),
              let parsed = Color(hex: tag.colorHex)
        else { return .gray }
        return parsed
    }

    private func pill(for tagName: String) -> some View {
        let isSelected = selectedTagNames.contains(tagName)
        let tagColor = color(for: tagName)
        return Button {
            if isSelected {
                selectedTagNames.remove(tagName)
            } else {
                selectedTagNames.insert(tagName)
            }
        } label: {
            Text(tagName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? tagColor : tagColor.opacity(0.18))
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.clear : tagColor.opacity(0.5),
                        lineWidth: 1
                    )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var morePill: some View {
        Button(action: onMore) {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                Text("More")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(
                Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
