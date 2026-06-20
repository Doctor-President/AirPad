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

import SwiftUI

struct NodeGridTile: View {
    let node: Node
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Forwarded to `NodeGradientLayer`. The grid passes `true` only at
    /// 2-col; 3 and 4-col render the gradient as a still frame to keep
    /// scrolling smooth when many blurred Circles share the viewport.
    var animateGradient: Bool = true

    @Environment(CorpusStore.self) private var store

    // Warm-cream ink palette — copy of NodeCardView's. Self-contained this
    // pass; share later if a third caller turns up.
    private static let inkTitle = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.98)
    private static let inkDeck  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.86)
    private static let inkMeta  = Color(red: 1.0, green: 0.976, blue: 0.941).opacity(0.68)
    private static let hairline = Color(red: 1.0, green: 0.925, blue: 0.804).opacity(0.22)

    private var hasHero: Bool { node.coverImageRelativePath != nil }

    var body: some View {
        ZStack {
            NodeGradientLayer(node: node, animated: animateGradient)
            if hasHero {
                heroOverlay
            }
            travelingScrim
            identityContent
            watermark
        }
    }

    // MARK: - Hero overlay
    // Top ~42% of the tile, bottom-faded mask — verbatim copy of the
    // card's treatment so the hero reads identically.

    private var heroOverlay: some View {
        let heroHeight = cellHeight * 0.42
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

    // MARK: - Identity content

    private var identityContent: some View {
        let category = node.primaryTag
        let titleText = displayTitle
        let showDeck = node.descriptionOnCard && !node.summary.isEmpty
        let tagList = Array(node.tags.prefix(3))
        let topInset: CGFloat = hasHero ? (cellHeight * 0.42 + 18) : 22
        let badges = badgeManifest

        return VStack(alignment: .leading, spacing: 0) {
            // Dateline
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
                .frame(maxWidth: .infinity, alignment: .leading)

            if showDeck {
                Text(node.summary)
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundColor(Self.inkDeck)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Flex slot — pushes badges + tags to the bottom.
            Spacer(minLength: 0)

            // Badge manifest
            if !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges, id: \.glyph) { badge in
                        HStack(spacing: 4) {
                            Image(systemName: badge.glyph)
                                .font(.system(size: 12))
                            Text("\(badge.count)")
                                .font(.system(size: 12, design: .serif))
                        }
                        .foregroundColor(Self.inkMeta)
                    }
                    Spacer(minLength: 0)
                }
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            }

            // Tags
            if !tagList.isEmpty {
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 0.5)
                    .padding(.top, badges.isEmpty ? 0 : 10)
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

    // MARK: - Badge manifest
    // Aggregate per-payload-type content counts across all of node.items.
    // Text and rating are excluded by design (text isn't a "thing you can
    // browse to"; rating is atomic and would show as stars elsewhere).
    // Audio has no sub-array, so count one per .audio entry.

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
