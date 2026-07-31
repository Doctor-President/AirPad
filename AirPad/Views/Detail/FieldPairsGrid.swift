import SwiftUI

/// Stage 5.2 C10 — the SHARED `.field` render used by BOTH the detail view's
/// Attributes section and QuickCapture. One component, not a fork
/// (`ws-card-primitive.md`): `StackedPairsFlow` derives its column count from
/// available width, so the narrower QuickCapture container proves the
/// one-primitive property rather than needing a trimmed copy. Resolves each
/// `.field` item's definition off the `@Observable` store (per-property
/// tracking — orphaned references drop out so the grid never places an empty
/// cell). Callers gate on non-emptiness.
struct FieldPairsGrid: View {

    let nodeID: String
    let fieldItems: [NodeItem]

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem?

    var body: some View {
        StackedPairsFlow(minColumnWidth: 150, columnSpacing: 24, rowSpacing: 18) {
            ForEach(resolvedPairs, id: \.item.id) { pair in
                cell(for: pair)
            }
        }
        .sheet(item: $editingItem) { item in
            if let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) {
                FieldValueEditorSheet(nodeID: nodeID, item: item, definition: def)
            }
        }
    }

    // Extracted so the ForEach's ViewBuilder stays cheap to type-check.
    @ViewBuilder
    private func cell(for pair: (item: NodeItem, value: FieldValue, definition: FieldDefinition)) -> some View {
        FieldPairCell(
            value: pair.value,
            definition: pair.definition,
            resolveNodeTitle: { id in store.nodes.first { $0.id == id }?.title },
            // Stage 5.3 — direct-manip write (boolean/rating) vs sheet edit.
            onDirectSet: { payload in
                Task {
                    await store.setFieldValue(
                        itemID: pair.item.id, nodeID: nodeID,
                        value: payload, upperValue: pair.value.upperValue
                    )
                }
            },
            onRequestEdit: { editingItem = pair.item }
        )
        .contextMenu {
            if pair.value.value != nil {
                Button("Clear value", role: .destructive) {
                    Task { await store.clearFieldValue(itemID: pair.item.id, nodeID: nodeID) }
                }
            }
            Button("Remove field", role: .destructive) {
                Task { await store.removeField(itemID: pair.item.id, nodeID: nodeID) }
            }
        }
    }

    private var resolvedPairs: [(item: NodeItem, value: FieldValue, definition: FieldDefinition)] {
        fieldItems.compactMap { item in
            guard let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) else { return nil }
            return (item, fv, def)
        }
    }
}

/// Stage 5.1 C6 — read-only STACKED PAIR for a `.field` atomic: caption label
/// ABOVE, value BELOW, both left-aligned. The VALUE carries the weight (larger,
/// primary ink); the label recedes (small, uppercase, letterspaced, dimmed).
/// Hierarchy is size + weight + spacing, never hue (T is colorblind — a
/// tint-based hierarchy is unreadable). Rendered inside `StackedPairsFlow`,
/// which sizes the cell; a value wider than one column takes a full row.
/// Unfilled value → em dash in the value position. No edit/delete yet (Stage 1).
struct FieldPairCell: View {

    let value: FieldValue
    let definition: FieldDefinition
    let resolveNodeTitle: (String) -> String?
    /// Stage 5.3 — direct-manipulation write (boolean toggles; rating taps land
    /// in C2). Sheet-kinds route through `onRequestEdit` instead.
    var onDirectSet: (FieldPayload) -> Void = { _ in }
    var onRequestEdit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(definition.displayName.uppercased())
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                .lineLimit(1)
            valueView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
    }

    /// Tapping a value edits it: boolean toggles in place (nil → Yes → No → Yes);
    /// the sheet-kinds open the editor. rating (C2) + the config kinds (C2) +
    /// vocabulary/nodeReference (C3) are wired in their commits.
    private func handleTap() {
        switch definition.kind {
        case .boolean:
            let current: Bool = { if case .boolean(let b)? = value.value { return b }; return false }()
            onDirectSet(.boolean(!current))
        case .number, .text, .url, .date, .location:
            onRequestEdit()
        case .measurement, .duration, .money, .rating, .vocabulary, .nodeReference:
            break   // wired in C2 / C3
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if definition.kind == .rating,
           (definition.config.ratingStyle ?? .stars) == .stars,
           case .rating(let v)? = value.value {
            stars(v, scale: definition.config.ratingScale ?? 5)
        } else if let text = FieldValueFormatter.display(
            value, definition: definition, resolveNodeTitle: resolveNodeTitle
        ) {
            HStack(spacing: 5) {
                Text(text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Stage 5.2 — url shows HOST only (via prettyURL), so it needs a
                // link affordance to still read as a link. DISPLAY glyph only;
                // opening the link (using the STORED verbatim url) is Stage 3.
                if definition.kind == .url {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                }
            }
        } else {
            Text("\u{2014}")   // em dash — present but unfilled
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
    }

    private func stars(_ v: Int, scale: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<scale, id: \.self) { idx in
                Image(systemName: idx < v ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(
                        idx < v
                            ? Color(hexString: "FACC15")
                            : AppearancePalette.ink.opacity(0.25)
                    )
            }
        }
    }
}

/// Stage 5.1 C6 — a width-derived wrapping flow for stacked-pair cells. Column
/// count comes from AVAILABLE WIDTH, never a context flag: as many uniform
/// columns of >= `minColumnWidth` as fit. A cell whose intrinsic width exceeds
/// one column (a long URL value) spans the FULL row instead of breaking
/// mid-token. This is the one-primitive rule (`ws-card-primitive.md`) — the
/// same layout gives two columns at 390pt and one at 190pt because the width
/// says so, with no detail-vs-card branch.
struct StackedPairsFlow: Layout {
    var minColumnWidth: CGFloat
    var columnSpacing: CGFloat
    var rowSpacing: CGFloat

    private func columnMetrics(for width: CGFloat) -> (count: Int, colWidth: CGFloat) {
        guard width > 0 else { return (1, minColumnWidth) }
        let count = max(1, Int((width + columnSpacing) / (minColumnWidth + columnSpacing)))
        let colWidth = (width - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        return (count, colWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
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

    /// Computes each subview's frame (origin + size) in a local coordinate space
    /// starting at (0, 0). Cells narrower than a column pack `count` per row; a
    /// cell wider than one column takes the full container width on its own row.
    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        let (cols, colWidth) = columnMetrics(for: width)
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var colInRow = 0

        func closeRow() {
            x = 0
            y += rowHeight + rowSpacing
            rowHeight = 0
            colInRow = 0
        }

        for sv in subviews {
            let ideal = sv.sizeThatFits(.unspecified)
            let fullRow = ideal.width > colWidth + 0.5
            if fullRow {
                if colInRow != 0 { closeRow() }
                let h = sv.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
                result.append(CGRect(x: 0, y: y, width: width, height: h))
                rowHeight = h
                closeRow()
            } else {
                if colInRow >= cols { closeRow() }
                let h = sv.sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height
                result.append(CGRect(x: x, y: y, width: colWidth, height: h))
                rowHeight = max(rowHeight, h)
                x += colWidth + columnSpacing
                colInRow += 1
            }
        }
        return result
    }
}
