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
    #if DEBUG
    /// Sim-gate hook — force a MID-RESIZE visual state on appear (the vertical-resize feedback
    /// loop lives in the mid-gesture frame, which a static screenshot can't otherwise reach):
    /// one tile's live rubber-band frame + the resolved outline. Proves the OTHER rows don't
    /// stretch while a tile is being sized up vertically.
    var debugForcedResize: (tileID: String, size: CGSize, span: AttributeGridSpan)? = nil
    #endif
    /// ws-attributes-grid P2/P3 — arrange mode (owned by the section header's glyph).
    /// While on, the grabber DRAG resizes a tile (growing only into free cells) and a
    /// body long-press LIFTS it to drag to another grid cell (the iOS-18 Home Screen
    /// model — placement, not array order). Sizes + positions accumulate locally and
    /// commit as ONE write when arrange mode ends (`updatedAt` untouched — arranging
    /// isn't editing).
    var isArranging: Bool = false
    /// Multiplies value + label point sizes (1 = current). For gate type-size sampling.
    var typeScale: CGFloat = 1
    /// Field-name label style. BAKED default = serif italic (T, 2026-08-25 — echoes the
    /// app's serif titles). A gate overrides it to sample alternatives.
    var labelStyle: AttrLabelStyle = .serifItalic

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem?
    /// Pending per-tile size overrides during an arrange session (itemID → size).
    @State private var pendingSizes: [String: AttributeGridSpan] = [:]
    /// Pending per-tile POSITION overrides during an arrange session (itemID → cell). A
    /// drop (and any tiles it displaces) writes here; empty = every tile at its resolved
    /// (stored-or-derived) home. This is what makes placement survive a resize with NO
    /// neighbour reflow.
    @State private var pendingPositions: [String: AttributeGridPosition] = [:]
    /// The in-flight corner-drag resize (ws-free-footprint — RUBBER-BAND). The finger
    /// describes a rectangle from the tile's FIXED top-left cell. Displacement is DEFERRED to
    /// release: during the gesture only the tile's own frame follows the finger (in points,
    /// `liveResizeFrame`) and the dashed outline shows the RESOLVED footprint (`resizeOutline`).
    /// On release the resolved span is committed off the PRISTINE `base` (so nothing is moved
    /// until the shape is settled). `span` is the last resolved footprint (for the haptic tick).
    private struct ResizeSession {
        let id: String
        let originRow: Int          // the tile's top-left cell, fixed for the gesture
        let originCol: Int
        let base: [String: Placed]  // layout at gesture start — release recomputes off this
        let originSpan: AttributeGridSpan // the tile's span at gesture start
        var span: AttributeGridSpan // last resolved footprint (tick + release commit)
        var everChanged: Bool = false // did the resolved span EVER differ from origin (even if
                                      // it returned) — so a drag-out-and-back isn't read as a tap
        // STABLE geometry captured at gesture start — the quantizer's denominators + the tile's
        // top-left in points. Captured (not re-read each frame) because the live rubber-band
        // frame pollutes the measured unitHeight; a quantizer whose denominator moves with the
        // finger is not a quantizer (T 2026-08-26, the vertical-resize feedback loop).
        let originX: CGFloat
        let originY: CGFloat
        let unitW: CGFloat
        let unitH: CGFloat
    }
    @State private var activeResize: ResizeSession?
    /// The resolved (cell-snapped) footprint the resize will land on — drives the dashed
    /// landing outline (same treatment as the reorder drop target), live for the gesture.
    @State private var resizeOutline: Placed?
    /// RUBBER-BAND — the dragged tile's live point size (continuous, NOT cell-snapped) while
    /// resizing. Passed to `AttributeCellGrid` so the tile's frame follows the finger; cleared
    /// on release, when the tile animates from these points to the resolved cell rectangle.
    @State private var liveResizeFrame: (id: String, size: CGSize)?
    /// Picker-detent haptic (the "tick" as a resize crosses each size threshold / a drop lands).
    private let resizeHaptic = UISelectionFeedbackGenerator()
    /// The tile currently lifted for a reorder drag + its live finger offset.
    @State private var draggingID: String?
    @State private var dragOffset: CGSize = .zero
    /// BUG A — the dragged tile's HOME top-left (grid space) captured at lift, so the drop
    /// target is computed from the TILE's position (`home + translation`), not the finger:
    /// the target no longer shifts by however far from the tile's corner you grabbed it.
    @State private var dragHomeOrigin: CGPoint?
    /// BUG C — mirrors the reorder gesture's liveness via `@GestureState` (auto-resets to
    /// false the instant the gesture ends OR cancels, guaranteed by SwiftUI). A lift with
    /// no drag never delivers a `DragGesture` value, so the sequenced `.onEnded` can be
    /// swallowed and the tile stays lifted — watching this reset is the belt-and-suspenders
    /// that always runs the cleanup.
    @GestureState private var isReorderPressing = false
    /// The grid CELL the dragged tile's leading corner would land on (drives the overlay
    /// landing-zone highlight, so a drop reads as landing ON a cell).
    @State private var dropTargetCell: AttributeGridPosition?
    /// Each tile's frame in the "attrGrid" space — used to reconstruct the row band
    /// heights for point→cell mapping + the arrange grid overlay.
    @State private var tileFrames: [String: CGRect] = [:]
    /// The grid's own width (from a background probe) — for point→cell mapping + overlay.
    @State private var gridWidth: CGFloat = 0

    static let gridSpace = "attrGrid"   // internal: FieldPairCell's resize gesture reports here
    /// The canonical grid width. Stored positions live in this 4-column space; a narrower
    /// container (the not-yet-built card back) falls back to a re-pack (see `AttributeCellGrid`).
    static let columns = 4
    /// ws-free-footprint — the height ceiling (rows). Width ceiling is `columns`; T ruled
    /// any 1–4 × 1–4. Rows still grow unbounded for LAYOUT, but a single tile caps here.
    static let maxRows = 4
    static let unitSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 12

    /// A tile's resolved footprint + cell in the 4-column grid.
    struct Placed: Equatable {
        var row: Int; var col: Int; var w: Int; var h: Int; var flexible: Bool
    }

    var body: some View {
        let placements = resolveLayout()
        // P4 — reserve the phantom "next page" row(s) in the LAYOUT while arranging so the
        // panel grows to hold them (kept off the background overlay, which can't size its
        // parent → the old bleed onto Ingredients). The count spans past the greater of the
        // content's max row and the live drag target (see `displayedRowCount`).
        let occupiedRows = placements.values.map { $0.row + $0.h }.max() ?? 0
        let reservedRows = max(0, displayedRowCount(placements) - occupiedRows)
        AttributeCellGrid(minUnitWidth: 80, unitSpacing: Self.unitSpacing,
                          rowSpacing: Self.rowSpacing, fixedFourUp: fixedFourUp,
                          reservedTrailingRows: reservedRows) {
            ForEach(resolvedTiles, id: \.item.id) { tile in
                cell(for: tile, placement: placements[tile.item.id])
            }
        }
        .coordinateSpace(name: Self.gridSpace)
        .background(   // width probe: point→cell mapping + overlay geometry need the true width
            GeometryReader { proxy in
                Color.clear.preference(key: GridWidthKey.self, value: proxy.size.width)
            }
        )
        .background(alignment: .topLeading) { arrangeGridOverlay }   // faint 4-col grid behind tiles
        .overlay(alignment: .topLeading) { dropTargetHighlight }     // reorder landing ring above tiles
        .overlay(alignment: .topLeading) { resizeCandidateHighlight } // 2-D resize candidate outline
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }
        // BUG C — the reorder gesture ended/cancelled: guarantee the lift is cleared even
        // when `.onEnded` never fired (a long-press with no drag). `endReorder` is a no-op
        // when nothing is lifted, and idempotent against `.onEnded` for a real drop.
        .onChange(of: isReorderPressing) { _, pressing in
            if !pressing && draggingID != nil { endReorder() }
        }
        .sheet(item: $editingItem) { item in
            if let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) {
                FieldValueEditorSheet(nodeID: nodeID, item: item, definition: def)
            }
        }
        .onChange(of: isArranging) { _, arranging in
            if arranging {
                pendingSizes = [:]; pendingPositions = [:]   // fresh session
            } else {
                commitArrangement()                          // one write on exit (sizes + positions)
            }
        }
    }

    /// The tile currently rendering at a LIVE rubber-band size — the real in-flight resize, or
    /// (DEBUG sim-gate) the forced mid-drag fixture. Both the per-tile `liveSize` and the
    /// `unitHeight` exclusion read this, so a forced fixture behaves exactly like a live drag.
    private func liveSize(for id: String) -> CGSize? {
        #if DEBUG
        if let d = debugForcedResize, d.tileID == id { return d.size }
        #endif
        return liveResizeFrame?.id == id ? liveResizeFrame?.size : nil
    }
    private var liveResizeID: String? {
        #if DEBUG
        if let d = debugForcedResize { return d.tileID }
        #endif
        return liveResizeFrame?.id
    }

    // MARK: - Grid occupancy helpers (pure, over the 4-column cell field)

    private func markOccupied(_ occ: inout Set<Int>, _ p: Placed) {
        for r in p.row..<(p.row + p.h) {
            for c in p.col..<(p.col + p.w) { occ.insert(r * Self.columns + c) }
        }
    }
    private func fits(_ occ: Set<Int>, _ p: Placed) -> Bool {
        guard p.row >= 0, p.col >= 0, p.col + p.w <= Self.columns else { return false }
        for r in p.row..<(p.row + p.h) {
            for c in p.col..<(p.col + p.w) where occ.contains(r * Self.columns + c) { return false }
        }
        return true
    }
    private func firstFree(_ occ: Set<Int>, w: Int, h: Int, rowLimit: Int) -> (row: Int, col: Int) {
        for row in 0...rowLimit {
            for col in 0...(Self.columns - w)
            where fits(occ, Placed(row: row, col: col, w: w, h: h, flexible: false)) {
                return (row, col)
            }
        }
        return (rowLimit + 1, 0)
    }
    private func overlaps(_ a: Placed, _ b: Placed) -> Bool {
        a.col < b.col + b.w && b.col < a.col + a.w && a.row < b.row + b.h && b.row < a.row + a.h
    }
    private func footprint(_ tile: ResolvedTile) -> (w: Int, h: Int, flexible: Bool) {
        // ws-free-footprint: the tile's explicit span, clamped to the grid. Growable text is
        // retired — a text tile occupies its stored height like everything else and fills it
        // with a height-aware line count (see FieldPairCell); `flexible` is no longer produced.
        (min(max(1, tile.span.w), Self.columns), max(1, tile.span.h), false)
    }

    // MARK: - Displayed row count (P4 — the Home Screen "next page" row)

    /// The drag target's footprint BOTTOM (a row count), or 0 when not dragging. Folding
    /// this into the displayed-row floor is what lets a tile dragged INTO the last row open
    /// a fresh empty row BENEATH it while the finger is still down (Home Screen next page) —
    /// without it, the drag would dead-end at the wall because the row doesn't exist yet.
    private func dragFloorRow(_ layout: [String: Placed]) -> Int {
        guard isArranging, let id = draggingID, let cell = dropTargetCell,
              let placed = layout[id] else { return 0 }
        return cell.row + placed.h
    }
    /// While a resize is in flight, extend the displayed rows to the resolved outline's bottom
    /// (like `dragFloorRow` for a reorder) — so a tall vertical resize's dashed outline + recess
    /// reach the resolved height instead of clamping to the pre-resize row count.
    private func resizeFloorRow() -> Int {
        guard isArranging, let o = effectiveResizeOutline else { return 0 }
        return o.row + o.h
    }

    /// How many grid rows to DISPLAY: the content rows, plus — while arranging — ONE empty
    /// trailing row past the greater of the content max row and the live drag target. Both
    /// `AttributeCellGrid`'s reserved height and `gridMetrics()` derive off this single
    /// floor so the panel bottom and the overlay's last row agree.
    private func displayedRowCount(_ layout: [String: Placed]) -> Int {
        let occupied = layout.values.map { $0.row + $0.h }.max() ?? 0
        guard isArranging else { return occupied }
        return max(occupied, dragFloorRow(layout), resizeFloorRow()) + 1
    }

    // MARK: - Layout resolution (stored positions + lazy homing)

    /// The authoritative per-tile placement: stored/pending positions honoured literally,
    /// position-less tiles HOMED into the first free row-major cell. When EVERY tile is
    /// homeless (a never-arranged node) this reproduces the pre-P3 greedy pack exactly, so
    /// the render is byte-identical — that IS the lazy migration ("nothing moves on
    /// upgrade"). A newly-added field on an arranged node drops into the first free cell.
    private func resolveLayout() -> [String: Placed] {
        let tiles = resolvedTiles
        var result: [String: Placed] = [:]
        var occ = Set<Int>()
        var homeless: [ResolvedTile] = []
        // Pass 1 — tiles with a resolved position (pending drag override, else stored).
        for t in tiles {
            let fp = footprint(t)
            guard let pos = pendingPositions[t.item.id] ?? t.item.attributeTile?.position else {
                homeless.append(t); continue
            }
            let col = min(max(0, pos.col), Self.columns - fp.w)
            let placed = Placed(row: max(0, pos.row), col: max(0, col),
                                w: fp.w, h: fp.h, flexible: fp.flexible)
            if fits(occ, placed) {
                result[t.item.id] = placed; markOccupied(&occ, placed)
            } else {
                homeless.append(t)   // stale/colliding stored position → re-home defensively
            }
        }
        // Pass 2 — home the homeless in ARRAY ORDER (first-free row-major).
        let rowLimit = tiles.count * 2 + 2
        for t in homeless {
            let fp = footprint(t)
            let free = firstFree(occ, w: fp.w, h: fp.h, rowLimit: rowLimit)
            let placed = Placed(row: free.row, col: free.col, w: fp.w, h: fp.h, flexible: fp.flexible)
            result[t.item.id] = placed; markOccupied(&occ, placed)
        }
        return result
    }

    // MARK: - Resize (ws-free-footprint — RUBBER-BAND, identity quantizer, any w×h)

    /// The a11y tap-cycle ladder — a small sensible set of footprints (the old four) the
    /// grabber TAP steps through, since a tap can't express a free 2-D shape. The DRAG is
    /// unconstrained.
    private static let cycleLadder: [AttributeGridSpan] = [
        .init(w: 1, h: 1), .init(w: 2, h: 1), .init(w: 2, h: 2), .init(w: 4, h: 1)
    ]

    /// Grabber TAP (a11y): step to the next ladder footprint, DISPLACING like the drag.
    private func cycleSize(_ tile: ResolvedTile) {
        #if DEBUG
        ArrangeGestureProbe.shared.cycles += 1
        #endif
        let layout = resolveLayout()
        guard let placed = layout[tile.item.id] else { return }
        let cur = AttributeGridSpan(w: placed.w, h: placed.h)
        let ladder = Self.cycleLadder
        let next = ladder[((ladder.firstIndex(of: cur) ?? -1) + 1) % ladder.count]
        applyResize(tile.item.id, span: next, base: layout,
                    originRow: placed.row, originCol: placed.col)
    }

    /// Commit a resize to `span` at the tile's fixed origin: displace collisions off `base`
    /// (the same `placeDisplacing` path as drop), then PIN every position so `resolveLayout`
    /// honours the new footprint. Shared by the drag RELEASE and the a11y tap-cycle. Only the
    /// grid EDGE binds (a wider/taller footprint shifts left / floors at row 0).
    private func applyResize(_ id: String, span: AttributeGridSpan, base: [String: Placed],
                             originRow: Int, originCol: Int) {
        let w = min(max(1, span.w), Self.columns)
        let h = min(max(1, span.h), Self.maxRows)
        var layout = base
        let moved = Placed(row: max(0, originRow), col: min(max(0, originCol), Self.columns - w),
                           w: w, h: h, flexible: false)
        placeDisplacing(id, moved, in: &layout)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            pendingSizes[id] = AttributeGridSpan(w: w, h: h)
            for (tid, p) in layout { pendingPositions[tid] = AttributeGridPosition(row: p.row, col: p.col) }
        }
        resizeHaptic.selectionChanged()
    }

    /// Corner DRAG resize — ws-free-footprint RUBBER-BAND (T ruled it from Control Center).
    /// During the gesture the tile's FRAME follows the finger continuously in POINTS
    /// (`liveResizeFrame`, not cell-snapped) and the dashed outline shows the RESOLVED
    /// footprint. The quantizer is now IDENTITY — the finger's cell extents map straight to
    /// (w,h), clamp w 1…columns / h 1…maxRows; no nearest-of-four, no tie-break, no
    /// class-hysteresis (there is no class boundary to flicker across — only cell boundaries,
    /// and the rubber-band frame is continuous, so a resting finger doesn't jump). Displacement
    /// is DEFERRED to release (`resizeEnd`) off the pristine base, so nothing moves until the
    /// shape is settled.
    private func resizeDrag(_ tile: ResolvedTile, finger: CGPoint) {
        #if DEBUG
        ArrangeGestureProbe.shared.drags += 1
        #endif
        // The grabber owns this touch — cancel any reorder lift that raced in.
        if draggingID != nil { draggingID = nil; dropTargetCell = nil }
        let currentLayout = resolveLayout()
        guard let placed = currentLayout[tile.item.id] else { return }
        let spacing = Self.unitSpacing

        var session: ResizeSession
        if let a = activeResize, a.id == tile.item.id {
            session = a
        } else {
            // New gesture — CAPTURE the stable geometry NOW, before the tile goes live. Every
            // later frame reads these, never a fresh gridMetrics (whose unitHeight the live
            // frame would pollute — the feedback loop).
            guard let m = gridMetrics() else { return }
            session = ResizeSession(
                id: tile.item.id, originRow: placed.row, originCol: placed.col,
                base: currentLayout,
                originSpan: AttributeGridSpan(w: placed.w, h: placed.h),
                span: AttributeGridSpan(w: placed.w, h: placed.h),
                originX: CGFloat(placed.col) * (m.unitWidth + spacing),
                originY: m.rowTops[min(placed.row, max(0, m.rowTops.count - 1))],
                unitW: m.unitWidth, unitH: m.unitHeight)
            resizeHaptic.prepare()
        }
        defer { activeResize = session }

        // RUBBER-BAND — the tile's live frame follows the finger in points (floor one cell;
        // clamped so a wider/taller footprint stays on the grid from the fixed origin). All
        // arithmetic uses the CAPTURED geometry, so the denominator can't move under the finger.
        let maxW = CGFloat(Self.columns - session.originCol) * (session.unitW + spacing) - spacing
        let maxH = CGFloat(Self.maxRows) * (session.unitH + spacing) - spacing
        let liveW = min(max(session.unitW, finger.x - session.originX), maxW)
        let liveH = min(max(session.unitH, finger.y - session.originY), maxH)
        liveResizeFrame = (tile.item.id, CGSize(width: liveW, height: liveH))

        // IDENTITY quantizer — cell extents map straight to (w,h). (calcXY margin term.)
        let w = min(max(1, Int(((finger.x - session.originX + spacing) / (session.unitW + spacing)).rounded())), Self.columns)
        let h = min(max(1, Int(((finger.y - session.originY + spacing) / (session.unitH + spacing)).rounded())), Self.maxRows)
        let col = min(max(0, session.originCol), Self.columns - w)
        resizeOutline = Placed(row: max(0, session.originRow), col: col, w: w, h: h, flexible: false)

        if session.span.w != w || session.span.h != h {   // crossed a cell boundary → tick
            resizeHaptic.selectionChanged(); resizeHaptic.prepare()
            session.span = AttributeGridSpan(w: w, h: h)
        }
        // Mark the moment the resolution first differs from origin (stays marked even if it
        // later returns) — so a drag-out-and-back is a no-op, never a tap.
        if w != session.originSpan.w || h != session.originSpan.h { session.everChanged = true }
    }

    /// Release — CLASSIFY BY OUTCOME, not by travel distance (T 2026-08-26 defect fix). The
    /// identity quantizer resolves a new (w,h) as soon as the finger crosses a cell midpoint,
    /// which from a corner grabber can be < the old 6pt SUMMED-travel tap threshold — so real
    /// resizes were being thrown away as taps. Primary test: did the resolved span change from
    /// the span at gesture start?
    ///   · final span ≠ origin              → a RESIZE — commit off the pristine base (displace + snap).
    ///   · never resolved away + still finger → a TAP  — cycle the a11y ladder (the tap's job).
    ///   · resolved away then back to origin  → a drag returned home — commit nothing, no cycle.
    /// The span change is the PRIMARY test; `everChanged`/`stillFinger` only distinguish a real
    /// tap from a drag that happened to end near where it started (its NET travel is small too).
    /// Per-axis, not summed — the arithmetic we retired from the resize model.
    private func resizeEnd(stillFinger: Bool) {
        guard let s = activeResize else { return }
        defer { liveResizeFrame = nil; resizeOutline = nil; activeResize = nil }
        if s.span != s.originSpan {
            applyResize(s.id, span: s.span, base: s.base, originRow: s.originRow, originCol: s.originCol)
        } else if !s.everChanged, stillFinger,
                  let tile = resolvedTiles.first(where: { $0.item.id == s.id }) {
            cycleSize(tile)   // a genuine tap (never dragged away) → step the ladder
        }
        // else: dragged out and back to the same shape — nothing to commit, don't cycle.
    }

    /// Persist the arrange session's SIZES + POSITIONS as one write. Passes the FULL
    /// resolved layout for every field tile (not just the ones touched) so the node's
    /// first arrange FREEZES its whole current layout into stored positions — the lazy
    /// migration. No-op tiles are skipped in the store; `updatedAt` untouched.
    private func commitArrangement() {
        let layout = resolveLayout()
        var payload: [String: (span: AttributeGridSpan, position: AttributeGridPosition)] = [:]
        for t in resolvedTiles {
            guard let p = layout[t.item.id] else { continue }
            payload[t.item.id] = (AttributeGridSpan(w: p.w, h: p.h),
                                  AttributeGridPosition(row: p.row, col: p.col))
        }
        pendingSizes = [:]; pendingPositions = [:]
        draggingID = nil; dropTargetCell = nil; dragOffset = .zero; dragHomeOrigin = nil
        activeResize = nil; resizeOutline = nil
        Task { await store.commitAttributeLayout(payload, nodeID: nodeID) }
    }

    // MARK: - Reorder (tile-body long-press → lift → drag → drop onto a CELL)

    /// Long-press lifted a tile for a move.
    private func beginReorder(_ id: String) {
        // A grabber resize is in progress → the corner owns this touch; don't also lift.
        guard activeResize == nil else { return }
        draggingID = id
        dragOffset = .zero
        dragHomeOrigin = tileFrames[id]?.origin   // BUG A — the tile's top-left before it moves
        dropTargetCell = resolveLayout()[id].map { AttributeGridPosition(row: $0.row, col: $0.col) }
        #if DEBUG
        print("[ARR] LIFT id=\(id)")
        ArrangeGestureProbe.shared.lifts += 1
        #endif
    }

    /// While dragging, the drop target is the grid CELL the dragged TILE covers — computed
    /// from the tile's visual top-left (`home + translation`), NOT the finger point (BUG A:
    /// the finger sits wherever you grabbed the tile, so the raw point was offset by the
    /// grab point). Falls back to the finger only if the home origin wasn't captured.
    private func updateReorder(point: CGPoint, translation: CGSize) {
        dragOffset = translation   // instant — the tile tracks the finger 1:1, never animated
        guard let id = draggingID, let placed = resolveLayout()[id] else { return }
        let topLeft = dragHomeOrigin.map {
            CGPoint(x: $0.x + translation.width, y: $0.y + translation.height)
        } ?? point
        let target = cell(at: topLeft, footprintWidth: placed.w)
        // Animate ONLY when the target cell changes: the landing highlight glides, and if the
        // target reaches the last row the panel opens a fresh row beneath the finger (the
        // Home Screen "next page" while still down) — a smooth grow, not a pop.
        if target != dropTargetCell {
            withAnimation(.snappy(duration: 0.2)) { dropTargetCell = target }
        }
        #if DEBUG
        ArrangeGestureProbe.shared.moves += 1
        #endif
    }

    /// Drop: place the dragged tile at the target cell; any tiles it lands on DISPLACE
    /// (the Home Screen model, T 2026-08-25) — via the same `placeDisplacing` path resize
    /// uses, here preferring the dragged tile's vacated footprint (the classic same-size
    /// swap). Tiles the drop doesn't touch stay exactly put (holes preserved).
    private func endReorder() {
        defer { draggingID = nil; dropTargetCell = nil; dragOffset = .zero; dragHomeOrigin = nil }
        guard let dragged = draggingID, let target = dropTargetCell else { return }
        applyDrop(dragged: dragged, to: target)
    }

    /// The ONE collision path shared by drop and resize (T 2026-08-26 — RESIZE DISPLACES).
    /// Place `moved` at its footprint, evicting every tile it overlaps. Each evicted tile
    /// goes to `preferred` (if given AND it fits) else the first free cell in reading order,
    /// opening a new row if nothing fits. No cascade — an evicted tile never pushes a third;
    /// holes it can't fill are left intact. Mutates `layout`; returns the evicted ids.
    @discardableResult
    private func placeDisplacing(_ movedID: String, _ moved: Placed,
                                 in layout: inout [String: Placed],
                                 preferred: ((Placed) -> Placed)? = nil) -> [String] {
        let displaced = layout
            .filter { $0.key != movedID && overlaps($0.value, moved) }
            .sorted { ($0.value.row * Self.columns + $0.value.col)
                    < ($1.value.row * Self.columns + $1.value.col) }
            .map(\.key)
        let displacedSet = Set(displaced)
        var occ = Set<Int>()
        for (id, p) in layout where id != movedID && !displacedSet.contains(id) { markOccupied(&occ, p) }
        layout[movedID] = moved; markOccupied(&occ, moved)

        let rowLimit = layout.count * 2 + 2
        for id in displaced {
            guard let p = layout[id] else { continue }
            var dest = preferred?(p)
            if dest == nil || !fits(occ, dest!) {   // no preference, or it's taken → first free
                let free = firstFree(occ, w: p.w, h: p.h, rowLimit: rowLimit)
                dest = Placed(row: free.row, col: free.col, w: p.w, h: p.h, flexible: p.flexible)
            }
            layout[id] = dest!; markOccupied(&occ, dest!)
        }
        return displaced
    }

    private func applyDrop(dragged: String, to target: AttributeGridPosition) {
        var layout = resolveLayout()
        guard let old = layout[dragged] else { return }
        let col = min(max(0, target.col), Self.columns - old.w)
        let moved = Placed(row: max(0, target.row), col: max(0, col),
                           w: old.w, h: old.h, flexible: old.flexible)
        guard moved.row != old.row || moved.col != old.col else { return }   // no-op drop

        let displaced = placeDisplacing(dragged, moved, in: &layout, preferred: { p in
            // Prefer the dragged tile's vacated footprint (the classic same-size swap).
            Placed(row: old.row, col: min(max(0, old.col), Self.columns - p.w),
                   w: p.w, h: p.h, flexible: p.flexible)
        })

        withAnimation(.snappy(duration: 0.25)) {
            for (id, p) in layout { pendingPositions[id] = AttributeGridPosition(row: p.row, col: p.col) }
        }
        resizeHaptic.selectionChanged()
        #if DEBUG
        print("[ARR] DROP \(dragged) -> r\(moved.row)c\(moved.col) (displaced \(displaced.count))")
        ArrangeGestureProbe.shared.reorders += 1
        #endif
    }

    // MARK: - Grid geometry reconstruction (for point→cell + overlay)

    private struct GridMetrics {
        let unitWidth: CGFloat
        let unitHeight: CGFloat      // the uniform AttributeGridRowHeight.unitHeight (P4 source)
        let rowTops: [CGFloat]       // count = rowCount + 1
        let rowHeights: [CGFloat]    // count = rowCount
    }

    /// Reconstruct the cell geometry from the true grid width + the rendered tile frames.
    /// Non-flex rows are the uniform `unitHeight` (the SAME `AttributeGridRowHeight` rule the
    /// Layout uses); a growable-text row takes its measured height. The row count is the
    /// shared `displayedRowCount` — content rows plus the phantom "next page" row while
    /// arranging — so this overlay's last row matches the panel's reserved bottom exactly.
    private func gridMetrics() -> GridMetrics? {
        guard gridWidth > 0 else { return nil }
        let unitWidth = (gridWidth - CGFloat(Self.columns - 1) * Self.unitSpacing) / CGFloat(Self.columns)
        guard unitWidth > 0 else { return nil }
        let layout = resolveLayout()
        // EXCLUDE the tile mid-resize — its rendered frame is the LIVE rubber-band size, not
        // evidence of a row height. Including it inflates unitHeight (it's still h==1 in the
        // model but stretched in points), which stretches every overlay row AND poisons the
        // resize quantizer's denominator (T 2026-08-26, the vertical-resize feedback loop).
        let resizingID = liveResizeID
        let unitHeight = AttributeGridRowHeight.unitHeight(
            from: layout.compactMap { (id, p) in
                guard id != resizingID else { return nil }
                return tileFrames[id].map { ($0.height, p.h, p.flexible) }
            })
        let rowCount = displayedRowCount(layout)
        guard rowCount > 0 else {
            return GridMetrics(unitWidth: unitWidth, unitHeight: unitHeight, rowTops: [0], rowHeights: [])
        }
        var flexHeight: [Int: CGFloat] = [:]
        for (id, p) in layout where p.flexible { flexHeight[p.row] = tileFrames[id]?.height ?? unitHeight }
        var tops = [CGFloat](repeating: 0, count: rowCount + 1)
        var heights = [CGFloat](repeating: unitHeight, count: rowCount)
        for r in 0..<rowCount {
            let h = flexHeight[r] ?? unitHeight
            heights[r] = h
            tops[r + 1] = tops[r] + h + Self.rowSpacing
        }
        return GridMetrics(unitWidth: unitWidth, unitHeight: unitHeight, rowTops: tops, rowHeights: heights)
    }

    /// Map a point (in the grid space) to the grid cell its LEADING corner should snap to,
    /// clamped so a `w`-wide footprint fits on-grid.
    private func cell(at point: CGPoint, footprintWidth w: Int) -> AttributeGridPosition? {
        guard let m = gridMetrics() else { return nil }
        let stride = m.unitWidth + Self.unitSpacing
        var col = Int((point.x / stride).rounded())
        col = min(max(0, col), Self.columns - w)
        var row = m.rowHeights.count - 1
        for r in 0..<m.rowHeights.count where point.y < m.rowTops[r] + m.rowHeights[r] {
            row = r; break
        }
        return AttributeGridPosition(row: max(0, row), col: max(0, col))
    }

    private func cellRect(_ m: GridMetrics, row: Int, col: Int, w: Int = 1, h: Int = 1) -> CGRect {
        let x = CGFloat(col) * (m.unitWidth + Self.unitSpacing)
        let width = CGFloat(w) * m.unitWidth + CGFloat(max(0, w - 1)) * Self.unitSpacing
        let y = m.rowTops[min(row, m.rowHeights.count)]
        let bottomRow = min(row + h, m.rowHeights.count)
        let height = m.rowTops[bottomRow] - y - (h > 0 ? Self.rowSpacing : 0)
        return CGRect(x: x, y: y, width: width, height: max(height, 0))
    }

    // MARK: - Arrange overlays

    /// The 4-column cell grid shown WHILE arranging (T's ruled-in instinct) so the footprint
    /// + available space read as landing on something. Gone on Done. P4 — every cell is a
    /// FLAT RECESS (filled, no stroke, no dash) so dashed now means ONLY "landing here"
    /// (`dropTargetHighlight`). The fill is `AppearancePalette.ink.opacity(0.08)` — adaptive,
    /// so it reads as an inset well in dark and a darker recess in light (the iOS empty-slot
    /// idiom in both modes). Includes the reserved phantom "next page" row.
    @ViewBuilder private var arrangeGridOverlay: some View {
        if isArranging, let m = gridMetrics(), !m.rowHeights.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(Array(0..<m.rowHeights.count), id: \.self) { r in
                    ForEach(Array(0..<Self.columns), id: \.self) { c in
                        let rect = cellRect(m, row: r, col: c)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppearancePalette.ink.opacity(0.08))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The landing-zone highlight for the tile being dragged — a filled, dashed cell block
    /// at the drop target so the snap reads as landing ON a cell.
    @ViewBuilder private var dropTargetHighlight: some View {
        if isArranging, let cellPos = dropTargetCell, let id = draggingID,
           let placed = resolveLayout()[id], let m = gridMetrics() {
            let col = min(max(0, cellPos.col), Self.columns - placed.w)
            let rect = cellRect(m, row: cellPos.row, col: col, w: placed.w, h: placed.h)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppearancePalette.ink.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppearancePalette.ink.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// The candidate-footprint outline for an in-flight RESIZE — the same dashed landing
    /// treatment as the reorder drop target, drawn on the cells the tile will occupy and
    /// gliding to each new candidate as the tile springs to fill it, so the gesture reads as
    /// directional and continuous (BUG B). Shows where the TILE lands; whether to also
    /// preview which neighbours get evicted is a separate T taste call (not built).
    /// The resolved footprint outline to draw — the live resize, or (DEBUG) the forced fixture.
    private var effectiveResizeOutline: Placed? {
        #if DEBUG
        if let d = debugForcedResize, let p = resolveLayout()[d.tileID] {
            return Placed(row: p.row, col: min(max(0, p.col), Self.columns - d.span.w),
                          w: d.span.w, h: d.span.h, flexible: false)
        }
        #endif
        return activeResize != nil ? resizeOutline : nil
    }

    @ViewBuilder private var resizeCandidateHighlight: some View {
        if isArranging, let f = effectiveResizeOutline, let m = gridMetrics() {
            let rect = cellRect(m, row: f.row, col: f.col, w: f.w, h: f.h)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppearancePalette.ink.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppearancePalette.ink.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.30, dampingFraction: 0.72), value: f)
        }
    }

    // Extracted so the ForEach's ViewBuilder stays cheap to type-check.
    @ViewBuilder
    private func cell(for tile: ResolvedTile, placement: Placed?) -> some View {
        let fp = footprint(tile)
        FieldPairCell(
            value: tile.value,
            definition: tile.definition,
            w: fp.w, h: fp.h,
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
            // Arrange mode: DRAG the corner grabber to resize (rubber-band → any w×h);
            // tap the grabber to step the a11y ladder. The tile BODY long-press → move.
            isArranging: isArranging,
            canResize: true,   // ws-free-footprint: every tile may take any size
            onResizeDrag: { resizeDrag(tile, finger: $0) },
            // Release classifies by OUTCOME (span change), not travel — the a11y tap-cycle is
            // now folded into `resizeEnd` (span unchanged + still finger). `stillFinger` is only
            // the secondary jitter guard.
            onResizeEnd: { resizeEnd(stillFinger: $0) },
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
        // The tile declares its RESOLVED grid cell + footprint so the layout places it
        // literally (no packing → holes persist). MUST be OUTERMOST — the enclosing
        // `AttributeCellGrid` reads it off the direct subview, so a `.contextMenu` wrapper
        // above it would hide the value.
        .attributeTileFootprint(
            w: fp.w, h: fp.h, flexible: fp.flexible,
            row: placement?.row ?? 0, col: placement?.col ?? 0,
            // RUBBER-BAND — while THIS tile is being dragged, its frame follows the finger in
            // points (overrides the cell rect); the outline shows where it'll resolve.
            liveSize: liveSize(for: tile.item.id)
        )
        // Report the tile's frame (grid space) so the grid geometry can be reconstructed.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TileFramesKey.self,
                    value: [tile.item.id: proxy.frame(in: .named(Self.gridSpace))]
                )
            }
        )
        .scaleEffect(draggingID == tile.item.id ? 1.04 : 1)
        .shadow(color: .black.opacity(draggingID == tile.item.id ? 0.28 : 0),
                radius: draggingID == tile.item.id ? 10 : 0, y: draggingID == tile.item.id ? 5 : 0)
        .offset(draggingID == tile.item.id ? dragOffset : .zero)
        .zIndex(draggingID == tile.item.id ? 1 : 0)
        // Tile BODY long-press → lift → drag = move. HIGH priority so the post-long-press
        // drag beats the enclosing ScrollView's scroll. Disabled outside arrange
        // (`.subviews`). The grabber's own high-priority drag still wins its corner.
        .highPriorityGesture(reorderGesture(tile), including: isArranging ? .all : .subviews)
    }

    private func reorderGesture(_ tile: ResolvedTile) -> some Gesture {
        // 0.4s hold to arm the move — firm enough that a quick corner grabber-grab can't
        // cross it, so a resize drag never also lifts the tile.
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(coordinateSpace: .named(Self.gridSpace)))
            // BUG C — true while the whole sequence is live; auto-resets on end/cancel. The
            // `.onChange(of: isReorderPressing)` in `body` runs the cleanup off this reset,
            // covering the no-drag lift where `.onEnded` can be swallowed.
            .updating($isReorderPressing) { _, state, _ in state = true }
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
        /// ws-free-footprint — the tile's explicit span (any 1–4 × 1–4). Rendering derives
        /// from this shape; there is no size-class enum on the render path any more.
        let span: AttributeGridSpan
    }

    private var resolvedTiles: [ResolvedTile] {
        // Array order — no longer the layout authority (position is), only the ForEach
        // identity + the homing tiebreak for position-less tiles.
        fieldItems.compactMap { item in
            guard let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) else { return nil }
            // Span resolution (a display rule, no data write): the in-flight arrange choice
            // wins; else the node's stored span; else the kind's default (proposed, not a
            // ceiling). Clamped defensively to the grid (w ≤ columns, h ≥ 1).
            let d = def.kind.defaultSizeClass
            let raw = pendingSizes[item.id] ?? item.attributeTile?.span
                ?? AttributeGridSpan(w: d.widthUnits, h: d.heightUnits)
            let span = AttributeGridSpan(w: min(max(1, raw.w), Self.columns), h: max(1, raw.h))
            return ResolvedTile(item: item, value: fv, definition: def, span: span)
        }
    }
}

/// ws-attributes-grid — a `.field` TILE: a discrete rounded shell (darker than the
/// detail ground so tiles read as separate objects at any arrangement — retires the
/// SERVES/VOLUME "down-or-across" ambiguity, which is why zebra striping stays rejected).
/// ws-free-footprint: the tile takes any span (w × h) and its CONTENT treatment is DERIVED
/// from that shape (not a size-class enum) —
///   · `h==1 && w>=3` → ROW      (caption leading, value trailing, one line).
///   · `w>=2 && h>=2` → LARGE    (caption over a big value that fills; text = prose block).
///   · `w==2 && h==1` → STACKED  (caption over value).
///   · otherwise      → COMPACT  (the same, tighter, for a narrow cell).
/// ANCHORING (T, from the shape-matrix spike): prose (text) reads from the TOP; atomic
/// values (number/money/date/duration/measurement/rating/boolean and other short values)
/// CENTER — a centred value reads as an object placed in a space. Hierarchy is size +
/// weight + spacing, never hue (T is colorblind).
struct FieldPairCell: View {

    let value: FieldValue
    let definition: FieldDefinition
    /// ws-free-footprint — the tile's explicit span, from which the treatment is derived.
    let w: Int
    let h: Int
    let resolveNodeTitle: (String) -> String?
    /// Stage 5.3 — direct-manipulation write (boolean toggles; rating taps). Sheet-
    /// kinds route through `onRequestEdit` instead.
    var onDirectSet: (FieldPayload) -> Void = { _ in }
    var onRequestEdit: () -> Void = {}
    /// P2 arrange mode — when on, DRAG the corner grabber to resize (rubber-band); a plain
    /// tap steps the a11y ladder. Inner controls are inert; the grabber shows if `canResize`.
    var isArranging: Bool = false
    var canResize: Bool = false
    /// The live finger location, in the grid ("attrGrid") coordinate space, so the resize
    /// rectangle can be measured from the tile's top-left. (Was the raw drag translation.)
    var onResizeDrag: (CGPoint) -> Void = { _ in }
    /// Release. The `Bool` is `stillFinger` — was the release near-zero travel (the secondary
    /// tap/jitter guard). The PRIMARY resize-vs-tap decision is made by the grid off the
    /// resolved-span change, not here.
    var onResizeEnd: (Bool) -> Void = { _ in }
    /// Multiplies the value + label point sizes (1 = current). Lets a gate sample smaller
    /// type for T to pick from; the chosen scale gets baked into the constants.
    var typeScale: CGFloat = 1
    /// Field-name label style. BAKED default = serif italic (T, 2026-08-25).
    var labelStyle: AttrLabelStyle = .serifItalic

    @Environment(\.colorScheme) private var colorScheme

    /// The content treatment DERIVED from the span's shape (ws-free-footprint, §4). This is
    /// the provisional rule the shape-matrix spike ran under — the starting point, not a
    /// final answer.
    enum Treatment { case row, large, stacked, compact }
    private var treatment: Treatment {
        if h == 1 && w >= 3 { return .row }
        if w >= 2 && h >= 2 { return .large }
        if w == 2 && h == 1 { return .stacked }
        return .compact
    }

    private var isTextKind: Bool { definition.kind == .text }
    /// PROSE (text) reads from the top; every other kind is an ATOMIC-style value that
    /// centres. The anchoring split, §5.
    private var isProse: Bool { isTextKind }
    /// A big-value LARGE tile that isn't prose or a rating row — renders the value hero-style
    /// (fills the box). Kept as the existing large rendering; type scaling stays deferred.
    private var isHero: Bool { treatment == .large && !isTextKind && !isRatingStars }
    private var isRatingStars: Bool {
        definition.kind == .rating && (definition.config.ratingStyle ?? .stars) == .stars
    }
    private var displayText: String? {
        FieldValueFormatter.display(value, definition: definition, resolveNodeTitle: resolveNodeTitle)
    }

    var body: some View {
        content
            // ANCHORING (§5): prose (text) reads from the TOP-LEADING; atomic values CENTER
            // (an object placed in a space). Applies to the vertical fill and the horizontal
            // content position both.
            .frame(maxWidth: .infinity, alignment: isProse ? .leading : .center)
            .padding(.horizontal, 12)
            .padding(.vertical, treatment == .large ? 14 : 10)
            // maxHeight fills the tile's reserved cell height (any h) so a value has no dead
            // gap below it; content anchors per the split above.
            .frame(minHeight: treatment == .large ? 84 : (treatment == .compact ? 44 : 52),
                   maxHeight: .infinity, alignment: isProse ? .topLeading : .center)
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
                        // Report the finger in the grid space so the resize rectangle is
                        // measured from the tile's top-left (the 2-D continuous model).
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(FieldPairsGrid.gridSpace))
                            .onChanged { onResizeDrag($0.location) }
                            .onEnded { v in
                                // The grid classifies by OUTCOME (did the resolved span change).
                                // We only pass whether the finger barely moved — the secondary
                                // tap/jitter guard. PER-AXIS, not summed (a diagonal tap must
                                // still count as still), floor 4pt.
                                let still = max(abs(v.translation.width), abs(v.translation.height)) < 4
                                onResizeEnd(still)
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
        // Content treatment DERIVED from the span's shape (§4); anchoring per §5 (prose
        // leads/tops, atomic centres).
        switch treatment {
        case .row:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The caption holds its intrinsic width (it's short); the VALUE is what
                // truncates when the row is narrow — never the label down to one glyph.
                label(large: false)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                valueView(large: false, fillHeight: false)   // one horizontal line
            }
        case .large:
            VStack(alignment: isProse ? .leading : .center, spacing: 6) {
                label(large: true)
                if isHero {
                    heroValue                                // atomic → big value fills (kept)
                } else {
                    valueView(large: true, fillHeight: true) // text prose fill / rating stars
                }
            }
        case .stacked, .compact:
            VStack(alignment: isProse ? .leading : .center, spacing: 3) {
                label(large: false)
                valueView(large: false, fillHeight: true)
            }
        }
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
    private func valueView(large: Bool, fillHeight: Bool) -> some View {
        if isRatingStars {
            let v: Int = { if case .rating(let n)? = value.value { return n }; return 0 }()
            let row = stars(v, scale: definition.config.ratingScale ?? 5, large: large)
            // Stars are a single row (height-aware can't add rows) — CENTER them in a tall
            // tile (atomic anchoring, §5). Type scaling to fill a tall rating is deferred.
            if fillHeight { row.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center) }
            else { row }
        } else if let text = displayText {
            if isProse && fillHeight {
                // PROSE height-aware fill (§6): as many WHOLE lines as fit the ACTUAL height,
                // top-aligned. NO minimumScaleFactor — the text renders at the SAME lineHeight
                // the count is computed from (the latent bug was N at full size while
                // minimumScaleFactor shrank the render, losing ~3 lines). Truncate with a tail
                // ellipsis past what fits (intentional truncation — grow the tile for more).
                let size = 14 * typeScale
                let lineH = UIFont.systemFont(ofSize: size, weight: .semibold).lineHeight
                GeometryReader { geo in
                    Text(text)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                        .lineLimit(attributeFillLineCount(height: geo.size.height, lineHeight: lineH))
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            } else {
                // ATOMIC (or a single-line row): ONE line, centred by the outer frame (§5),
                // scales to fit the width before it truncates (e.g. "French" on a 190pt back).
                HStack(spacing: 5) {
                    Text(text)
                        .font(.system(size: (large ? 38 : 14) * typeScale, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(large ? 0.5 : 0.6)
                        .truncationMode(.tail)
                    urlArrow
                }
            }
        } else {
            Text("\u{2014}")   // em dash — present but unfilled
                .font(.system(size: (large ? 38 : 14) * typeScale, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    @ViewBuilder private var urlArrow: some View {
        if definition.kind == .url {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
        }
    }

    /// Whole lines that fit `height` at `lineHeight` (≥1). ws-free-footprint §6: because the
    /// prose fill uses NO minimumScaleFactor, the text renders at exactly `lineHeight`, so the
    /// count is measured against the height it ACTUALLY renders at.
    private func attributeFillLineCount(height: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0, height.isFinite, height > 0 else { return 1 }
        return max(1, Int((height + 0.5) / lineHeight))
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
    /// The tile's RESOLVED grid cell (4-column space), computed by `FieldPairsGrid`
    /// (stored position, else derived first-free home). The layout places the tile here
    /// literally — no packing — so interior holes persist.
    var row: Int = 0
    var col: Int = 0
    /// ws-free-footprint RUBBER-BAND — while this tile is being drag-resized, its frame is
    /// this LIVE POINT size (not the cell rectangle), anchored at its cell origin, so it
    /// follows the finger continuously. Nil otherwise (the tile snaps to its w×h cells).
    var liveSize: CGSize? = nil
}

/// Defaults to a 2×1 (`.stacked`) footprint at the origin for any subview that doesn't declare one.
private struct AttributeTileFootprintKey: LayoutValueKey {
    static let defaultValue = AttributeTileFootprint(w: 2, h: 1)
}

/// Collects each tile's frame (in the grid coordinate space) so the grid geometry can be
/// reconstructed for point→cell mapping + the arrange overlay.
private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

/// The grid's own resolved width, so `FieldPairsGrid` can map a drag point to a cell and
/// draw the arrange overlay at the true unit metrics.
private struct GridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    /// Declares a tile's grid footprint + resolved cell to the enclosing `AttributeCellGrid`.
    func attributeTileFootprint(w: Int, h: Int, flexible: Bool = false,
                                row: Int = 0, col: Int = 0, liveSize: CGSize? = nil) -> some View {
        layoutValue(key: AttributeTileFootprintKey.self,
                    value: AttributeTileFootprint(w: w, h: h, flexible: flexible,
                                                  row: row, col: col, liveSize: liveSize))
    }
}

/// ws-attributes-grid P4 — the ONE uniform cell-row-height rule, called by BOTH
/// `AttributeCellGrid.layout(for:width:)` (measured subview heights) and
/// `FieldPairsGrid.gridMetrics` (rendered tile-frame heights). Sharing the rule AND the
/// fallback constant is what guarantees the panel's reserved bottom and the arrange
/// overlay's last row land on the same pixel — the two derivations can no longer drift.
/// The rule: the tallest NON-flex single-row tile sets the height (a 2-tall tile spans
/// two; a flex text block owns its own variable band); else the tallest non-flex tile;
/// else a constant.
enum AttributeGridRowHeight {
    static let fallback: CGFloat = 52
    static func unitHeight(from tiles: [(height: CGFloat, h: Int, flexible: Bool)]) -> CGFloat {
        let singles = tiles.filter { $0.h == 1 && !$0.flexible }.map(\.height)
        let nonFlex = tiles.filter { !$0.flexible }.map(\.height)
        return max(singles.max() ?? nonFlex.max() ?? fallback, 1)
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
    /// ws-attributes-grid P4 — empty trailing rows to RESERVE below the content in
    /// `sizeThatFits` (0 normally; while arranging, the phantom "next page" row — plus any
    /// extra rows the live drag target needs). Reserving it in the LAYOUT (not a background
    /// overlay, which doesn't size its parent) is what keeps the phantom row INSIDE the
    /// ATTRIBUTES panel instead of bleeding onto the sections below. `FieldPairsGrid`
    /// computes the count so the reserved bottom and the overlay's last row agree.
    var reservedTrailingRows: Int = 0

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
        let laid = layout(for: subviews, width: width)
        let content = laid.frames.map(\.maxY).max() ?? 0
        // Reserve the phantom "next page" row(s) IN the height so the panel grows to hold
        // them (a background overlay can't do this — it doesn't size its parent). Each empty
        // row is a uniform `unitHeight + rowSpacing`, using the SAME `unitHeight` the frames
        // used, so the reserved bottom lines up with the overlay's last row.
        let reserved = CGFloat(max(0, reservedTrailingRows)) * (laid.unitHeight + rowSpacing)
        return CGSize(width: width, height: content + reserved)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = layout(for: subviews, width: bounds.width)
        for (i, f) in laid.frames.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                proposal: ProposedViewSize(width: f.width, height: f.height)
            )
        }
    }

    /// Frames in a local (0,0) space. At the canonical 4-column width each tile is placed
    /// at its RESOLVED cell (`FieldPairsGrid` supplies row/col: stored position, else a
    /// derived first-free home) — NO packing pass, so interior holes persist and trailing
    /// empty rows never accrue (rows only exist where a tile sits; the Home Screen model).
    /// A narrower container (the not-yet-built card back — position can't be shown in <4
    /// columns) falls back to the old greedy re-pack in reading order. Rows are a UNIFORM
    /// `unitHeight` (attributes are scannable, not prose); a `.large` reserves two, and a
    /// flex text block takes its intrinsic height.
    private func layout(for subviews: Subviews, width: CGFloat) -> (frames: [CGRect], unitHeight: CGFloat) {
        let (columns, unitWidth) = columnMetrics(for: width)
        guard columns > 0 else { return ([], AttributeGridRowHeight.fallback) }

        func tileWidth(_ w: Int) -> CGFloat {
            CGFloat(w) * unitWidth + CGFloat(max(0, w - 1)) * unitSpacing
        }

        // Footprint + declared cell per tile. A FLEXIBLE tile spans every column and takes
        // its intrinsic (measured) height; every other tile snaps to whole cells.
        struct Spec { let i: Int; let w: Int; let h: Int; let row: Int; let col: Int
                      let measured: CGFloat; let flexible: Bool; let liveSize: CGSize? }
        let specs: [Spec] = subviews.enumerated().map { (i, sv) in
            let fp = sv[AttributeTileFootprintKey.self]
            let w = fp.flexible ? columns : min(max(1, fp.w), columns)
            let h = max(1, fp.h)
            let measured = sv.sizeThatFits(ProposedViewSize(width: tileWidth(w), height: nil)).height
            return Spec(i: i, w: w, h: h, row: max(0, fp.row), col: max(0, fp.col),
                        measured: measured, flexible: fp.flexible, liveSize: fp.liveSize)
        }
        // Uniform cell-row height — the SAME rule `FieldPairsGrid.gridMetrics` uses (so the
        // panel bottom and the arrange overlay can't drift): tallest non-flex single-row tile.
        // A tile mid-resize (liveSize set) is EXCLUDED — its frame is the live rubber-band
        // size, not a row-height measurement (the vertical-resize feedback loop).
        let unitHeight = AttributeGridRowHeight.unitHeight(
            from: specs.filter { $0.liveSize == nil }.map { ($0.measured, $0.h, $0.flexible) })

        var placements: [(row: Int, col: Int, spec: Spec)] = []
        if columns >= canonicalColumns {
            // POSITIONED: place each tile at its resolved cell (clamp col so it stays on-grid).
            for spec in specs {
                let col = min(max(0, spec.col), columns - spec.w)
                placements.append((spec.row, max(0, col), spec))
            }
        } else {
            // Narrow fallback — greedy re-pack in ARRAY (subview) order; a 4-column
            // position can't be represented in <4 columns, so we fall back to the exact
            // pre-P3 packing. This keeps an un-arranged node byte-identical at EVERY width
            // (the migration guarantee), and a narrow container never shows a starved grid.
            var occupied = Set<Int>()
            func fits(row: Int, col: Int, w: Int, h: Int) -> Bool {
                guard col + w <= columns else { return false }
                for r in row..<(row + h) {
                    for c in col..<(col + w) where occupied.contains(r * columns + c) { return false }
                }
                return true
            }
            let rowLimit = specs.count * 2 + 2
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
            }
        }

        let maxRow = placements.map { $0.row + $0.spec.h }.max() ?? 0

        // Row Y-positions. Each cell-row advances by `unitHeight + rowSpacing`, EXCEPT a
        // row carrying a flex tile, which advances by that tile's intrinsic height instead.
        var rowStride = [CGFloat](repeating: unitHeight + rowSpacing, count: maxRow + 1)
        for p in placements where p.spec.flexible {
            rowStride[p.row] = p.spec.measured + rowSpacing
        }
        var rowTop = [CGFloat](repeating: 0, count: maxRow + 2)
        for r in 0..<(maxRow + 1) { rowTop[r + 1] = rowTop[r] + rowStride[r] }

        // Emit in SUBVIEW order (placements may be re-sorted in the fallback branch).
        var out = [CGRect](repeating: .zero, count: specs.count)
        for p in placements {
            let x = CGFloat(p.col) * (unitWidth + unitSpacing)
            let y = rowTop[p.row]
            if let live = p.spec.liveSize {
                // RUBBER-BAND — the drag-resized tile follows the finger in points, anchored
                // at its cell origin (overrides the cell rectangle until release).
                out[p.spec.i] = CGRect(x: x, y: y, width: live.width, height: live.height)
            } else {
                let h: CGFloat = p.spec.flexible
                    ? p.spec.measured
                    : rowTop[p.row + p.spec.h] - rowTop[p.row] - rowSpacing
                out[p.spec.i] = CGRect(x: x, y: y, width: tileWidth(p.spec.w), height: h)
            }
        }
        return (out, unitHeight)
    }

    /// The canonical grid width. At or above this column count the layout honours stored
    /// positions literally; below it re-packs (see `frames`).
    private var canonicalColumns: Int { 4 }
}
