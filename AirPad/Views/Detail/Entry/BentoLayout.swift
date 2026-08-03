import Foundation

/// Stage 4.2 commit 6 — deterministic bento packer.
///
/// The brief asks for a "bento-style" grid: variable-aspect tiles, wide items
/// optionally promoted to a hero row, the whole card filling its width with
/// no horizontal gaps. The polished feel of bento layouts in apps like
/// Apple Photos or Notion is non-trivial to reproduce; this commit ships a
/// deterministic, predictable packer with sensible defaults and leaves
/// tuning for after we've eyeballed the result on real corpora.
///
/// ## Algorithm — at a glance
///
/// Walk items **in order**. At each row-start, decide whether the next item
/// is a "hero" (aspect ≥ `heroAspectThreshold`) — if so, it gets its own row
/// and we continue with the next index. Otherwise, take the next `k` items
/// for a row, where `k` comes from `partitionForRemaining(_:)`:
///
/// | remaining | row sizes      |
/// |-----------|----------------|
/// | 1         | [1]            |
/// | 2         | [2]            |
/// | 3         | [3]            |
/// | 4         | [2, 2]         |
/// | 5         | [3, 2]         |
/// | 6         | [3, 3]         |
/// | 7         | [3, 2, 2]      |
/// | 8         | [3, 3, 2]      |
/// | 9         | [3, 3, 3]      |
/// | ≥10       | greedy 3s with a 2-tail if `remaining % 3 == 1` (so 10 = [3,3,2,2], 11 = [3,3,3,2], 12 = [3,3,3,3]) |
///
/// **Rationale.** Three per row is the densest comfortable target at iPad
/// card widths (each tile gets enough pixels to read as content, not a
/// favicon). Two per row is the natural fallback when the count doesn't
/// divide cleanly. We never use rows of 1 (other than hero rows) because a
/// lone tile mid-grid reads as a layout bug, not an emphasis. The
/// preference order `…, [3, 2, 2]` over `…, [2, 3, 2]` keeps wider rows at
/// the top — visually heavier rows up high matches the reading order users
/// expect from a feed-style grid.
///
/// ## Hero promotion
///
/// At each row-start we peek at the next item; if its aspect ≥
/// `heroAspectThreshold` (1.7 — landscape-ish, looks "wide" not just
/// rectangular), it gets a full-width row of its own. Multiple heroes in the
/// same gallery are fine — every wide item that lands at a row-start
/// position becomes a hero. We don't re-order the array to make every wide
/// item a hero (that would lose user intent + break determinism on insert);
/// we only promote at natural row boundaries.
///
/// ## Within-row sizing
///
/// Given a row of `k` items with `gutter` between them and total `rowWidth`:
///
///     availableForTiles = rowWidth - (k - 1) * gutter
///     h = availableForTiles / sum(aspects in row)
///     width_i = h * aspect_i
///
/// The math guarantees `sum(width_i) + (k-1)*gutter == rowWidth` exactly,
/// so every row fills the card edge-to-edge regardless of mix.
///
/// ## Missing aspect ratios (defensive path)
///
/// Caller passes `aspectFor: (GalleryItem) -> Double` which already
/// resolves the `measuredAspects[id] ?? galleryItem.aspectRatio ?? 1.0`
/// chain from `GalleryBody`, clamped (0.3, 4.0). The packer treats every
/// missing/invalid aspect as 1.0 via the caller's fallback, so a brand-new
/// migrated entry lays out as a clean grid of squares until measurements
/// land — at which point the renderer reflows.
///
/// ## Determinism
///
/// `plan(items:cardWidth:gutter:aspectFor:)` is a pure function of its
/// inputs. No hashing, no time-based randomness, no implicit sort, no
/// hidden state. Same input array + same `cardWidth` always produces the
/// same `BentoPlan`. Two consecutive calls produce identical output — the
/// renderer can rebuild on every redraw without worrying about layout
/// jitter.
enum BentoLayout {

    /// Items with aspect ≥ this threshold get promoted to a hero row when
    /// they land at a row-start position. 1.7 chosen as "clearly landscape"
    /// — typical 16:9 video frames (1.78) qualify, typical phone photos
    /// (4:3 = 1.33) do not.
    static let heroAspectThreshold: Double = 1.7

    /// Standard gutter between tiles, vertical and horizontal. Matches the
    /// 6pt spacing the commit-4 placeholder grid used so the bento → carousel
    /// toggle doesn't introduce a visual rhythm change.
    static let defaultGutter: CGFloat = 6

    /// One row in the plan. `indices` references back into the source
    /// `galleryItems` array (parallel array, not Index types — Swift's
    /// `[GalleryItem]` indexing is Int-based, so plain Ints are fine).
    struct Row: Equatable {
        let indices: [Int]
        let height: CGFloat
        /// True if this row was promoted because the lead item is a hero.
        /// Renderer can use this to apply a slightly different chrome (e.g.
        /// taller minimum height) if we ever want to; commit 6 doesn't, but
        /// the flag is cheap and lets commit 7+ tune without re-deriving.
        let isHero: Bool
    }

    /// Full layout plan for one gallery. `totalHeight` is the sum of row
    /// heights plus inter-row gutters — caller can feed it directly into
    /// `.frame(height:)` to size the bento container.
    struct Plan: Equatable {
        let rows: [Row]
        let totalHeight: CGFloat
    }

    /// Compute the row partition for `remaining` items, **assuming no hero
    /// promotion**. Hero handling is layered on top in `plan(...)` — this
    /// function is just the standard-row table from the docs above.
    ///
    /// Pulled out as its own function so unit-style assertions (T8/T9-style
    /// diagnostic harness, if commit 8 adds one) can check the table
    /// directly without going through the full planner.
    static func partitionForRemaining(_ remaining: Int) -> [Int] {
        switch remaining {
        case ..<1: return []
        case 1: return [1]
        case 2: return [2]
        case 3: return [3]
        case 4: return [2, 2]
        case 5: return [3, 2]
        case 6: return [3, 3]
        case 7: return [3, 2, 2]
        case 8: return [3, 3, 2]
        case 9: return [3, 3, 3]
        default:
            // Greedy 3s with a 2-tail when `remaining % 3 == 1` (would
            // otherwise leave a [1] singleton). Walks the same table for
            // the last 4-9 items so the tail matches the small-N rules.
            var rows: [Int] = []
            var left = remaining
            while left > 9 {
                rows.append(3)
                left -= 3
            }
            rows.append(contentsOf: partitionForRemaining(left))
            return rows
        }
    }

    /// Build the layout. See top-of-file docs for the algorithm.
    static func plan<Item>(
        items: [Item],
        cardWidth: CGFloat,
        gutter: CGFloat = defaultGutter,
        aspectFor: (Item) -> Double
    ) -> Plan {
        guard !items.isEmpty, cardWidth > 0 else {
            return Plan(rows: [], totalHeight: 0)
        }

        var rows: [Row] = []
        var cursor = 0
        let n = items.count

        while cursor < n {
            // Hero check at the row-start position.
            let leadAspect = aspectFor(items[cursor])
            if leadAspect >= heroAspectThreshold {
                let height = cardWidth / leadAspect
                rows.append(Row(indices: [cursor], height: height, isHero: true))
                cursor += 1
                continue
            }

            // Standard row — partition size depends on remaining count.
            let remaining = n - cursor
            let table = partitionForRemaining(remaining)
            // Pull the FIRST partition entry; the next loop iteration will
            // call partitionForRemaining again on the new `remaining`. This
            // is what makes hero promotion compose cleanly: a hero in the
            // middle of the sequence just shrinks `remaining` by 1 and the
            // table re-decides the next row.
            let k = table.first ?? remaining
            let rowIndices = Array(cursor..<(cursor + k))
            let rowAspects = rowIndices.map { aspectFor(items[$0]) }
            let aspectSum = rowAspects.reduce(0, +)
            let availableForTiles = cardWidth - CGFloat(k - 1) * gutter
            // aspectSum can't be zero in practice (aspectFor returns clamped
            // ≥ 0.3 from GalleryBody), but guard anyway so a future caller
            // without that clamp can't divide by zero.
            let height: CGFloat = aspectSum > 0
                ? availableForTiles / CGFloat(aspectSum)
                : 0
            rows.append(Row(indices: rowIndices, height: height, isHero: false))
            cursor += k
        }

        let rowHeights = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let interRowGutters = CGFloat(max(0, rows.count - 1)) * gutter
        return Plan(rows: rows, totalHeight: rowHeights + interRowGutters)
    }

    /// Width of `item` in a row of given `height`. Caller already knows
    /// which row the item belongs to (it has the `Row` from the plan), so
    /// this is just `height * aspect` — exposed as a named helper so the
    /// renderer doesn't re-derive it inline and so the units stay obvious.
    static func tileWidth(forAspect aspect: Double, rowHeight: CGFloat) -> CGFloat {
        rowHeight * CGFloat(aspect)
    }

    // MARK: - Horizontal bento (the vertical packer, rotated 90°)

    /// `plan(...)` rotated 90°: instead of filling a fixed WIDTH with rows that
    /// stack DOWN, `planHorizontal(...)` fills a fixed HEIGHT (the 220pt gallery
    /// band) with columns that march ACROSS. The two are one idea; the map is:
    ///
    /// | vertical `plan`            | horizontal `planHorizontal`      |
    /// |----------------------------|----------------------------------|
    /// | rowWidth (`cardWidth`)     | columnHeight (fixed band)        |
    /// | `Row.height`               | `Column.width`                   |
    /// | wide-hero promotion        | TALL promotion                   |
    /// | row of k side-by-side      | column of k stacked              |
    ///
    /// ## Tall promotion — the load-bearing rule
    /// A wide item gets a hero row; the rotation of "wide" is "tall", so a tall
    /// item gets a full-HEIGHT column of its own. The threshold is DERIVED from
    /// the vertical one (not a second magic constant): `tallAspectThreshold =
    /// 1 / heroAspectThreshold` (≈ 0.588). At each COLUMN-START we peek the next
    /// item; if its aspect ≤ that, it becomes a full-height column, `width =
    /// columnHeight × aspect`. Promotion happens ONLY at column-start — same
    /// determinism + respect-user-order rationale as the row-start hero rule; we
    /// don't re-order to promote every tall item. This matters because most
    /// gallery content is portrait: a naive two-deep stack of 9:16 shots yields
    /// ~60pt slivers, and promotion is what prevents that (they read at full
    /// band height instead).
    ///
    /// ## Within-column sizing
    /// A column of `k` stacked items shares one WIDTH `w`; heights vary by aspect
    /// (mirror of the vertical's shared-height / varying-width):
    ///
    ///     availableForTiles = columnHeight - (k - 1) * gutter
    ///     w = availableForTiles / sum(1 / aspect_i)
    ///     height_i = w / aspect_i
    ///
    /// so `sum(height_i) + (k-1)*gutter == columnHeight` exactly — every column
    /// fills the band top-to-bottom.
    ///
    /// ## Partition — a SEPARATE table (do NOT reuse `partitionForRemaining`)
    /// The vertical packs 3-per-row because 3 across a card width still read as
    /// content; 3 stacked in a 220pt band is ~70pt each — too small. Horizontal
    /// packs TWO (`partitionForRemainingHorizontal`). And unlike the vertical, a
    /// trailing SINGLE is fine here — a lone full-height tile reads as emphasis,
    /// not a bug — so the no-singleton rule does not carry over.
    ///
    /// ## Determinism
    /// Same contract as `plan(...)`: a pure function of its inputs, no hashing /
    /// sort / hidden state; identical input always yields an identical plan.

    /// Items with aspect ≤ this get a full-height column. DERIVED from the
    /// vertical hero threshold so the two rules can't drift apart (≈ 0.588).
    static let tallAspectThreshold: Double = 1.0 / heroAspectThreshold

    /// One column in the horizontal plan. `indices` reference back into the
    /// source array (Int-based, mirroring `Row.indices`). `isTall` marks a
    /// column promoted because its lead item is tall (the rotation of `isHero`).
    struct Column: Equatable {
        let indices: [Int]
        let width: CGFloat
        let isTall: Bool
    }

    /// Full horizontal plan. `totalWidth` = sum of column widths + inter-column
    /// gutters; the band height is fixed by the caller (not stored here).
    struct HorizontalPlan: Equatable {
        let columns: [Column]
        let totalWidth: CGFloat
    }

    /// Column partition for `remaining` items, **assuming no tall promotion** —
    /// greedy 2s with a trailing `[1]` when `remaining` is odd. A trailing single
    /// is intentional here (emphasis, not a bug), unlike `partitionForRemaining`.
    static func partitionForRemainingHorizontal(_ remaining: Int) -> [Int] {
        guard remaining >= 1 else { return [] }
        var cols: [Int] = []
        var left = remaining
        while left >= 2 { cols.append(2); left -= 2 }
        if left == 1 { cols.append(1) }
        return cols
    }

    /// Build the horizontal plan. See the doc block above for the algorithm.
    static func planHorizontal<Item>(
        items: [Item],
        columnHeight: CGFloat,
        gutter: CGFloat = defaultGutter,
        aspectFor: (Item) -> Double
    ) -> HorizontalPlan {
        guard !items.isEmpty, columnHeight > 0 else {
            return HorizontalPlan(columns: [], totalWidth: 0)
        }

        var columns: [Column] = []
        var cursor = 0
        let n = items.count

        while cursor < n {
            // Tall check at the column-start position.
            let leadAspect = aspectFor(items[cursor])
            if leadAspect <= tallAspectThreshold {
                let width = columnHeight * CGFloat(leadAspect)
                columns.append(Column(indices: [cursor], width: width, isTall: true))
                cursor += 1
                continue
            }

            // Standard column — partition size depends on remaining count.
            let remaining = n - cursor
            let table = partitionForRemainingHorizontal(remaining)
            let k = table.first ?? remaining
            let colIndices = Array(cursor..<(cursor + k))
            // Rotated from the vertical's `sum(aspects)`: here heights share the
            // width, so the sizing key is `sum(1/aspect)`.
            let inverseAspectSum = colIndices.reduce(CGFloat(0)) {
                $0 + CGFloat(1.0 / aspectFor(items[$1]))
            }
            let availableForTiles = columnHeight - CGFloat(k - 1) * gutter
            // Guarded like the vertical's `aspectSum > 0` (aspectFor is clamped
            // ≥ 0.3, so 1/aspect ≤ 3.33 and the sum is > 0 in practice).
            let width: CGFloat = inverseAspectSum > 0
                ? availableForTiles / inverseAspectSum
                : 0
            columns.append(Column(indices: colIndices, width: width, isTall: false))
            cursor += k
        }

        let columnWidths = columns.reduce(CGFloat(0)) { $0 + $1.width }
        let interColumnGutters = CGFloat(max(0, columns.count - 1)) * gutter
        return HorizontalPlan(columns: columns, totalWidth: columnWidths + interColumnGutters)
    }

    /// Height of `item` in a column of given `width` — `width / aspect`, the
    /// rotation of `tileWidth(forAspect:rowHeight:)`. Works for every column kind
    /// (tall single, standard multi, trailing single) since a full-height column
    /// has `width = columnHeight × aspect`, so `width / aspect == columnHeight`.
    static func tileHeight(forAspect aspect: Double, columnWidth: CGFloat) -> CGFloat {
        columnWidth / CGFloat(aspect)
    }
}
