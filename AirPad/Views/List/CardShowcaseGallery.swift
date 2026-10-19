#if DEBUG
import SwiftUI

/// live-23 — `-CardShowcase <coverflow|vertical|grid2|grid3> [-CardShowcasePage n]`: the synthetic showcase entries
/// (`-UITestSeedCardShowcase`) laid out as the REAL card faces (`NodeCardView` / `NodeGridTile`) at their real sizes —
/// scaled down for the tall coverflow and vertical faces — so one still shows every case a face must handle (BEFORE
/// vs PROPOSAL contact sheets, the dark body, the hero fade). Renders over everything; never hit-testable. DEBUG only.
struct CardShowcaseGallery: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    static let order = ["showcase-gallery", "showcase-fig", "showcase-lists", "showcase-voice", "showcase-doc",
                        "showcase-recipe", "showcase-links", "showcase-long-title", "showcase-mixed", "showcase-short-note", "showcase-steps"]

    private var kind: String { UserDefaults.standard.string(forKey: "CardShowcase") ?? "grid2" }
    private var page: Int { UserDefaults.standard.integer(forKey: "CardShowcasePage") }

    /// live-26 (3b) — `-CardShowcaseSet markup`: the markup fixtures (`-UITestSeedMarkupShowcase`) instead.
    /// live-26 (3c) — `-CardShowcaseSet fade`: the hero-fade fixtures (`-UITestSeedFadeShowcase`).
    static let fadeOrder = ["fade-photo-busy", "fade-photo-landscape", "fade-gradient-art", "fade-fluted"]
    static let markupOrder = ["markup-checklist-editor", "markup-checklist-raw", "markup-html", "markup-literal",
                              "markup-untitled", "markup-list-styled", "markup-summary"]

    private var nodes: [Node] {
        let set = UserDefaults.standard.string(forKey: "CardShowcaseSet")
        let order = set == "markup" ? Self.markupOrder : set == "fade" ? Self.fadeOrder : Self.order
        return order.compactMap { id in store.nodes.first { $0.id == id } }
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            ZStack(alignment: .top) {
                CardSurfaceResolved.ground(dark: colorScheme == .dark).ignoresSafeArea()
                content(W: W)
                    .padding(.top, 70)
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("cardShowcase")
    }

    @ViewBuilder
    private func content(W: CGFloat) -> some View {
        switch kind {
        case "coverflow":
            // The carousel face: 0.79 × width, 1.95 × that tall (clamped to 640 on a Pro Max), shown at 0.6.
            let w = W * 0.79, h = min(w * CGFloat(CardTuningDefaults.value(.carousel, .height)), 640)
            pageGrid(columns: 2, rows: 2, cell: CGSize(width: w, height: h), scale: 0.6) { node in
                NodeCardView(nodeID: node.id, fallbackNode: node, animateEntry: false, presentation: .carousel)
            }
        case "vertical":
            let w = W * 0.9, h = W * CGFloat(CardTuningDefaults.value(.vertical, .height))
            pageGrid(columns: 1, rows: 4, cell: CGSize(width: w, height: h), scale: 1) { node in
                NodeCardView(nodeID: node.id, fallbackNode: node, animateEntry: false, presentation: .vertical)
            }
        default:
            let cols = kind == "grid3" ? 3 : 2
            let cellW = (W - 10 * CGFloat(cols + 1)) / CGFloat(cols), cellH = cellW * 7 / 5
            pageGrid(columns: cols, rows: cols == 3 ? 4 : 3, cell: CGSize(width: cellW, height: cellH), scale: 1) { node in
                tile(node, cellW: cellW, cellH: cellH, cols: cols)
            }
        }
    }

    private func tile(_ node: Node, cellW: CGFloat, cellH: CGFloat, cols: Int) -> some View {
        let dark = colorScheme == .dark
        let shadowScale = min(cellW / 175, 1)
        return NodeGridTile(node: node, cellWidth: cellW, cellHeight: cellH, animateGradient: false, columnCount: cols)
            .frame(width: cellW, height: cellH)
            .overlay(NodeGridView.tileSheen)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: AppearancePalette.cardShadow, radius: CardSurfaceResolved.shadowRadius(dark: dark) * shadowScale,
                    x: 0, y: CardSurfaceResolved.shadowY(dark: dark) * shadowScale)
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(CardSurfaceResolved.rimGradient(dark: dark), lineWidth: CardSurfaceResolved.rimWidth(dark: dark)))
            .overlay(CardEmbossOverlay(cornerRadius: 14))
    }

    /// One page of `columns × rows` cells, each the real face at `cell` size, drawn at `scale`.
    private func pageGrid<Face: View>(columns: Int, rows: Int, cell: CGSize, scale: CGFloat,
                                      @ViewBuilder face: @escaping (Node) -> Face) -> some View {
        let per = columns * rows
        let slice = Array(nodes.dropFirst(page * per).prefix(per))
        let gap: CGFloat = 10
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { c in
                        let i = r * columns + c
                        if i < slice.count {
                            face(slice[i])
                                .frame(width: cell.width, height: cell.height)
                                .scaleEffect(scale)
                                .frame(width: cell.width * scale, height: cell.height * scale)
                        } else {
                            Color.clear.frame(width: cell.width * scale, height: cell.height * scale)
                        }
                    }
                }
            }
        }
    }
}
#endif
