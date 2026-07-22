// NodeGridTile.swift
// Lightweight browse primitive for the uniform-tile grid. Self-contained:
// does NOT call NodeCardView. Renders the gradient + hero + identity block
// + a type-badge manifest in place of the card's full payload strips. The
// full card stays the workspace primitive (detail / Studio / Canvas);
// this tile is the scan-the-corpus surface.
//
// One async load: the hero cover image (same resolver the card uses).
// Badge manifest is a cheap aggregate of already-loaded `node.items` —
// no file reads, no thumbnail fetches. That's the perf point.
//
// The grid cell owns shape (`.frame` + `.clipShape(14)` in NodeGridView).
// This view does NOT apply its own clip.
//
// Every layout constant in this file is sourced from a per-density tuning
// snapshot (`TileTuningValues`) backed by @AppStorage and dialed live via
// the DEBUG TileTuningPanel (see NodeGridTileTuning.swift). Once the final
// numbers settle, bake them as static constants and drop both the storage
// indirection and the tuning file.

import SwiftUI
import UIKit

struct NodeGridTile: View {
    let node: Node
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Forwarded to `NodeGradientLayer`. The grid passes `true` only at
    /// 2-col; 3 and 4-col render the gradient as a still frame to keep
    /// scrolling smooth when many blurred Circles share the viewport.
    var animateGradient: Bool = true
    /// Density driver. 2-col = editorial composition; 3-col+ = title-only.
    let columnCount: Int

    /// Drift-speed multiplier for the gradient on dense (3-col+) tiles, where
    /// the blobs are small and full-speed drift reads as shimmer. Slows them
    /// to ambient breathing. The one dial to nudge on device — T's eye is the
    /// spec on the exact value (brief suggests ~0.3–0.5).
    private static let denseGradientDriftScale: CGFloat = 0.4

    @Environment(CorpusStore.self) private var store

    // MARK: - Tuning storage (per-density, live)
    // Mirrors every key declared in TileTuningKey. The panel mutates the
    // same UserDefaults entries → these @AppStorage observers fire → every
    // visible tile re-renders. `tuning(for:)` collapses this set into a
    // single `TileTuningValues` snapshot consumed by the body.

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

    private var isEditorial: Bool { columnCount <= 2 }

    /// Per-render snapshot. The 3-col branch leaves deck/meta/spacing slots
    /// populated with their (inert) defaults so we don't need optional
    /// plumbing — the title-only path simply doesn't reference them.
    private var tuning: TileTuningValues {
        if isEditorial {
            return TileTuningValues(
                heroPercent:            CGFloat(heroPercent_2col),
                heroBottomPadding:      CGFloat(heroBottomPadding_2col),
                titleBaseSize:          CGFloat(titleBaseSize_2col),
                titleHPadding:          CGFloat(titleHPadding_2col),
                titleTracking:          CGFloat(titleTracking_2col),
                titleLineSpacing:       CGFloat(titleLineSpacing_2col),
                titleLineLimit:         titleLineLimit_2col,
                titleMinScale:          CGFloat(titleMinScale_2col),
                titleMaxScale:          CGFloat(titleMaxScale_2col),
                titleAnchor:            .top, // unused in 2-col
                deckBaseSize:           CGFloat(deckBaseSize_2col),
                deckTracking:           CGFloat(deckTracking_2col),
                deckLineSpacing:        CGFloat(deckLineSpacing_2col),
                deckLineLimit:          deckLineLimit_2col,
                metaBaseSize:           CGFloat(metaBaseSize_2col),
                metaTracking:           CGFloat(metaTracking_2col),
                spacingDatelineToTitle: CGFloat(spacingDatelineToTitle_2col),
                spacingTitleToDeck:     CGFloat(spacingTitleToDeck_2col),
                spacingDeckToTags:      CGFloat(spacingDeckToTags_2col),
                bottomPadding:          CGFloat(bottomPadding_2col),
                hairlineOpacity:        hairlineOpacity_2col,
                gradientCircleScale:    CGFloat(gradientCircleScale_2col),
                gradientBlurScale:      CGFloat(gradientBlurScale_2col),
                gradientOffsetScale:    CGFloat(gradientOffsetScale_2col),
                gradientVignette:       CGFloat(gradientVignette_2col)
            )
        } else {
            return TileTuningValues(
                heroPercent:            CGFloat(heroPercent_3col),
                heroBottomPadding:      CGFloat(heroBottomPadding_3col),
                titleBaseSize:          CGFloat(titleBaseSize_3col),
                titleHPadding:          CGFloat(titleHPadding_3col),
                titleTracking:          CGFloat(titleTracking_3col),
                titleLineSpacing:       CGFloat(titleLineSpacing_3col),
                titleLineLimit:         titleLineLimit_3col,
                titleMinScale:          CGFloat(titleMinScale_3col),
                titleMaxScale:          CGFloat(titleMaxScale_3col),
                titleAnchor:            TileTitleAnchor(rawValue: titleAnchorRaw_3col) ?? .top,
                deckBaseSize:           CGFloat(TileTuningDefaults.deckBaseSize_2col),
                deckTracking:           CGFloat(TileTuningDefaults.deckTracking_2col),
                deckLineSpacing:        CGFloat(TileTuningDefaults.deckLineSpacing_2col),
                deckLineLimit:          TileTuningDefaults.deckLineLimit_2col,
                metaBaseSize:           CGFloat(TileTuningDefaults.metaBaseSize_2col),
                metaTracking:           CGFloat(TileTuningDefaults.metaTracking_2col),
                spacingDatelineToTitle: CGFloat(TileTuningDefaults.spacingDatelineToTitle_2col),
                spacingTitleToDeck:     CGFloat(TileTuningDefaults.spacingTitleToDeck_2col),
                spacingDeckToTags:      CGFloat(TileTuningDefaults.spacingDeckToTags_2col),
                bottomPadding:          CGFloat(bottomPadding_3col),
                hairlineOpacity:        TileTuningDefaults.hairlineOpacity_2col,
                gradientCircleScale:    CGFloat(gradientCircleScale_3col),
                gradientBlurScale:      CGFloat(gradientBlurScale_3col),
                gradientOffsetScale:    CGFloat(gradientOffsetScale_3col),
                gradientVignette:       CGFloat(gradientVignette_3col)
            )
        }
    }

    /// Reserved top zone for hero-or-gradient. Hero and gradient-only tiles
    /// share one silhouette: text always starts below this height.
    private var heroZoneHeight: CGFloat { cellHeight * tuning.heroPercent }

    // Adaptive ink palette — trait-dynamic port of NodeCardView's (the tile had
    // copied NodeCardView's OLD static cream, before the card went adaptive). Dark
    // reproduces the shipped warm-cream VERBATIM (byte-identical to Solar Flare);
    // light sources from AppearancePalette.ink (#232A2E) so title/deck/meta/hairline
    // read as DARK type on the gradient's cream lower section (Cucumber Water),
    // matching the single card. Same opacities either way — the flip is coupled
    // plumbing, not a judged knob.
    private static let cream     = Color(red: 1.0, green: 0.976, blue: 0.941)
    private static let creamHair = Color(red: 1.0, green: 0.925, blue: 0.804)
    private static let inkLight: UIColor =
        UIColor(AppearancePalette.ink).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

    private static func ink(_ darkOpaque: Color, _ alpha: CGFloat) -> Color {
        let dark = UIColor(darkOpaque).withAlphaComponent(alpha)
        let light = inkLight.withAlphaComponent(alpha)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static let inkTitle = ink(cream, 0.98)
    private static let inkDeck  = ink(cream, 0.86)
    private static let inkMeta  = ink(cream, 0.68)
    // Full-alpha base; the body multiplies by `t.hairlineOpacity`.
    private static let hairlineColor = ink(creamHair, 1.0)

    // Legibility shadow behind ink. Dark: black (shipped scrim substitute —
    // byte-identical). Light: a soft WHITE halo so type separates from the
    // multiplied mid-tone pigment without smearing dark onto parchment.
    private static let inkShadow = Color(UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.black : UIColor.white
    })

    // Traveling-scrim ink. Dark: black (identical) — darkens the type bands over
    // the bright gradient. Light: clear — a dark scrim pools as dirty bands on
    // parchment; ink + halo carry legibility instead.
    private static let scrimInk = Color(UIColor {
        $0.userInterfaceStyle == .dark ? UIColor.black : UIColor.clear
    })

    // MARK: - Type scaling

    private static let minScale: CGFloat = 0.62

    /// Mirrors `NodeGridView.tileSpacing`. Duplicated rather than threaded
    /// because the tile shouldn't gain an extra plumbing parameter for one
    /// constant.
    private static let gridTileSpacing: CGFloat = 10

    /// 2-col cell width, derived from the current `cellWidth` + `columnCount`
    /// by inverting NodeGridView's sizing math. At `columnCount == 2` this
    /// equals `cellWidth`, so `scaled(_:)` lands exactly on the base sizes.
    private var referenceCellWidth: CGFloat {
        let spacing = Self.gridTileSpacing
        let containerW = cellWidth * CGFloat(columnCount) + spacing * CGFloat(columnCount + 1)
        return (containerW - spacing * 3) / 2
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        base * max(cellWidth / referenceCellWidth, Self.minScale)
    }

    /// Char-count-driven title boost in [1.0, maxScale]. Short titles get
    /// the full boost; titles past `boostCeiling` chars settle at 1.0. Per
    /// density now — caller passes the active `tuning.titleMaxScale`.
    private func titleScaleFactor(for text: String, maxScale: CGFloat) -> CGFloat {
        let chars = CGFloat(text.count)
        let boostFloor: CGFloat = 12
        let boostCeiling: CGFloat = 40
        let t = max(0, min(1, (chars - boostFloor) / (boostCeiling - boostFloor)))
        return maxScale - (maxScale - 1.0) * t
    }

    private var hasHero: Bool { node.coverImageRelativePath != nil }

    var body: some View {
        // Anchor the color blobs to the hero zone when no cover exists, so
        // a gradient-only tile and a hero tile share the same silhouette:
        // color form on top, dark text band below. Derived from the
        // current heroPercent + cellHeight — not a separate knob (yet).
        let gradientCenterY: CGFloat = hasHero
            ? 0
            : (heroZoneHeight - cellHeight) / 2
        return ZStack {
            NodeGradientLayer(
                node: node,
                circleScale:   tuning.gradientCircleScale,
                blurScale:     tuning.gradientBlurScale,
                offsetScale:   tuning.gradientOffsetScale,
                vignette:      tuning.gradientVignette,
                centerYOffset: gradientCenterY,
                animated:      animateGradient,
                // Hero tiles pool the gradient at the floor beneath the photo.
                anchor:        hasHero ? .bottom : .center,
                // Dense tiles now animate (motion is ~free on the GPU) but at
                // slowed drift so small blobs breathe rather than shimmer.
                driftSpeedScale: columnCount >= 3 ? Self.denseGradientDriftScale : 1.0
            )
            if hasHero {
                heroOverlay
            }
            travelingScrim
            identityContent
            if isEditorial {
                watermark
            }
        }
    }

    // MARK: - Hero overlay

    private var heroOverlay: some View {
        let heroHeight = heroZoneHeight
        return VStack(spacing: 0) {
            GridTileHeroImage(node: node)
                .frame(width: cellWidth, height: heroHeight)
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black,  location: 0.0),
                            .init(color: .black,  location: 0.78),
                            .init(color: .clear,  location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Spacer(minLength: 0)
        }
    }

    // MARK: - Traveling scrim

    private var travelingScrim: some View {
        // Lower clear stop pulled up from 0.80 → 0.55 so the dark band reaches
        // higher behind the bumped-up text.
        LinearGradient(
            stops: [
                .init(color: Self.scrimInk.opacity(0.42), location: 0.0),
                .init(color: Color.clear,                 location: 0.20),
                .init(color: Color.clear,                 location: 0.55),
                .init(color: Self.scrimInk.opacity(0.52), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - Identity content

    @ViewBuilder
    private var identityContent: some View {
        // Text always begins below the reserved hero zone plus the density's
        // air gap (`heroBottomPadding`) so the leading line clears the fade.
        let topInset: CGFloat = heroZoneHeight + tuning.heroBottomPadding

        if isEditorial {
            editorialContent(topInset: topInset)
        } else {
            titleOnlyContent(topInset: topInset)
        }
    }

    // MARK: 2-col editorial composition

    private func editorialContent(topInset: CGFloat) -> some View {
        let category = node.primaryTag
        let titleText = displayTitle
        let showDeck = node.descriptionOnCard && !node.summary.isEmpty
        let tagList = Array(node.tags.prefix(3))
        let t = tuning

        return VStack(alignment: .leading, spacing: 0) {
            // Dateline
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let category {
                    Text(category)
                        .font(.system(size: scaled(t.metaBaseSize), design: .serif))
                        .italic()
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(node.relativeTimestamp.uppercased())
                    .font(.system(size: scaled(t.metaBaseSize), design: .serif))
                    .tracking(t.metaTracking)
                    .foregroundColor(Self.inkMeta)
                    .lineLimit(1)
            }
            .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)

            Rectangle()
                .fill(Self.hairlineColor.opacity(t.hairlineOpacity))
                .frame(height: 0.5)
                .padding(.top, 8)
                .padding(.bottom, t.spacingDatelineToTitle)

            // Title — hyphenated via cached AttributedString so the wrap
            // looks intentional when a line ends mid-word.
            Text(HyphenatedTextCache.attributed(titleText))
                .font(.system(size: scaled(t.titleBaseSize * titleScaleFactor(for: titleText, maxScale: t.titleMaxScale)), weight: .bold, design: .serif))
                .tracking(t.titleTracking)
                .foregroundColor(Self.inkTitle)
                .shadow(color: Self.inkShadow.opacity(0.45), radius: 3, x: 0, y: 1)
                .lineSpacing(t.titleLineSpacing)
                .lineLimit(t.titleLineLimit)
                .minimumScaleFactor(t.titleMinScale)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showDeck {
                Text(HyphenatedTextCache.attributed(node.summary))
                    .font(.system(size: scaled(t.deckBaseSize), design: .serif))
                    .italic()
                    .foregroundColor(Self.inkDeck)
                    .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
                    .tracking(t.deckTracking)
                    .lineSpacing(t.deckLineSpacing)
                    .lineLimit(t.deckLineLimit)
                    .minimumScaleFactor(t.titleMinScale)
                    .multilineTextAlignment(.leading)
                    .padding(.top, t.spacingTitleToDeck)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Flex slot — pushes tags to the bottom (min gap configurable).
            Spacer(minLength: t.spacingDeckToTags)

            // Tags
            if !tagList.isEmpty {
                Rectangle()
                    .fill(Self.hairlineColor.opacity(t.hairlineOpacity))
                    .frame(height: 0.5)
                    .padding(.bottom, 10)
                Text(tagList.map { $0.uppercased() }.joined(separator: " · "))
                    .font(.system(size: scaled(t.metaBaseSize), weight: .medium, design: .serif))
                    .tracking(t.metaTracking)
                    .foregroundColor(Self.inkMeta)
                    .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, t.titleHPadding)
        .padding(.top, topInset)
        .padding(.bottom, t.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 3-col+ title-only composition

    private func titleOnlyContent(topInset: CGFloat) -> some View {
        let t = tuning
        // titleAnchor drives Spacer placement within the text zone:
        //   .top    → no leading Spacer, trailing Spacer
        //   .center → Spacer / Title / Spacer
        //   .bottom → leading Spacer, no trailing Spacer
        return VStack(spacing: 0) {
            if t.titleAnchor != .top {
                Spacer(minLength: 0)
            }
            Text(HyphenatedTextCache.attributed(displayTitle))
                .font(.system(size: scaled(t.titleBaseSize * titleScaleFactor(for: displayTitle, maxScale: t.titleMaxScale)), weight: .bold, design: .serif))
                .tracking(t.titleTracking)
                .foregroundColor(Self.inkTitle)
                .shadow(color: Self.inkShadow.opacity(0.45), radius: 3, x: 0, y: 1)
                .lineSpacing(t.titleLineSpacing)
                .lineLimit(t.titleLineLimit)
                .minimumScaleFactor(t.titleMinScale)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if t.titleAnchor != .bottom {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, t.titleHPadding)
        .padding(.top, topInset)
        .padding(.bottom, t.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Badge manifest
    // Aggregate per-payload-type content counts across all of node.items.
    // Text and rating are excluded by design.

    private struct Badge {
        let glyph: String
        let count: Int
    }

    private var badgeManifest: [Badge] {
        var images = 0
        var links = 0
        var docs = 0
        var audio = 0
        for item in node.items {
            switch item.type {
            case .imageVideo:
                images += item.mediaItems?.count ?? 0
            case .link:
                links += item.linkItems?.count ?? 0
            case .document:
                docs += item.documentItems?.count ?? 0
            case .audio:
                audio += 1
            case .text, .image, .video, .rating:
                break
            }
        }
        var result: [Badge] = []
        if images > 0 { result.append(Badge(glyph: "photo.stack", count: images)) }
        if links > 0  { result.append(Badge(glyph: "link",        count: links)) }
        if docs > 0   { result.append(Badge(glyph: "doc.text",    count: docs)) }
        if audio > 0  { result.append(Badge(glyph: "waveform",    count: audio)) }
        return result
    }

    // MARK: - Watermark

    private var watermark: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Image("NavMarkBlue")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundColor(Self.inkTitle)
                    .frame(width: 30, height: 30)
                    .opacity(0.08)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Title fallback

    private var displayTitle: String {
        if !node.title.isEmpty { return node.title }
        if let firstText = node.items.first?.content, !firstText.isEmpty { return firstText }
        return "Untitled"
    }
}

// MARK: - GridTileHeroImage
// Self-contained mirror of NodeCardView.CardHeroImage (which is private
// to that file). Same resolver path — `store.coverImageURL(for:)` — so
// card and tile stay byte-identical on what they resolve.

private struct GridTileHeroImage: View {
    let node: Node

    @Environment(CorpusStore.self) private var store
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: node.coverImageRelativePath) {
            image = nil
            guard node.coverImageRelativePath != nil,
                  let url = await store.coverImageURL(for: node) else { return }
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else { return nil }
                return img
            }.value
            if let decoded { image = decoded }
        }
    }
}

// MARK: - HyphenatedTextCache
// Process-wide memo of the AttributedString produced for each source
// string. Hyphenation via Unicode soft hyphens (U+00AD) inserted at
// OS-computed hyphenation points; SwiftUI Text honors them at wrap time.
// Per-render computation across a scrolling LazyVGrid of 30–50 tiles is
// measurable; this cache makes each unique title cost a one-time hit,
// then reads are dictionary lookups.
//
// Cache is unbounded — typical AirPad corpora are a few thousand nodes,
// so worst-case footprint is bounded and small. MainActor-isolated since
// SwiftUI bodies run on the main actor; no locking needed.

@MainActor
enum HyphenatedTextCache {
    private static var cache: [String: AttributedString] = [:]

    static func attributed(_ source: String) -> AttributedString {
        if let cached = cache[source] { return cached }
        let value = make(source)
        cache[source] = value
        return value
    }

    private static func make(_ source: String) -> AttributedString {
        AttributedString(insertingSoftHyphens(source))
    }

    private static func insertingSoftHyphens(_ source: String) -> String {
        guard !source.isEmpty else { return source }
        let locale: CFLocale = CFLocaleCopyCurrent()
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return source }

        // Only hyphenate words at/above this length. Short words wrap fine
        // at spaces; hyphenating them produces awkward breaks like
        // "Sex Jour-nal" when "Sex" / "Journal" would be cleaner.
        let minHyphenatedLength = 10

        // Split into alternating whitespace/word runs, preserving exact
        // whitespace so re-joining is lossless.
        var runs: [Substring] = []
        var startIdx = source.startIndex
        var prevWS = source.first?.isWhitespace ?? false
        for idx in source.indices {
            let isWS = source[idx].isWhitespace
            if isWS != prevWS {
                runs.append(source[startIdx..<idx])
                startIdx = idx
                prevWS = isWS
            }
        }
        runs.append(source[startIdx...])

        return runs.map { run -> String in
            guard let first = run.first, !first.isWhitespace,
                  run.count >= minHyphenatedLength else {
                return String(run)
            }
            return hyphenateWord(String(run), locale: locale)
        }.joined()
    }

    /// Position-walking soft-hyphen insertion for a single word. Called
    /// only for words at/above `minHyphenatedLength`; short words flow
    /// through `insertingSoftHyphens` unchanged.
    private static func hyphenateWord(_ word: String, locale: CFLocale) -> String {
        let cf = word as CFString
        let length = CFStringGetLength(cf)
        guard length > 1 else { return word }
        let range = CFRange(location: 0, length: length)

        var positions: [Int] = []
        var pivot = length - 1
        while pivot > 0 {
            let loc = CFStringGetHyphenationLocationBeforeIndex(cf, pivot, range, 0, locale, nil)
            if loc == kCFNotFound || loc <= 0 || loc >= pivot { break }
            positions.append(loc)
            pivot = loc
        }
        guard !positions.isEmpty else { return word }

        var result = word
        for cfIndex in positions {
            guard
                let utf16Idx = result.utf16.index(result.utf16.startIndex,
                                                  offsetBy: cfIndex,
                                                  limitedBy: result.utf16.endIndex),
                let stringIdx = String.Index(utf16Idx, within: result)
            else { continue }
            result.insert("\u{00AD}", at: stringIdx)
        }
        return result
    }
}
