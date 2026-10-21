import SwiftUI
import UIKit

/// live-30 (1) — the chat transcript as a `UICollectionView` (T 2026-10-20: build it the standard, robust way instead of
/// diagnosing the SwiftUI stack). The SwiftUI transcript lost the end in chats of ~5 turns on device: a lazy stack's row
/// heights keep changing after they are estimated, so a one-shot `scrollTo` lands on a target that moves.
///
/// live-31 (1) — streaming never moves the view (T ruled 2026-10-20; supersedes live-30's "at the end, the view follows
/// the answer", which made the blocks "swim" on device). The pattern of the Claude / ChatGPT apps:
///  • on send, ONE scroll brings the new question near the top, with runway below it (the layout's `runwayAnchor`
///    keeps that offset reachable while the answer is shorter than the screen); asked while scrolled up, nothing moves;
///  • while an answer streams, nothing the layout learns changes the offset: a cell on screen or below grows downward,
///    a change above the screen shifts the offset by the same amount (so what's on screen stays still);
///  • ↓ goes to the end once and doesn't follow; a drag to the end mid-stream doesn't follow either;
///  • once the answer is done, the runway shrinks only below the visible area (each time a scroll comes to rest).
/// "Scrolled up" means by the reader's own hand: short of the end only because the last answer ran past the bottom,
/// the next question still comes to the top (the 2026-10-05 freeze lab's follow-ups caught that).
/// "At the end" stays a state (`followsEnd`) for everything else: opening a chat lands on the last line and keeps it
/// through late self-sizing, the keyboard and the panel moving.
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
    /// live-31 — the host's top fade, as a fraction of the height: a question brought near the top sits below it.
    var topFadeFraction: CGFloat = 0

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
        c.topFadeFraction = topFadeFraction
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
        /// live-31 — this turn's question has been brought near the top (or left where it was); reset when the answer ends.
        private var pinnedThisTurn = false
        /// live-31 — the reader scrolled UP, away from the end, themselves: a new question then moves nothing. (Being short
        /// of the end because the last answer ran past the bottom isn't that — the next question still comes to the top.)
        private var readerScrolledUp = false
        private var dragStartOffset: CGFloat = 0
        var onAtEndChange: ((Bool) -> Void)?
        var onScrollTopOffset: ((CGFloat) -> Void)?
        var onTap: (() -> Void)?
        var topFadeFraction: CGFloat = 0

        /// The ↓ arrow shows past this distance from the end (the SwiftUI transcript's 80 pt).
        static let arrowDistance: CGFloat = 80
        /// A user scroll that comes to rest within this distance of the end follows the end again.
        static let followDistance: CGFloat = 32

        /// DEBUG `-TranscriptLive30 YES` — live-30's contract (the RED baseline for the live-31 rows): at the end, the view
        /// follows a streaming answer; no question brought to the top, no runway. Always false in Release.
        static var live30: Bool {
            #if DEBUG
            UserDefaults.standard.bool(forKey: "TranscriptLive30")
            #else
            false
            #endif
        }

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
            let nowStreaming = session.isStreaming && !Self.live30
            guard new != items || switched || firstLoad || nowStreaming != layout.streaming else { return }
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
            // live-31 — where the reader is BEFORE this change: scrolled up by their own hand, or not.
            let readerAtEnd = !readerScrolledUp || layout.followsEnd || layout.endOffset(in: cv) - cv.contentOffset.y <= Self.arrowDistance
            let lastUser = session.messages.last(where: { $0.role == .user })?.id
            let newQuestion = !switched && !firstLoad && lastUser.map { !had.contains(.message($0)) } == true
            let streamStarted = nowStreaming && !layout.streaming
            var pin: UUID? = nil
            if Self.live30 {
                // live-30: a new conversation, a restore, or a change other than one message arriving lands on the end.
                if switched || firstLoad || (newCount != oldCount && newCount != oldCount + 1) { layout.followsEnd = true }
            } else if switched || firstLoad {
                layout.followsEnd = true
                layout.setRunwayAnchor(nil)
                pinnedThisTurn = false
                readerScrolledUp = false
            } else if newQuestion || (streamStarted && !pinnedThisTurn) {
                // A turn starts (a question sent, or a retry / regenerate streaming again): at the end, its question is
                // brought near the top once; scrolled up, nothing moves. Either way the view stops following.
                if readerAtEnd { pin = lastUser; readerScrolledUp = false }
                layout.followsEnd = false
                pinnedThisTurn = true
            } else if newCount >= oldCount + 2, !nowStreaming {
                layout.followsEnd = true   // a bulk change (a restore) lands on the end
            }
            if layout.streaming, !nowStreaming {
                // The answer is done: the runway keeps only what's on screen (now, or when the reader's scroll comes to
                // rest); the rest goes as the reader scrolls back.
                pinnedThisTurn = false
                if !cv.isTracking, !cv.isDecelerating { layout.setRunwayAnchor(layout.runwayAnchor.map { min($0, cv.contentOffset.y) }) }
            }
            layout.streaming = nowStreaming
            #if DEBUG
            cv.debugAnswerStreaming = session.isStreaming
            #endif
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
            if let pin { bringNearTop(.message(pin)) }
            else if layout.followsEnd, !layout.streaming { scrollToEnd(animated: false) }
            reportGeometry()
        }

        /// live-31 — the one movement of a turn: the question's top near the top of the transcript (below the host's top
        /// fade), with runway below it so the answer has room to grow. Only ever downward (a question already that high,
        /// or taller than the screen, stays where it is).
        private func bringNearTop(_ item: TranscriptItem) {
            guard let cv = collectionView, let layout, let top = layout.frame(of: item)?.minY else { return }
            let clearance = ChatTranscriptLayout.topInset + topFadeFraction * cv.bounds.height
            let target = max(0, top - clearance)
            let offset = cv.contentOffset.y
            #if DEBUG || TESTFLIGHT
            ChatScrollTrace.shared.event(String(format: "question to top %.0f→%.0f", offset, max(target, offset)), messages: messageCount)
            #endif
            guard target > offset + 1 else {
                layout.setRunwayAnchor(offset)   // nothing moves; the answer still has room below
                return
            }
            layout.setRunwayAnchor(target)
            cv.animatingToEnd = true   // no snap-to-end under the animation
            cv.setContentOffset(CGPoint(x: 0, y: target), animated: true)
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

        /// Opening a chat and ↓ land on the last line. live-31: while an answer streams, ↓ goes there once and doesn't
        /// follow (the answer keeps growing below; ↓ comes back when it passes the bottom again).
        func scrollToEnd(animated: Bool) {
            guard let cv = collectionView, let layout else { return }
            #if DEBUG
            if layout.streaming, TranscriptMotion.on { TranscriptMotion.shared.downTappedWhileStreaming() }
            #endif
            if !layout.streaming { layout.followsEnd = true }
            readerScrolledUp = false
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
            // The end may have moved while the ↓ animation ran: land on where it is now (never while streaming).
            guard let cv = collectionView, let layout else { return }
            cv.animatingToEnd = false
            if layout.followsEnd, !layout.streaming { cv.contentOffset = CGPoint(x: 0, y: layout.endOffset(in: cv)) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let cv = collectionView, let layout else { return }
            // Only the reader's own scrolling decides whether the transcript follows the end; the layout's own
            // adjustments and the ↓ animation don't. live-31: never while an answer streams.
            if cv.isTracking || cv.isDecelerating {
                layout.followsEnd = !layout.streaming && layout.endOffset(in: cv) - cv.contentOffset.y <= Self.followDistance
            }
            reportGeometry()
        }

        /// The runway shrinks below the visible area once a scroll comes to REST (nothing on screen moves). Never during a
        /// drag or a fling: shrinking the content under a decelerating / bouncing scroll view kept its animation from ever
        /// settling (the freeze lab's app never went idle).
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollSettled() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { scrollSettled() } }
        private func scrollSettled() {
            if let cv = collectionView, let layout {
                let away = layout.endOffset(in: cv) - cv.contentOffset.y > Self.arrowDistance
                if !away { readerScrolledUp = false } else if cv.contentOffset.y < dragStartOffset - 1 { readerScrolledUp = true }
            }
            settleRunway()
        }
        private func settleRunway() {
            guard let cv = collectionView, let layout, !layout.streaming, !cv.isTracking, !cv.isDecelerating,
                  let a = layout.runwayAnchor, cv.contentOffset.y < a - 0.5 else { return }
            layout.setRunwayAnchor(max(0, cv.contentOffset.y))
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            collectionView?.animatingToEnd = false
            dragStartOffset = scrollView.contentOffset.y
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
                #if DEBUG
                if !nowAtEnd, layout.streaming, TranscriptMotion.on { TranscriptMotion.shared.arrowShownWhileStreaming() }
                #endif
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
            StreamGeoRecorder.shared.note(content: layout.naturalHeight, offset: offY, streaming: session?.isStreaming ?? false)
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
    /// live-31 — `-TranscriptMotionLog YES`: what moved on screen, per display frame, while an answer streamed
    /// (the session's flag, so the live-30 baseline is measured too).
    var debugAnswerStreaming = false
    private var motionLink: CADisplayLink?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard TranscriptMotion.on else { return }
        if window != nil, motionLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(motionTick))
            link.add(to: .main, forMode: .common)
            motionLink = link
        } else if window == nil {
            motionLink?.invalidate(); motionLink = nil
        }
    }
    @objc private func motionTick() { TranscriptMotion.shared.sample(self) }
    #endif

    override func layoutSubviews() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { if ChatTranscript.openTrace { Self.trace(String(format: "layoutSubviews h=%.0f off=%.0f content=%.0f took=%.1fms", bounds.height, contentOffset.y, contentSize.height, (CACurrentMediaTime() - t0) * 1000)) } }
        #endif
        let h = bounds.height
        let layout = collectionViewLayout as? ChatTranscriptLayout
        if let layout, abs(h - lastHeight) > 0.5 {
            let end = layout.endOffset(in: self, height: h)
            let offset = contentOffset.y
            if layout.followsEnd, !layout.streaming {
                contentOffset = CGPoint(x: 0, y: end)   // at the end: the end
            } else if lastHeight > 0, layout.streaming || layout.naturalHeight < offset + lastHeight {
                // live-31 — while an answer streams, or with the runway showing at the bottom: the TOP edge stays put
                // (nothing on screen moves); the runway keeps this offset reachable at the new height.
                if offset + h > layout.naturalHeight { layout.setRunwayAnchor(max(layout.runwayAnchor ?? 0, offset), height: h) }
            } else if lastHeight > 0 {
                // Elsewhere the bottom edge stays put: what sat above the composer stays there.
                contentOffset = CGPoint(x: 0, y: min(max(0, offset + lastHeight - h), end))
            }
        }
        lastHeight = h
        super.layoutSubviews()
        // Safety net for the end: after this pass's cells sized themselves, a transcript that follows the end shows it
        // (never under the reader's finger, a fling, the ↓ animation, or while an answer streams).
        if let layout, layout.followsEnd, !layout.streaming, !isTracking, !isDecelerating, !animatingToEnd {
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
    /// live-31 — an answer is streaming: nothing the layout learns moves what's on screen (no following the end).
    var streaming = false
    /// live-31 — the runway: while set, the content is at least this offset + the view's height, so the offset that
    /// brought the question near the top stays reachable while the answer is still shorter than the screen.
    private(set) var runwayAnchor: CGFloat?
    /// The rows' own height (no runway): the end the ↓ arrow and `followsEnd` aim at.
    private(set) var naturalHeight: CGFloat = 0

    private var heights: [TranscriptItem: CGFloat] = [:]
    private var heightsWidth: CGFloat = 0
    private var attrs: [UICollectionViewLayoutAttributes] = []
    /// A runway-only invalidation doesn't rebuild the rows.
    private var needsRebuild = true
    private final class RunwayInvalidation: UICollectionViewLayoutInvalidationContext {}

    func forgetHeights() { heights.removeAll(); invalidateLayout() }
    func carryHeight(from a: TranscriptItem, to b: TranscriptItem) { if let h = heights[a] { heights[b] = h } }
    func frame(of item: TranscriptItem) -> CGRect? {
        guard let i = (0..<attrs.count).first(where: { itemAt?(IndexPath(item: $0, section: 0)) == item }) else { return nil }
        return attrs[i].frame
    }

    /// The content height with the runway (`height` = the view's height).
    private func contentHeight(_ height: CGFloat) -> CGFloat {
        guard let a = runwayAnchor else { return naturalHeight }
        return max(naturalHeight, a + height)
    }

    /// Set (or clear, or shrink) the runway; it goes by itself once the rows reach past it.
    func setRunwayAnchor(_ a: CGFloat?, height: CGFloat? = nil) {
        guard let cv = collectionView else { runwayAnchor = a; return }
        let h = height ?? cv.bounds.height
        let new = a.flatMap { naturalHeight >= $0 + h ? nil : $0 }
        guard new != runwayAnchor else { return }
        runwayAnchor = new
        invalidateLayout(with: RunwayInvalidation())
    }

    /// The offset that shows the last line: the rows' bottom at the view's bottom (0 when it all fits). Not the runway.
    func endOffset(in cv: UICollectionView, height: CGFloat? = nil) -> CGFloat {
        max(0, naturalHeight - (height ?? cv.bounds.height))
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if !(context is RunwayInvalidation) { needsRebuild = true }
        super.invalidateLayout(with: context)
    }

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let width = cv.bounds.width
        let n = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        if abs(width - heightsWidth) > 0.5 { heights.removeAll(); heightsWidth = width; needsRebuild = true }
        if needsRebuild || attrs.count != n {
            needsRebuild = false
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
            naturalHeight = n > 0 ? y - Self.spacing + Self.bottomInset : 0
        }
        if let a = runwayAnchor, naturalHeight >= a + cv.bounds.height { runwayAnchor = nil }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight(collectionView?.bounds.height ?? 0))
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
        let h = cv.bounds.height
        let before = contentHeight(h)
        if let item = itemAt?(original.indexPath) { heights[item] = preferred.size.height }
        // Keep the cached frames current at once: several cells can size themselves in one pass.
        attrs[i] = Self.moved(attrs[i]) { $0.size.height = preferred.size.height }
        for j in (i + 1)..<attrs.count { attrs[j] = Self.moved(attrs[j]) { $0.origin.y += delta } }
        naturalHeight += delta
        let offset = cv.contentOffset.y
        let target: CGFloat
        if followsEnd, !streaming {
            target = max(0, naturalHeight - h)                         // the end stays the end
        } else if old.maxY <= offset + 0.5 {
            target = offset + delta                                    // a change above the screen: the reader stays put
            if let a = runwayAnchor { runwayAnchor = a + delta }       // … and so does the runway under the question
        } else {
            target = offset                                            // on screen or below: it grows downward
        }
        if let a = runwayAnchor, naturalHeight >= a + h { runwayAnchor = nil }
        if abs(target - offset) > 0.01 { ctx.contentOffsetAdjustment = CGPoint(x: 0, y: target - offset) }
        ctx.contentSizeAdjustment = CGSize(width: 0, height: contentHeight(h) - before)
        return ctx
    }
}

#if DEBUG
/// live-31 (1) — `-TranscriptMotionLog YES` (shown with `-GauntletUI` as the `transcript.motion` label): per display frame
/// while an answer streams, how far anything on screen moved. Measured between the reader's own scrolls and the one
/// send / ↓ animation (a "still" stretch); the worst over the turn:
///  • `offset` — the content offset; • `above` — the top of any on-screen cell other than the streaming answer;
///  • `tailTop` — the streaming answer's top; • `inCell` — its SwiftUI content's top in the cell's own space (a shift
///    inside the cell; a centring by the hosting view itself doesn't show here — the video's pixel track checks that);
///  • `grow` / `shrink` — how often the streaming answer's height went up / down (`hz` = grows per second);
///  • `down` / `back` — ↓ taps while it streamed, and how often ↓ showed again afterwards in that stream (no following).
/// Read from the cells' presentation layers, so a UIKit animation shows up too.
@Observable final class TranscriptMotion {
    static let shared = TranscriptMotion()
    static let on = UserDefaults.standard.bool(forKey: "TranscriptMotionLog")
    var line = "streams=0"
    /// The streaming answer's content top in its cell's coordinate space (its SwiftUI geometry).
    @ObservationIgnored var tailContentY: CGFloat?
    @ObservationIgnored private var streams = 0
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var grow = 0
    @ObservationIgnored private var shrink = 0
    @ObservationIgnored private var offsetMax: CGFloat = 0
    @ObservationIgnored private var aboveMax: CGFloat = 0
    @ObservationIgnored private var tailTopMax: CGFloat = 0
    @ObservationIgnored private var inCellMax: CGFloat = 0
    @ObservationIgnored private var base: [TranscriptItem: CGFloat] = [:]
    @ObservationIgnored private var baseOffset: CGFloat?
    @ObservationIgnored private var baseInCell: CGFloat?
    @ObservationIgnored private var lastTailH: CGFloat?
    @ObservationIgnored private var wasStreaming = false
    /// ↓ tapped while streaming, and ↓ shown again afterwards in the same stream (it didn't follow).
    @ObservationIgnored private var downTaps = 0
    @ObservationIgnored private var arrowBack = 0
    func downTappedWhileStreaming() { downTaps += 1; publish() }
    func arrowShownWhileStreaming() { if downTaps > 0 { arrowBack += 1; publish() } }
    @ObservationIgnored private var t0: CFTimeInterval = 0

    func sample(_ cv: ChatTranscriptCollectionView) {
        guard let layout = cv.collectionViewLayout as? ChatTranscriptLayout else { return }
        let streaming = cv.debugAnswerStreaming
        if streaming, !wasStreaming {
            streams += 1; frames = 0; grow = 0; shrink = 0; downTaps = 0; arrowBack = 0
            offsetMax = 0; aboveMax = 0; tailTopMax = 0; inCellMax = 0; lastTailH = nil
            t0 = CACurrentMediaTime(); rebase()
        }
        defer { wasStreaming = streaming }
        if !streaming, wasStreaming { publish() }
        guard streaming else { return }
        // The reader's scrolls and the one send / ↓ animation are movements on purpose: start a new still stretch.
        if cv.isTracking || cv.isDecelerating || cv.animatingToEnd { rebase(); return }
        frames += 1
        let off = cv.contentOffset.y
        if let b = baseOffset { offsetMax = max(offsetMax, abs(off - b)) } else { baseOffset = off }
        for cell in cv.visibleCells {
            guard let ip = cv.indexPath(for: cell), let item = layout.itemAt?(ip) else { continue }
            let f = cell.layer.presentation()?.frame ?? cell.frame
            let y = cv.convert(CGPoint(x: 0, y: f.minY), to: nil).y
            if let b = base[item] {
                let d = abs(y - b)
                if item == .tail { tailTopMax = max(tailTopMax, d) } else { aboveMax = max(aboveMax, d) }
            } else { base[item] = y }
            if item == .tail {
                if let last = lastTailH { if f.height > last + 0.5 { grow += 1 } else if f.height < last - 0.5 { shrink += 1 } }
                lastTailH = f.height
                if let inCell = tailContentY {   // the content's top in the cell's own space (a SwiftUI shift)
                    if let b = baseInCell { inCellMax = max(inCellMax, abs(inCell - b)) } else { baseInCell = inCell }
                }
            }
        }
        if frames % 15 == 0 { publish() }
    }

    private func rebase() { base = [:]; baseOffset = nil; baseInCell = nil; publish() }

    private func publish() {
        let secs = max(0.001, CACurrentMediaTime() - t0)
        line = String(format: "streams=%d frames=%d offset=%.1f above=%.1f tailTop=%.1f inCell=%.1f grow=%d shrink=%d hz=%.1f down=%d back=%d",
                      streams, frames, offsetMax, aboveMax, tailTopMax, inCellMax, grow, shrink, Double(grow) / secs, downTaps, arrowBack)
    }
}
#endif
