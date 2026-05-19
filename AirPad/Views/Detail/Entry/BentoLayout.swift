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
}
