import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Sweep 2b · 2.2 — the Cards collection-view spike (Ops design-refs/mac-sweep-1/sheet-collection-views.md, "The spike").
// Mac only, Cards only, behind switches; today's SwiftUI grid stays the default and nothing is deleted.
//
//   Arm A (control): today's lazy grid, but each card is laid out once at the design width (205 pt) and scaled to its
//                    cell, so a width change no longer reaches the cards (their `NodeTileView ==` inputs stay the same).
//   Arm B:           a UICollectionView (compositional layout) with the same SwiftUI card in each cell, the card's
//                    content view placed by hand so a cell can either re-lay out its card at every new width
//                    (`relayout`) or scale the card it has during a width change and re-lay it out once the width has
//                    been still for 150 ms (`scale`). Selection is UIKit's (click, ⌘ / ⇧-click, ⌘A, arrows, Return,
//                    Esc, box drag, a menu for the selected items, drag one card out as a text file).
//
// Switches (Settings › About › Version ×5 › Mac feel (testing)) are UserDefaults keys, so the same names work as launch
// arguments for the bench (`-MacCardsCollection B -MacCardsResize scale -MacCardsClick select`). Compiled only into Mac
// builds with DEBUG or DEVSWITCHES (Xcode runs, TestFlight); an App Store archive has none of this file.

#if targetEnvironment(macCatalyst) && (DEBUG || DEVSWITCHES)

enum MacCardsSpike {
    /// today | A | B
    static let engineKey = "MacCardsCollection"
    /// Arm B: relayout | scale
    static let resizeKey = "MacCardsResize"
    /// Arm B: open (a click opens the entry, today) | select (a click selects; double-click or Return opens)
    static let clickKey = "MacCardsClick"
    /// Arm B, bench only (not in the panel): own (AirPad's Mac rules on top of UIKit's selection, the default) |
    /// system (UIKit's own multiple selection, focus and primary action, plus Return / Esc / ⌘A / the menu)
    static let selectionKey = "MacCardsSelection"

    static func string(_ key: String, _ fallback: String) -> String { UserDefaults.standard.string(forKey: key) ?? fallback }

    /// Bench `-MacCardsLog YES` (DEBUG / PERFLOG builds only): one stderr line per selection change, open, menu, band,
    /// drag and settle, for `scripts/mac/perf/2b-cards-select.py`. Indices and counts only, never entry text.
    static let log: Bool = {
        #if DEBUG || PERFLOG
        UserDefaults.standard.bool(forKey: "MacCardsLog")
        #else
        false
        #endif
    }()
    static func note(_ line: @autoclosure () -> String) {
        guard log else { return }
        let s = String(format: "MACCARDS at %.0f ", Date().timeIntervalSince1970 * 1000) + line() + "\n"
        FileHandle.standardError.write(Data(s.utf8))
    }
}

/// Arm A — the card laid out at the design size and scaled into its cell (top-leading), so the cell's width is not one
/// of the card's inputs.
struct MacCardsArmAScale: ViewModifier {
    let on: Bool
    let cellW: CGFloat
    let cellH: CGFloat
    func body(content: Content) -> some View {
        if on {
            content
                .scaleEffect(cellW / NodeGridView.macCardDesignWidth, anchor: .topLeading)
                .frame(width: cellW, height: cellH, alignment: .topLeading)
        } else {
            content
        }
    }
}

// MARK: - Arm B

struct MacCardsCollectionView: UIViewRepresentable {
    let nodes: [Node]
    let targetWidth: Double
    let railLane: CGFloat
    let spacing: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let appFont: EntryBodyFont
    let store: CorpusStore
    let resize: String
    let click: String
    let selectionMode: String
    var onGridWidth: (CGFloat) -> Void
    var onOpen: (Node) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MacCardsUICollectionView {
        let c = context.coordinator
        c.apply(self)
        let cv = MacCardsUICollectionView(frame: .zero, collectionViewLayout: c.makeLayout())
        c.attach(cv)
        Perf.mark("cards B make \(resize) \(click) \(selectionMode)")
        MacCardsSpike.note("make resize=\(resize) click=\(click) selection=\(selectionMode)")
        return cv
    }

    func updateUIView(_ cv: MacCardsUICollectionView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ cv: MacCardsUICollectionView, coordinator: Coordinator) {
        coordinator.settleWork?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDragDelegate, UIGestureRecognizerDelegate {
        weak var collectionView: MacCardsUICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private(set) var nodes: [Node] = []
        private var byID: [String: Node] = [:]
        private var targetWidth: Double = NodeGridView.macCardWidthDefault
        private var railLane: CGFloat = 0
        private var spacing: CGFloat = 10
        private var topInset: CGFloat = 6
        private var bottomInset: CGFloat = 24
        private(set) var appFont: EntryBodyFont = .sourceSerif4
        private(set) var store: CorpusStore?
        private var resize = "relayout"
        private var click = "open"
        private var selectionMode = "own"
        private var onGridWidth: ((CGFloat) -> Void)?
        private var onOpen: ((Node) -> Void)?
        /// Scale method: true while the width is changing (cells scale the card they have).
        private(set) var scaling = false
        var settleWork: DispatchWorkItem?
        private(set) var columns = 1
        private var lastWidth: CGFloat = 0
        private var anchor: IndexPath?
        /// The last pointer press on the collection view (left button): when, where, with which modifiers.
        private struct Press { var time: CFTimeInterval; var location: CGPoint; var modifiers: UIKeyModifierFlags }
        private var press: Press?
        private var bandBase: Set<IndexPath> = []
        private var ownSelection: Bool { selectionMode != "system" }

        func apply(_ v: MacCardsCollectionView) {
            targetWidth = v.targetWidth; railLane = v.railLane; spacing = v.spacing
            topInset = v.topInset; bottomInset = v.bottomInset
            appFont = v.appFont; store = v.store
            resize = v.resize; click = v.click; selectionMode = v.selectionMode
            onGridWidth = v.onGridWidth; onOpen = v.onOpen
        }

        // MARK: Layout — today's column rule, in UIKit

        func makeLayout() -> UICollectionViewCompositionalLayout {
            let layout = UICollectionViewCompositionalLayout { [weak self] _, env in
                guard let self else { return nil }
                return self.section(width: env.container.effectiveContentSize.width)
            }
            return layout
        }

        private func section(width w: CGFloat) -> NSCollectionLayoutSection {
            // NodeGridView.gridContent's rule: as many columns as keep the cards nearest the chosen width.
            let cols = max(1, Int(((w - spacing - railLane) / (CGFloat(targetWidth) + spacing)).rounded()))
            columns = cols
            let cellW = max(1, (w - spacing * 2 - spacing * CGFloat(cols - 1) - railLane) / CGFloat(cols))
            let cellH = cellW * 7.0 / 5.0
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(cellW), heightDimension: .absolute(cellH)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cellH)),
                repeatingSubitem: item, count: cols)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsetsReference = .none
            section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: spacing, bottom: bottomInset, trailing: spacing + railLane)
            return section
        }

        // MARK: Setup

        func attach(_ cv: MacCardsUICollectionView) {
            collectionView = cv
            cv.coordinator = self
            cv.backgroundColor = .clear
            cv.contentInsetAdjustmentBehavior = .never
            cv.accessibilityIdentifier = "cardsCollection"
            cv.delegate = self
            cv.allowsSelection = true
            cv.allowsMultipleSelection = true
            cv.allowsFocus = !ownSelection
            cv.selectionFollowsFocus = !ownSelection
            cv.dragDelegate = self
            cv.dragInteractionEnabled = true

            let registration = UICollectionView.CellRegistration<MacCardCell, String> { [weak self] cell, _, id in
                guard let self, let node = self.byID[id] else { return }
                cell.coordinator = self
                cell.show(node)
                cell.accessibilityIdentifier = "cardCell-\(node.id)"
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, ip, id in
                cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: id)
            }

            // The pointer press (and its modifier keys) as it lands; never takes the touch from anyone.
            let observer = UITapGestureRecognizer(target: self, action: #selector(clicked(_:)))
            observer.cancelsTouchesInView = false
            observer.delaysTouchesEnded = false
            observer.delegate = self
            cv.addGestureRecognizer(observer)
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
            double.numberOfTapsRequired = 2
            double.cancelsTouchesInView = false
            double.delaysTouchesEnded = false
            double.delegate = self
            cv.addGestureRecognizer(double)
            if ownSelection {
                let band = UIBandSelectionInteraction { [weak self] i in self?.band(i) }
                band.shouldBeginHandler = { [weak cv] _, p in cv?.indexPathForItem(at: p) == nil }
                cv.addInteraction(band)
            }
            cv.onWidth = { [weak self] w in self?.widthChanged(w) }
            cv.onKey = { [weak self] k in self?.key(k) }
            cv.onSelectAll = { [weak self] in self?.selectAll() }
            cv.ownArrows = ownSelection
            applySnapshot(force: true)
        }

        func update(_ v: MacCardsCollectionView) {
            let oldTarget = targetWidth, oldFont = appFont, oldRail = railLane
            apply(v)
            guard let cv = collectionView else { return }
            if targetWidth != oldTarget || railLane != oldRail {
                widthChanged(cv.bounds.width, force: true)
                cv.collectionViewLayout.invalidateLayout()
            }
            if appFont != oldFont { for case let cell as MacCardCell in cv.visibleCells { cell.markDirty() } }
            nodesChanged(v.nodes)
        }

        private func nodesChanged(_ new: [Node]) {
            let ids = new.map(\.id)
            let oldIDs = nodes.map(\.id)
            var changed: [String] = []
            for n in new { if let o = byID[n.id], !Self.sameCard(o, n) { changed.append(n.id) } }
            nodes = new
            byID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if ids != oldIDs { applySnapshot(force: false) }
            if !changed.isEmpty, var snap = dataSource?.snapshot() {
                snap.reconfigureItems(changed.filter { snap.indexOfItem($0) != nil })
                dataSource?.apply(snap, animatingDifferences: false)
            }
        }

        private func applySnapshot(force: Bool) {
            if force { byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            snap.appendItems(nodes.map(\.id))
            dataSource?.apply(snap, animatingDifferences: false)
            MacCardsSpike.note("items n=\(nodes.count)")
        }

        /// The fields the card draws (NodeTileView's `==`).
        private static func sameCard(_ l: Node, _ r: Node) -> Bool {
            l.title == r.title && l.summary == r.summary && l.tags == r.tags && l.items == r.items &&
            l.coverImageRelativePath == r.coverImageRelativePath && l.descriptionOnCard == r.descriptionOnCard &&
            l.updatedAt == r.updatedAt
        }

        func node(at ip: IndexPath) -> Node? {
            guard let id = dataSource?.itemIdentifier(for: ip) else { return nil }
            return byID[id]
        }

        // MARK: Width changes (the two cell methods)

        private func widthChanged(_ w: CGFloat, force: Bool = false) {
            if w != lastWidth { onGridWidth?(w) }
            let had = lastWidth
            lastWidth = w
            guard resize == "scale", had > 0 || force else { return }
            scaling = true
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func settle() {
            guard scaling, let cv = collectionView else { return }
            scaling = false
            Perf.mark("cards B settle")
            Perf.interval("cardsB.settle") {
                for cell in cv.visibleCells { cell.setNeedsLayout() }
                cv.layoutIfNeeded()
            }
            MacCardsSpike.note("settle w=\(Int(cv.bounds.width)) cols=\(columns)")
        }

        // MARK: Selection

        private var selected: Set<IndexPath> { Set(collectionView?.indexPathsForSelectedItems ?? []) }

        private func setSelection(_ want: Set<IndexPath>, _ source: String) {
            guard let cv = collectionView else { return }
            let have = selected
            for ip in have.subtracting(want) { cv.deselectItem(at: ip, animated: false) }
            for ip in want.subtracting(have).sorted() { cv.selectItem(at: ip, animated: false, scrollPosition: []) }
            noteSelection(source)
        }

        private func noteSelection(_ source: String) {
            guard MacCardsSpike.log else { return }
            let s = selected.map(\.item).sorted()
            MacCardsSpike.note("sel n=\(s.count) via=\(source) idx=\(s.prefix(16).map(String.init).joined(separator: ","))")
        }

        private func open(_ ip: IndexPath, via: String) {
            guard let node = node(at: ip) else { return }
            MacCardsSpike.note("open idx=\(ip.item) via=\(via)")
            Perf.mark("cards B open")
            collectionView?.resignFirstResponder()   // the entry takes the keys (Return / Esc are not the cards' there)
            onOpen?(node)
        }

        /// A pointer press is fresh for this long: UIKit's own selection changes from it are AirPad's to make (own mode).
        private var pointerFresh: Bool { press.map { CACurrentMediaTime() - $0.time < 0.6 } ?? false }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            if (g as? UITapGestureRecognizer)?.numberOfTapsRequired == 1, let cv = collectionView,
               let t = event.allTouches?.first {
                press = Press(time: CACurrentMediaTime(), location: t.location(in: cv), modifiers: event.modifierFlags)
                if !cv.isFirstResponder { cv.becomeFirstResponder() }
            }
            return true
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func clicked(_ g: UITapGestureRecognizer) {
            guard let cv = collectionView else { return }
            let p = g.location(in: cv)
            let mods = press?.modifiers ?? g.modifierFlags
            guard let ip = cv.indexPathForItem(at: p) else {
                // A click on the ground between / around the cards clears the selection (Finder, Photos).
                if !mods.contains(.command) && !mods.contains(.shift) { setSelection([], "ground") }
                return
            }
            guard ownSelection else { return }   // system: UIKit selected (or not) by itself
            if mods.contains(.command) {
                var s = selected
                if s.contains(ip) { s.remove(ip) } else { s.insert(ip) }
                anchor = ip
                setSelection(s, "cmd")
            } else if mods.contains(.shift), let a = anchor {
                let lo = min(a.item, ip.item), hi = max(a.item, ip.item)
                setSelection(Set((lo...hi).map { IndexPath(item: $0, section: 0) }), "shift")
            } else {
                anchor = ip
                setSelection([ip], "click")
                if click == "open" { open(ip, via: "click") }
            }
        }

        @objc private func doubleClicked(_ g: UITapGestureRecognizer) {
            guard click == "select", let cv = collectionView, let ip = cv.indexPathForItem(at: g.location(in: cv)) else { return }
            open(ip, via: "double")
        }

        func collectionView(_ cv: UICollectionView, shouldSelectItemAt ip: IndexPath) -> Bool { !(ownSelection && pointerFresh) }
        func collectionView(_ cv: UICollectionView, shouldDeselectItemAt ip: IndexPath) -> Bool { !(ownSelection && pointerFresh) }
        func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { anchor = ip; noteSelection("uikit") }
        func collectionView(_ cv: UICollectionView, didDeselectItemAt ip: IndexPath) { noteSelection("uikit") }

        /// UIKit's primary action (a selection that doesn't extend one). System mode: the click that opens in "open";
        /// in "select" a click never opens (double-click and Return do).
        func collectionView(_ cv: UICollectionView, performPrimaryActionForItemAt ip: IndexPath) {
            MacCardsSpike.note("primary idx=\(ip.item)")
            guard !ownSelection, click == "open", pointerFresh else { return }
            open(ip, via: "primary")
        }

        private func selectAll() {
            let n = collectionView?.numberOfItems(inSection: 0) ?? 0
            setSelection(Set((0..<n).map { IndexPath(item: $0, section: 0) }), "cmdA")
        }

        private func key(_ k: MacCardsUICollectionView.Key) {
            guard let cv = collectionView else { return }
            switch k {
            case .escape:
                setSelection([], "esc")
            case .returnKey:
                let s = selected
                guard let ip = (anchor.flatMap { s.contains($0) ? $0 : nil }) ?? s.sorted().first else { return }
                open(ip, via: "return")
            case .left, .right, .up, .down:
                let n = cv.numberOfItems(inSection: 0)
                guard n > 0 else { return }
                let from = anchor?.item ?? selected.map(\.item).min() ?? -1
                var to: Int
                switch k {
                case .left: to = from - 1
                case .right: to = from + 1
                case .up: to = from - columns
                default: to = from < 0 ? 0 : from + columns
                }
                to = min(max(to, 0), n - 1)
                let ip = IndexPath(item: to, section: 0)
                anchor = ip
                setSelection([ip], "arrow")
                if let f = cv.layoutAttributesForItem(at: ip)?.frame { cv.scrollRectToVisible(f.insetBy(dx: 0, dy: -spacing), animated: false) }
            }
        }

        // MARK: Box (rubber-band) selection — own mode

        private func band(_ i: UIBandSelectionInteraction) {
            guard let cv = collectionView else { return }
            switch i.state {
            case .began:
                let m = i.initialModifierFlags
                bandBase = m.contains(.shift) || m.contains(.command) ? selected : []
            case .selecting:
                let r: CGRect? = i.selectionRect
                guard let r else { return }
                let hits = (cv.collectionViewLayout.layoutAttributesForElements(in: r) ?? [])
                    .filter { $0.representedElementCategory == .cell && $0.frame.intersects(r) }.map(\.indexPath)
                let want = bandBase.union(hits)
                if want != selected {
                    let have = selected
                    for ip in have.subtracting(want) { cv.deselectItem(at: ip, animated: false) }
                    for ip in want.subtracting(have) { cv.selectItem(at: ip, animated: false, scrollPosition: []) }
                }
            case .ended:
                if let first = selected.sorted().first { anchor = first }
                noteSelection("band")
            default:
                break
            }
        }

        // MARK: Menu (zero, one or many selected)

        func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            guard let first = ips.first else { return nil }
            let clicked = cv.indexPathForItem(at: point) ?? first
            MacCardsSpike.note("menu n=\(ips.count) idx=\(clicked.item)")
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var actions: [UIMenuElement] = [UIAction(title: "Open") { _ in self?.open(clicked, via: "menu") }]
                if ips.count > 1 {
                    actions.append(UIAction(title: "Deselect All") { _ in self?.setSelection([], "menu") })
                }
                return UIMenu(title: ips.count > 1 ? "\(ips.count) entries" : "", children: actions)
            }
        }

        func collectionView(_ cv: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
            MacCardsSpike.note("menu shown selected=\(selected.count)")
        }

        // MARK: Cells on / off screen (the card's gradient animates only on screen)

        func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
            (cell as? MacCardCell)?.setOnScreen(true)
        }
        func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt ip: IndexPath) {
            (cell as? MacCardCell)?.setOnScreen(false)
        }

        // MARK: Drag out (stretch): one card → a text file

        func collectionView(_ cv: UICollectionView, itemsForBeginning session: any UIDragSession, at ip: IndexPath) -> [UIDragItem] {
            guard let node = node(at: ip) else { return [] }
            MacCardsSpike.note("drag idx=\(ip.item)")
            let name = Self.fileName(node.title)
            let text = ([node.title, node.summary] + (node.tags.isEmpty ? [] : ["Tags: " + node.tags.joined(separator: ", ")]))
                .filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
            let provider = NSItemProvider()
            provider.suggestedName = name
            provider.registerFileRepresentation(for: .plainText, visibility: .all, openInPlace: false) { done in
                do {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CardsDrag-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent(name).appendingPathExtension("txt")
                    try Data(text.utf8).write(to: url)
                    done(url, false, nil)
                } catch {
                    done(nil, false, error)
                }
                return nil
            }
            let item = UIDragItem(itemProvider: provider)
            item.localObject = node.id
            return [item]
        }

        private static func fileName(_ title: String) -> String {
            let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters)
            let t = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "Entry" : String(t.prefix(120))
        }
    }
}

/// The collection view: reports width changes before its layout pass, and owns the keys (Return, Esc, arrows) and ⌘A.
final class MacCardsUICollectionView: UICollectionView {
    enum Key { case escape, returnKey, left, right, up, down }
    weak var coordinator: MacCardsCollectionView.Coordinator?
    var onWidth: ((CGFloat) -> Void)?
    var onKey: ((Key) -> Void)?
    var onSelectAll: (() -> Void)?
    var ownArrows = true
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidth?(bounds.width)   // before the cells take their new sizes (the scale method needs to know first)
        }
        super.layoutSubviews()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        // Only while the cards are what's showing: an open entry over them keeps its own Return / Esc / arrows.
        guard window != nil, coordinator?.store?.isInDetailView != true else { return nil }
        var k = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey)),
        ]
        if ownArrows {
            k += [
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(leftKey)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(rightKey)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upKey)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downKey)),
            ]
        }
        k.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return k
    }
    @objc private func returnKey() { onKey?(.returnKey) }
    @objc private func escapeKey() { onKey?(.escape) }
    @objc private func leftKey() { onKey?(.left) }
    @objc private func rightKey() { onKey?(.right) }
    @objc private func upKey() { onKey?(.up) }
    @objc private func downKey() { onKey?(.down) }

    /// Edit › Select All (⌘A) arrives here while the cards hold the keyboard.
    override func selectAll(_ sender: Any?) { onSelectAll?() }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(selectAll(_:)) { return window != nil && coordinator?.store?.isInDetailView != true }
        return super.canPerformAction(action, withSender: sender)
    }
}

/// One card. The SwiftUI card's content view is placed by hand (not the cell's `contentConfiguration` slot) so the
/// scale method can keep the card it has, at the size it was laid out at, under a transform while the width changes.
final class MacCardCell: UICollectionViewCell {
    weak var coordinator: MacCardsCollectionView.Coordinator?
    private var node: Node?
    private var host: (UIView & UIContentView)?
    private var rendered: CGSize = .zero
    private var nodeDirty = true
    private var stateDirty = false
    private var onScreen = true

    func show(_ n: Node) {
        node = n
        nodeDirty = true
        setNeedsLayout()
    }
    func markDirty() { stateDirty = true; setNeedsLayout() }
    func setOnScreen(_ on: Bool) {
        guard on != onScreen else { return }
        onScreen = on
        markDirty()
    }
    override var isSelected: Bool { didSet { if isSelected != oldValue { markDirty() } } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = contentView.bounds.size
        guard node != nil, size.width > 1, size.height > 1 else { return }
        if (coordinator?.scaling ?? false) && !nodeDirty && rendered != .zero {
            // Scale, then settle: keep the card laid out at `rendered`, scaled to the cell.
            if stateDirty { render(rendered) }
            guard let host else { return }
            host.transform = .identity
            host.bounds = CGRect(origin: .zero, size: rendered)
            host.center = CGPoint(x: size.width / 2, y: size.height / 2)
            host.transform = CGAffineTransform(scaleX: size.width / rendered.width, y: size.height / rendered.height)
        } else {
            // Re-lay out at the cell's own size (always, in the relayout method).
            if nodeDirty || stateDirty || rendered != size { render(size) }
            guard let host else { return }
            host.transform = .identity
            host.frame = CGRect(origin: .zero, size: size)
        }
    }

    private func render(_ size: CGSize) {
        guard let node, let coordinator, let store = coordinator.store else { return }
        Perf.interval("cardsB.cell") {
            let config = UIHostingConfiguration {
                MacCardCellContent(node: node, size: size, selected: isSelected, onScreen: onScreen)
                    .environment(store)
                    .environment(\.appBodyFont, coordinator.appFont)
            }
            .margins(.all, 0)
            if let host {
                host.configuration = config
            } else {
                let v = config.makeContentView()
                v.isUserInteractionEnabled = false   // the cell takes the clicks; nothing in the card is hit-tested
                contentView.addSubview(v)
                host = v
            }
        }
        rendered = size
        nodeDirty = false
        stateDirty = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nodeDirty = true
    }
}

/// The cell's SwiftUI: today's card and its grid dressing (sheen, clip, lift, rim, emboss), as `NodeGridView` draws it.
private struct MacCardCellContent: View {
    let node: Node
    let size: CGSize
    let selected: Bool
    let onScreen: Bool
    @Environment(CorpusStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = Perf.body(Self.self)
        let dark = colorScheme == .dark
        let shadowScale = min(size.width / 360, 1)
        NodeGridTile(
            node: node,
            cellWidth: size.width,
            cellHeight: size.height,
            animateGradient: !perfAB("cardstatic"),
            columnCount: 2,
            designWidth: NodeGridView.macCardDesignWidth
        )
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .selectionHighlight(isSelecting: selected, isPicked: selected, cornerRadius: 14)
        .environment(\.blobFieldPaused, !(onScreen && !store.isInDetailView && phase == .active))
        .allowsHitTesting(false)
        .overlay(NodeGridView.tileSheen)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: AppearancePalette.cardShadow,
                radius: CardSurfaceResolved.shadowRadius(dark: dark) * shadowScale,
                x: 0,
                y: CardSurfaceResolved.shadowY(dark: dark) * shadowScale)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CardSurfaceResolved.rimGradient(dark: dark), lineWidth: CardSurfaceResolved.rimWidth(dark: dark))
                .allowsHitTesting(false)
        )
        .overlay(CardEmbossOverlay(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cardTile-\(node.id)")
    }
}

#if DEBUG
/// `-MacCardsSpikeSelfTest` (with `-MacCardsCollection B` and `-MacCardsResize relayout|scale`, or `A` / `today`): Cards
/// on the Sample Library — arm B's collection view is up, its cells hold a laid-out card, a width change scales (scale)
/// or re-lays out (relayout) and settles back to identity at the cell's size, ⌘A / Esc / an arrow / Return act on the
/// selection, and a still of each arm (`<tmp>/macshots/cards-<arm>.png`). Not a speed or real-event test.
@MainActor
enum MacCardsSpikeSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let engine = MacCardsSpike.string(MacCardsSpike.engineKey, "today")
        let resize = MacCardsSpike.string(MacCardsSpike.resizeKey, "relayout")
        let arm = engine == "B" ? "B-\(resize)" : engine
        router.perform(.viewCards)   // View › Cards: the Library, as Cards
        await settle(3.0)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func find(_ v: UIView) -> MacCardsUICollectionView? {
            if let c = v as? MacCardsUICollectionView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        let cv = windows.lazy.compactMap { find($0) }.first
        rows.append("INFO arm \(arm) · \(store.nodes.count) entries · view \(store.filterState(for: .corpus).viewMode.rawValue)")
        RunningOnMac.snapshot("cards-\(arm)")
        guard engine == "B" else {
            row("arm \(arm): no collection view in the window", cv == nil)
            return "[MacCardsSpikeSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { !$0.hasPrefix("INFO") }.count - fails)/\(rows.filter { !$0.hasPrefix("INFO") }.count)\n" + rows.joined(separator: "\n")
        }
        guard let cv, let coord = cv.coordinator else { return "[MacCardsSpikeSelfTest] FAIL — no collection view (arm B)" }
        let n = cv.numberOfItems(inSection: 0)
        row("arm B: one item per entry", n == store.filteredNodes(in: .corpus).count && n > 0, "\(n) items")
        func hosts() -> [(cell: CGSize, host: CGSize, identity: Bool)] {
            cv.visibleCells.compactMap { c in
                guard let h = c.contentView.subviews.first else { return nil }
                return (c.bounds.size, h.bounds.size, h.transform.isIdentity)
            }
        }
        let h0 = hosts()
        row("cells hold a card laid out at the cell's size", h0.count >= 4 && h0.allSatisfy { $0.identity && abs($0.cell.width - $0.host.width) < 0.5 },
            "\(cv.visibleCells.count) cells, \(h0.count) with a card · first \(h0.first.map { "\($0.cell) / \($0.host)" } ?? "-")")
        // A width change: the sidebar hidden (the cards' width grows), caught on the first pass at the new width.
        let layout = MacLayout.shared
        let side0 = layout.sidebarVisible, cvW0 = cv.bounds.width
        layout.sidebarVisible.toggle()
        for _ in 0..<100 where cv.bounds.width == cvW0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        let mid = hosts()
        let scaledMid = mid.contains { !$0.identity }
        rows.append(String(format: "INFO width %.0f → %.0f; mid-change: %d of %d scaled, scaling %@", cvW0, cv.bounds.width, mid.filter { !$0.identity }.count, mid.count, coord.scaling ? "on" : "off"))
        if resize == "scale" { row("scale: mid-change the cards are scaled, not re-laid out", scaledMid && coord.scaling) }
        else { row("relayout: mid-change every card is laid out at its cell's size", !scaledMid && mid.allSatisfy { abs($0.cell.width - $0.host.width) < 0.5 }) }
        await settle(0.8)
        let after = hosts()
        row("after the change: settled at the new size (identity, card = cell)", !coord.scaling && after.allSatisfy { $0.identity && abs($0.cell.width - $0.host.width) < 0.5 },
            "\(after.first.map { "\($0.cell) / \($0.host)" } ?? "-")")
        layout.sidebarVisible = side0
        await settle(0.8)
        // Selection through the same paths the keys and the menu take.
        cv.becomeFirstResponder()
        cv.selectAll(nil); await settle(0.2)
        row("⌘A (selectAll:) selects every card", (cv.indexPathsForSelectedItems?.count ?? 0) == n, "\(cv.indexPathsForSelectedItems?.count ?? 0) of \(n)")
        let sel = cv.visibleCells.filter(\.isSelected).count
        row("selected cards draw selected (visible cells)", sel == cv.visibleCells.count, "\(sel) of \(cv.visibleCells.count)")
        cv.onKey?(.escape); await settle(0.2)
        row("Esc clears", (cv.indexPathsForSelectedItems?.count ?? 0) == 0)
        cv.onKey?(.right); await settle(0.2)
        let one = cv.indexPathsForSelectedItems ?? []
        row("an arrow selects one card", one.count == 1, "\(one.map(\.item))")
        cv.onKey?(.down); await settle(0.2)
        let two = cv.indexPathsForSelectedItems ?? []
        row("↓ moves one row (\(coord.columns) columns)", two.count == 1 && two[0].item == (one.first?.item ?? 0) + coord.columns, "\(two.map(\.item))")
        cv.onKey?(.returnKey); await settle(1.5)
        row("Return opens the selected card", store.isInDetailView)
        RunningOnMac.snapshot("cards-\(arm)-open")
        router.dismissDetailRequest += 1; await settle(1.2)
        row("back on the cards", !store.isInDetailView && cv.window != nil)
        cv.onKey?(.escape)
        return "[MacCardsSpikeSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { !$0.hasPrefix("INFO") }.count - fails)/\(rows.filter { !$0.hasPrefix("INFO") }.count)\n" + rows.joined(separator: "\n")
    }
}
#endif

#endif
