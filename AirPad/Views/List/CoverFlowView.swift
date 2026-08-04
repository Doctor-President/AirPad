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
    @Environment(\.colorScheme) private var colorScheme
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

    // Card-content tuning (shared with vertical scroll via CardTuning). Height
    // is the carousel's card-height multiplier (×cardWidth); spacing reuses the
    // CoverFlowKey above. Hero-zone / font / text-opacity live inside
    // NodeCardView, keyed by `presentation: .carousel`.
    @AppStorage(CardTuningKey.key(.carousel, .height))
    private var cardHeightRatio: Double = CardTuningDefaults.value(.carousel, .height)

    // Native-scroll carousel (geometry proven on-device via a throwaway spike).
    // The system scroll engine drives motion (drag/momentum/viewAligned snap)
    // via an invisible per-card track; the visible cards ride in an overlay
    // ZStack deck that owns ONLY draw order (mount order → centred card
    // frontmost; a LazyHStack ignores zIndex, the R8 finding). `snappedID` is
    // the viewAligned centred card (snap haptic); `centerFraction` is the live
    // fractional centred index from the scroll offset. CRITICAL mapping:
    // contentOffset at rest on card 0 is −edgeMargin, so
    // centerFraction = (offset + edgeMargin) / stride — NOT offset/stride,
    // which left every card edgeMargin/stride (~0.16 card) off-centre (the
    // e9e6baf askew bug, reverted, then proven-and-fixed via the spike).
    @State private var snappedID: String?
    @State private var centerFraction: CGFloat = 0

    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let pickHaptic = UIImpactFeedbackGenerator(style: .medium)

    #if DEBUG
    @State private var showTuningPanel = false
    @State private var tuningPanelOffset: CGSize = .zero
    @State private var showCardTuning = false
    @State private var cardTuningOffset: CGSize = .zero
    #endif

    private var nodes: [Node] { store.filteredNodes(in: scope) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                AppearancePalette.mapBackground(dark: colorScheme == .dark).ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                carousel

                #if DEBUG
                tuningTrigger
                if showTuningPanel {
                    floatingTuningPanel
                }
                if showCardTuning {
                    floatingCardTuningPanel
                }
                #endif
            }
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            // In-detail link-following (backlinks, suggestion preview) STACKS
            // here so back returns to the originating detail. See `NodeDetailRoute`.
            .navigationDestination(for: NodeDetailRoute.self) { route in
                NodeDetailView(nodeID: route.nodeID, focusEntryID: route.entryID)
            }
            // §3 — search ROW tap pops the detail so the focus is visible.
            .onChange(of: router.dismissDetailRequest) { _, _ in
                navigationPath = NavigationPath()
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

    /// ZStack deck. Every card gets the SAME fixed frame (width from
    /// `centerWidthFraction`, height from the clamped `cardHeightRatio`);
    /// scale + rotation rake on top of that frame, never sizing it, so the
    /// editorial face doesn't clip. Position and draw order come from
    /// `centerFraction`: each visible card is offset by `(index −
    /// centerFraction)·stride` and the deck is mounted farthest → nearest so
    /// the centre card draws frontmost.
    private var carousel: some View {
        GeometryReader { geo in
        let screenW = geo.size.width
        let cardWidth = screenW * CGFloat(centerWidthFraction)
        // Carousel card-height multiplier (×cardWidth). Default 1.95 (+25%
        // over R7's 1.56, itself up from the 5:7 grid face's 7/5 = 1.4). Now a
        // CardTuning dial. Clamped below to the reserved band so the taller
        // card never overflows/clips.
        let cardHeightRatio = CGFloat(self.cardHeightRatio)

        // Reserved bands above/below the carousel. Top (90) clears the
        // back/chrome row. Bottom = Librarian peek (95) + the density pill's
        // offset above it (12) + the pill height (~48) + ~12pt breathing room
        // = peek + 72, so the card's bottom edge clears the pill. With that
        // band the clamp below lands max card height ≈ 640 on Pro Max. Equal
        // `Spacer`s centre the card in the leftover space.
        let topReserve: CGFloat = 90
        let bottomReserve: CGFloat = LibrarianPanelLayout.peekDetentHeight + 72

        // Clamp the +25% target to the space actually available between the
        // reserves (measured via GeometryReader) so it can't overflow/clip.
        let availableHeight = max(0, geo.size.height - topReserve - bottomReserve)
        let cardHeight = min(cardWidth * cardHeightRatio, availableHeight)

        // Stride between adjacent card centres: card width + the (negative)
        // inter-card spacing, so neighbours overlap exactly as before. Card k
        // sits at x = (k − centerFraction)·stride from the deck centre.
        let cardStride = cardWidth + CGFloat(cardSpacing)

        // Symmetric inset so the first/last card can settle at centre under
        // .viewAligned. contentOffset at rest on card 0 is −edgeMargin, so the
        // centred index adds it back (proven by the spike; see the @State note).
        let edgeMargin = (screenW - cardWidth) / 2
        let centerFraction = self.centerFraction

        // Visible window: centre ± 2 (everything else stays unmounted).
        // Ordered farthest → nearest so the most-centred card mounts LAST and
        // therefore draws frontmost — mount order IS draw order in a ZStack.
        // The deck is an OVERLAY on the native scroll track; it owns ONLY draw
        // order (a LazyHStack ignores zIndex, the R8 finding).
        let count = nodes.count
        let centreIdx = Int(centerFraction.rounded())
        let visible: [Int] = count > 0
            ? Array(max(0, centreIdx - 2)...min(count - 1, centreIdx + 2))
            : []
        let ordered = visible.sorted {
            abs(CGFloat($0) - centerFraction) > abs(CGFloat($1) - centerFraction)
        }

        return VStack(spacing: 0) {
            Color.clear.frame(height: topReserve)
            Spacer(minLength: 0)
            // Native scroll TRACK — invisible per-card slots hand the carousel
            // the system scroll engine (drag/momentum/viewAligned snap): the
            // same fluidity as vertical scroll. The visible cards ride in the
            // overlay deck below, driven by the live scroll offset. Taps on a
            // slot open its node (drags scroll); the overlay is non-interactive.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CGFloat(cardSpacing)) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { _, node in
                        Color.clear
                            .frame(width: cardWidth, height: cardHeight)
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
                    }
                }
                .scrollTargetLayout()
            }
            .scrollClipDisabled()
            .contentMargins(.horizontal, edgeMargin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $snappedID)
            // Live scroll offset → continuous centred-card index. VERIFIED
            // mapping: (offset + edgeMargin) / stride (raw offset/stride left
            // every card ~0.16 off-centre — the reverted e9e6baf bug).
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offsetX in
                self.centerFraction = cardStride > 0 ? (offsetX + edgeMargin) / cardStride : 0
            }
            // One light tap per snap-to-new-card.
            .onChange(of: snappedID) { _, newID in
                if newID != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            // #3 — shared focus signal. CoverFlow never had a consumer, so it
            // used to leave the shared flag dirty for the NEXT view — the root
            // of the intermittent misses. Cards are keyed by node id via
            // `.scrollPosition(id:)`, so setting `snappedID` scrolls to the card.
            .onFocusRequest { id in
                guard nodes.contains(where: { $0.id == id }) else { return }
                withAnimation { snappedID = id }
            }
            .frame(height: cardHeight)
            .overlay {
                // Visual deck — windowed, positioned + raked by centerFraction,
                // mounted farthest → nearest so the centred card draws
                // frontmost. Non-interactive: taps + drags fall through to the
                // track ScrollView beneath.
                ZStack {
                    ForEach(ordered, id: \.self) { index in
                        let node = nodes[index]
                        let dist = CGFloat(index) - centerFraction
                        CoverFlowCell(
                            node: node,
                            cardWidth: cardWidth,
                            cardHeight: cardHeight,
                            rotationMaxDegrees: rotationMaxDegrees,
                            sideScale: sideScale,
                            perspective: perspective,
                            isSelecting: selection.isActive,
                            isPicked: selection.isSelected(node.id),
                            // Rake saturates at ±1 (edge cards look like the ±1
                            // neighbour, just pushed further out by the offset).
                            phase: max(-1, min(1, dist))
                        )
                        .offset(x: dist * cardStride)
                        .matchedTransitionSource(id: node.id, in: zoomNamespace)
                    }
                }
                .frame(height: cardHeight)
                .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            Color.clear.frame(height: bottomReserve)
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
                        .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Card-content tuner (height / hero / font / opacity / spacing)
                // — distinct from the carousel-geometry tuner beside it.
                Button {
                    showCardTuning.toggle()
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.35))
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

    private var floatingCardTuningPanel: some View {
        VStack {
            Spacer()
            CardTuningPanel(
                isPresented: $showCardTuning,
                position: $cardTuningOffset
            )
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
    #endif
}

// MARK: - CoverFlowCell
// Per-card wrapper. Owns the fixed frame and the rake (scale + Y-axis
// rotation hinged inward toward center), driven directly by `phase` — the
// signed, clamped distance from centre — since the deck no longer lives in a
// ScrollView (so `scrollTransition` is unavailable). Position (offset) and
// draw order are owned by the parent ZStack deck.

private struct CoverFlowCell: View {
    let node: Node
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let rotationMaxDegrees: Double
    let sideScale: Double
    let perspective: Double
    let isSelecting: Bool
    let isPicked: Bool
    /// −1 (leading) … 0 (centre) … +1 (trailing). Left cards hinge on their
    /// right edge, right cards on their left — both rake inward toward centre.
    let phase: CGFloat

    var body: some View {
        let absV = abs(phase)
        let scale = 1.0 - (1.0 - CGFloat(sideScale)) * absV
        let degrees = -Double(phase) * rotationMaxDegrees
        let anchor = UnitPoint(x: phase < 0 ? 1.0 : 0.0, y: 0.5)
        return NodeCardView(
            nodeID: node.id,
            fallbackNode: node,
            animateEntry: false
        )
        .frame(width: cardWidth, height: cardHeight)
        // #3 — shared focus glow. Applied before the rake so it transforms with
        // the card face (matches NodeCardView's 30pt rounding).
        .focusHighlight(nodeID: node.id, cornerRadius: 30)
        // BUG 10 — shared selection treatment (checkmark + Klein outline), raked
        // with the card like the focus glow.
        .selectionHighlight(isSelecting: isSelecting, isPicked: isPicked, cornerRadius: 30)
        .scaleEffect(scale)
        .rotation3DEffect(
            .degrees(degrees),
            axis: (x: 0, y: 1, z: 0),
            anchor: anchor,
            perspective: CGFloat(perspective)
        )
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
