import SwiftUI

/// Spike — vertical fast-scroll rail for sorted grids.
/// Two flavors via `ScrubMode`:
///   - `.discrete` (alphabetical): one labelled row per first-letter
///     bucket; tap-region maps finger-Y to the nearest bucket.
///   - `.continuous` (recency): a uniform ruler of faint ticks;
///     finger-Y is lerped between newest and oldest dates, drag
///     velocity picks day/week/month/year resolution, and the bloom
///     shows the human-readable snapped date.
/// Throwaway. Static factories build modes from a node list.
struct ScrubberSpike: View {
    let mode: ScrubMode
    let scrollTo: (String) -> Void
    /// Fires on the FIRST onChanged of each gesture (the scrub-begin moment).
    /// NodeGridView wires this to a `ScrollMomentumStopper` so any in-flight
    /// flick decay is killed BEFORE the first `scrollTo`, otherwise the rail
    /// appears to lag behind the coast.
    var onScrubBegin: () -> Void = {}

    @State private var activeRegionID: String? = nil          // discrete only
    @State private var activeBloomLabel: String? = nil
    @State private var lastContinuousTargetID: String? = nil  // continuous only
    @State private var bloomOpacity: Double = 0
    @State private var isScrubbing: Bool = false

    /// Tunables exposed so Tom can dial them on device without rebuilding —
    /// no UI yet; flip via debug overrides or NSUserDefaults if needed.
    @AppStorage("cf_scrub_fastThreshold") private var fastThreshold: Double = 1500
    @AppStorage("cf_scrub_slowThreshold") private var slowThreshold: Double = 200
    @AppStorage("cf_scrub_tickCount") private var tickCount: Int = 45
    /// Fraction of the available band the rail occupies — the rest is split
    /// evenly above/below so the band stays vertically centered in the grid
    /// zone (Apple Music pattern; keeps every mark within the thumb arc).
    @AppStorage("cf_scrub_railHeightFraction") private var railHeightFraction: Double = 0.62

    private let railWidth: CGFloat = 24
    /// Match NodeGridView's `topInset` (110) so the rail starts below the
    /// chrome row, and reserve enough below for the sort/density row AND
    /// the "+" capture button that floats above it (~200 total).
    private let railTopInset: CGFloat = 110
    private let railBottomInset: CGFloat = 200
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let availableHeight = max(0, geo.size.height - railTopInset - railBottomInset)
            let railHeight = max(0, availableHeight * railHeightFraction)
            // Equal flex above and below recenters the band within the grid
            // zone — drag math reads value.location.y in the rail's own
            // coordinate space so it scales to the compressed height
            // automatically.
            let flexSpace = max(0, (availableHeight - railHeight) / 2)
            ZStack {
                VStack(spacing: 0) {
                    Color.clear.frame(height: railTopInset + flexSpace)
                    HStack(spacing: 0) {
                        Spacer()
                        railContent(height: railHeight)
                            .frame(width: railWidth, height: railHeight)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if !isScrubbing {
                                            isScrubbing = true
                                            onScrubBegin()
                                        }
                                        handleDrag(value: value, height: railHeight)
                                        if bloomOpacity < 1 { bloomOpacity = 1 }
                                    }
                                    .onEnded { _ in
                                        isScrubbing = false
                                        withAnimation(.easeOut(duration: 0.35)) {
                                            bloomOpacity = 0
                                        }
                                    }
                            )
                    }
                    .frame(height: railHeight)
                    Color.clear.frame(height: railBottomInset + flexSpace)
                }

                if let label = activeBloomLabel {
                    bloomLabel(label)
                        .opacity(bloomOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func railContent(height: CGFloat) -> some View {
        switch mode {
        case .discrete(let regions):
            discreteRail(regions: regions, height: height)
        case .continuous:
            continuousRail(height: height)
        }
    }

    private func discreteRail(regions: [ScrubRegion], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(regions) { region in
                let isActive = region.id == activeRegionID
                Text(region.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: railWidth, height: height)
    }

    /// Decorative dense ruler — does NOT drive the date mapping. Every 5th
    /// tick is longer/brighter so it reads as a ruler rather than a sparse
    /// dot strip. Position is purely continuous off finger-Y.
    private func continuousRail(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<max(tickCount, 1), id: \.self) { i in
                let isMajor = i % 5 == 0
                Capsule()
                    .fill(.white.opacity(isMajor ? 0.45 : 0.22))
                    .frame(width: isMajor ? 10 : 6, height: isMajor ? 2 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: railWidth, height: height)
    }

    /// Short labels (≤2 chars: single letters, year suffix) render in the
    /// 80pt circular disc. Longer labels (date ranges) need horizontal
    /// room, so swap to a capsule with a smaller font.
    @ViewBuilder
    private func bloomLabel(_ text: String) -> some View {
        if text.count <= 2 {
            Text(text)
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 160, height: 160)
                .background {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(Color.black.opacity(0.35))
                    }
                }
        } else {
            Text(text)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.black.opacity(0.35))
                    }
                }
        }
    }

    private func handleDrag(value: DragGesture.Value, height: CGFloat) {
        switch mode {
        case .discrete(let regions):
            handleDiscreteDrag(value: value, height: height, regions: regions)
        case .continuous(let timeline):
            handleContinuousDrag(value: value, height: height, timeline: timeline)
        }
    }

    private func handleDiscreteDrag(
        value: DragGesture.Value,
        height: CGFloat,
        regions: [ScrubRegion]
    ) {
        guard !regions.isEmpty, height > 0 else { return }
        let clampedY = max(0, min(height, value.location.y))
        let step = height / CGFloat(regions.count)
        var idx = Int(clampedY / max(step, 0.001))
        if idx >= regions.count { idx = regions.count - 1 }
        let region = regions[idx]
        if activeRegionID != region.id {
            activeRegionID = region.id
            activeBloomLabel = region.label
            haptic.impactOccurred()
            scrollTo(region.firstNodeID)
        }
    }

    /// Continuous drag — must follow velocity each event so decelerate-
    /// while-still-holding refines in place (the "settle to precision"
    /// feel the brief asks for). Resolution + snapped date are recomputed
    /// every change, haptic fires only when the snapped node target shifts.
    private func handleContinuousDrag(
        value: DragGesture.Value,
        height: CGFloat,
        timeline: RecencyTimeline
    ) {
        guard height > 0 else { return }
        let t = max(0, min(1, value.location.y / height))
        let span = timeline.newest.timeIntervalSince(timeline.oldest)
        let date = timeline.newest.addingTimeInterval(-span * t)

        let velocity = abs(value.velocity.height)
        let resolution = pickResolution(
            velocity: velocity,
            spansMultiYear: timeline.spansMultipleYears
        )
        let snapped = resolution.snap(date)
        let label = resolution.bloomLabel(snapped)
        let target = snapTarget(
            for: snapped,
            resolution: resolution,
            in: timeline.nodes
        )

        if let target, target.id != lastContinuousTargetID {
            lastContinuousTargetID = target.id
            haptic.impactOccurred()
            scrollTo(target.id)
        }

        if activeBloomLabel != label {
            activeBloomLabel = label
        }
    }

    private func pickResolution(velocity: Double, spansMultiYear: Bool) -> ScrubResolution {
        if velocity > fastThreshold {
            return spansMultiYear ? .year : .month
        } else if velocity < slowThreshold {
            return .day
        } else {
            return .week
        }
    }

    /// Newest node within or before the bucket end (list is desc by date).
    /// Falling through to `nodes.last` covers the case where the user has
    /// scrubbed past the oldest entry.
    private func snapTarget(
        for date: Date,
        resolution: ScrubResolution,
        in nodes: [Node]
    ) -> Node? {
        let interval = resolution.interval(containing: date)
        return nodes.first(where: { $0.createdAt < interval.end }) ?? nodes.last
    }
}

// MARK: - Mode + supporting types

enum ScrubMode {
    case discrete([ScrubRegion])
    case continuous(RecencyTimeline)
}

struct ScrubRegion: Identifiable {
    var id: String { firstNodeID }
    let label: String
    let firstNodeID: String
}

struct RecencyTimeline {
    let nodes: [Node]   // sorted newest → oldest by `createdAt`
    let newest: Date
    let oldest: Date
    let spansMultipleYears: Bool
}

/// Adaptive scrub resolution. `.year` is built in but only engages when
/// the corpus spans more than one calendar year (gating in
/// `pickResolution`), so single-year corpora cap at `.month`.
private enum ScrubResolution {
    case day, week, month, year

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        }
    }

    func snap(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: calendarComponent, for: date)?.start ?? date
    }

    func interval(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: calendarComponent, for: date)
            ?? DateInterval(start: date, duration: 0)
    }

    func bloomLabel(_ date: Date) -> String {
        switch self {
        case .day:   return Self.dayFmt.string(from: date)
        case .week:  return "Week of \(Self.weekFmt.string(from: date))"
        case .month: return Self.monthFmt.string(from: date)
        case .year:  return String(Calendar.current.component(.year, from: date))
        }
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()
    private static let weekFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
}

// MARK: - Mode factories

extension ScrubberSpike {
    /// Distinct first-letter buckets, in the order they appear in the
    /// already-alphabetically-sorted node list. Non-letter first chars
    /// bucket under "#".
    static func alphabeticalRegions(for nodes: [Node]) -> [ScrubRegion] {
        var seen = Set<String>()
        var out: [ScrubRegion] = []
        for node in nodes {
            let letter = alphabeticalBucket(for: node)
            if seen.insert(letter).inserted {
                out.append(ScrubRegion(label: letter, firstNodeID: node.id))
            }
        }
        return out
    }

    /// Build a timeline from a recency-sorted node list. Returns nil for
    /// empty input; caller skips mounting in that case. The multi-year
    /// span check gates whether `.year` resolution engages at fast drag.
    static func recencyTimeline(for nodes: [Node]) -> RecencyTimeline? {
        guard let first = nodes.first, let last = nodes.last else { return nil }
        let cal = Calendar.current
        let spansMulti = cal.component(.year, from: first.createdAt)
            != cal.component(.year, from: last.createdAt)
        return RecencyTimeline(
            nodes: nodes,
            newest: first.createdAt,
            oldest: last.createdAt,
            spansMultipleYears: spansMulti
        )
    }

    private static func alphabeticalBucket(for node: Node) -> String {
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

// MARK: - Grid scroll-momentum interrupt (spike helper)

/// Held by NodeGridView, wired into the scrubber's `onScrubBegin`. Drops
/// a `StopperProbe` inside the grid's ScrollView; at scrub-start, walks
/// up the probe's superview chain to find the underlying UIScrollView
/// and pins its `contentOffset` to itself, which cancels any in-flight
/// deceleration. Without this, a quick flick-then-grab makes the rail
/// wait out the coast before responding.
final class ScrollMomentumStopper {
    weak var probeView: UIView?

    func stop() {
        var current: UIView? = probeView
        while let view = current {
            if let scrollView = view as? UIScrollView {
                scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                return
            }
            current = view.superview
        }
    }
}

/// Zero-size sentinel view planted inside the grid's ScrollView content
/// so its UIView lands somewhere inside the UIScrollView subtree —
/// `ScrollMomentumStopper.stop()` then walks upward to find the scroll
/// view at scrub-start.
struct StopperProbe: UIViewRepresentable {
    let stopper: ScrollMomentumStopper

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        let s = stopper
        DispatchQueue.main.async { s.probeView = view }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
