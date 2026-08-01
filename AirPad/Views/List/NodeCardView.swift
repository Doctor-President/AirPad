// NodeCardView.swift
// Editorial 5:7 card face — full-bleed NodeGradientLayer + optional hero,
// dateline · serif title · deck · inline small-caps tags.
// Preserves the struct's interface and selection chrome.

import SwiftUI
import UIKit

// Non-optional Color hex initializer for palette colors
extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&int) else {
            self = .clear
            return
        }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

struct NodeCardView: View {
    // R2 — the card observes the store itself so in-place mutations to
    // its node trigger a re-render without waiting for the list to
    // recycle. Mirrors NodeDetailView's pattern: keep the ID, look up
    // the live Node in `body`, fall back to the snapshot only if the
    // node has been deleted.
    let nodeID: String
    let fallbackNode: Node
    /// Grid context disables this — many tiny cards bouncing on viewport
    /// entry reads as noise. Default keeps carousel behavior unchanged.
    var animateEntry: Bool = true
    /// Which full-card surface this face renders in — selects the per-
    /// presentation tuning values (hero-zone / font / text-opacity) via
    /// `CardTuning`. Defaults to `.carousel` to preserve the memberwise-
    /// init call shape at existing sites.
    var presentation: CardPresentation = .carousel

    // CardTuning dials. DEBUG: live @AppStorage — the DEBUG-only CardTuningPanel
    // (CoverFlow / VerticalScroll) dials them. RELEASE: plain constants set to
    // CardTuningDefaults with ZERO UserDefaults access (mirrors 725a646), so a
    // device carrying stale Debug-dialed keys no longer drifts on reinstall, and
    // a fresh install is unchanged (it always fell through to these defaults).
    #if DEBUG
    @AppStorage private var heroFraction: Double
    @AppStorage private var fontScale: Double
    @AppStorage private var textOpacity: Double
    #else
    private let heroFraction: Double
    private let fontScale: Double
    private let textOpacity: Double
    #endif

    private var hero: CGFloat { CGFloat(heroFraction) }
    private var fs: CGFloat { CGFloat(fontScale) }

    init(nodeID: String,
         fallbackNode: Node,
         animateEntry: Bool = true,
         presentation: CardPresentation = .carousel) {
        self.nodeID = nodeID
        self.fallbackNode = fallbackNode
        self.animateEntry = animateEntry
        self.presentation = presentation
        #if DEBUG
        _heroFraction = AppStorage(wrappedValue: CardTuningDefaults.value(presentation, .heroZone),
                                   CardTuningKey.key(presentation, .heroZone))
        _fontScale = AppStorage(wrappedValue: CardTuningDefaults.value(presentation, .fontScale),
                                CardTuningKey.key(presentation, .fontScale))
        _textOpacity = AppStorage(wrappedValue: CardTuningDefaults.value(presentation, .textOpacity),
                                  CardTuningKey.key(presentation, .textOpacity))
        #else
        heroFraction = CardTuningDefaults.value(presentation, .heroZone)
        fontScale    = CardTuningDefaults.value(presentation, .fontScale)
        textOpacity  = CardTuningDefaults.value(presentation, .textOpacity)
        #endif
    }

    @Environment(CorpusStore.self) private var store
    @State private var appeared = false

    private var node: Node {
        store.nodes.first(where: { $0.id == nodeID }) ?? fallbackNode
    }

    // Ink palette — trait-dynamic so text reads in BOTH rooms. Dark reproduces
    // the shipped warm-cream VERBATIM (byte-identical to Solar Flare); light
    // sources from the shipped light ink (AppearancePalette.ink, #232A2E) so
    // titles/decks/meta read on Cucumber-Water parchment. Same opacities either
    // way — the ink flip is coupled plumbing, not a judged knob. Built via a
    // trait UIColor (the AppearancePalette convention); the dark UIColor is the
    // exact SwiftUI cream round-tripped through UIColor so dark stays identical.
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
    private static let hairline = ink(creamHair, 0.22)

    // Legibility shadow behind ink. Dark: black (the shipped scrim substitute —
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

    private static let cornerRadius: CGFloat = 30

    // R6 — raised-panel float cue, copied from the Note panel's rim treatment
    // (TextEntryBody.Panel) and extended with a faint specular sheen. Two
    // intensities, dial on device. Keep faint: the gradient art stays the hero.
    private static let rimOpacity: Double = 0.24    // top-edge white rim light
    private static let sheenOpacity: Double = 0.14  // specular top sheen
    private static let rimWidth: CGFloat = 1.5       // rim hairline width

    var body: some View {
        if animateEntry {
            cardBody
                .transition(.scale(scale: 0.85, anchor: .center).combined(with: .opacity))
                .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: appeared)
                .onAppear { appeared = true }
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        // Selection affordance (checkmark + Klein outline) is applied by the
        // shared `.selectionHighlight` modifier at the call site (BUG 10), not
        // rendered here — this face is selection-agnostic.
        HStack(spacing: 12) {
            GeometryReader { geo in
                let hasHero = node.coverImageRelativePath != nil
                // Anchor the color blobs to the hero zone when no cover exists
                // so a gradient-only card and a hero card share the same
                // silhouette: color form on top, dark text band below. Mirrors
                // NodeGridTile's resolver — same heroPercent (0.42) the
                // editorial topInset uses, so the gradient and the title band
                // stay in sync.
                let heroZoneHeight = geo.size.height * hero
                let gradientCenterY: CGFloat = hasHero
                    ? 0
                    : (heroZoneHeight - geo.size.height) / 2
                ZStack {
                    // Hero-image cards anchor the gradient to the floor so the
                    // color pools beneath the photo instead of washing up into
                    // it. No-hero cards keep the full-bleed centered look.
                    NodeGradientLayer(node: node,
                                      centerYOffset: gradientCenterY,
                                      anchor: hasHero ? .bottom : .center)
                    if hasHero {
                        heroOverlay(width: geo.size.width, height: geo.size.height)
                    }
                    travelingScrim
                    editorialContent(cardHeight: geo.size.height)
                    sheen
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                // R6 — top-edge rim light (float cue). Brightest along the
                // upper edge, fading down the sides, so the face reads as a
                // raised panel catching ambient light from above.
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(Self.rimOpacity), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: Self.rimWidth
                        )
                        .allowsHitTesting(false)
                )
                // Warm, appearance-adaptive lift — shared AppearancePalette
                // token (dark = the shipped black@0.32, byte-identical; light =
                // warm brown-gray on parchment). The grid tiles reuse the same
                // token so carousel + grid can't drift.
                .shadow(color: AppearancePalette.cardShadow, radius: 12, x: 0, y: 4)
            }
        }
    }

    // MARK: - Hero overlay

    @ViewBuilder
    private func heroOverlay(width: CGFloat, height: CGFloat) -> some View {
        let heroHeight = height * hero
        VStack(spacing: 0) {
            CardHeroImage(node: node)
                .equatable()
                .frame(width: width, height: heroHeight)
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
    // Vertical gradient that darkens only the very top and very bottom
    // (where type sits) and fades to nothing across the middle so the
    // gradient still breathes. Strength is an on-device dial.

    private var travelingScrim: some View {
        LinearGradient(
            stops: [
                .init(color: Self.scrimInk.opacity(0.42), location: 0.0),
                .init(color: Color.clear,                 location: 0.20),
                .init(color: Color.clear,                 location: 0.80),
                .init(color: Self.scrimInk.opacity(0.52), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - Specular sheen
    // R6 — a faint glassy highlight concentrated at the very top edge, fading
    // out fast so it re-lights the top of the raised panel without washing the
    // gradient art. Pairs with the top-edge rim light for the float cue.

    private var sheen: some View {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(Self.sheenOpacity),        location: 0.0),
                .init(color: Color.white.opacity(Self.sheenOpacity * 0.35), location: 0.12),
                .init(color: Color.clear,                                   location: 0.40)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - Editorial content

    private func editorialContent(cardHeight: CGFloat) -> some View {
        let category = node.primaryTag
        let titleText = displayTitle
        let showDeck = node.descriptionOnCard && !node.summary.isEmpty
        let tagList = Array(node.tags.prefix(3))
        // Reserve the SAME hero zone whether or not a hero exists, so the
        // title always sits below the color band (gradientCenterY in the
        // ZStack rides the same fraction). Parity with NodeGridTile.
        let topInset: CGFloat = cardHeight * hero + 18

        // Entry-stream partition. Atomics are normalized to the contiguous
        // front of `node.items`; foldIndex is guaranteed ≥ atomicCount.
        // Clamped defensively for the case where a legacy node decoded
        // with foldIndex=0 but has atomics — keeps slicing safe.
        let atomics = Array(node.items.prefix(while: { $0.type.isAtomic }))
        let atomicCount = atomics.count
        let foldIdx = min(max(node.effectiveFoldIndex, atomicCount), node.items.count)
        let payloads = Array(node.items[atomicCount..<foldIdx])
        let hasFoldedPayload = !payloads.isEmpty

        let preBodyGap: CGFloat = 12     // gap the old `Spacer(minLength: 12)` carried
        let postStatGap: CGFloat = atomicCount > 0 ? 8 : 0

        return VStack(alignment: .leading, spacing: 0) {
            // Dateline row
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let category {
                    Text(category)
                        .font(.system(size: 12 * fs, design: .serif))
                        .italic()
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(node.relativeTimestamp.uppercased())
                    .font(.system(size: 10 * fs, design: .serif))
                    .tracking(2.2)
                    .foregroundColor(Self.inkMeta)
                    .lineLimit(1)
            }
            .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)

            Rectangle()
                .fill(Self.hairline)
                .frame(height: 0.5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            // Title
            Text(titleText)
                .font(.system(size: 23 * fs, weight: .bold, design: .serif))
                .tracking(-0.35)
                .foregroundColor(Self.inkTitle)
                .shadow(color: Self.inkShadow.opacity(0.45), radius: 3, x: 0, y: 1)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if showDeck {
                if hasFoldedPayload {
                    // Folded entries own the flex slot below — keep the deck a
                    // capped 3-line lede so the body has room.
                    Text(node.summary)
                        .font(.system(size: 14 * fs, design: .serif))
                        .italic()
                        .foregroundColor(Self.inkDeck)
                        .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .padding(.top, 8)
                } else {
                    // R3: nothing folded → the deck fills the body via the same
                    // line-fit math as the payload forms (fill to the last full
                    // line that fits, tail-truncate). fitLinesText is a greedy
                    // GeometryReader, so it claims the flex slot the empty body
                    // GeometryReader used to hold — stat line + tags still pin
                    // to the bottom.
                    fitLinesText(
                        node.summary,
                        fontSize: 14 * fs,
                        italic: true,
                        lineSpacing: 3,
                        color: Self.inkDeck,
                        shadowOpacity: 0.4
                    )
                    .padding(.top, 8)
                }
            }

            // Entry stream — replaces the old `Spacer(minLength: 12)`.
            // Order: stat line (atomic prefix) → greedy-filled payload
            // stream against MEASURED leftover space → "+N more".
            // The GeometryReader takes the flexible slot, anchoring tags
            // to the bottom the same way the original spacer did.
            Spacer().frame(height: preBodyGap)

            if atomicCount > 0 {
                statLineView(atomics)
                    .padding(.bottom, postStatGap)
            }

            if hasFoldedPayload {
                // Selection (fitPayloads) runs at minimum footprints — no
                // feedback loop. After selection, elastic entries (.text,
                // .audio's transcript) flex to fill leftover slack via
                // `.frame(maxHeight: .infinity)`; rigid entries hold their
                // declared footprint. Multiple elastic entries share the
                // slack through SwiftUI's natural flex.
                GeometryReader { proxy in
                    let fit = Self.fitPayloads(payloads, budget: proxy.size.height)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(fit.rendered) { item in
                            payloadForm(for: item)
                                .frame(maxWidth: .infinity,
                                       maxHeight: Self.isElastic(item.type) ? .infinity : Self.payloadFootprint(for: item.type),
                                       alignment: .topLeading)
                        }
                        if fit.overflowCount > 0 {
                            overflowLine(fit.overflowCount)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .clipped()
            } else if !showDeck {
                // No deck to fill and nothing folded: hold the flex slot so the
                // tags still pin to the bottom (preserves the title-only layout).
                Spacer(minLength: 0)
            }

            // Tags row
            if !tagList.isEmpty {
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 0.5)
                    .padding(.bottom, 10)
                Text(tagList.map { $0.uppercased() }.joined(separator: " · "))
                    .font(.system(size: 10 * fs, weight: .medium, design: .serif))
                    .tracking(2.0)
                    .foregroundColor(Self.inkMeta)
                    .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, topInset)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Text-opacity dial — multiplies the whole editorial block (default
        // 1.0 = identical). Faint hairlines/shadows ride along, acceptable
        // for a face-tuning knob.
        .opacity(textOpacity)
    }

    // MARK: - Entry stream — stat line, payload card-forms, overflow

    /// Atomic prefix flowed onto one middot-separated line. Today the only
    /// atomic type is `.rating` (rendered as filled/empty stars to
    /// `rating.value` / `rating.scale`, mirroring `RatingAttributeRow` in
    /// NodeDetailView). Cook time / serves will slot in here as additional
    /// `case` branches in `atomicGlyph(_:)` when they ship.
    @ViewBuilder
    private func statLineView(_ atomics: [NodeItem]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(atomics.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 {
                    Text("·")
                        .font(.system(size: 12, design: .serif))
                        .foregroundColor(Self.inkMeta)
                }
                atomicGlyph(item)
            }
            Spacer(minLength: 0)
        }
        .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private func atomicGlyph(_ item: NodeItem) -> some View {
        switch item.type {
        case .rating:
            let rating = item.rating ?? Rating(value: 0)
            HStack(spacing: 2) {
                ForEach(0..<rating.scale, id: \.self) { idx in
                    let filled = idx < rating.value
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(Self.inkMeta)
                }
            }
        case .field:
            fieldGlyph(item)
        default:
            EmptyView()
        }
    }

    /// Stage 5.1 — the card stat-line glyph for a `.field` atomic. Resolves the
    /// corpus-level definition; a rating-kind field in the star style renders
    /// stars (mirroring the legacy `.rating` glyph), every other kind renders
    /// the shared formatter's compact value. Unfilled value / orphaned
    /// definition → renders nothing (the middot separator is suppressed by the
    /// empty glyph collapsing).
    @ViewBuilder
    private func fieldGlyph(_ item: NodeItem) -> some View {
        if let fv = item.field, let def = store.fieldDefinition(id: fv.definitionID) {
            if def.kind == .rating,
               (def.config.ratingStyle ?? .stars) == .stars,
               case .rating(let v)? = fv.value {
                let scale = def.config.ratingScale ?? 5
                HStack(spacing: 2) {
                    ForEach(0..<scale, id: \.self) { idx in
                        Image(systemName: idx < v ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(Self.inkMeta)
                    }
                }
            } else if let text = FieldValueFormatter.display(
                fv, definition: def,
                resolveNodeTitle: { id in store.nodes.first { $0.id == id }?.title }
            ) {
                Text(text)
                    .font(.system(size: 12, design: .serif))
                    .foregroundColor(Self.inkMeta)
                    .lineLimit(1)
            }
        }
    }

    /// Compact card-form per payload type. Elastic forms (`.text`,
    /// `.audio`) flex into the leftover card slack via the parent's
    /// `.frame(maxHeight: .infinity)`; their internal text uses
    /// `fitLinesText` so truncation happens at the last full line that
    /// fits (no mid-line clip). Rigid forms (galleries, links, docs)
    /// hold their declared footprint.
    @ViewBuilder
    private func payloadForm(for item: NodeItem) -> some View {
        switch item.type {
        case .text:
            fitLinesText(
                item.content ?? "",
                fontSize: 13,
                lineSpacing: 2,
                color: Self.inkDeck,
                shadowOpacity: 0.35,
                renderMarkdown: true   // #18: render formatted markdown, not raw `**…**`
            )
        case .imageVideo:
            galleryStrip(for: item)
        case .link:
            linkStrip(for: item)
        case .document:
            documentStrip(for: item)
        case .audio:
            audioRow(for: item)
        case .image:
            placeholderRow("Image", systemImage: "photo")
        case .video:
            placeholderRow("Video", systemImage: "video")
        case .rating, .field:
            // Atomic — rendered in the stat line via `atomicGlyph`, never as
            // a payload card form.
            EmptyView()
        }
    }

    private func placeholderRow(_ label: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .serif))
                .tracking(1.4)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundColor(Self.inkMeta)
        .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
    }

    private func overflowLine(_ count: Int) -> some View {
        Text("+\(count) more")
            .font(.system(size: 11, design: .serif))
            .italic()
            .foregroundColor(Self.inkMeta.opacity(0.85))
            .shadow(color: Self.inkShadow.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    /// Horizontal scrollable thumbnail strip for a promoted `.imageVideo`
    /// entry. Reuses `GalleryItemTile` chrome-free — no per-tile tap (the
    /// whole card owns the tap), no aspect persistence (the card is a
    /// read-only mirror; the detail view's gallery owns that write path).
    /// Each tile is framed by its persisted aspect; tiles whose aspect
    /// hasn't been measured yet fall back to square. Empty/nil
    /// `mediaItems` collapses to nothing (the entry still occupies its
    /// booked 80pt budget — visible-empty is rare and the alternative
    /// would skew fold ordering).
    @ViewBuilder
    private func galleryStrip(for item: NodeItem) -> some View {
        if let media = item.mediaItems, !media.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media) { gItem in
                        GalleryItemTile(
                            galleryItem: gItem,
                            nodeID: node.id,
                            parentItem: item,
                            showVideoBadge: true,
                            onMeasuredAspect: nil
                        )
                        .frame(
                            width: 80 * CGFloat(gItem.aspectRatio ?? 1.0),
                            height: 80
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(height: 80)
        }
    }

    /// Horizontal scrollable strip of compact link tiles for a promoted
    /// `.link` entry. Read-only mirror of `LinkGalleryTile` — no menu,
    /// no tap, no on-appear OG fetch. Renders cached fields only; the
    /// detail view owns the write path. Empty/nil `linkItems` collapses
    /// to nothing (the entry still occupies its booked 64pt budget).
    @ViewBuilder
    private func linkStrip(for item: NodeItem) -> some View {
        if let links = item.linkItems, !links.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(links) { linkItem in
                        CardLinkTile(linkItem: linkItem, nodeID: node.id)
                    }
                }
            }
            .frame(height: 64)
        }
    }

    /// Horizontal scrollable strip of compact document tiles for a
    /// promoted `.document` entry. Read-only mirror of
    /// `DocumentGalleryTile` — no menu, no tap-to-QuickLook, no
    /// extraction fire-and-forget. Renders cached fields only.
    @ViewBuilder
    private func documentStrip(for item: NodeItem) -> some View {
        if let docs = item.documentItems, !docs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(docs) { docItem in
                        CardDocumentTile(documentItem: docItem, nodeID: node.id)
                    }
                }
            }
            .frame(height: 64)
        }
    }

    /// Compact row for a promoted `.audio` entry. Read-only mirror of
    /// `VoiceEntryBody` — a static waveform glyph (no playback affordance:
    /// you can't play from the card, so a play glyph would be misleading)
    /// + duration (only when present and > 0) + transcript when present.
    /// Two-zone layout for elasticity: a rigid control row on top (glyph +
    /// duration, intrinsic height) and an elastic `fitLinesText` transcript
    /// below that fills the leftover slack and tail-truncates at the last
    /// full line.
    @ViewBuilder
    private func audioRow(for item: NodeItem) -> some View {
        let duration = Self.formattedDuration(item.durationSeconds)
        let transcript = (item.transcript?.isEmpty == false) ? item.transcript : nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 22))
                    .foregroundColor(Self.inkDeck)
                if let duration {
                    Text(duration)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(Self.inkTitle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .shadow(color: Self.inkShadow.opacity(0.4), radius: 2, x: 0, y: 1)
            if let transcript {
                fitLinesText(
                    transcript,
                    fontSize: 11,
                    italic: true,
                    lineSpacing: 2,
                    color: Self.inkMeta,
                    shadowOpacity: 0.4
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Returns nil when there's no real duration to show. Zero or
    // negative values are unknown/uninitialized states (entries created
    // before the duration probe ran) — emit nothing rather than "0:00"
    // or "--:--", which both lie about the audio.
    private static func formattedDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Footprints + greedy-fill engine
    // Tunable constants. Whole-or-skip: each card-form declares a fixed
    // bounded footprint; we sum in fold order; render while the running
    // sum + the next footprint ≤ budget. No live measurement.

    fileprivate struct PayloadFit {
        let rendered: [NodeItem]
        let overflowCount: Int
    }

    /// Inter-item spacing inside the body VStack (matches the VStack's
    /// own `spacing: 8` so the budget math is honest).
    private static let payloadInterSpacing: CGFloat = 8
    /// "+N more" line footprint (one short italic line).
    private static let overflowFootprint: CGFloat = 18

    private static func payloadFootprint(for type: NodeItemType) -> CGFloat {
        switch type {
        case .text:        return 64
        case .imageVideo:  return 80
        case .link:        return 64
        case .document:    return 64
        case .audio:       return 52
        case .image:       return 28
        case .video:       return 28
        case .rating, .field:  return 0
        }
    }

    /// Elastic forms get `.frame(maxHeight: .infinity)` in the body
    /// ForEach so they expand to fill leftover slack after `fitPayloads`
    /// has selected at minimum footprints. Selection is unchanged —
    /// keeping `isElastic` out of `fitPayloads` is what avoids a feedback
    /// loop. Gallery growth is intentionally a separate later commit.
    private static func isElastic(_ type: NodeItemType) -> Bool {
        switch type {
        case .text, .audio: return true
        default:            return false
        }
    }

    /// Reusable "fit text to height" view: measures the slot, divides by
    /// `fontSize × 1.35 + lineSpacing`, and caps `lineLimit` so the tail
    /// truncates at the last full line that fits — no mid-line clip.
    /// Pulled out so both `.text` payload and the `.audio` transcript
    /// share the same line-fit math.
    @ViewBuilder
    private func fitLinesText(
        _ content: String,
        fontSize: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false,
        lineSpacing: CGFloat = 2,
        color: Color,
        shadowOpacity: Double = 0.35,
        renderMarkdown: Bool = false
    ) -> some View {
        // Decode ONCE here (not per geometry pass) when this is a markdown note body.
        let attributed: AttributedString? = renderMarkdown
            ? Self.markdownBody(content, fontSize: fontSize, weight: weight, italic: italic)
            : nil
        return GeometryReader { proxy in
            let lineHeight = fontSize * 1.35 + lineSpacing
            let maxLines = max(1, Int(proxy.size.height / lineHeight))
            let styled: Text = {
                if let attributed { return Text(attributed) }  // #18: formatted, not raw markdown
                var t = Text(content).font(.system(size: fontSize, weight: weight, design: .serif))
                if italic { t = t.italic() }
                return t
            }()
            styled
                .foregroundColor(color)
                .shadow(color: Self.inkShadow.opacity(shadowOpacity), radius: 2, x: 0, y: 1)
                .lineLimit(maxLines)
                .truncationMode(.tail)
                .lineSpacing(lineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// #18 — renders a note body's markdown as read-only styled text for the card,
    /// REUSING the detail Note pipeline's PARSE (`MarkdownCodec.decode`) — NOT the
    /// editor/UITextView. Bold / italic / underline / strike / inline-code render;
    /// the card's serif scale + foreground are applied here (not `NoteTypography`,
    /// which is the note's 17pt paragraph typography). Attachment placeholders
    /// (inline images) are stripped — SwiftUI `Text` can't render `NSTextAttachment`.
    /// Best-effort: any decode oddity still renders as text, never raw asterisks.
    private static func markdownBody(_ markdown: String, fontSize: CGFloat,
                                     weight: Font.Weight, italic baseItalic: Bool) -> AttributedString {
        let ns = MarkdownCodec.decode(markdown)
        guard ns.length > 0 else { return AttributedString(markdown) }
        var out = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length), options: []) { attrs, range, _ in
            // Strip attachment placeholders (U+FFFC); Text can't render attachments.
            let seg = (ns.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !seg.isEmpty else { return }
            var piece = AttributedString(seg)
            let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.traitBold)
            let isItalic = traits.contains(.traitItalic) || baseItalic
            let isMono = (attrs[.airpadInlineCode] as? Bool) == true || traits.contains(.traitMonoSpace)
            var font = Font.system(size: fontSize,
                                   weight: isBold ? .bold : weight,
                                   design: isMono ? .monospaced : .serif)
            if isItalic { font = font.italic() }
            piece.font = font
            if (attrs[.underlineStyle] as? Int).map({ $0 != 0 }) ?? false { piece.underlineStyle = .single }
            if (attrs[.strikethroughStyle] as? Int).map({ $0 != 0 }) ?? false { piece.strikethroughStyle = .single }
            // No foreground — the card's `.foregroundColor(color)` controls it.
            out.append(piece)
        }
        return out.characters.isEmpty ? AttributedString(markdown) : out
    }

    fileprivate static func fitPayloads(_ payloads: [NodeItem], budget: CGFloat) -> PayloadFit {
        guard budget > 0, !payloads.isEmpty else {
            return PayloadFit(rendered: [], overflowCount: payloads.count)
        }
        var used: CGFloat = 0
        var rendered: [NodeItem] = []
        for (idx, item) in payloads.enumerated() {
            let footprint = payloadFootprint(for: item.type)
            let spacing: CGFloat = rendered.isEmpty ? 0 : payloadInterSpacing
            let leftAfter = payloads.count - idx - 1
            // Reserve "+N more" only when including this item would still
            // leave items behind. When this is the last fit, no reservation.
            let overflowReservation: CGFloat = leftAfter > 0
                ? (overflowFootprint + payloadInterSpacing)
                : 0
            if used + spacing + footprint + overflowReservation <= budget {
                rendered.append(item)
                used += spacing + footprint
            } else {
                break
            }
        }
        return PayloadFit(rendered: rendered, overflowCount: payloads.count - rendered.count)
    }

    // MARK: - Title fallback

    private var displayTitle: String {
        if !node.title.isEmpty { return node.title }
        if let firstText = node.items.first?.content, !firstText.isEmpty { return firstText }
        return "Untitled"
    }
}

// MARK: - CardHeroImage
// Async cover-image loader for the card. Reuses `store.coverImageURL(for:)`
// — the same resolver `NodeDetailView.heroZone` / `HeroImageBanner` use —
// so card and hero stay byte-identical on what they resolve. Sized by its
// parent (no aspect-ratio math here); the card pins the hero to the top
// ~42% and masks the bottom edge into a fade.

private struct CardHeroImage: View, Equatable {
    let node: Node

    @Environment(CorpusStore.self) private var store
    @State private var image: UIImage? = nil

    // `Node.==` is id-only, so a heroCrop (or cover-path) change on the SAME node
    // wouldn't re-render this child — the framing only refreshed after navigating
    // away and back (the reported cache-invalidation bug). Same fix RecentNodeRow
    // uses: diff on exactly what this view renders. The crop re-applies to the
    // already-cached image (no reload → no flash), riding the same @Observable
    // store publish that already updates title/summary in the parent body.
    static func == (l: CardHeroImage, r: CardHeroImage) -> Bool {
        l.node.id == r.node.id &&
        l.node.coverImageRelativePath == r.node.coverImageRelativePath &&
        l.node.heroCrop == r.node.heroCrop
    }

    var body: some View {
        Group {
            if let image {
                // #7 — apply the node's hero crop so the card framing matches
                // what the user dialed in the detail banner. Fast path (no
                // GeometryReader) whenever there's no non-zero crop — the common
                // case across a scrolling list/grid.
                if node.heroCrop?.fit == .fullHeight {
                    // BUG 24 — whole image letterboxed inside the FIXED hero zone;
                    // the card's gradient shows through the bars. Tiles never grow.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if let crop = node.heroCrop, crop.offset != .zero {
                    croppedFill(image: image, crop: crop)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
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

    /// #7 — cover cropped by the node's hero offset. GeometryReader supplies the
    /// live frame the normalized offset is resolved against; the offset is
    /// clamped to the overflow so a crop can't expose an edge (shared math in
    /// `HeroCrop.clampedPointOffset`). Parent's frame/clip still bound this.
    private func croppedFill(image: UIImage, crop: HeroCrop) -> some View {
        GeometryReader { geo in
            let aspect: CGFloat = image.size.height > 0 ? image.size.width / image.size.height : 1
            let offset = HeroCrop.clampedPointOffset(
                normalizedOffset: crop.offset, imageAspect: aspect,
                width: geo.size.width, height: geo.size.height)
            Color.clear
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .offset(x: offset.x, y: offset.y)
                }
                .clipped()
        }
    }
}

