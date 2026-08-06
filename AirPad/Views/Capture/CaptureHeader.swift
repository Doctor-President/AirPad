import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Rendered-geometry measurement (proves parity, DEBUG-only)

/// Collects the rendered frame of each header boundary (keyed by name) in a shared
/// coordinate space, so the parity table is built from RENDERED geometry — NOT from
/// reading the source (source agreement is what was already assumed and was wrong).
/// `-HeaderMeasure YES` on either capture screen dumps the table via NSLog.
struct HeaderBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The coordinate space the header + its surrounding hero/first-entry taps report
/// into. Placed on the scroll content by each surface.
let captureHeaderSpace = "captureHeaderSpace"

extension View {
    /// Tag a header boundary for measurement (no-op layout: a clear background).
    func measureHeaderBound(_ id: String) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: HeaderBoundsKey.self,
                                       value: [id: g.frame(in: .named(captureHeaderSpace))])
            }
        )
    }

    /// Install the measurement collector on the scroll content. On `-HeaderMeasure`
    /// it logs the seven inter-element gaps computed from rendered frames.
    func collectHeaderMeasurements(surface: String) -> some View {
        coordinateSpace(.named(captureHeaderSpace))
            .onPreferenceChange(HeaderBoundsKey.self) { frames in
                guard ProcessInfo.processInfo.arguments.contains("-HeaderMeasure") else { return }
                CaptureHeaderMeasure.log(surface: surface, frames: frames)
            }
    }
}

enum CaptureHeaderMeasure {
    /// Gap(A→B) = B.minY − A.maxY, from the rendered frames.
    static func log(surface: String, frames: [String: CGRect]) {
        func gap(_ a: String, _ b: String) -> String {
            guard let ra = frames[a], let rb = frames[b] else { return "—" }
            return String(format: "%.1f", rb.minY - ra.maxY)
        }
        let rows: [(String, String, String)] = [
            ("hero→title",                 "hero",        "title"),
            ("title→summary",              "title",       "summary"),
            ("summary→chip lanes",         "summary",     "collections"),
            ("collections lane→tags lane", "collections", "tags"),
            ("chip lanes→ATTRIBUTES hairline", "tags",    "hairline"),
            ("hairline→ATTRIBUTES text",   "hairline",    "attrText"),
            ("ATTRIBUTES text→first entry","attrText",    "firstEntry"),
        ]
        var out = "[HeaderMeasure] surface=\(surface)\n"
        for (label, a, b) in rows { out += String(format: "  %-30@ %@\n", label as NSString, gap(a, b)) }
        NSLog("%@", out)
    }
}

// MARK: - Shared header region

/// The header region — title · summary · lever + chip lanes · ATTRIBUTES — shared by
/// BOTH capture surfaces (`QuikCaptureView` and `NodeDetailView`), so the vertical
/// rhythm has ONE source and cannot drift (it drifted precisely because each surface
/// owned a copy: QuikCapture used literal `24` + a `Divider`, NodeDetail read
/// `EntryVisualSettings`). ALL spacing here reads `EntryVisualSettings` — the single
/// source both surfaces now share.
///
/// Surface-specific leaves are slots (like `CaptureChromeBar`'s leading slot): the
/// Title/Summary fields (with their own bindings, focus, and NodeDetail's band-
/// collapse opacity), the collections/tags chip rows, and the ATTRIBUTES section.
struct CaptureHeader<Title: View, Summary: View, Collections: View, Tags: View, Attributes: View>: View {
    let nodeID: String
    /// Whether the summary field renders (the surfaces share the same predicate).
    let showSummary: Bool
    /// Whether the ATTRIBUTES section renders. In CAPTURE it is ALWAYS shown (its
    /// "+" is the first-field entry point); the detail view keeps its normal-viewing
    /// gate (atomics present). The caller resolves this — see each surface.
    let showAttributes: Bool
    let onLeverTap: () -> Void
    @ViewBuilder var title: Title
    @ViewBuilder var summary: Summary
    @ViewBuilder var collections: Collections
    @ViewBuilder var tags: Tags
    @ViewBuilder var attributes: Attributes

    @State private var laneStackHeight: CGFloat = 60
    private var s: EntryVisualSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
                .measureHeaderBound("title")

            if showSummary {
                summary
                    .measureHeaderBound("summary")     // measure CONTENT, then pad
                    .padding(.top, s.titleToSummary)   // #3 — one value, both surfaces
            }

            // THE LEVER — feather button LEFT, the two chip lanes RIGHT. The inter-
            // lane gap is `chipRowGap` (#1 — one value, both surfaces; QuikCapture had
            // 24).
            HStack(alignment: .center, spacing: 12) {
                LeverButton(nodeID: nodeID, diameter: laneStackHeight, onTap: onLeverTap)
                VStack(alignment: .leading, spacing: 0) {
                    collections.measureHeaderBound("collections")
                    tags
                        .measureHeaderBound("tags")     // measure CONTENT, then pad
                        .padding(.top, s.chipRowGap)
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: LaneStackHeightKey.self, value: g.size.height)
                    }
                )
            }
            .padding(.top, s.summaryToChips)   // one value, both surfaces
            .onPreferenceChange(LaneStackHeightKey.self) { laneStackHeight = $0 }

            if showAttributes {
                // Hairline above ATTRIBUTES (T's #4 model references it). Symmetric
                // spacing: hairline→ATTRIBUTES-text ≈ ATTRIBUTES-text→first entry, from
                // ONE constant (`CaptureHeaderMetrics.attributesSymmetricGap`). The
                // hairline sits `chipsToDivider` below the tags lane.
                Rectangle()
                    .fill(AppearancePalette.ink.opacity(0.12))
                    .frame(height: 1)
                    .measureHeaderBound("hairline")     // measure CONTENT, then pad
                    .padding(.top, s.chipsToDivider)

                attributes
                    .padding(.top, CaptureHeaderMetrics.attributesSymmetricGap)
            }
        }
    }
}

/// Header constants NOT already owned by `EntryVisualSettings`. Kept minimal — the
/// per-gap rhythm lives in `EntryVisualSettings` (the shared source).
enum CaptureHeaderMetrics {
    /// #4 — the gap ABOVE the ATTRIBUTES section (hairline → section). Tuned with
    /// `attributesToEntries` (below) so the two gaps flanking the "ATTRIBUTES" text
    /// read ≈ equal — symmetric by these two constants, one owner, both surfaces.
    static let attributesSymmetricGap: CGFloat = 10
    /// #4 — the gap BELOW the ATTRIBUTES section (section → first payload entry). Set
    /// EQUAL to `attributesSymmetricGap` so, given the "ATTRIBUTES" row's internal
    /// geometry (the +/- button centres the 10pt text in a 24pt row), the two gaps
    /// flanking the text measure ≈ equal (16pt each — verified by the table below).
    static let attributesToEntries: CGFloat = 10
}

// MARK: - Shared ATTRIBUTES section (unified from the two per-surface copies)

/// The pinned ATTRIBUTES section, shared by both capture surfaces (was two
/// near-identical copies — `AttributesSection` in NodeDetailView, the file-private
/// `QuikCaptureAttributesSection` in QuikCaptureView). Renders the "ATTRIBUTES"
/// header + a "+" that opens the Add-Field sheet, then any `.field` atomics
/// (`FieldPairsGrid`) and legacy `.rating` rows. The "+" and section are the
/// first-field entry point on the capture surfaces, so the section is always shown
/// there even with no atomics yet.
struct CaptureAttributesSection: View {
    let nodeID: String
    @Binding var showFieldSheet: Bool
    /// So the header's "ATTRIBUTES" text can be measured for the parity table.
    var measured: Bool = false

    @Environment(CorpusStore.self) private var store
    @State private var editingItem: NodeItem? = nil

    private var node: Node? { store.nodes.first { $0.id == nodeID } }

    private var atomicItems: [NodeItem] {
        guard let node else { return [] }
        let count = node.items.lazy.filter { $0.type.isAtomic }.count
        return Array(node.items.prefix(count))
    }
    private var fieldItems: [NodeItem] { atomicItems.filter { $0.type == .field } }
    private var nonFieldAtomics: [NodeItem] { atomicItems.filter { $0.type != .field } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader
            if !fieldItems.isEmpty {
                FieldPairsGrid(nodeID: nodeID, fieldItems: fieldItems)
            }
            if !nonFieldAtomics.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(nonFieldAtomics) { item in rowFor(item) }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            if item.type == .rating, let rating = item.rating {
                RatingEditSheet(itemID: item.id, nodeID: nodeID,
                                initialValue: rating.value, scale: rating.scale)
                    .presentationDetents([.height(260)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("ATTRIBUTES")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .modifier(MeasureIf(measured: measured, id: "attrText"))
            Spacer(minLength: 0)
            Button { showFieldSheet = true } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func rowFor(_ item: NodeItem) -> some View {
        switch item.type {
        case .rating:
            RatingAttributeRow(
                item: item,
                onTap: { editingItem = item },
                onDelete: { Task { await store.deleteEntry(itemID: item.id, nodeID: nodeID) } }
            )
        default:
            EmptyView()
        }
    }
}

/// Applies `measureHeaderBound` only when the section is being measured, so the
/// tap never affects the non-measured render.
private struct MeasureIf: ViewModifier {
    let measured: Bool
    let id: String
    func body(content: Content) -> some View {
        if measured { content.measureHeaderBound(id) } else { content }
    }
}
