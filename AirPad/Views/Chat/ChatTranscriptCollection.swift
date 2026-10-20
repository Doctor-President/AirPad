import SwiftUI
import UIKit

/// live-30 (1) — the chat transcript as a `UICollectionView` (T 2026-10-20: build it the standard, robust way instead of
/// diagnosing the SwiftUI stack). The SwiftUI transcript lost the end in chats of ~5 turns on device: a lazy stack's row
/// heights keep changing after they are estimated, so a one-shot `scrollTo` lands on a target that moves.
///
/// Here "at the end" is a STATE the layout keeps, not a scroll that is aimed once:
///  • `ChatTranscriptLayout.followsEnd` is on when the reader is at the end (on open, after ↓, after a drag or fling
///    that lands there) and off once the reader scrolls away;
///  • every height change the layout learns (a cell sizing itself, an answer streaming, a table appearing, an older
///    row's real height replacing its estimate) is applied with an offset adjustment in the SAME invalidation: while it
///    follows the end, the offset becomes the new end; otherwise a change above the screen shifts the offset by the
///    same amount, so what the reader is looking at doesn't move.
///
/// Why bottom-anchored and not the inverted (flipped) list: on iOS 26 a normal collection view with this layout gets the
/// same structural end, while UIKit keeps its own idea of top and bottom — VoiceOver reads oldest → newest, the Chats
/// sheet's swipe-down, the scroll indicator and the status-bar tap all work unpatched; a flipped list reverses each.
///
/// One transcript for the Librarian panel and the Chat view (`ChatTranscript` hosts it). Diffable data; self-sizing
/// cells whose content is the SwiftUI rows (`TranscriptItemView`) via `UIHostingConfiguration`.
struct ChatTranscriptCollection: UIViewRepresentable {
    let session: ChatSession
    /// Oldest first (the screen's order): every message, then the live Thought process and the streaming answer.
    let items: [TranscriptItem]
    let context: TranscriptRowContext
    let scroller: TranscriptScroller
    /// The ↓ arrow shows when the reader is more than `arrowDistance` from the end. Reported only on change.
    var onAtEndChange: (Bool) -> Void
    /// #1-followup — how far the transcript is scrolled from its TOP (the Librarian's collapsing title).
    var onScrollTopOffset: ((CGFloat) -> Void)?
    /// A tap anywhere in the transcript (the Chat view drops its composer's focus); never swallows the tap.
    var onTap: () -> Void
    var hiddenFromAccessibility = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context ctx: Context) -> ChatTranscriptCollectionView {
        let c = ctx.coordinator
        let layout = ChatTranscriptLayout()
        let cv = ChatTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.contentInsetAdjustmentBehavior = .never   // the SwiftUI frame already sits inside the safe area / above the composer
        cv.keyboardDismissMode = .interactive
        cv.alwaysBounceVertical = true
        cv.accessibilityIdentifier = "chat.transcript"
        cv.delegate = c
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = c
        cv.addGestureRecognizer(tap)
        c.attach(cv, layout: layout, session: session, context: context)
        scroller.coordinator = c
        return cv
    }

    func updateUIView(_ cv: ChatTranscriptCollectionView, context ctx: Context) {
        let c = ctx.coordinator
        c.onAtEndChange = onAtEndChange
        c.onScrollTopOffset = onScrollTopOffset
        c.onTap = onTap
        scroller.coordinator = c
        // Faded out by the host: no elements. (`isHidden` / `accessibilityElementsHidden` alone leave the cells in the tree
        // — SwiftUI lists the hosted view explicitly — so the container says it has none.) The host has already faded the
        // transcript to 0, so this changes nothing on screen, and it keeps laying out (it reopens at the end).
        if cv.hidesElements != hiddenFromAccessibility {
            cv.hidesElements = hiddenFromAccessibility
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
        c.update(items: items, sessionID: session.id, session: session)
    }
}

/// The ↓ arrow's channel into the collection view.
@MainActor
final class TranscriptScroller {
    weak var coordinator: ChatTranscriptCollection.Coordinator?
    func scrollToEnd() { coordinator?.scrollToEnd(animated: true) }
}

extension ChatTranscriptCollection {
    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        private weak var collectionView: ChatTranscriptCollectionView?
        private var layout: ChatTranscriptLayout?
        private var dataSource: UICollectionViewDiffableDataSource<Int, TranscriptItem>?
        private weak var session: ChatSession?
        private var items: [TranscriptItem] = []
        private var estimates: [TranscriptItem: CGFloat] = [:]
        private var sessionID: UUID?
        private var messageCount = 0
        private var atEnd = true
        private var lastTop: CGFloat = -1
        private var inUpdate = false
        var onAtEndChange: ((Bool) -> Void)?
        var onScrollTopOffset: ((CGFloat) -> Void)?
        var onTap: (() -> Void)?

        /// The ↓ arrow shows past this distance from the end (the SwiftUI transcript's 80 pt).
        static let arrowDistance: CGFloat = 80
        /// A user scroll that comes to rest within this distance of the end follows the end again.
        static let followDistance: CGFloat = 32

        func attach(_ cv: ChatTranscriptCollectionView, layout: ChatTranscriptLayout, session: ChatSession, context: TranscriptRowContext) {
            collectionView = cv
            self.layout = layout
            self.session = session
            let registration = UICollectionView.CellRegistration<ChatTranscriptCell, TranscriptItem> { [weak session] cell, _, item in
                guard let session else { return }
                #if DEBUG
                if ChatTranscript.openTrace { ChatTranscriptCollectionView.trace("configure \(item)") }
                #endif
                cell.contentConfiguration = UIHostingConfiguration {
                    // Identity = the item, so a reused cell never carries another message's SwiftUI state.
                    TranscriptItemView(item: item, session: session, context: context).id(item)
                }
                .margins(.all, 0)
                .minSize(height: 1)
                cell.backgroundConfiguration = .clear()
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, ip, item in
                cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: item)
            }
            layout.itemAt = { [weak self] ip in
                guard let items = self?.items, ip.item < items.count else { return nil }
                return items[ip.item]
            }
            layout.estimate = { [weak self] item in self?.estimates[item] ?? 80 }
            cv.onLayout = { [weak self] in self?.reportGeometry() }
        }

        // MARK: Data

        func update(items new: [TranscriptItem], sessionID id: UUID, session: ChatSession) {
            guard let cv = collectionView, let layout, let dataSource else { return }
            #if DEBUG
            let t0 = CACurrentMediaTime()
            defer { if ChatTranscript.openTrace { ChatTranscriptCollectionView.trace(String(format: "update items=%d took=%.1fms", new.count, (CACurrentMediaTime() - t0) * 1000)) } }
            #endif
            inUpdate = true
            defer { inUpdate = false }
            self.session = session
            let switched = sessionID != nil && sessionID != id
            let firstLoad = sessionID == nil
            guard new != items || switched || firstLoad else { return }
            let oldCount = messageCount
            let newCount = session.messages.count
            #if DEBUG || TESTFLIGHT
            if newCount != oldCount, !firstLoad { ChatScrollTrace.shared.event("messages \(oldCount)→\(newCount)", messages: newCount) }
            #endif
            if switched { layout.forgetHeights(); estimates.removeAll() }
            // The streaming answer becomes its message in place: start the committed cell at the tail's height so
            // the commit doesn't show an estimate for a frame.
            let had = Set(items)
            if had.contains(.tail), !new.contains(.tail), let added = new.last(where: { !had.contains($0) }) {
                layout.carryHeight(from: .tail, to: added)
            }
            // A new conversation, a restore, or a change other than one message arriving (regenerate, retry) lands on
            // the end, as the SwiftUI transcript's "bulk change → jump to the latest" did.
            if switched || firstLoad || (newCount != oldCount && newCount != oldCount + 1) { layout.followsEnd = true }
            items = new
            sessionID = id
            messageCount = newCount
            // Estimates once per item (the layout asks on every pass, and a pass runs per streamed chunk).
            let byID = Dictionary(session.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for item in new where estimates[item] == nil { estimates[item] = Self.estimatedHeight(item, byID) }
            var snap = NSDiffableDataSourceSnapshot<Int, TranscriptItem>()
            snap.appendSections([0])
            snap.appendItems(new)
            dataSource.apply(snap, animatingDifferences: false)
            cv.layoutIfNeeded()
            if layout.followsEnd { scrollToEnd(animated: false) }
            reportGeometry()
        }

        /// A rough height before a cell has measured itself (only the scroll indicator and far-away rows use it).
        private static func estimatedHeight(_ item: TranscriptItem, _ byID: [UUID: ChatSession.Message]) -> CGFloat {
            switch item {
            case .tail, .thought: return 44
            case .message(let id):
                guard let m = byID[id] else { return 80 }
                let lines = CGFloat(max(1, m.text.count / 42 + m.text.filter { $0 == "\n" }.count / 2))
                switch m.role {
                case .user: return 24 * lines + 20
                case .activity: return 40
                case .assistant: return 24 * lines + 60
                }
            }
        }

        // MARK: Scrolling

        func scrollToEnd(animated: Bool) {
            guard let cv = collectionView, let layout else { return }
            layout.followsEnd = true
            cv.layoutIfNeeded()
            let end = layout.endOffset(in: cv)
            if animated, abs(cv.contentOffset.y - end) > 1 {
                cv.animatingToEnd = true
                cv.setContentOffset(CGPoint(x: 0, y: end), animated: true)
            } else {
                cv.contentOffset = CGPoint(x: 0, y: end)
            }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            // The end may have moved while the ↓ animation ran (an answer streaming in): land on where it is now.
            guard let cv = collectionView, let layout else { return }
            cv.animatingToEnd = false
            if layout.followsEnd { cv.contentOffset = CGPoint(x: 0, y: layout.endOffset(in: cv)) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView, let layout else { return }
            // Only the reader's own scrolling decides whether the transcript follows the end; the layout's own
            // adjustments and the ↓ animation don't.
            if cv.isTracking || cv.isDecelerating {
                layout.followsEnd = layout.endOffset(in: cv) - cv.contentOffset.y <= Self.followDistance
            }
            reportGeometry()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            collectionView?.animatingToEnd = false
            #if DEBUG || TESTFLIGHT
            ChatScrollTrace.shared.event("drag began", messages: messageCount)
            #endif
        }

        private func reportGeometry() {
            guard let cv = collectionView, let layout else { return }
            let content = cv.contentSize.height, container = cv.bounds.height, offY = cv.contentOffset.y
            let fromEnd = layout.endOffset(in: cv) - offY
            let nowAtEnd = fromEnd <= Self.arrowDistance
            // Reported outside SwiftUI's update pass (`update` runs inside `updateUIView`): the hosts write @State.
            let top = max(0, offY)
            if nowAtEnd != atEnd {
                atEnd = nowAtEnd
                if inUpdate { DispatchQueue.main.async { [weak self] in self?.onAtEndChange?(nowAtEnd) } } else { onAtEndChange?(nowAtEnd) }
            }
            if abs(top - lastTop) > 0.25 {
                lastTop = top
                if inUpdate { DispatchQueue.main.async { [weak self] in self?.onScrollTopOffset?(top) } } else { onScrollTopOffset?(top) }
            }
            #if DEBUG
            if ChatTranscript.scrollGeoLog {
                print(String(format: "[ScrollGeo] t=%.3f content=%.1f container=%.1f offY=%.1f visMaxY=%.1f insetT=%.1f insetB=%.1f n=%d follows=%d",
                             Date().timeIntervalSince1970, content, container, offY, offY + container, 0.0, 0.0, messageCount,
                             layout.followsEnd ? 1 : 0))
            }
            FreezeProbe.hit("geo.transform", "content=\(Int(content)) container=\(Int(container)) offY=\(Int(offY)) visMaxY=\(Int(offY + container)) insetT=0 insetB=0")
            StreamGeoRecorder.shared.note(content: content, offset: offY, streaming: session?.isStreaming ?? false)
            #endif
            #if DEBUG || TESTFLIGHT
            ChatScrollTrace.shared.geometry(content: content, container: container, offY: offY, insetB: 0, messages: messageCount)
            #endif
        }

        // MARK: Taps / selection

        @objc func tapped() { onTap?() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool { false }
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
    }
}

/// The transcript's collection view: keeps the bottom edge where it was when its height changes (the keyboard, the
/// composer growing, the Librarian panel moving between half and full), and reports each layout pass.
final class ChatTranscriptCollectionView: UICollectionView {
    var onLayout: (() -> Void)?
    /// The host faded the transcript out (see `ChatTranscriptCollection.hiddenFromAccessibility`).
    var hidesElements = false {
        didSet { accessibilityElementsHidden = hidesElements }
    }
    override var accessibilityElements: [Any]? {
        get { hidesElements ? [] : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }
    override func accessibilityElementCount() -> Int { hidesElements ? 0 : super.accessibilityElementCount() }
    private var lastHeight: CGFloat = 0
    private var reportedFirstLayout = false

    /// The ↓ arrow's animation is running (the end isn't re-snapped under it).
    var animatingToEnd = false

    #if DEBUG
    static func trace(_ s: String) { print(String(format: "[OpenTrace] %.3f %@", CACurrentMediaTime(), s)) }
    #endif

    override func layoutSubviews() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { if ChatTranscript.openTrace { Self.trace(String(format: "layoutSubviews h=%.0f off=%.0f content=%.0f took=%.1fms", bounds.height, contentOffset.y, contentSize.height, (CACurrentMediaTime() - t0) * 1000)) } }
        #endif
        let h = bounds.height
        let layout = collectionViewLayout as? ChatTranscriptLayout
        if let layout, abs(h - lastHeight) > 0.5 {
            // The bottom edge stays put: at the end that's the end; elsewhere what sat above the composer stays there.
            let end = layout.endOffset(in: self, height: h)
            if layout.followsEnd {
                contentOffset = CGPoint(x: 0, y: end)
            } else if lastHeight > 0 {
                contentOffset = CGPoint(x: 0, y: min(max(0, contentOffset.y + lastHeight - h), end))
            }
        }
        lastHeight = h
        super.layoutSubviews()
        // Safety net for the end: after this pass's cells sized themselves, a transcript that follows the end shows it
        // (never under the reader's finger, a fling, or the ↓ animation).
        if let layout, layout.followsEnd, !isTracking, !isDecelerating, !animatingToEnd {
            let end = layout.endOffset(in: self)
            if abs(contentOffset.y - end) > 0.5 {
                contentOffset = CGPoint(x: 0, y: end)
                super.layoutSubviews()
            }
        }
        onLayout?()
        #if DEBUG
        if !reportedFirstLayout, h > 0, window != nil {
            reportedFirstLayout = true
            // Perf gate: the first committed layout of the transcript (one runloop after mount).
            let n = numberOfSections > 0 ? numberOfItems(inSection: 0) : 0
            DispatchQueue.main.async { GauntletMetrics.shared.transcriptLaidOut(messages: n) }
        }
        #endif
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Dynamic Type changed: every measured height is stale.
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            (collectionViewLayout as? ChatTranscriptLayout)?.forgetHeights()
        }
    }
}

/// A cell sizes itself to its SwiftUI content at the layout's width.
final class ChatTranscriptCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let a = attrs.copy() as! UICollectionViewLayoutAttributes
        let size = contentView.systemLayoutSizeFitting(CGSize(width: attrs.size.width, height: UIView.layoutFittingCompressedSize.height),
                                                       withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        a.size = CGSize(width: attrs.size.width, height: max(1, ceil(size.height)))
        return a
    }
}

/// A vertical list, oldest at the top, that keeps the end (or the reader's place) through every height change.
final class ChatTranscriptLayout: UICollectionViewLayout {
    /// The SwiftUI transcript's paddings and row spacing.
    static let topInset: CGFloat = 16, bottomInset: CGFloat = 24, spacing: CGFloat = 18

    var itemAt: ((IndexPath) -> TranscriptItem?)?
    var estimate: ((TranscriptItem) -> CGFloat)?
    /// The reader is at the end: every change keeps them there (see `ChatTranscriptCollection`).
    var followsEnd = true

    private var heights: [TranscriptItem: CGFloat] = [:]
    private var heightsWidth: CGFloat = 0
    private var attrs: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    func forgetHeights() { heights.removeAll(); invalidateLayout() }
    func carryHeight(from a: TranscriptItem, to b: TranscriptItem) { if let h = heights[a] { heights[b] = h } }

    /// The offset that shows the last line: the content's bottom at the view's bottom (0 when it all fits).
    func endOffset(in cv: UICollectionView, height: CGFloat? = nil) -> CGFloat {
        max(0, max(contentHeight, cv.contentSize.height) - (height ?? cv.bounds.height))
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let width = cv.bounds.width
        if abs(width - heightsWidth) > 0.5 { heights.removeAll(); heightsWidth = width }
        let n = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        var out: [UICollectionViewLayoutAttributes] = []
        out.reserveCapacity(n)
        var y = Self.topInset
        for i in 0..<n {
            let ip = IndexPath(item: i, section: 0)
            let item = itemAt?(ip)
            let h = item.flatMap { heights[$0] } ?? item.flatMap { estimate?($0) } ?? 80
            let a = UICollectionViewLayoutAttributes(forCellWith: ip)
            a.frame = CGRect(x: 0, y: y, width: width, height: h)
            out.append(a)
            y += h + Self.spacing
        }
        attrs = out
        contentHeight = n > 0 ? y - Self.spacing + Self.bottomInset : 0
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !attrs.isEmpty else { return [] }
        // Binary search for the first row reaching into the rect; rows are in y order.
        var lo = 0, hi = attrs.count
        while lo < hi { let mid = (lo + hi) / 2; if attrs[mid].frame.maxY < rect.minY { lo = mid + 1 } else { hi = mid } }
        var out: [UICollectionViewLayoutAttributes] = []
        var i = lo
        while i < attrs.count, attrs[i].frame.minY <= rect.maxY { out.append(attrs[i]); i += 1 }
        return out
    }

    override func layoutAttributesForItem(at ip: IndexPath) -> UICollectionViewLayoutAttributes? {
        ip.item < attrs.count ? attrs[ip.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        abs(newBounds.width - (collectionView?.bounds.width ?? 0)) > 0.5
    }

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        guard original.indexPath.item < attrs.count else { return false }
        return abs(preferred.size.height - attrs[original.indexPath.item].frame.height) > 0.5
    }

    /// A changed copy (attributes UIKit already holds are never mutated in place).
    private static func moved(_ a: UICollectionViewLayoutAttributes, _ change: (inout CGRect) -> Void) -> UICollectionViewLayoutAttributes {
        let c = a.copy() as! UICollectionViewLayoutAttributes
        var f = c.frame; change(&f); c.frame = f
        return c
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let ctx = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let i = original.indexPath.item
        guard let cv = collectionView, i < attrs.count else { return ctx }
        let old = attrs[i].frame
        let delta = preferred.size.height - old.height
        if let item = itemAt?(original.indexPath) { heights[item] = preferred.size.height }
        // Keep the cached frames current at once: several cells can size themselves in one pass.
        attrs[i] = Self.moved(attrs[i]) { $0.size.height = preferred.size.height }
        for j in (i + 1)..<attrs.count { attrs[j] = Self.moved(attrs[j]) { $0.origin.y += delta } }
        contentHeight += delta
        let offset = cv.contentOffset.y
        let target: CGFloat
        if followsEnd {
            target = max(0, contentHeight - cv.bounds.height)        // the end stays the end
        } else if old.maxY <= offset + 0.5 {
            target = offset + delta                                    // a change above the screen: the reader stays put
        } else {
            target = offset                                            // on screen or below: it grows downward
        }
        if abs(target - offset) > 0.01 { ctx.contentOffsetAdjustment = CGPoint(x: 0, y: target - offset) }
        ctx.contentSizeAdjustment = CGSize(width: 0, height: delta)
        return ctx
    }
}
