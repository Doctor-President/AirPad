// NodeGridTileTuning.swift
// Per-density live tuning for NodeGridTile. Splits every layout constant
// into _2col / _3col @AppStorage keys so editorial and title-only can be
// dialed independently. NodeGridTile reads `TileTuningValues.resolved(...)`
// once per render via the matching @AppStorage observers — change a slider
// and every visible tile re-renders.
//
// Once the final numbers settle on device, bake them back as static
// constants in NodeGridTile and delete this file.

import SwiftUI
import UIKit

// MARK: - Title placement (3-col+)

enum TileTitleAnchor: String, CaseIterable {
    case top, center, bottom
    var label: String { rawValue.capitalized }
}

// MARK: - Keys
// One source of truth for the UserDefaults key strings — referenced by
// every @AppStorage in this file (panel) and in NodeGridTile (resolver).
// Keep them aligned; a typo divides the tile from the panel silently.

enum TileTuningKey {
    // Hero
    static let heroPercent_2col          = "tile.heroPercent_2col"
    static let heroPercent_3col          = "tile.heroPercent_3col"
    static let heroBottomPadding_2col    = "tile.heroBottomPadding_2col"
    static let heroBottomPadding_3col    = "tile.heroBottomPadding_3col"
    // Title
    static let titleBaseSize_2col        = "tile.titleBaseSize_2col"
    static let titleBaseSize_3col        = "tile.titleBaseSize_3col"
    static let titleHPadding_2col        = "tile.titleHPadding_2col"
    static let titleHPadding_3col        = "tile.titleHPadding_3col"
    static let titleTracking_2col        = "tile.titleTracking_2col"
    static let titleTracking_3col        = "tile.titleTracking_3col"
    static let titleLineSpacing_2col     = "tile.titleLineSpacing_2col"
    static let titleLineSpacing_3col     = "tile.titleLineSpacing_3col"
    static let titleLineLimit_2col       = "tile.titleLineLimit_2col"
    static let titleLineLimit_3col       = "tile.titleLineLimit_3col"
    static let titleMinScale_2col        = "tile.titleMinScale_2col"
    static let titleMinScale_3col        = "tile.titleMinScale_3col"
    static let titleMaxScale_2col        = "tile.titleMaxScale_2col"
    static let titleMaxScale_3col        = "tile.titleMaxScale_3col"
    static let titleAnchor_3col          = "tile.titleAnchor_3col"
    // Deck (2-col only)
    static let deckBaseSize_2col         = "tile.deckBaseSize_2col"
    static let deckTracking_2col         = "tile.deckTracking_2col"
    static let deckLineSpacing_2col      = "tile.deckLineSpacing_2col"
    static let deckLineLimit_2col        = "tile.deckLineLimit_2col"
    // Meta (2-col only — dateline + tags)
    static let metaBaseSize_2col         = "tile.metaBaseSize_2col"
    static let metaTracking_2col         = "tile.metaTracking_2col"
    // Spacing
    static let spacingDatelineToTitle_2col = "tile.spacingDatelineToTitle_2col"
    static let spacingTitleToDeck_2col     = "tile.spacingTitleToDeck_2col"
    static let spacingDeckToTags_2col      = "tile.spacingDeckToTags_2col"
    static let bottomPadding_2col          = "tile.bottomPadding_2col"
    static let bottomPadding_3col          = "tile.bottomPadding_3col"
    // Hairline
    static let hairlineOpacity_2col      = "tile.hairlineOpacity_2col"
    // Gradient (per-density: tile callers pass these into NodeGradientLayer
    // to scale the whole composition down + add a dark-rim vignette so the
    // gradient reads as a contained form instead of edge-to-edge wash.
    // Hero / full card don't read these keys — they call NodeGradientLayer
    // with the layer's own 1.0/1.0/1.0/0 defaults.)
    static let gradientCircleScale_2col  = "tile.gradientCircleScale_2col"
    static let gradientCircleScale_3col  = "tile.gradientCircleScale_3col"
    static let gradientBlurScale_2col    = "tile.gradientBlurScale_2col"
    static let gradientBlurScale_3col    = "tile.gradientBlurScale_3col"
    static let gradientOffsetScale_2col  = "tile.gradientOffsetScale_2col"
    static let gradientOffsetScale_3col  = "tile.gradientOffsetScale_3col"
    static let gradientVignette_2col     = "tile.gradientVignette_2col"
    static let gradientVignette_3col     = "tile.gradientVignette_3col"
}

// MARK: - Defaults
// Baked from Tom's device-dialed values (widget v3 export). These are the
// new "Reset" floor — existing UserDefaults entries are NOT migrated, so
// older installs see their dialed values until they hit Reset; fresh
// installs see these directly.

enum TileTuningDefaults {
    // Hero
    static let heroPercent_2col: Double         = 0.43
    static let heroPercent_3col: Double         = 0.52
    static let heroBottomPadding_2col: Double   = 6
    static let heroBottomPadding_3col: Double   = 8
    // Title
    static let titleBaseSize_2col: Double       = 18
    static let titleBaseSize_3col: Double       = 20
    static let titleHPadding_2col: Double       = 16
    static let titleHPadding_3col: Double       = 10
    static let titleTracking_2col: Double       = -0.45
    static let titleTracking_3col: Double       = -0.15
    static let titleLineSpacing_2col: Double    = 0
    static let titleLineSpacing_3col: Double    = 0
    static let titleLineLimit_2col: Int         = 4
    static let titleLineLimit_3col: Int         = 5
    static let titleMinScale_2col: Double       = 0.80
    static let titleMinScale_3col: Double       = 0.92
    static let titleMaxScale_2col: Double       = 1.0
    static let titleMaxScale_3col: Double       = 1.55
    static let titleAnchor_3col: String         = TileTitleAnchor.center.rawValue
    // Deck
    static let deckBaseSize_2col: Double        = 11
    static let deckTracking_2col: Double        = 0
    static let deckLineSpacing_2col: Double     = 3
    static let deckLineLimit_2col: Int          = 3
    // Meta
    static let metaBaseSize_2col: Double        = 7
    static let metaTracking_2col: Double        = 2.0
    // Spacing
    static let spacingDatelineToTitle_2col: Double = 8
    static let spacingTitleToDeck_2col: Double     = 9
    static let spacingDeckToTags_2col: Double      = 0
    static let bottomPadding_2col: Double          = 10
    static let bottomPadding_3col: Double          = 16
    // Hairline
    static let hairlineOpacity_2col: Double     = 0.36
    // Gradient
    static let gradientCircleScale_2col: Double = 0.64
    static let gradientCircleScale_3col: Double = 0.46
    static let gradientBlurScale_2col: Double   = 0.50
    static let gradientBlurScale_3col: Double   = 0.42
    static let gradientOffsetScale_2col: Double = 0.70
    static let gradientOffsetScale_3col: Double = 0.30
    static let gradientVignette_2col: Double    = 0.62
    static let gradientVignette_3col: Double    = 0.26
}

// MARK: - Resolved values
// Per-density snapshot of every tuned constant. NodeGridTile builds one of
// these per render (`tuning(for: isEditorial)`) and reads it instead of
// touching @AppStorage directly. The 3-col branch leaves deck/meta/spacing
// slots populated with defaults (inert — not rendered in 3-col).

struct TileTuningValues {
    let heroPercent: CGFloat
    let heroBottomPadding: CGFloat

    let titleBaseSize: CGFloat
    let titleHPadding: CGFloat
    let titleTracking: CGFloat
    let titleLineSpacing: CGFloat
    let titleLineLimit: Int
    let titleMinScale: CGFloat
    let titleMaxScale: CGFloat
    let titleAnchor: TileTitleAnchor

    let deckBaseSize: CGFloat
    let deckTracking: CGFloat
    let deckLineSpacing: CGFloat
    let deckLineLimit: Int

    let metaBaseSize: CGFloat
    let metaTracking: CGFloat

    let spacingDatelineToTitle: CGFloat
    let spacingTitleToDeck: CGFloat
    let spacingDeckToTags: CGFloat
    let bottomPadding: CGFloat

    let hairlineOpacity: Double

    let gradientCircleScale: CGFloat
    let gradientBlurScale: CGFloat
    let gradientOffsetScale: CGFloat
    let gradientVignette: CGFloat
}

// MARK: - TileTuningPanel (DEBUG)
// v3: small floating widget instead of a bottom sheet. ~280×130, mounted as
// an overlay in NodeGridView's ZStack, draggable by the header bar.
// Default position is bottom-center; the parent owns `position` so it
// survives close/re-open within a session. One slider at a time — pick a
// param from the menu chip and the slider rebinds to its @AppStorage entry.
//
// Title placement (3-col anchor) is the lone non-slider: when selected,
// the slider row swaps for a 3-state segmented control.

#if DEBUG
struct TileTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    // Hero
    @AppStorage(TileTuningKey.heroPercent_2col)       private var heroPercent_2col: Double       = TileTuningDefaults.heroPercent_2col
    @AppStorage(TileTuningKey.heroPercent_3col)       private var heroPercent_3col: Double       = TileTuningDefaults.heroPercent_3col
    @AppStorage(TileTuningKey.heroBottomPadding_2col) private var heroBottomPadding_2col: Double = TileTuningDefaults.heroBottomPadding_2col
    @AppStorage(TileTuningKey.heroBottomPadding_3col) private var heroBottomPadding_3col: Double = TileTuningDefaults.heroBottomPadding_3col
    // Title
    @AppStorage(TileTuningKey.titleBaseSize_2col)     private var titleBaseSize_2col: Double     = TileTuningDefaults.titleBaseSize_2col
    @AppStorage(TileTuningKey.titleBaseSize_3col)     private var titleBaseSize_3col: Double     = TileTuningDefaults.titleBaseSize_3col
    @AppStorage(TileTuningKey.titleHPadding_2col)     private var titleHPadding_2col: Double     = TileTuningDefaults.titleHPadding_2col
    @AppStorage(TileTuningKey.titleHPadding_3col)     private var titleHPadding_3col: Double     = TileTuningDefaults.titleHPadding_3col
    @AppStorage(TileTuningKey.titleTracking_2col)     private var titleTracking_2col: Double     = TileTuningDefaults.titleTracking_2col
    @AppStorage(TileTuningKey.titleTracking_3col)     private var titleTracking_3col: Double     = TileTuningDefaults.titleTracking_3col
    @AppStorage(TileTuningKey.titleLineSpacing_2col)  private var titleLineSpacing_2col: Double  = TileTuningDefaults.titleLineSpacing_2col
    @AppStorage(TileTuningKey.titleLineSpacing_3col)  private var titleLineSpacing_3col: Double  = TileTuningDefaults.titleLineSpacing_3col
    @AppStorage(TileTuningKey.titleLineLimit_2col)    private var titleLineLimit_2col: Int       = TileTuningDefaults.titleLineLimit_2col
    @AppStorage(TileTuningKey.titleLineLimit_3col)    private var titleLineLimit_3col: Int       = TileTuningDefaults.titleLineLimit_3col
    @AppStorage(TileTuningKey.titleMinScale_2col)     private var titleMinScale_2col: Double     = TileTuningDefaults.titleMinScale_2col
    @AppStorage(TileTuningKey.titleMinScale_3col)     private var titleMinScale_3col: Double     = TileTuningDefaults.titleMinScale_3col
    @AppStorage(TileTuningKey.titleMaxScale_2col)     private var titleMaxScale_2col: Double     = TileTuningDefaults.titleMaxScale_2col
    @AppStorage(TileTuningKey.titleMaxScale_3col)     private var titleMaxScale_3col: Double     = TileTuningDefaults.titleMaxScale_3col
    @AppStorage(TileTuningKey.titleAnchor_3col)       private var titleAnchorRaw_3col: String    = TileTuningDefaults.titleAnchor_3col
    // Deck (2-col only)
    @AppStorage(TileTuningKey.deckBaseSize_2col)      private var deckBaseSize_2col: Double      = TileTuningDefaults.deckBaseSize_2col
    @AppStorage(TileTuningKey.deckTracking_2col)      private var deckTracking_2col: Double      = TileTuningDefaults.deckTracking_2col
    @AppStorage(TileTuningKey.deckLineSpacing_2col)   private var deckLineSpacing_2col: Double   = TileTuningDefaults.deckLineSpacing_2col
    @AppStorage(TileTuningKey.deckLineLimit_2col)     private var deckLineLimit_2col: Int        = TileTuningDefaults.deckLineLimit_2col
    // Meta (2-col only)
    @AppStorage(TileTuningKey.metaBaseSize_2col)      private var metaBaseSize_2col: Double      = TileTuningDefaults.metaBaseSize_2col
    @AppStorage(TileTuningKey.metaTracking_2col)      private var metaTracking_2col: Double      = TileTuningDefaults.metaTracking_2col
    // Spacing
    @AppStorage(TileTuningKey.spacingDatelineToTitle_2col) private var spacingDatelineToTitle_2col: Double = TileTuningDefaults.spacingDatelineToTitle_2col
    @AppStorage(TileTuningKey.spacingTitleToDeck_2col)     private var spacingTitleToDeck_2col: Double     = TileTuningDefaults.spacingTitleToDeck_2col
    @AppStorage(TileTuningKey.spacingDeckToTags_2col)      private var spacingDeckToTags_2col: Double      = TileTuningDefaults.spacingDeckToTags_2col
    @AppStorage(TileTuningKey.bottomPadding_2col)          private var bottomPadding_2col: Double          = TileTuningDefaults.bottomPadding_2col
    @AppStorage(TileTuningKey.bottomPadding_3col)          private var bottomPadding_3col: Double          = TileTuningDefaults.bottomPadding_3col
    // Hairline
    @AppStorage(TileTuningKey.hairlineOpacity_2col)        private var hairlineOpacity_2col: Double        = TileTuningDefaults.hairlineOpacity_2col
    // Gradient
    @AppStorage(TileTuningKey.gradientCircleScale_2col)    private var gradientCircleScale_2col: Double    = TileTuningDefaults.gradientCircleScale_2col
    @AppStorage(TileTuningKey.gradientCircleScale_3col)    private var gradientCircleScale_3col: Double    = TileTuningDefaults.gradientCircleScale_3col
    @AppStorage(TileTuningKey.gradientBlurScale_2col)      private var gradientBlurScale_2col: Double      = TileTuningDefaults.gradientBlurScale_2col
    @AppStorage(TileTuningKey.gradientBlurScale_3col)      private var gradientBlurScale_3col: Double      = TileTuningDefaults.gradientBlurScale_3col
    @AppStorage(TileTuningKey.gradientOffsetScale_2col)    private var gradientOffsetScale_2col: Double    = TileTuningDefaults.gradientOffsetScale_2col
    @AppStorage(TileTuningKey.gradientOffsetScale_3col)    private var gradientOffsetScale_3col: Double    = TileTuningDefaults.gradientOffsetScale_3col
    @AppStorage(TileTuningKey.gradientVignette_2col)       private var gradientVignette_2col: Double       = TileTuningDefaults.gradientVignette_2col
    @AppStorage(TileTuningKey.gradientVignette_3col)       private var gradientVignette_3col: Double       = TileTuningDefaults.gradientVignette_3col

    // Density currently being edited. Stays local — re-opening the widget
    // resumes on whatever density was last shown.
    @State private var density: Density = .threeCol
    // Selected param key. Defaults to the first param of the current
    // density (Hero %). Flipping density remaps to the equivalent key in
    // the new density when one exists.
    @State private var selectedKey: String = TileTuningKey.heroPercent_3col
    // Live drag delta; committed into `position` on .onEnded.
    @GestureState private var dragTranslation: CGSize = .zero
    // True for ~1.2s after a successful Copy values tap — swaps the
    // clipboard icon for a checkmark so Tom sees the export landed.
    @State private var justCopied: Bool = false

    private enum Density: String, CaseIterable {
        case twoCol = "2-col"
        case threeCol = "3-col"
    }
    private var isTwoCol: Bool { density == .twoCol }

    private static let widgetWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 8) {
            header
            densityToggle
            paramChip
            controlRow
        }
        .padding(12)
        .frame(width: Self.widgetWidth)
        .modifier(WidgetSurface())
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        .offset(x: position.width + dragTranslation.width,
                y: position.height + dragTranslation.height)
    }

    // MARK: - Header (drag handle + close)

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
        // Drag lives on the header only — putting it on the whole widget
        // would fight the slider's own gesture. Familiar pattern from
        // floating panels (PiP, Stage Manager).
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

    // MARK: - Density toggle

    private var densityToggle: some View {
        Picker("Density", selection: $density) {
            ForEach(Density.allCases, id: \.self) { d in
                Text(d.rawValue).tag(d)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: density) { _, new in
            selectedKey = Self.remappedKey(from: selectedKey, to: new)
        }
    }

    // MARK: - Param chip (Menu)

    private var paramChip: some View {
        Menu {
            ForEach(ParamSection.allCases, id: \.self) { section in
                let items = currentParams.filter { $0.section == section }
                if !items.isEmpty {
                    Section(section.rawValue) {
                        ForEach(items, id: \.key) { p in
                            Button {
                                selectedKey = p.key
                            } label: {
                                Text(p.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedParamLabel)
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
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Control row (slider / segmented swap)

    @ViewBuilder
    private var controlRow: some View {
        if selectedKey == TileTuningKey.titleAnchor_3col {
            Picker("Anchor", selection: $titleAnchorRaw_3col) {
                ForEach(TileTitleAnchor.allCases, id: \.rawValue) { a in
                    Text(a.label).tag(a.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 32)
        } else if let int = currentIntBinding(), let p = currentParamDef(), case .stepper(let r) = p.control {
            Slider(value: intToDoubleBinding(int), in: Double(r.lowerBound)...Double(r.upperBound), step: 1)
                .frame(height: 32)
        } else if let d = currentDoubleBinding(), let p = currentParamDef(), case .slider(let r, let step, _) = p.control {
            Slider(value: d, in: r, step: step)
                .frame(height: 32)
        } else {
            // Selected key has no binding — shouldn't happen if metadata
            // is in sync with @AppStorage. Render an empty placeholder so
            // the widget keeps its shape.
            Color.clear.frame(height: 32)
        }
    }

    // MARK: - Param metadata

    private enum ParamSection: String, CaseIterable, Hashable {
        case hero = "Hero"
        case title = "Title"
        case titlePlacement = "Placement"
        case deck = "Deck"
        case meta = "Meta"
        case spacing = "Spacing"
        case gradient = "Gradient"
    }

    private struct ParamDef: Hashable {
        let key: String
        let label: String        // human label (UI: chip, Menu entries)
        let exportLabel: String  // snake/camel label used in the copy-export
        let section: ParamSection
        let control: Control

        enum Control: Hashable {
            case slider(range: ClosedRange<Double>, step: Double, format: String)
            case stepper(range: ClosedRange<Int>)
            case anchor

            static func == (lhs: Control, rhs: Control) -> Bool {
                switch (lhs, rhs) {
                case let (.slider(r1, s1, f1), .slider(r2, s2, f2)):
                    return r1 == r2 && s1 == s2 && f1 == f2
                case let (.stepper(r1), .stepper(r2)):
                    return r1 == r2
                case (.anchor, .anchor):
                    return true
                default:
                    return false
                }
            }

            func hash(into hasher: inout Hasher) {
                switch self {
                case let .slider(r, s, f):
                    hasher.combine(0); hasher.combine(r.lowerBound); hasher.combine(r.upperBound); hasher.combine(s); hasher.combine(f)
                case let .stepper(r):
                    hasher.combine(1); hasher.combine(r.lowerBound); hasher.combine(r.upperBound)
                case .anchor:
                    hasher.combine(2)
                }
            }
        }
    }

    private static let twoColParams: [ParamDef] = [
        .init(key: TileTuningKey.heroPercent_2col,            label: "Hero %",             exportLabel: "hero_percent",            section: .hero,    control: .slider(range: 0.30...0.65, step: 0.01, format: "%.2f")),
        .init(key: TileTuningKey.heroBottomPadding_2col,      label: "Hero bottom gap",    exportLabel: "hero_bottomPadding",      section: .hero,    control: .slider(range: 0...40,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleBaseSize_2col,          label: "Title size",         exportLabel: "title_baseSize",          section: .title,   control: .slider(range: 10...40,     step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleHPadding_2col,          label: "Title H pad",        exportLabel: "title_hPadding",          section: .title,   control: .slider(range: 0...48,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleTracking_2col,          label: "Title tracking",     exportLabel: "title_tracking",          section: .title,   control: .slider(range: -0.8...0.4,  step: 0.05, format: "%.2f")),
        .init(key: TileTuningKey.titleLineSpacing_2col,       label: "Title line spacing", exportLabel: "title_lineSpacing",       section: .title,   control: .slider(range: 0...20,      step: 0.5,  format: "%.1f")),
        .init(key: TileTuningKey.titleLineLimit_2col,         label: "Title line limit",   exportLabel: "title_lineLimit",         section: .title,   control: .stepper(range: 1...6)),
        .init(key: TileTuningKey.titleMinScale_2col,          label: "Title min scale",    exportLabel: "title_minScale",          section: .title,   control: .slider(range: 0.50...1.0,  step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.titleMaxScale_2col,          label: "Title max scale",    exportLabel: "title_maxScale",          section: .title,   control: .slider(range: 1.0...2.0,   step: 0.05, format: "%.2f")),
        .init(key: TileTuningKey.deckBaseSize_2col,           label: "Deck size",          exportLabel: "deck_baseSize",           section: .deck,    control: .slider(range: 8...24,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.deckTracking_2col,           label: "Deck tracking",      exportLabel: "deck_tracking",           section: .deck,    control: .slider(range: -0.5...0.5,  step: 0.05, format: "%.2f")),
        .init(key: TileTuningKey.deckLineSpacing_2col,        label: "Deck line spacing",  exportLabel: "deck_lineSpacing",        section: .deck,    control: .slider(range: 0...12,      step: 0.5,  format: "%.1f")),
        .init(key: TileTuningKey.deckLineLimit_2col,          label: "Deck line limit",    exportLabel: "deck_lineLimit",          section: .deck,    control: .stepper(range: 1...6)),
        .init(key: TileTuningKey.metaBaseSize_2col,           label: "Meta size",          exportLabel: "meta_baseSize",           section: .meta,    control: .slider(range: 6...18,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.metaTracking_2col,           label: "Meta tracking",      exportLabel: "meta_tracking",           section: .meta,    control: .slider(range: 0...4.0,     step: 0.1,  format: "%.2f")),
        .init(key: TileTuningKey.spacingDatelineToTitle_2col, label: "Dateline → Title",   exportLabel: "spacing_datelineToTitle", section: .spacing, control: .slider(range: 0...32,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.spacingTitleToDeck_2col,     label: "Title → Deck",       exportLabel: "spacing_titleToDeck",     section: .spacing, control: .slider(range: 0...24,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.spacingDeckToTags_2col,      label: "Deck → Tags min",    exportLabel: "spacing_deckToTags",      section: .spacing, control: .slider(range: 0...48,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.bottomPadding_2col,          label: "Bottom pad",         exportLabel: "bottom_padding",          section: .spacing, control: .slider(range: 0...40,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.hairlineOpacity_2col,        label: "Hairline opacity",   exportLabel: "hairline_opacity",        section: .spacing, control: .slider(range: 0...0.5,     step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientCircleScale_2col,    label: "Gradient circles",   exportLabel: "gradient_circleScale",    section: .gradient, control: .slider(range: 0.3...1.2, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientBlurScale_2col,      label: "Gradient blur",      exportLabel: "gradient_blurScale",      section: .gradient, control: .slider(range: 0.3...1.5, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientOffsetScale_2col,    label: "Gradient spread",    exportLabel: "gradient_offsetScale",    section: .gradient, control: .slider(range: 0.3...1.2, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientVignette_2col,       label: "Gradient vignette",  exportLabel: "gradient_vignette",       section: .gradient, control: .slider(range: 0.0...1.0, step: 0.02, format: "%.2f"))
    ]

    private static let threeColParams: [ParamDef] = [
        .init(key: TileTuningKey.heroPercent_3col,        label: "Hero %",             exportLabel: "hero_percent",       section: .hero,           control: .slider(range: 0.30...0.65, step: 0.01, format: "%.2f")),
        .init(key: TileTuningKey.heroBottomPadding_3col,  label: "Hero bottom gap",    exportLabel: "hero_bottomPadding", section: .hero,           control: .slider(range: 0...40,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleBaseSize_3col,      label: "Title size",         exportLabel: "title_baseSize",     section: .title,          control: .slider(range: 10...40,     step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleHPadding_3col,      label: "Title H pad",        exportLabel: "title_hPadding",     section: .title,          control: .slider(range: 0...48,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.titleTracking_3col,      label: "Title tracking",     exportLabel: "title_tracking",     section: .title,          control: .slider(range: -0.8...0.4,  step: 0.05, format: "%.2f")),
        .init(key: TileTuningKey.titleLineSpacing_3col,   label: "Title line spacing", exportLabel: "title_lineSpacing",  section: .title,          control: .slider(range: 0...20,      step: 0.5,  format: "%.1f")),
        .init(key: TileTuningKey.titleLineLimit_3col,     label: "Title line limit",   exportLabel: "title_lineLimit",    section: .title,          control: .stepper(range: 1...6)),
        .init(key: TileTuningKey.titleMinScale_3col,      label: "Title min scale",    exportLabel: "title_minScale",     section: .title,          control: .slider(range: 0.50...1.0,  step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.titleMaxScale_3col,      label: "Title max scale",    exportLabel: "title_maxScale",     section: .title,          control: .slider(range: 1.0...2.0,   step: 0.05, format: "%.2f")),
        .init(key: TileTuningKey.titleAnchor_3col,        label: "Title anchor",       exportLabel: "title_anchor",       section: .titlePlacement, control: .anchor),
        .init(key: TileTuningKey.bottomPadding_3col,      label: "Bottom pad",         exportLabel: "bottom_padding",     section: .spacing,        control: .slider(range: 0...40,      step: 1,    format: "%.0f")),
        .init(key: TileTuningKey.gradientCircleScale_3col, label: "Gradient circles",  exportLabel: "gradient_circleScale", section: .gradient,      control: .slider(range: 0.3...1.2, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientBlurScale_3col,   label: "Gradient blur",     exportLabel: "gradient_blurScale",   section: .gradient,      control: .slider(range: 0.3...1.5, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientOffsetScale_3col, label: "Gradient spread",   exportLabel: "gradient_offsetScale", section: .gradient,      control: .slider(range: 0.3...1.2, step: 0.02, format: "%.2f")),
        .init(key: TileTuningKey.gradientVignette_3col,    label: "Gradient vignette", exportLabel: "gradient_vignette",    section: .gradient,      control: .slider(range: 0.0...1.0, step: 0.02, format: "%.2f"))
    ]

    private var currentParams: [ParamDef] {
        isTwoCol ? Self.twoColParams : Self.threeColParams
    }

    private func currentParamDef() -> ParamDef? {
        currentParams.first(where: { $0.key == selectedKey })
    }

    private var selectedParamLabel: String {
        currentParamDef()?.label ?? "—"
    }

    private var selectedValueString: String {
        guard let p = currentParamDef() else { return "" }
        switch p.control {
        case .slider(_, _, let format):
            if let d = currentDoubleBinding() {
                return String(format: format, d.wrappedValue)
            }
            return ""
        case .stepper:
            if let i = currentIntBinding() {
                return "\(i.wrappedValue)"
            }
            return ""
        case .anchor:
            return TileTitleAnchor(rawValue: titleAnchorRaw_3col)?.label ?? ""
        }
    }

    // Remap a selected key when the density toggle flips. Tries the
    // equivalent slot in the new density (heroPercent_2col → heroPercent_3col);
    // falls back to the first param of the new density when no counterpart
    // exists (e.g. deck/meta/dateline-spacing don't live in 3-col).
    private static func remappedKey(from oldKey: String, to newDensity: Density) -> String {
        let newSuffix: String
        let oldSuffix: String
        switch newDensity {
        case .twoCol:    newSuffix = "_2col"; oldSuffix = "_3col"
        case .threeCol:  newSuffix = "_3col"; oldSuffix = "_2col"
        }
        let params = (newDensity == .twoCol) ? twoColParams : threeColParams
        if oldKey.hasSuffix(oldSuffix) {
            let base = String(oldKey.dropLast(oldSuffix.count))
            let candidate = base + newSuffix
            if params.contains(where: { $0.key == candidate }) {
                return candidate
            }
        }
        return params.first?.key ?? oldKey
    }

    // MARK: - Binding lookup by key
    // @AppStorage gives back a `Binding` via the `$` prefix but only by
    // name. Map dynamic key → static binding via this switch. The currently
    // selected key uses `currentDoubleBinding()` / `currentIntBinding()`;
    // the copy-export loop reads each key via `doubleBinding(forKey:)`
    // / `intBinding(forKey:)`.

    private func currentDoubleBinding() -> Binding<Double>? { doubleBinding(forKey: selectedKey) }
    private func currentIntBinding() -> Binding<Int>? { intBinding(forKey: selectedKey) }

    private func doubleBinding(forKey key: String) -> Binding<Double>? {
        switch key {
        case TileTuningKey.heroPercent_2col:             return $heroPercent_2col
        case TileTuningKey.heroPercent_3col:             return $heroPercent_3col
        case TileTuningKey.heroBottomPadding_2col:       return $heroBottomPadding_2col
        case TileTuningKey.heroBottomPadding_3col:       return $heroBottomPadding_3col
        case TileTuningKey.titleBaseSize_2col:           return $titleBaseSize_2col
        case TileTuningKey.titleBaseSize_3col:           return $titleBaseSize_3col
        case TileTuningKey.titleHPadding_2col:           return $titleHPadding_2col
        case TileTuningKey.titleHPadding_3col:           return $titleHPadding_3col
        case TileTuningKey.titleTracking_2col:           return $titleTracking_2col
        case TileTuningKey.titleTracking_3col:           return $titleTracking_3col
        case TileTuningKey.titleLineSpacing_2col:        return $titleLineSpacing_2col
        case TileTuningKey.titleLineSpacing_3col:        return $titleLineSpacing_3col
        case TileTuningKey.titleMinScale_2col:           return $titleMinScale_2col
        case TileTuningKey.titleMinScale_3col:           return $titleMinScale_3col
        case TileTuningKey.titleMaxScale_2col:           return $titleMaxScale_2col
        case TileTuningKey.titleMaxScale_3col:           return $titleMaxScale_3col
        case TileTuningKey.deckBaseSize_2col:            return $deckBaseSize_2col
        case TileTuningKey.deckTracking_2col:            return $deckTracking_2col
        case TileTuningKey.deckLineSpacing_2col:         return $deckLineSpacing_2col
        case TileTuningKey.metaBaseSize_2col:            return $metaBaseSize_2col
        case TileTuningKey.metaTracking_2col:            return $metaTracking_2col
        case TileTuningKey.spacingDatelineToTitle_2col:  return $spacingDatelineToTitle_2col
        case TileTuningKey.spacingTitleToDeck_2col:      return $spacingTitleToDeck_2col
        case TileTuningKey.spacingDeckToTags_2col:       return $spacingDeckToTags_2col
        case TileTuningKey.bottomPadding_2col:           return $bottomPadding_2col
        case TileTuningKey.bottomPadding_3col:           return $bottomPadding_3col
        case TileTuningKey.hairlineOpacity_2col:         return $hairlineOpacity_2col
        case TileTuningKey.gradientCircleScale_2col:     return $gradientCircleScale_2col
        case TileTuningKey.gradientCircleScale_3col:     return $gradientCircleScale_3col
        case TileTuningKey.gradientBlurScale_2col:       return $gradientBlurScale_2col
        case TileTuningKey.gradientBlurScale_3col:       return $gradientBlurScale_3col
        case TileTuningKey.gradientOffsetScale_2col:     return $gradientOffsetScale_2col
        case TileTuningKey.gradientOffsetScale_3col:     return $gradientOffsetScale_3col
        case TileTuningKey.gradientVignette_2col:        return $gradientVignette_2col
        case TileTuningKey.gradientVignette_3col:        return $gradientVignette_3col
        default: return nil
        }
    }

    private func intBinding(forKey key: String) -> Binding<Int>? {
        switch key {
        case TileTuningKey.titleLineLimit_2col: return $titleLineLimit_2col
        case TileTuningKey.titleLineLimit_3col: return $titleLineLimit_3col
        case TileTuningKey.deckLineLimit_2col:  return $deckLineLimit_2col
        default: return nil
        }
    }

    private func intToDoubleBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(b.wrappedValue) },
            set: { b.wrappedValue = Int($0.rounded()) }
        )
    }

    // MARK: - Copy values

    /// Reads every @AppStorage knob (both densities) and copies a
    /// plain-text snapshot to the system pasteboard. Used to report values
    /// back so the defaults table can be baked from observed-on-device
    /// numbers in a follow-up pass.
    private func copyValues() {
        var lines: [String] = []
        lines.append("2-col:")
        for p in Self.twoColParams {
            lines.append("  \(p.exportLabel): \(formattedValue(for: p))")
        }
        lines.append("")
        lines.append("3-col:")
        for p in Self.threeColParams {
            lines.append("  \(p.exportLabel): \(formattedValue(for: p))")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCopied = true
        // Detached cancellation isn't worth wiring — a stray late flip-off
        // is harmless. Plain async sleep is enough.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            justCopied = false
        }
    }

    private func formattedValue(for p: ParamDef) -> String {
        switch p.control {
        case .slider(_, _, let format):
            let v = doubleBinding(forKey: p.key)?.wrappedValue ?? 0
            return String(format: format, v)
        case .stepper:
            let v = intBinding(forKey: p.key)?.wrappedValue ?? 0
            return "\(v)"
        case .anchor:
            // Only one anchor key today (titleAnchor_3col) — read the
            // string-backed @AppStorage directly.
            return titleAnchorRaw_3col
        }
    }
}

// MARK: - WidgetSurface
// Liquid Glass on iOS 26+, .thinMaterial fallback below. Mirrors the
// `chromeSurface` helper in CanvasChrome.swift so the widget reads as
// part of the same chrome family.

private struct WidgetSurface: ViewModifier {
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
