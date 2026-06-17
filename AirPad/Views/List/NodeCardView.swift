// NodeCardView.swift
// Editorial 5:7 card face — full-bleed NodeGradientLayer + optional hero,
// dateline · serif title · deck · inline small-caps tags · feather watermark.
// Preserves the struct's interface and selection chrome.

import SwiftUI

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

// CardPalette is dead — the editorial card uses NodeGradientLayer for its
// full-bleed background. Left in place to avoid touching call sites that
// don't exist; safe to delete in a follow-up sweep.
struct CardPalette {
    let a: Color
    let b: Color
    let c: Color
    let d: Color

    static let all: [CardPalette] = [
        CardPalette(a: Color(hexString: "2D0A5E"), b: Color(hexString: "C43C2A"), c: Color(hexString: "7A52FF"), d: Color(hexString: "E36B4E")),
        CardPalette(a: Color(hexString: "041E2A"), b: Color(hexString: "E36B4E"), c: Color(hexString: "0A4A5E"), d: Color(hexString: "FFD7C2")),
        CardPalette(a: Color(hexString: "071A0A"), b: Color(hexString: "D4830A"), c: Color(hexString: "0A3A14"), d: Color(hexString: "E6A020")),
        CardPalette(a: Color(hexString: "0A0520"), b: Color(hexString: "9D174D"), c: Color(hexString: "1A0A3D"), d: Color(hexString: "B857D4")),
        CardPalette(a: Color(hexString: "0A1020"), b: Color(hexString: "B857D4"), c: Color(hexString: "1A2A4A"), d: Color(hexString: "7A52FF")),
        CardPalette(a: Color(hexString: "041A1A"), b: Color(hexString: "E36B4E"), c: Color(hexString: "0A3A3A"), d: Color(hexString: "C43C2A")),
        CardPalette(a: Color(hexString: "030A1A"), b: Color(hexString: "C47A0A"), c: Color(hexString: "0D1B5E"), d: Color(hexString: "E6A020")),
    ]
}

struct NodeCardView: View {
    let node: Node
    let selected: Bool
    let dist: Int
    var isSelecting: Bool = false
    var isPicked: Bool = false

    @State private var appeared = false

    // Warm-cream ink palette — every text element draws from this.
    private static let inkTitle = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.98)
    private static let inkDeck  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.86)
    private static let inkMeta  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.68)
    private static let hairline = Color(red: 1.0, green: 0.925, blue: 0.804).opacity(0.22)
    private static let cornerRadius: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 2)
                        .frame(width: 26, height: 26)
                    if isPicked {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 32)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            GeometryReader { geo in
                ZStack {
                    NodeGradientLayer(node: node)
                    if node.coverImageRelativePath != nil {
                        heroOverlay(width: geo.size.width, height: geo.size.height)
                    }
                    travelingScrim
                    editorialContent(cardHeight: geo.size.height,
                                     hasHero: node.coverImageRelativePath != nil)
                    watermark
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .stroke(Color.white, lineWidth: isSelecting && isPicked ? 3 : 0)
                )
                .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 4)
            }
        }
        .transition(.scale(scale: 0.85, anchor: .center).combined(with: .opacity))
        .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: appeared)
        .onAppear { appeared = true }
    }

    // MARK: - Hero overlay

    @ViewBuilder
    private func heroOverlay(width: CGFloat, height: CGFloat) -> some View {
        let heroHeight = height * 0.42
        VStack(spacing: 0) {
            CardHeroImage(node: node)
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
                .init(color: Color.black.opacity(0.42), location: 0.0),
                .init(color: Color.clear,               location: 0.20),
                .init(color: Color.clear,               location: 0.80),
                .init(color: Color.black.opacity(0.52), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - Editorial content

    private func editorialContent(cardHeight: CGFloat, hasHero: Bool) -> some View {
        let category = node.primaryTag
        let titleText = displayTitle
        let showDeck = node.descriptionOnCard && !node.summary.isEmpty
        let tagList = Array(node.tags.prefix(3))
        // When a hero is present, push the editorial block below the fade
        // so it reads as its own zone (don't tuck content up into the fade).
        let topInset: CGFloat = hasHero ? (cardHeight * 0.42 + 18) : 22

        // Entry-stream partition. Atomics are normalized to the contiguous
        // front of `node.items`; foldIndex is guaranteed ≥ atomicCount.
        // Clamped defensively for the case where a legacy node decoded
        // with foldIndex=0 but has atomics — keeps slicing safe.
        let atomics = Array(node.items.prefix(while: { $0.type.isAtomic }))
        let atomicCount = atomics.count
        let foldIdx = min(max(node.foldIndex, atomicCount), node.items.count)
        let payloads = Array(node.items[atomicCount..<foldIdx])

        let preBodyGap: CGFloat = 12     // gap the old `Spacer(minLength: 12)` carried
        let postStatGap: CGFloat = atomicCount > 0 ? 8 : 0

        return VStack(alignment: .leading, spacing: 0) {
            // Dateline row
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let category {
                    Text(category)
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(node.relativeTimestamp.uppercased())
                    .font(.system(size: 10, design: .serif))
                    .tracking(2.2)
                    .foregroundColor(Self.inkMeta)
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)

            Rectangle()
                .fill(Self.hairline)
                .frame(height: 0.5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            // Title
            Text(titleText)
                .font(.system(size: 23, weight: .bold, design: .serif))
                .tracking(-0.35)
                .foregroundColor(Self.inkTitle)
                .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if showDeck {
                Text(node.summary)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundColor(Self.inkDeck)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .padding(.top, 8)
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

            GeometryReader { proxy in
                let fit = Self.fitPayloads(payloads, budget: proxy.size.height)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fit.rendered) { item in
                        payloadForm(for: item)
                            .frame(maxWidth: .infinity,
                                   maxHeight: Self.payloadFootprint(for: item.type),
                                   alignment: .topLeading)
                    }
                    if fit.overflowCount > 0 {
                        overflowLine(fit.overflowCount)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .clipped()

            // Tags row
            if !tagList.isEmpty {
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 0.5)
                    .padding(.bottom, 10)
                Text(tagList.map { $0.uppercased() }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium, design: .serif))
                    .tracking(2.0)
                    .foregroundColor(Self.inkMeta)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, topInset)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
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
        default:
            EmptyView()
        }
    }

    /// Compact card-form per payload type. Commit 1: `.text` renders the
    /// real form (3-line cap with tail truncation); all other payload
    /// types render a one-line typed placeholder so the engine and
    /// budget math are verifiable end-to-end. Each later commit deletes
    /// one placeholder branch as the real form lands.
    @ViewBuilder
    private func payloadForm(for item: NodeItem) -> some View {
        switch item.type {
        case .text:
            Text(item.content ?? "")
                .font(.system(size: 13, design: .serif))
                .foregroundColor(Self.inkDeck)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .lineLimit(3)
                .truncationMode(.tail)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        case .rating:
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
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
    }

    private func overflowLine(_ count: Int) -> some View {
        Text("+\(count) more")
            .font(.system(size: 11, design: .serif))
            .italic()
            .foregroundColor(Self.inkMeta.opacity(0.85))
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
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
    /// + duration (only when present and > 0) + one-line transcript
    /// sliver if present. The whole card owns the tap.
    @ViewBuilder
    private func audioRow(for item: NodeItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 22))
                .foregroundColor(Self.inkDeck)
            VStack(alignment: .leading, spacing: 2) {
                if let duration = Self.formattedDuration(item.durationSeconds) {
                    Text(duration)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(Self.inkTitle)
                        .lineLimit(1)
                }
                if let transcript = item.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.system(size: 11, design: .serif))
                        .italic()
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
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
        case .rating:      return 0
        }
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

    // MARK: - Feather watermark

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

// MARK: - CardHeroImage
// Async cover-image loader for the card. Reuses `store.coverImageURL(for:)`
// — the same resolver `NodeDetailView.heroZone` / `HeroImageBanner` use —
// so card and hero stay byte-identical on what they resolve. Sized by its
// parent (no aspect-ratio math here); the card pins the hero to the top
// ~42% and masks the bottom edge into a fade.

private struct CardHeroImage: View {
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

// MARK: - CardLinkTile
// Compact read-only mirror of LinkGalleryTile, sized for the card body
// strip (~200pt × 64pt). Renders cached OG image / favicon / title /
// siteName only — no menu, no tap-to-open, no OGMetadataService fetch.
// The whole card owns the tap; the detail view's gallery owns the
// fetch/snapshot/write paths.

private struct CardLinkTile: View {
    let linkItem: LinkItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var thumbImage: UIImage? = nil

    private static let inkTitle = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.95)
    private static let inkMeta  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.55)

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundColor(Self.inkTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let site = linkItem.siteName, !site.isEmpty {
                    Text(site)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 64, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        .task(id: "\(linkItem.imageFile ?? "")|\(linkItem.faviconFile ?? "")") {
            await loadCachedImage()
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08))
            if let img = thumbImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "link")
                    .font(.system(size: 16))
                    .foregroundColor(Self.inkMeta)
            }
        }
    }

    private var displayTitle: String {
        if let t = linkItem.title, !t.isEmpty { return t }
        return linkItem.url
    }

    // Prefer the OG image; fall back to favicon. Cached only — never
    // triggers OGMetadataService. If neither resolves, the SF Symbol
    // fallback in `thumb` keeps the slot occupied.
    private func loadCachedImage() async {
        thumbImage = nil
        var url: URL? = nil
        if linkItem.imageFile != nil {
            url = await store.resolveLinkItemImageURL(linkItem, nodeID: nodeID)
        }
        if url == nil, linkItem.faviconFile != nil {
            url = await store.resolveLinkItemFaviconURL(linkItem, nodeID: nodeID)
        }
        guard let url else { return }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let decoded { thumbImage = decoded }
    }
}

// MARK: - CardDocumentTile
// Compact read-only mirror of DocumentGalleryTile, sized for the card
// body strip (~200pt × 64pt). Renders cached page-1 thumbnail / title /
// metrics only — no menu, no tap-to-QuickLook, no
// DocumentExtractionService fire-and-forget.

private struct CardDocumentTile: View {
    let documentItem: DocumentItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var thumbnail: UIImage? = nil

    private static let inkTitle = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.95)
    private static let inkMeta  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.55)

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundColor(Self.inkTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let metrics = metricsLine {
                    Text(metrics)
                        .font(.system(size: 10, design: .serif))
                        .foregroundColor(Self.inkMeta)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 200, height: 64, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
        .task(id: documentItem.thumbnailFile) {
            await loadCachedThumbnail()
        }
    }

    @ViewBuilder
    private var thumb: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.08))
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundColor(Self.inkMeta)
            }
        }
    }

    private var displayTitle: String {
        documentItem.documentTitle ?? documentItem.fileName
    }

    private var metricsLine: String? {
        var parts: [String] = []
        if let pages = documentItem.pageCount, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        if let words = documentItem.wordCount, words > 0 {
            parts.append("\(words) words")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch documentItem.fileType.lowercased() {
        case "pdf":          return "doc.richtext.fill"
        case "html", "htm":  return "globe"
        default:             return "doc.fill"
        }
    }

    private func loadCachedThumbnail() async {
        thumbnail = nil
        guard documentItem.thumbnailFile != nil,
              let url = await store.documentThumbnailFileURL(for: documentItem, nodeID: nodeID) else { return }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let decoded { thumbnail = decoded }
    }
}
