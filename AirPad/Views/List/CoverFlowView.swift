// CoverFlowView.swift
// Promoted from the spike — Cover Flow is now a real browse primitive
// alongside NodeGridView. Selected when the density pill picks "Full"
// (gridColumnCount == 1). NavigationStack shell mirrors NodeGridView
// verbatim so the R5 detailViewDepth invariant + router-driven Librarian
// nav handoff work unchanged across the swap.
//
// Each card is a full NodeCardView face inside a horizontal `.viewAligned`
// ScrollView, with a per-cell scrollTransition rake (scale + Y-axis
// rotation hinged inward toward center). The focal card is lifted by an
// index-distance zIndex on the direct HStack child — preference-key
// measurement is unusable here because PreferenceKey.reduce() collapses
// sibling values to a single shared number.

import SwiftUI
import UIKit

// MARK: - CoverFlowView

struct CoverFlowView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Namespace private var zoomNamespace

    var scope: CanvasScope = .corpus

    @State private var navigationPath = NavigationPath()
    /// Mirrors NodeGridView's dedupe — Node ID currently sitting at the
    /// top of the navigation stack after a router-driven push.
    @State private var currentDetailNodeID: String? = nil

    @AppStorage(CoverFlowKey.rotationMaxDegrees)
    private var rotationMaxDegrees: Double = CoverFlowDefaults.rotationMaxDegrees
    @AppStorage(CoverFlowKey.sideScale)
    private var sideScale: Double = CoverFlowDefaults.sideScale
    @AppStorage(CoverFlowKey.centerWidthFraction)
    private var centerWidthFraction: Double = CoverFlowDefaults.centerWidthFraction
    @AppStorage(CoverFlowKey.perspective)
    private var perspective: Double = CoverFlowDefaults.perspective
    @AppStorage(CoverFlowKey.cardSpacing)
    private var cardSpacing: Double = CoverFlowDefaults.cardSpacing

    @State private var snappedID: String?

    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let pickHaptic = UIImpactFeedbackGenerator(style: .medium)

    #if DEBUG
    @State private var showTuningPanel = false
    @State private var tuningPanelOffset: CGSize = .zero
    #endif

    private var nodes: [Node] { store.filteredNodes(in: scope) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                carousel

                #if DEBUG
                tuningTrigger
                if showTuningPanel {
                    floatingTuningPanel
                }
                #endif
            }
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                if id != currentDetailNodeID {
                    navigationPath = NavigationPath([node])
                    currentDetailNodeID = id
                }
                router.pendingNodeNavigationID = nil
            }
            .onChange(of: navigationPath.count) { _, newCount in
                store.detailViewDepth = newCount
                if newCount == 0 { currentDetailNodeID = nil }
            }
        }
        .onAppear {
            navHaptic.prepare()
            pickHaptic.prepare()
            store.detailViewDepth = navigationPath.count
        }
    }

    // MARK: - Carousel

    /// Every card gets the SAME fixed frame (width derived from screen +
    /// `centerWidthFraction`, height locked to width × 7/5). Scale and
    /// rotation apply on top of that frame, never to size it — so size
    /// stays uniform and the editorial face doesn't clip. `contentMargins`
    /// derives from the same fraction so the first/last cards can settle
    /// near center under `.viewAligned`.
    private var carousel: some View {
        let screenW = UIScreen.main.bounds.width
        let cardWidth = screenW * CGFloat(centerWidthFraction)
        let cardHeight = cardWidth * 7.0 / 5.0
        let edgeMargin = (screenW - cardWidth) / 2.0

        // Index of the currently-snapped card in the array; falls back to 0
        // before the first snap settles (initial paint). Drives a symmetric
        // zIndex ramp so the focal card sits on top.
        let snappedIndex: Int = snappedID
            .flatMap { id in nodes.firstIndex(where: { $0.id == id }) } ?? 0

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: CGFloat(cardSpacing)) {
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    CoverFlowCell(
                        node: node,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight,
                        rotationMaxDegrees: rotationMaxDegrees,
                        sideScale: sideScale,
                        perspective: perspective
                    )
                    .matchedTransitionSource(id: node.id, in: zoomNamespace)
                    .id(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selection.isActive {
                            pickHaptic.impactOccurred()
                            selection.toggle(node.id)
                        } else {
                            navHaptic.impactOccurred()
                            navigationPath.append(node)
                        }
                    }
                    // Most-centered card = highest zIndex (`nodes.count`),
                    // each step away subtracts 1. Must live on the direct
                    // HStack child — preference-key feedback for this is a
                    // dead end because reduce() collapses to one shared
                    // value across siblings.
                    .zIndex(Double(nodes.count - abs(index - snappedIndex)))
                }
            }
            .scrollTargetLayout()
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, edgeMargin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $snappedID)
        // Nudge the carousel down so the focal card clears the second
        // chrome row (density pill). Tune on device alongside NodeGridView.topInset.
        .padding(.top, 40)
        .onChange(of: snappedID) { _, newID in
            // One light tap per snap-to-new-card.
            if newID != nil {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: - Tuning trigger (DEBUG)

    #if DEBUG
    private var tuningTrigger: some View {
        VStack {
            HStack {
                Button {
                    showTuningPanel.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 60)
        .padding(.leading, 10)
    }

    private var floatingTuningPanel: some View {
        VStack {
            Spacer()
            CoverFlowTuningPanel(
                isPresented: $showTuningPanel,
                position: $tuningPanelOffset
            )
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
    #endif
}

// MARK: - CoverFlowCell
// Per-card wrapper. Owns the fixed frame and the scroll-transition rake
// (scale + Y-axis rotation hinged inward toward center). The zIndex that
// pulls the focal card forward is applied by the parent in the ForEach —
// preference-driven measurement is unusable here because PreferenceKey.reduce()
// collapses sibling values to a single shared number.

private struct CoverFlowCell: View {
    let node: Node
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let rotationMaxDegrees: Double
    let sideScale: Double
    let perspective: Double

    var body: some View {
        NodeCardView(
            nodeID: node.id,
            fallbackNode: node,
            animateEntry: false
        )
        .frame(width: cardWidth, height: cardHeight)
        .scrollTransition(axis: .horizontal) { content, phase in
            // phase.value: -1 (leading) … 0 (center) … +1 (trailing).
            // Cards on the left hinge on their right (.trailing) edge;
            // cards on the right hinge on their left (.leading) edge —
            // both hinge inward toward center.
            let v = phase.value
            let absV = abs(v)
            let scale = 1.0 - (1.0 - CGFloat(sideScale)) * absV
            let degrees = -v * rotationMaxDegrees
            let anchor = UnitPoint(x: v < 0 ? 1.0 : 0.0, y: 0.5)
            return content
                .scaleEffect(scale)
                .rotation3DEffect(
                    .degrees(degrees),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: anchor,
                    perspective: CGFloat(perspective)
                )
        }
    }
}

// MARK: - Keys / defaults

enum CoverFlowKey {
    static let rotationMaxDegrees  = "coverflow.rotationMaxDegrees"
    static let sideScale           = "coverflow.sideScale"
    static let centerWidthFraction = "coverflow.centerWidthFraction"
    static let perspective         = "coverflow.perspective"
    static let cardSpacing         = "coverflow.cardSpacing"
}

enum CoverFlowDefaults {
    static let rotationMaxDegrees: Double  = 44
    static let sideScale: Double           = 0.59
    static let centerWidthFraction: Double = 0.79
    static let perspective: Double         = 0.55
    static let cardSpacing: Double         = -60   // negative = neighbors tuck behind center
}

// MARK: - CoverFlowTuningPanel (DEBUG)
// Same shape as TileTuningPanel — header (drag + copy + close), param chip
// (Menu), one slider at a time bound to the selected key. Copy values dumps
// the five knobs as cf_… lines to UIPasteboard so Tom can paste back the
// numbers to bake as defaults once the feel lands.

#if DEBUG
struct CoverFlowTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    @AppStorage(CoverFlowKey.rotationMaxDegrees)
    private var rotationMaxDegrees: Double = CoverFlowDefaults.rotationMaxDegrees
    @AppStorage(CoverFlowKey.sideScale)
    private var sideScale: Double = CoverFlowDefaults.sideScale
    @AppStorage(CoverFlowKey.centerWidthFraction)
    private var centerWidthFraction: Double = CoverFlowDefaults.centerWidthFraction
    @AppStorage(CoverFlowKey.perspective)
    private var perspective: Double = CoverFlowDefaults.perspective
    @AppStorage(CoverFlowKey.cardSpacing)
    private var cardSpacing: Double = CoverFlowDefaults.cardSpacing

    @State private var selectedKey: String = CoverFlowKey.rotationMaxDegrees
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var justCopied: Bool = false

    private static let widgetWidth: CGFloat = 280

    private struct ParamDef {
        let key: String
        let label: String
        let exportLabel: String
        let range: ClosedRange<Double>
        let step: Double
        let format: String
    }

    private static let params: [ParamDef] = [
        .init(key: CoverFlowKey.rotationMaxDegrees,
              label: "Rotation max°",
              exportLabel: "cf_rotationMaxDegrees",
              range: 0...90, step: 1, format: "%.0f"),
        .init(key: CoverFlowKey.sideScale,
              label: "Side scale",
              exportLabel: "cf_sideScale",
              range: 0.50...1.0, step: 0.01, format: "%.2f"),
        .init(key: CoverFlowKey.centerWidthFraction,
              label: "Center width %",
              exportLabel: "cf_centerWidthFraction",
              range: 0.30...0.90, step: 0.01, format: "%.2f"),
        .init(key: CoverFlowKey.perspective,
              label: "Perspective",
              exportLabel: "cf_perspective",
              range: 0.0...1.5, step: 0.05, format: "%.2f"),
        .init(key: CoverFlowKey.cardSpacing,
              label: "Card spacing",
              exportLabel: "cf_cardSpacing",
              range: -120...60, step: 2, format: "%.0f")
    ]

    var body: some View {
        VStack(spacing: 8) {
            header
            paramChip
            sliderRow
        }
        .padding(12)
        .frame(width: Self.widgetWidth)
        .modifier(CoverFlowWidgetSurface())
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        .offset(x: position.width + dragTranslation.width,
                y: position.height + dragTranslation.height)
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
            HStack(spacing: 4) {
                Spacer()
                Button {
                    copyValues()
                } label: {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(justCopied ? Color.green : .secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy values")
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    position.width  += value.translation.width
                    position.height += value.translation.height
                }
        )
    }

    // MARK: Param chip

    private var paramChip: some View {
        Menu {
            ForEach(Self.params, id: \.key) { p in
                Button {
                    selectedKey = p.key
                } label: {
                    Text(p.label)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedDef?.label ?? "—")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(selectedValueString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    // MARK: Slider

    @ViewBuilder
    private var sliderRow: some View {
        if let p = selectedDef, let binding = binding(for: p.key) {
            Slider(value: binding, in: p.range, step: p.step)
                .frame(height: 32)
        } else {
            Color.clear.frame(height: 32)
        }
    }

    private var selectedDef: ParamDef? {
        Self.params.first(where: { $0.key == selectedKey })
    }

    private var selectedValueString: String {
        guard let p = selectedDef, let b = binding(for: p.key) else { return "" }
        return String(format: p.format, b.wrappedValue)
    }

    private func binding(for key: String) -> Binding<Double>? {
        switch key {
        case CoverFlowKey.rotationMaxDegrees:  return $rotationMaxDegrees
        case CoverFlowKey.sideScale:           return $sideScale
        case CoverFlowKey.centerWidthFraction: return $centerWidthFraction
        case CoverFlowKey.perspective:         return $perspective
        case CoverFlowKey.cardSpacing:         return $cardSpacing
        default: return nil
        }
    }

    // MARK: Copy values

    private func copyValues() {
        var lines: [String] = []
        for p in Self.params {
            let v = binding(for: p.key)?.wrappedValue ?? 0
            lines.append("\(p.exportLabel): \(String(format: p.format, v))")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            justCopied = false
        }
    }
}

// MARK: - Widget surface
// Liquid Glass on iOS 26+, .thinMaterial fallback below. Mirrors the
// TileTuningPanel surface so the two DEBUG widgets read as a family.

private struct CoverFlowWidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}
#endif
