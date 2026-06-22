import SwiftUI

/// Spike — alphabet fast-scroll rail for the alphabetical-sorted grid.
/// Trailing-edge vertical strip; drag jumps the grid to each letter
/// group's first node and blooms the active letter center-screen.
/// Throwaway: only meaningful under Alphabetical sort, the caller is
/// responsible for gating visibility (and corpus-size threshold).
///
/// Letter buckets are derived from the already-sorted node list — distinct
/// first-letters in order, each mapped to the first node in that group.
/// Non-letter first chars bucket under "#" (mirrors `CorpusStore.sortTitle`
/// — `localizedStandardCompare` puts digits/symbols before letters, so "#"
/// reads as the catch-all top bucket).
struct AlphabetScrubberSpike: View {
    let nodes: [Node]
    let scrollTo: (String) -> Void

    @State private var activeLetter: String? = nil
    @State private var bloomOpacity: Double = 0

    private let railWidth: CGFloat = 24
    /// Match NodeGridView's `topInset` (110) so the rail starts below the
    /// chrome row, and reserve enough below for the sort/density row AND
    /// the "+" capture button that floats above it (~200 total) so the
    /// trailing W/Z letters don't sit under the capture button.
    private let railTopInset: CGFloat = 110
    private let railBottomInset: CGFloat = 200
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private struct Entry: Identifiable {
        let id: String
        let firstNodeID: String
    }

    private var entries: [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for node in nodes {
            let letter = Self.bucket(for: node)
            if seen.insert(letter).inserted {
                out.append(Entry(id: letter, firstNodeID: node.id))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let railHeight = max(0, geo.size.height - railTopInset - railBottomInset)
            ZStack {
                VStack(spacing: 0) {
                    Color.clear.frame(height: railTopInset)
                    HStack(spacing: 0) {
                        Spacer()
                        rail(height: railHeight)
                            .frame(width: railWidth, height: railHeight)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        handleDrag(y: value.location.y, height: railHeight)
                                        if bloomOpacity < 1 { bloomOpacity = 1 }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.35)) {
                                            bloomOpacity = 0
                                        }
                                    }
                            )
                    }
                    .frame(height: railHeight)
                    Color.clear.frame(height: railBottomInset)
                }

                if let letter = activeLetter {
                    bloomDisc(letter: letter)
                        .opacity(bloomOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func rail(height: CGFloat) -> some View {
        let list = entries
        return VStack(spacing: 0) {
            ForEach(list) { entry in
                Text(entry.id)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(entry.id == activeLetter ? 0.95 : 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: railWidth, height: height)
    }

    private func bloomDisc(letter: String) -> some View {
        Text(letter)
            .font(.system(size: 80, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 160, height: 160)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.black.opacity(0.35))
                }
            }
    }

    private func handleDrag(y: CGFloat, height: CGFloat) {
        let list = entries
        guard !list.isEmpty, height > 0 else { return }
        let clampedY = max(0, min(height, y))
        let step = height / CGFloat(list.count)
        var idx = Int(clampedY / max(step, 0.001))
        if idx >= list.count { idx = list.count - 1 }
        let entry = list[idx]
        if activeLetter != entry.id {
            activeLetter = entry.id
            haptic.impactOccurred()
            scrollTo(entry.firstNodeID)
        }
    }

    /// Mirrors `CorpusStore.sortTitle` — keep in lockstep so the rail's
    /// buckets match the actual alphabetical sort order. Duplicated rather
    /// than exposing the store helper because this view is throwaway.
    private static func bucket(for node: Node) -> String {
        let title: String
        if !node.title.isEmpty {
            title = node.title
        } else if let first = node.items.first?.content, !first.isEmpty {
            title = first
        } else {
            title = "Untitled"
        }
        guard let first = title.first else { return "#" }
        if first.isLetter { return String(first).uppercased() }
        return "#"
    }
}
