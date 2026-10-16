#if DEBUG
import SwiftUI

/// live-21 (1) — RENDER ONLY (Ops/briefs/brief-librarian-surface-light-mode-renders.md). DEBUG launch arguments that
/// re-skin the real surfaces for T's taste stills; none of this exists in a TestFlight/App Store build, and with no
/// argument every value below is nil, so the shipped look is unchanged.
///   -RenderPanel A|B|C|D|E        Librarian panel variant (A = today)
///   -RenderPalette L1|L2|L3       light-mode palette (L1 = today)
///   -RenderShadow S1|S2|S3|S4     card shadow (S1 = today; S2 half; S3 none; S4 none + 0.5 pt hairline)
///   -RenderField F1|F2|F3|F4      field brightness (F1 = the palette's own; F2/F3 one/two steps lighter; F4 one darker)
///   -RenderLayer field|cards|shadow|hairline  -RenderLayerBG white|black   (layered export: one pass, on a flat ground)
///   -RenderLongAnswer YES         the Librarian opens a synthetic chat whose answer is four paragraphs
///   -RenderHideChrome YES         no top bar, no Librarian (for the layered export)
enum RenderVariant {
    private static let d = UserDefaults.standard
    static var panel: String? { d.string(forKey: "RenderPanel") }
    static var palette: String { d.string(forKey: "RenderPalette") ?? "L1" }
    static var shadow: String { d.string(forKey: "RenderShadow") ?? "S1" }
    static var field: String { d.string(forKey: "RenderField") ?? "F1" }
    static var layer: String? { d.string(forKey: "RenderLayer") }
    static var layerBGHex: String { d.string(forKey: "RenderLayerBG") == "black" ? "000000" : "FFFFFF" }
    static var hideChrome: Bool { d.bool(forKey: "RenderHideChrome") || layer != nil }
    static var longAnswer: Bool { d.bool(forKey: "RenderLongAnswer") }
    static var paletteIsDefault: Bool { palette == "L1" && field == "F1" }
    /// Any -Render* argument: hides the DEBUG tuner icons, which no shipping build has.
    static var active: Bool { ["RenderPanel", "RenderPalette", "RenderShadow", "RenderField", "RenderLayer"].contains { d.object(forKey: $0) != nil } }

    // MARK: Palettes (light mode). One temperature per palette for field + cards + panel (L2/L3).

    struct Palette {
        let field: String          // the library/Map ground (F1)
        let fieldSteps: [String]   // F2, F3, F4
        let cardPaper: String      // the card face's paper
        let cardLightness: Double  // ×paper (L1 keeps today's 1.1 → #FFFFFA)
        let detailGround: String   // bgBase (entry detail ground)
        let elevated: String       // bgElevated
        let panelTint: String      // Librarian light panel tint
        let panelStroke: String
        let dot: String            // library dot colour
        let shadow: String         // card shadow colour
    }

    static let palettes: [String: Palette] = [
        "L1": Palette(field: "DDDDDD", fieldSteps: ["E8E8E8", "F3F3F3", "D2D2D2"], cardPaper: "F4EFE3", cardLightness: 1.100,
                      detailGround: "F4EFE3", elevated: "FAF6EC", panelTint: "F4EFE3", panelStroke: "CEBBA2",
                      dot: "2E3A40", shadow: "434343"),
        "L2": Palette(field: "EFECE6", fieldSteps: ["F4F2ED", "F8F6F2", "E6E2DA"], cardPaper: "FBF9F5", cardLightness: 1.0,
                      detailGround: "EFECE6", elevated: "FBF9F5", panelTint: "FBF9F5", panelStroke: "DCD6CC",
                      dot: "3B362F", shadow: "3F3A33"),
        "L3": Palette(field: "ECECEA", fieldSteps: ["F1F1EF", "F6F6F4", "E3E3E0"], cardPaper: "FAFAF8", cardLightness: 1.0,
                      detailGround: "ECECEA", elevated: "FAFAF8", panelTint: "FAFAF8", panelStroke: "D6D6D2",
                      dot: "33383B", shadow: "3B3C3D"),
    ]
    static var current: Palette { palettes[palette] ?? palettes["L1"]! }

    /// The light field hex for the chosen palette + brightness step.
    static var fieldHex: String {
        let p = current
        switch field {
        case "F2": return p.fieldSteps[0]
        case "F3": return p.fieldSteps[1]
        case "F4": return p.fieldSteps[2]
        default:   return p.field
        }
    }

    // MARK: Card surface overrides (CardSurfaceStore.read)

    static func dial(_ d: CardSurfaceDial, baked: Double) -> Double {
        switch d {
        case .baseLightness: return palette == "L1" ? baked : current.cardLightness
        case .shadowAlpha:
            if layer == "shadow" { return 1.0 }
            if layer != nil { return 0 }
            switch shadow { case "S2": return baked * 0.5; case "S3", "S4": return 0; default: return baked }
        case .shadowRadius: return shadow == "S2" && layer == nil ? baked * 0.5 : baked
        case .rimOpacity:
            if layer == "hairline" { return 1.0 }
            if layer == "shadow" { return 0 }
            return shadow == "S4" ? 0.16 : baked
        case .rimWidth: return (shadow == "S4" || layer == "hairline") ? 0.5 : baked
        case .embossLightAlpha, .embossDarkAlpha: return (layer == "shadow" || layer == "hairline") ? 0 : baked
        default: return baked
        }
    }

    static func hex(_ h: CardSurfaceHex, baked: String) -> String {
        switch h {
        case .groundHex: return (layer != nil && layer != "field") ? layerBGHex : fieldHex
        case .shadowHex: return palette == "L1" ? baked : current.shadow
        case .rimHex:    return (shadow == "S4" || layer == "hairline") ? "000000" : baked
        default:         return baked
        }
    }

    static func flag(_ f: CardSurfaceFlag, baked: Bool) -> Bool {
        if f == .rimTopOnly, shadow == "S4" || layer == "hairline" { return false }   // a full hairline edge
        return baked
    }

    /// Layered export: the card face is replaced by the flat ground on the shadow + hairline passes (so only the pass
    /// itself differs between the white- and black-ground renders), hidden on the field pass.
    static var faceIsGround: Bool { layer == "shadow" || layer == "hairline" }
    static var hideCards: Bool { layer == "field" }
    static var hideDots: Bool { layer != nil && layer != "field" }
}

/// The Librarian light/dark panel per variant. A = today (the caller's own material).
struct RenderPanelMaterial: View {
    let variant: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        let tint = dark ? Color(hexString: "141414") : Color(hexString: RenderVariant.current.panelTint)
        let stroke = dark ? Color.white.opacity(0.10) : Color(hexString: RenderVariant.current.panelStroke)
        Group {
            switch variant {
            case "B":   // frosted + desaturated: heavy blur, high-opacity warm-neutral tint across the reading area
                ZStack {
                    shape.fill(.thickMaterial)
                    shape.fill(tint.opacity(dark ? 0.80 : 0.82))
                    shape.strokeBorder(stroke, lineWidth: dark ? 0.5 : 1.0)
                }
            case "C", "E":   // graduated: translucent top band → near-opaque behind the transcript
                GeometryReader { geo in
                    let band = min(0.35, 150 / max(geo.size.height, 1))
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(LinearGradient(stops: [
                            .init(color: tint.opacity(dark ? 0.30 : 0.35), location: 0),
                            .init(color: tint.opacity(dark ? 0.90 : 0.93), location: band),
                            .init(color: tint.opacity(dark ? 0.90 : 0.93), location: 1)],
                            startPoint: .top, endPoint: .bottom))
                        shape.strokeBorder(stroke, lineWidth: dark ? 0.5 : 1.0)
                    }
                }
            default:   // D: Liquid Glass (regular) for the whole panel
                Color.clear.glassEffect(.regular, in: shape)
            }
        }
        .padding(.bottom, -150)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

extension RenderVariant {
    /// The synthetic long answer for the panel renders (Sample-Library register; ≥ 3 paragraphs).
    static let longAnswerChat: Chat = {
        let epoch = Date(timeIntervalSince1970: 1_760_500_000)
        let answer = """
        Across your notes, three threads keep coming back: **paper**, **light**, and **grammar**. The paper notes are the most concrete — Tomoe River's thinness, how fountain-pen ink sits on top of it rather than sinking in, and the way a heavy nib shows through to the next page. [1]

        The light notes are looser. You describe the cucumber-water light of late afternoon, the colour of a north-facing room in winter, and a photograph whose shadows went blue rather than grey. They read less like observations than like a vocabulary you are building, one adjective at a time. [2]

        The grammar notes are the most argued. The gerund note sets out the difference between a verbal noun and a participle, then tests it against sentences you collected from novels — and admits two of them still don't fit either rule cleanly. [3]

        If you want one entry to start from, the gerund note is the most developed: it has the clearest question, the most examples, and a list of what you still want to check. The paper and light threads would each benefit from a single summary note that gathers the scattered observations in one place.
        """
        let cites = [1, 2, 3].map { i in
            ChatSession.Message.Citation(index: i, nodeID: "render-\(i)", title: ["Tomoe River paper", "Cucumber-water light", "On the Gerund"][i - 1],
                                         snippet: "Synthetic citation \(i).")
        }
        return Chat(id: UUID(), title: "What threads run through my notes?", createdAt: epoch, updatedAt: epoch,
                    messages: [.init(role: .user, text: "What threads run through my notes, and where should I start?"),
                               .init(role: .assistant, text: answer, citations: cites)])
    }()
}
#endif
