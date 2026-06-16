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

            Spacer(minLength: 12)

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
