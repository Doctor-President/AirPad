import SwiftUI
import UIKit

/// Field-name label style — a sample toggle. SF Rounded has NO italic face (so `.italic()`
/// on it is a no-op), so the italic variants switch design to one that has one.
enum AttrLabelStyle: CaseIterable {
    case regular       // rounded, upright (current)
    case serifItalic   // serif italic — matches the app's serif titles
    case sansItalic    // default-sans italic
}

#if DEBUG
/// Arrange-mode gesture probe — an on-screen HUD reads these counters so an XCUITest
/// (which can't read stdout) can OBSERVE whether the grabber drag vs the tile tap fires.
@Observable final class ArrangeGestureProbe {
    static let shared = ArrangeGestureProbe()
    var drags = 0
    var cycles = 0
    var reorders = 0
    var lifts = 0
    var moves = 0
}
#endif

/// ws-attributes-grid (P1) — the SHARED `.field` render used by BOTH the detail
/// view's Attributes section and QuickCapture. One component, not a fork
/// (`ws-card-primitive.md`). Now a **Control Center cell grid**: each field is a
/// discrete TILE whose `AttributeSizeClass` (resolved from the node override or the
/// kind default) SELECTS both its grid footprint and its rendering. `AttributeCellGrid`
/// derives its unit-column count from available width (2-up floor, 4-unit ceiling),
/// so the narrow QuickCapture / card-back container reflows down to 2-up with no
/// detail-vs-card branch. Resolves each `.field` item's definition off the
/// `@Observable` store (orphaned references drop out — never an empty cell).
struct FieldPairsGrid: View {

    let nodeID: String
    let fieldItems: [NodeItem]
    /// DEBUG-only geometry A/B (see `AttributeCellGrid.fixedFourUp`).
    var fixedFourUp: Bool = false
    /// ws-attributes-grid P2 — arrange mode (owned by the section header's glyph). While
    /// on, tapping a tile CYCLES its size through the kind's allowed set; the normal
    /// value-edit tap + remove menu are suspended. Sizes accumulate locally and commit
    /// as ONE write when arrange mode ends (`updatedAt` untouched — arranging isn't editing).
    var isArranging: Bool = false
    /// Multiplies value + label point sizes (1 = current). For gate type-size sampling.
    var typeScale: CGFloat = 1
    /// Field-name label style. BAKED default = serif italic (T, 2026-08-25 — echoes the
    /// app's serif titles). A gate overrides it to sample alternatives.
    var labelStyle: AttrLabelStyle = .serifItalic

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem?
    /// Pending per-tile size overrides during an arrange session (itemID → size).
    @State private var pendingSizes: [String: AttributeSizeClass] = [:]
    /// The in-flight corner-drag resize: which tile, the size index the drag began at (so
    /// absolute finger travel maps to steps), and the last index applied (to fire the
    /// spring + haptic only when the snapped size actually changes).
    @State private var activeResize: (id: String, startIndex: Int, lastIndex: Int)?
    /// Picker-detent haptic (the "tick" as a resize crosses each size threshold).
    private let resizeHaptic = UISelectionFeedbackGenerator()
    /// Pending field ORDER during an arrange session (item ids). nil = the store's order.
    @State private var pendingOrder: [String]?
    /// The tile currently lifted for a reorder drag + its live finger offset + drop target.
    @State private var draggingID: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dropTargetID: String?
    /// Each tile's frame in the "attrGrid" space, for hit-testing the drop target.
    @State private var tileFrames: [String: CGRect] = [:]

    private static let gridSpace = "attrGrid"

    var body: some View {
        AttributeCellGrid(minUnitWidth: 80, unitSpacing: 10, rowSpacing: 12, fixedFourUp: fixedFourUp) {
            ForEach(resolvedTiles, id: \.item.id) { tile in
                cell(for: tile)
            }
        }
        .coordinateSpace(name: Self.gridSpace)
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        .sheet(item: $editingItem) { item in
            if let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) {
                FieldValueEditorSheet(nodeID: nodeID, item: item, definition: def)
            }
        }
        .onChange(of: isArranging) { _, arranging in
            if arranging {
                pendingSizes = [:]; pendingOrder = nil   // fresh session
            } else {
                commitArrangement()                      // one write on exit (sizes + order)
            }
        }
    }

    /// Advance a tile to the next size in its kind's allowed set (wraps). Records the
    /// choice locally; it persists when arrange mode ends.
    private func cycleSize(_ tile: ResolvedTile) {
        #if DEBUG
        print("[ARR] CYCLE id=\(tile.item.id)")
        ArrangeGestureProbe.shared.cycles += 1
        #endif
        let options = tile.definition.kind.supportedSizeClasses
        guard !options.isEmpty else { return }
        let next: AttributeSizeClass
        if let idx = options.firstIndex(of: tile.sizeClass) {
            next = options[(idx + 1) % options.count]
        } else {
            next = options[0]
        }
        pendingSizes[tile.item.id] = next
    }

    /// Control-Center-style corner DRAG resize: absolute finger travel (down/right =
    /// bigger, up/left = smaller) maps to steps along the kind's ordered size set, which
    /// the grid snaps to live. Anchors the START index on the first change so the mapping
    /// stays stable while the tile reflows underneath the finger.
    private func resizeDrag(_ tile: ResolvedTile, translation: CGSize) {
        #if DEBUG
        print("[ARR] DRAG id=\(tile.item.id) dx=\(Int(translation.width)) dy=\(Int(translation.height))")
        ArrangeGestureProbe.shared.drags += 1
        #endif
        // The grabber owns this touch — cancel any reorder lift that raced in, so the
        // tile never both resizes AND lifts.
        if draggingID != nil { draggingID = nil; dropTargetID = nil; pendingOrder = nil }
        let options = tile.definition.kind.supportedSizeClasses
        guard options.count > 1 else { return }
        let startIndex: Int, lastIndex: Int
        if let active = activeResize, active.id == tile.item.id {
            startIndex = active.startIndex; lastIndex = active.lastIndex
        } else {
            startIndex = options.firstIndex(of: tile.sizeClass) ?? 0
            lastIndex = startIndex
            activeResize = (tile.item.id, startIndex, startIndex)
            resizeHaptic.prepare()
        }
        let stepPoints: CGFloat = 46   // finger travel per size step
        let steps = Int(((translation.width + translation.height) / stepPoints).rounded())
        let target = min(max(0, startIndex + steps), options.count - 1)
        // Only when the SNAPPED size changes: spring the layout (tile + neighbours reflow
        // together) and tick the picker haptic — this is what makes a snapped resize read
        // as CONTINUOUS rather than a jump.
        guard target != lastIndex else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
            pendingSizes[tile.item.id] = options[target]
        }
        resizeHaptic.selectionChanged()
        resizeHaptic.prepare()
        activeResize = (tile.item.id, startIndex, target)
    }

    /// Persist the arrange session's SIZES and ORDER as one write (no-op if nothing
    /// changed). `updatedAt` is left untouched by both store calls — arranging isn't editing.
    private func commitArrangement() {
        let sizes = pendingSizes
        let order = pendingOrder
        pendingSizes = [:]; pendingOrder = nil
        draggingID = nil; dropTargetID = nil; dragOffset = .zero
        Task {
            if let order { await store.commitFieldOrder(order, nodeID: nodeID) }
            if !sizes.isEmpty { await store.commitAttributeSizes(sizes, nodeID: nodeID) }
        }
    }

    // MARK: - Reorder (tile-body long-press → lift → drag → drop)

    /// Long-press lifted a tile: begin a reorder session anchored on the current order.
    private func beginReorder(_ id: String) {
        // A grabber resize is in progress (its immediate drag set this before the 0.4s
        // long-press could fire) → the corner owns this touch; don't also lift for reorder.
        guard activeResize == nil else { return }
        if pendingOrder == nil { pendingOrder = resolvedTiles.map(\.item.id) }
        draggingID = id
        dragOffset = .zero
        dropTargetID = id
        #if DEBUG
        print("[ARR] LIFT id=\(id)")
        ArrangeGestureProbe.shared.lifts += 1
        #endif
    }

    /// While dragging, the drop target is the tile whose frame contains the finger.
    private func updateReorder(point: CGPoint, translation: CGSize) {
        dragOffset = translation
        // EXCLUDE the dragged tile: its frame follows the finger (it's offset), so it would
        // always match. We want the sibling tile UNDER the finger as the drop target.
        if let hit = tileFrames.first(where: { $0.key != draggingID && $0.value.contains(point) })?.key {
            dropTargetID = hit
        }
        #if DEBUG
        ArrangeGestureProbe.shared.moves += 1
        #endif
    }

    /// Drop: move the dragged tile to the drop target's slot in the pending order. The
    /// grid re-lays-out to the new order; the commit itself waits for Done.
    private func endReorder() {
        defer { draggingID = nil; dropTargetID = nil; dragOffset = .zero }
        guard let dragged = draggingID, let target = dropTargetID, dragged != target,
              var order = pendingOrder,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(dragged, at: to)
        withAnimation(.snappy(duration: 0.25)) { pendingOrder = order }
        #if DEBUG
        print("[ARR] REORDER \(dragged) -> slot \(to)")
        ArrangeGestureProbe.shared.reorders += 1
        #endif
    }

    // Extracted so the ForEach's ViewBuilder stays cheap to type-check.
    @ViewBuilder
    private func cell(for tile: ResolvedTile) -> some View {
        FieldPairCell(
            value: tile.value,
            definition: tile.definition,
            sizeClass: tile.sizeClass,
            resolveNodeTitle: { id in store.nodes.first { $0.id == id }?.title },
            // Stage 5.3 — direct-manip write (boolean/rating) vs sheet edit.
            onDirectSet: { payload in
                Task {
                    await store.setFieldValue(
                        itemID: tile.item.id, nodeID: nodeID,
                        value: payload, upperValue: tile.value.upperValue
                    )
                }
            },
            onRequestEdit: { editingItem = tile.item },
            // P2 arrange mode: DRAG the corner grabber to resize; tap the grabber to step
            // one size (a11y). The tile BODY long-press → reorder. Edit/remove suspend.
            isArranging: isArranging,
            canResize: tile.definition.kind.supportedSizeClasses.count > 1,
            onResizeDrag: { resizeDrag(tile, translation: $0) },
            onResizeEnd: { activeResize = nil },
            onGrabberTap: { cycleSize(tile) },
            typeScale: typeScale,
            labelStyle: labelStyle
        )
        .contextMenu {
            // Suspended in arrange mode — the tile owns the gesture there.
            if !isArranging {
                if tile.value.value != nil {
                    Button("Clear value", role: .destructive) {
                        Task { await store.clearFieldValue(itemID: tile.item.id, nodeID: nodeID) }
                    }
                }
                Button("Remove field", role: .destructive) {
                    Task { await store.removeField(itemID: tile.item.id, nodeID: nodeID) }
                }
            }
        }
        // The tile declares its grid footprint so the layout snaps it to whole cells.
        // MUST be OUTERMOST — the enclosing `AttributeCellGrid` reads it off the direct
        // subview, so a `.contextMenu` wrapper above it would hide the value.
        // A text attribute at `.large` is the GROWABLE BLOCK: full-width, flexible
        // (intrinsic) height so it grows vertically to hold all its prose.
        .attributeTileFootprint(
            w: tile.isGrowableText ? 4 : tile.sizeClass.widthUnits,
            h: tile.isGrowableText ? 1 : tile.sizeClass.heightUnits,
            flexible: tile.isGrowableText
        )
        // Report the tile's frame (in the grid space) for reorder drop-target hit-testing.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TileFramesKey.self,
                    value: [tile.item.id: proxy.frame(in: .named(Self.gridSpace))]
                )
            }
        )
        // Reorder lift: the dragged tile follows the finger + rises; a drop-target tile
        // shows a ring where the dragged tile will land.
        .overlay {
            if isArranging, dropTargetID == tile.item.id, draggingID != tile.item.id, draggingID != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppearancePalette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .scaleEffect(draggingID == tile.item.id ? 1.04 : 1)
        .shadow(color: .black.opacity(draggingID == tile.item.id ? 0.28 : 0),
                radius: draggingID == tile.item.id ? 10 : 0, y: draggingID == tile.item.id ? 5 : 0)
        .offset(draggingID == tile.item.id ? dragOffset : .zero)
        .zIndex(draggingID == tile.item.id ? 1 : 0)
        // Tile BODY long-press → lift → drag = reorder. HIGH priority so the post-long-press
        // drag beats the enclosing ScrollView's scroll. Disabled outside arrange
        // (`.subviews`). The grabber's own high-priority drag still wins its corner.
        .highPriorityGesture(reorderGesture(tile), including: isArranging ? .all : .subviews)
    }

    private func reorderGesture(_ tile: ResolvedTile) -> some Gesture {
        // 0.4s hold to arm reorder — firm enough that a quick corner grabber-grab can't
        // cross it, so a resize drag never also lifts the tile for reorder.
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(coordinateSpace: .named(Self.gridSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginReorder(tile.item.id)
                case .second(true, let drag?):
                    updateReorder(point: drag.location, translation: drag.translation)
                default:
                    break
                }
            }
            .onEnded { _ in endReorder() }
    }

    struct ResolvedTile {
        let item: NodeItem
        let value: FieldValue
        let definition: FieldDefinition
        let sizeClass: AttributeSizeClass
        /// A text attribute at `.large` — the full-width, vertically-growing prose block.
        var isGrowableText: Bool { definition.kind == .text && sizeClass == .large }
    }

    private var resolvedTiles: [ResolvedTile] {
        // Honor the in-flight arrange ORDER (a reorder drag); else the store's order.
        let ordered: [NodeItem]
        if let pendingOrder {
            let byID = Dictionary(fieldItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            ordered = pendingOrder.compactMap { byID[$0] }
                + fieldItems.filter { !pendingOrder.contains($0.id) }
        } else {
            ordered = fieldItems
        }
        return ordered.compactMap { item in
            guard let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) else { return nil }
            // ws-attributes-grid — size resolution (a display rule, no data write):
            // the node's explicit tile wins; else the kind's migration/creation
            // default (stacked pairs → 1×2, long text → full-row). Clamp defensively
            // to what the kind actually supports so a stale/foreign size can't render.
            // The in-flight arrange choice wins; else the node's stored size; else the
            // kind's migration/creation default. Clamp to what the kind supports.
            let resolved = pendingSizes[item.id] ?? item.attributeTile?.sizeClass ?? def.kind.defaultSizeClass
            let size = def.kind.supportedSizeClasses.contains(resolved) ? resolved : def.kind.defaultSizeClass
            return ResolvedTile(item: item, value: fv, definition: def, sizeClass: size)
        }
    }
}

/// ws-attributes-grid — a `.field` TILE: a discrete rounded shell (darker than the
/// detail ground so tiles read as separate objects at any arrangement — retires the
/// SERVES/VOLUME "down-or-across" ambiguity, which is why zebra striping stays
/// rejected) whose CONTENT is arranged by `sizeClass`:
///   · `.stacked` (1×2) — caption over value, the shipped stacked-pair treatment.
///   · `.compact` (1×1) — the same, tighter, for a single narrow cell.
///   · `.row`     (1×4) — caption LEADING, value TRAILING, one line.
///   · `.large`   (2×2) — stacked again, rendered LARGER.
/// Hierarchy is size + weight + spacing, never hue (T is colorblind).
struct FieldPairCell: View {

    let value: FieldValue
    let definition: FieldDefinition
    let sizeClass: AttributeSizeClass
    let resolveNodeTitle: (String) -> String?
    /// Stage 5.3 — direct-manipulation write (boolean toggles; rating taps). Sheet-
    /// kinds route through `onRequestEdit` instead.
    var onDirectSet: (FieldPayload) -> Void = { _ in }
    var onRequestEdit: () -> Void = {}
    /// P2 arrange mode — when on, DRAG the corner grabber to resize (Control Center
    /// model); a plain tap cycles one step. Inner controls are inert; the grabber shows
    /// if `canResize`.
    var isArranging: Bool = false
    var canResize: Bool = false
    var onResizeDrag: (CGSize) -> Void = { _ in }
    var onResizeEnd: () -> Void = {}
    /// Grabber TAP (a11y alternative to the drag) — steps one size. Body tap has NO role.
    var onGrabberTap: () -> Void = {}
    /// Multiplies the value + label point sizes (1 = current). Lets a gate sample smaller
    /// type for T to pick from; the chosen scale gets baked into the constants.
    var typeScale: CGFloat = 1
    /// Field-name label style. BAKED default = serif italic (T, 2026-08-25).
    var labelStyle: AttrLabelStyle = .serifItalic

    @Environment(\.colorScheme) private var colorScheme

    private var isTextKind: Bool { definition.kind == .text }
    /// A text attribute at `.large` — the full-width prose block that grows vertically.
    private var isGrowableText: Bool { isTextKind && sizeClass == .large }
    /// A non-text `.large` tile — the 2×2 HERO whose value renders large to fill it.
    private var isHero: Bool { sizeClass == .large && !isTextKind }
    private var isRatingStars: Bool {
        definition.kind == .rating && (definition.config.ratingStyle ?? .stars) == .stars
    }
    private var displayText: String? {
        FieldValueFormatter.display(value, definition: definition, resolveNodeTitle: resolveNodeTitle)
    }

    var body: some View {
        content
            // Label-over-value tiles CENTER their content (T, 2026-08-25); the growable
            // prose block stays left-aligned (prose reads left).
            .frame(maxWidth: .infinity, alignment: isGrowableText ? .leading : .center)
            .padding(.horizontal, 12)
            .padding(.vertical, sizeClass == .large ? 14 : 10)
            // maxHeight fills the grid's reserved cell height so a `.large` (2-row) tile
            // has no dead gap below its content. Content is CENTERED (equal top/bottom
            // padding + horizontally centered) — except the growable text block, which
            // top-aligns left with its label.
            .frame(minHeight: sizeClass == .large ? 84 : (sizeClass == .compact ? 44 : 52),
                   maxHeight: .infinity, alignment: isGrowableText ? .topLeading : .center)
            // In arrange mode only the tile-level tap (size cycle) is live — inner
            // controls (stars, links) must not intercept.
            .allowsHitTesting(!isArranging)
            .background(AttributeTileShell.fill(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isArranging ? AppearancePalette.ink.opacity(0.35)
                                              : AttributeTileShell.rim(colorScheme),
                                  lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if isArranging && canResize {
                    // The VISUAL grabber stays 26pt; the HIT target is a 44pt zone around
                    // it (Apple's minimum) so a fingertip reliably lands on it.
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear.frame(width: 44, height: 44)
                        ControlResizeGrabber().frame(width: 26, height: 26)
                    }
                    .contentShape(Rectangle())
                    // HIGH priority so a touch on the grabber always wins over the tile
                    // body's reorder long-press (grabber = resize, body = reorder).
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { onResizeDrag($0.translation) }
                            .onEnded { v in
                                // Negligible travel = a TAP → step one size (a11y path).
                                if abs(v.translation.width) + abs(v.translation.height) < 6 {
                                    onGrabberTap()
                                }
                                onResizeEnd()
                            }
                    )
                }
            }
            .contentShape(Rectangle())
            // Arrange mode: the tile BODY has NO tap (ruled). The tap gesture is fully
            // DISABLED there (`.subviews`) — leaving it attached, even as a no-op, starves
            // the parent's reorder long-press of the touch. Outside arrange, a tap edits.
            .gesture(TapGesture().onEnded { handleTap() },
                     including: isArranging ? .subviews : .all)
            #if DEBUG
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("attrTile-\(definition.id)")
            .overlay(alignment: .topLeading) {
                if UserDefaults.standard.bool(forKey: "ATTRWIDTH") {
                    GeometryReader { geo in
                        Text("\(Int(geo.size.width))")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(1)
                            .background(Color.black.opacity(0.7))
                            .allowsHitTesting(false)
                    }
                }
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if isGrowableText {
            // GROWABLE BLOCK: label over full prose that wraps and grows — no truncation.
            VStack(alignment: .leading, spacing: 6) {
                label(large: false)
                growableValue
            }
        } else {
            switch sizeClass {
            case .row:
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The caption holds its intrinsic width (it's short); the VALUE is what
                    // truncates when the row is narrow — never the label down to one glyph.
                    label(large: false)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    valueView(large: false)
                }
            case .large:
                // HERO — label small over a large value that dynamically fills the square.
                VStack(alignment: .center, spacing: 6) {
                    label(large: true)
                    if isRatingStars {
                        valueView(large: true)
                    } else {
                        heroValue
                    }
                }
            case .stacked, .compact:
                VStack(alignment: .center, spacing: 3) {
                    label(large: false)
                    valueView(large: false)
                }
            }
        }
    }

    /// The growable prose value — wraps to as many lines as the text needs and lets the
    /// tile grow vertically (`.fixedSize(vertical:)` = never truncate).
    private var growableValue: some View {
        Text(displayText ?? "\u{2014}")
            .font(.system(size: 18 * typeScale, weight: .regular))
            .foregroundStyle(AppearancePalette.ink.opacity(displayText == nil ? 0.3 : 0.92))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The HERO value — sizes DYNAMICALLY to the space it's given: a short value ("106")
    /// grows to fill; a longer one scales down. The base font is the box height (so it
    /// fills vertically) and `minimumScaleFactor` shrinks it to fit the width — so the
    /// value is as big as it can be in both dimensions, no dead space, no overflow.
    private var heroValue: some View {
        GeometryReader { geo in
            Text(displayText ?? "\u{2014}")
                .font(.system(size: max(geo.size.height, 1), weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(displayText == nil ? 0.3 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.08)
                // CENTER — the hero value centers with its label (was `.leading`, which
                // left the big number left-aligned while the label centered).
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func label(large: Bool) -> some View {
        let size = (large ? 12 : 9) * typeScale
        let font: Font
        switch labelStyle {
        case .regular:     font = .system(size: size, weight: .medium, design: .rounded)
        case .serifItalic: font = .system(size: size, weight: .medium, design: .serif).italic()
        case .sansItalic:  font = .system(size: size, weight: .medium, design: .default).italic()
        }
        return Text(definition.displayName.uppercased())
            .font(font)
            .tracking(0.7)
            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            // The caption scales with the value on a tight tile (so "COOK TIME" doesn't clip
            // to "COOK…" while the value has room to breathe).
            .minimumScaleFactor(0.75)
    }

    /// Tapping a value edits it: boolean toggles in place; the sheet-kinds open the
    /// editor. Star ratings are DIRECT MANIPULATION per-star (whole-cell tap = no-op).
    private func handleTap() {
        switch definition.kind {
        case .boolean:
            let current: Bool = { if case .boolean(let b)? = value.value { return b }; return false }()
            onDirectSet(.boolean(!current))
        case .number, .text, .url, .date, .location, .duration, .money, .measurement:
            onRequestEdit()
        case .rating:
            if (definition.config.ratingStyle ?? .stars) != .stars { onRequestEdit() }
        case .vocabulary, .nodeReference:
            onRequestEdit()
        }
    }

    @ViewBuilder
    private func valueView(large: Bool) -> some View {
        if definition.kind == .rating,
           (definition.config.ratingStyle ?? .stars) == .stars {
            let v: Int = { if case .rating(let n)? = value.value { return n }; return 0 }()
            stars(v, scale: definition.config.ratingScale ?? 5, large: large)
        } else if let text = FieldValueFormatter.display(
            value, definition: definition, resolveNodeTitle: resolveNodeTitle
        ) {
            HStack(spacing: 5) {
                Text(text)
                    // HERO (`large`) renders the value big to fill the 2×2 square.
                    .font(.system(size: (large ? 38 : 14) * typeScale, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(sizeClass == .large ? 2 : 1)
                    .multilineTextAlignment(.center)
                    // The value SCALES to fit a tight tile before it truncates — same one
                    // system at every width (full size when there's room; shrinks only when
                    // cramped, e.g. "French" on a 190pt card back). Tail-truncates only past
                    // the floor. This is what keeps a compact tile from feeling crowded.
                    .minimumScaleFactor(large ? 0.5 : 0.6)
                    .truncationMode(.tail)
                if definition.kind == .url {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                }
            }
        } else {
            Text("\u{2014}")   // em dash — present but unfilled
                .font(.system(size: (large ? 38 : 14) * typeScale, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    /// Stars degrade to fit — a full row never CLIPS at a narrow size. `ViewThatFits`
    /// tries the full row, then a smaller row, then a "★ N" summary (which itself can
    /// tail-truncate the number). This keeps a resized-tiny rating legible instead of a
    /// star clipped mid-stroke (the "truncation reads intentional at every size" rule).
    private func stars(_ v: Int, scale: Int, large: Bool) -> some View {
        let base: CGFloat = large ? 20 : 15
        return ViewThatFits(in: .horizontal) {
            starRow(v, scale: scale, size: base)
            starRow(v, scale: scale, size: base * 0.72)
            starSummary(v, size: base)
        }
    }

    private func starRow(_ v: Int, scale: Int, size: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<scale, id: \.self) { idx in
                Image(systemName: idx < v ? "star.fill" : "star")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(idx < v ? Color(hexString: "FACC15")
                                             : AppearancePalette.ink.opacity(0.25))
                    .contentShape(Rectangle())
                    // DIRECT MANIPULATION: tap star n → set n; tap the current top star → clear.
                    .onTapGesture { onDirectSet(.rating(idx + 1 == v ? 0 : idx + 1)) }
            }
        }
    }

    /// The tight fallback: one star + the value, so an over-tight rating tile still reads.
    private func starSummary(_ v: Int, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Color(hexString: "FACC15"))
            Text("\(v)")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .lineLimit(1)
        }
    }
}

// MARK: - Arrange-mode resize grabber

/// The iOS Control-Center-style corner resize grabber — a light curved bar that HUGS the
/// tile's rounded bottom-right corner with ROUNDED ends, matching how Control Center and
/// Home-Screen widgets show a draggable corner in edit mode. Drawn as a STROKED arc with
/// round line caps (a filled sector gives blunt radial ends); the stroke width IS the
/// bar thickness, centred on the corner radius so the outer edge sits on the tile corner.
private struct ControlResizeGrabber: View {
    /// Must match the tile's corner radius so the grabber traces it exactly.
    var cornerRadius: CGFloat = 12
    var thickness: CGFloat = 6.5
    var body: some View {
        CornerGrabberArc(cornerRadius: cornerRadius, thickness: thickness)
            .stroke(Color.white.opacity(0.95),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round))
            .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 0.5)
    }
}

/// The centre-line arc of the grabber, tracing the frame's bottom-right ROUNDED corner.
/// Centred `cornerRadius` in from the corner at the band's mid radius, so a stroke of
/// `thickness` puts the OUTER edge on the tile's corner. The sweep is inset a hair from
/// the exact tangents so the round caps land cleanly at the edges, not past them.
private struct CornerGrabberArc: Shape {
    var cornerRadius: CGFloat = 12
    var thickness: CGFloat = 6.5
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius)
        let midR = max(1, cornerRadius - thickness / 2)      // band centre-line
        let inset = Angle.degrees(Double((thickness / 2 / midR) * 180 / .pi))
        // 0° = right-edge tangent, 90° = bottom-edge tangent → the corner quarter.
        p.addArc(center: c, radius: midR,
                 startAngle: .degrees(0) + inset,
                 endAngle: .degrees(90) - inset,
                 clockwise: false)
        return p
    }
}

// MARK: - Tile shell tone (Q4 — TASTE, T rules on device)

/// The attribute tile shell — a rounded fill DARKER than the detail ground so tiles
/// read as discrete objects. Q4 is a TASTE call T rules on device; this exposes a
/// closed set of candidate hex pairs (both modes) selected by the `ATTRSHELL` debug
/// key (0 = default), so the P3 device pass can A/B them. No invented adaptive value
/// — explicit hex, both modes.
enum AttributeTileShell {
    /// (darkHex, lightHex) candidates. The tile reads as a DISCRETE object by moving the
    /// SAME direction the app's elevated surfaces move in each mode: in DARK it goes
    /// DARKER than the `#1A1A1A` ground (the section tint lightens; the tile darkens →
    /// strong separation); in LIGHT it LIFTS BRIGHTER than the `#F4EFE3` parchment (the
    /// app lifts by luminance — `bgElevated #FAF6EC`, near-white entry cards), NOT the
    /// earlier warm-tan (#EAE3D3) which darkened + over-warmed against the cool
    /// `ink@0.05` Attributes section and read "off." Q4 is a TASTE call T rules on device
    /// via the `ATTRSHELL` key.
    static let candidates: [(dark: String, light: String)] = [
        ("111111", "FBF7EE"),   // 0 — default: dark recedes, light lifts (card idiom)
        ("0D0D0D", "FEFCF6"),   // 1 — firmer: brighter lift, nearer white
        ("161616", "F1ECDF"),   // 2 — subtle: a quieter step from the section
    ]

    private static var index: Int {
        let n = UserDefaults.standard.integer(forKey: "ATTRSHELL")
        return (0..<candidates.count).contains(n) ? n : 0
    }

    static func fill(_ scheme: ColorScheme) -> Color {
        let c = candidates[index]
        return Color(hexString: scheme == .dark ? c.dark : c.light)
    }

    static func rim(_ scheme: ColorScheme) -> Color {
        // A hairline rim: a faint light in dark, a faint dark in light — reads as a
        // carved edge, not an outline.
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.06)
    }
}

// MARK: - The cell grid

/// A tile's grid footprint in cells — width units (1 / 2 / 4) and height rows (1, or 2
/// for `.large`). BOTH travel in ONE `LayoutValueKey`: chaining two separate
/// `.layoutValue` calls only surfaces the outermost key to the parent `Layout` (the
/// inner one is silently dropped), so width and height must ride a single value.
///
/// `flexible` marks a FULL-WIDTH tile whose height is its INTRINSIC content height
/// rather than a snapped cell height — the growable text block (a text attribute at
/// `.large`): it spans every column and grows vertically to hold all its text, no
/// truncation. Because it owns the whole row band, it never shares a row with another
/// tile, so a variable height doesn't disturb the uniform-cell packing around it.
struct AttributeTileFootprint: Equatable {
    var w: Int
    var h: Int
    var flexible: Bool = false
}

/// Defaults to a 2×1 (`.stacked`) footprint for any subview that doesn't declare one.
private struct AttributeTileFootprintKey: LayoutValueKey {
    static let defaultValue = AttributeTileFootprint(w: 2, h: 1)
}

/// Collects each tile's frame (in the grid coordinate space) so a reorder drag can
/// hit-test which tile the finger is over.
private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

extension View {
    /// Declares a tile's grid footprint to the enclosing `AttributeCellGrid`.
    func attributeTileFootprint(w: Int, h: Int, flexible: Bool = false) -> some View {
        layoutValue(key: AttributeTileFootprintKey.self,
                    value: AttributeTileFootprint(w: w, h: h, flexible: flexible))
    }
}

/// ws-attributes-grid — the Control Center cell grid. Evolves `StackedPairsFlow`'s
/// width-derived columns (kept — "extend, don't replace"): the unit-column count
/// comes from AVAILABLE WIDTH, clamped to a **2-up floor** and a **4-unit ceiling**
/// (T: "stay 2-UP at ~190pt, never a single starved column"; "the grid is 4 units
/// wide"). Each tile snaps to `min(widthUnits, columns)` whole cells; tiles pack
/// left-to-right, wrapping when the next tile won't fit the remaining columns. A
/// `.large` tile is simply taller (its content renders larger); rows top-align.
struct AttributeCellGrid: Layout {
    var minUnitWidth: CGFloat
    var unitSpacing: CGFloat
    var rowSpacing: CGFloat
    /// DEBUG-only A/B for the geometry taste call: `true` forces a 4-unit grid (2-unit
    /// stacked pairs stay 2-up but truncate at the ~190 card-back); default is the
    /// adaptive [2,4] model (readable, opens to 4-up as width grows).
    var fixedFourUp: Bool = false

    /// Column count = as many `minUnitWidth` base units as fit, clamped to a **2-up
    /// floor** and the **4-unit ceiling** (T: "the grid is 4 units wide"; "stay 2-UP
    /// at ~190pt, never a single starved column"). The floor is what keeps a 2-unit
    /// stacked pair READABLE rather than a truncated sliver: at ~190 the grid is 2
    /// units (a stacked pair takes the full width, still legible) and compact 1-unit
    /// tiles pack 2-up; at detail widths it opens to 4 units so stacked pairs sit
    /// 2-up. `minUnitWidth` is the readable-half floor (a stacked pair = 2 units).
    private func columnMetrics(for width: CGFloat) -> (columns: Int, unitWidth: CGFloat) {
        guard width > 0 else { return (2, minUnitWidth) }
        let columns: Int
        if fixedFourUp {
            columns = width < 150 ? 2 : 4
        } else {
            let raw = Int((width + unitSpacing) / (minUnitWidth + unitSpacing))
            columns = min(4, max(2, raw))
        }
        let unitWidth = (width - CGFloat(columns - 1) * unitSpacing) / CGFloat(columns)
        return (columns, unitWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minUnitWidth * 2 + unitSpacing)
        let frames = frames(for: subviews, width: width)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(for: subviews, width: bounds.width)
        for (i, f) in frames.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                proposal: ProposedViewSize(width: f.width, height: f.height)
            )
        }
    }

    /// Frames in a local (0,0) space, packed as a true 2D cell grid (the Control Center
    /// model). Each tile occupies `min(widthUnits, columns) × heightUnits` cells; tiles
    /// are placed greedily into the first free block scanning row-major, so a 1-tall
    /// tile BACKFILLS the cell beside a `.large` 2×2 rather than leaving a gap. Rows are
    /// a UNIFORM `unitHeight` (attributes are scannable, not prose — see decisions.md):
    /// the tallest 1-tall tile sets it, and a `.large` reserves `2·unitHeight + spacing`.
    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        let (columns, unitWidth) = columnMetrics(for: width)
        guard columns > 0 else { return [] }

        func tileWidth(_ w: Int) -> CGFloat {
            CGFloat(w) * unitWidth + CGFloat(w - 1) * unitSpacing
        }

        // Footprint per tile. A FLEXIBLE tile spans every column and takes its intrinsic
        // (measured) height; every other tile snaps to whole cells.
        struct Spec { let w: Int; let h: Int; let measured: CGFloat; let flexible: Bool }
        let specs: [Spec] = subviews.map { sv in
            let fp = sv[AttributeTileFootprintKey.self]
            let w = fp.flexible ? columns : min(max(1, fp.w), columns)
            let h = max(1, fp.h)
            let measured = sv.sizeThatFits(ProposedViewSize(width: tileWidth(w), height: nil)).height
            return Spec(w: w, h: h, measured: measured, flexible: fp.flexible)
        }
        // Uniform cell-row height from the tallest NON-flex single-row tile (a 2-tall tile
        // spans two; a flex tile owns its own variable-height band, excluded here).
        let fixedSingles = specs.filter { $0.h == 1 && !$0.flexible }.map(\.measured)
        let unitHeight = max(fixedSingles.max()
                             ?? specs.filter { !$0.flexible }.map(\.measured).max()
                             ?? 44, 1)

        // Greedy 2D packing over an unbounded (row × columns) cell field. A flex tile is
        // full-width, so it occupies one whole cell-row that nothing else shares; its band
        // is then stretched to its intrinsic height via `rowStride`.
        var occupied = Set<Int>()               // key = row * columns + col
        func fits(row: Int, col: Int, w: Int, h: Int) -> Bool {
            guard col + w <= columns else { return false }
            for r in row..<(row + h) {
                for c in col..<(col + w) where occupied.contains(r * columns + c) { return false }
            }
            return true
        }
        let rowLimit = subviews.count * 2 + 2   // safety ceiling; every tile fits well within
        var placements: [(row: Int, col: Int, spec: Spec)] = []
        var maxRow = 0
        for spec in specs {
            var placedRow = 0, placedCol = 0
            scan: for row in 0...rowLimit {
                for col in 0..<columns where fits(row: row, col: col, w: spec.w, h: spec.h) {
                    placedRow = row; placedCol = col; break scan
                }
            }
            for r in placedRow..<(placedRow + spec.h) {
                for c in placedCol..<(placedCol + spec.w) { occupied.insert(r * columns + c) }
            }
            placements.append((placedRow, placedCol, spec))
            maxRow = max(maxRow, placedRow + spec.h)
        }

        // Row Y-positions. Each cell-row advances by `unitHeight + rowSpacing`, EXCEPT a
        // row carrying a flex tile, which advances by that tile's intrinsic height instead.
        var rowStride = [CGFloat](repeating: unitHeight + rowSpacing, count: maxRow + 1)
        for p in placements where p.spec.flexible {
            rowStride[p.row] = p.spec.measured + rowSpacing
        }
        var rowTop = [CGFloat](repeating: 0, count: maxRow + 2)
        for r in 0..<(maxRow + 1) { rowTop[r + 1] = rowTop[r] + rowStride[r] }

        return placements.map { p in
            let x = CGFloat(p.col) * (unitWidth + unitSpacing)
            let y = rowTop[p.row]
            let h: CGFloat = p.spec.flexible
                ? p.spec.measured
                : rowTop[p.row + p.spec.h] - rowTop[p.row] - rowSpacing
            return CGRect(x: x, y: y, width: tileWidth(p.spec.w), height: h)
        }
    }
}
