#if DEBUG
import SwiftUI
import UIKit

//  Brief BB4 — DEBUG-ONLY type-system preview harness.
//
//  Purpose: render the SIX candidate type systems (Ops/reference/typography-audit.md §10)
//  through the app's REAL primitives — the real MSDF atlas + shader for orb titles, the real
//  territory pill, the real card, the real entry — so T judges type in the shipping
//  primitive rather than a specimen sheet (the banked lesson from the note-editor arc).
//
//  ★ Release is byte-identical. Every override site is `#if DEBUG` and returns nil when no
//  `-TypeSystem` launch arg is present, so the shipping expression is what compiles in
//  Release. This whole file is compiled out.
//
//  Launch args:
//    -TypeSystem <1...6>     pick a candidate system
//    -OrbRole label|title    orb titles use the system's LABEL face (default, = today's
//                            condensed-caps register) or its TITLE face (so an orb and its
//                            card read as siblings). T asked to see both (Brief BB).
//
//  Two honest limits, surfaced in the preview's own caption:
//   · Space Grotesk and Playfair ship ONLY as pre-baked MSDF atlases — there is no .ttf — so
//     system 5's card/entry cannot render in its own face. It falls back to Lato and says so.
//   · SF Pro / New York cannot be baked into an atlas (Apple's license), so systems 3 and 4
//     BORROW a bundled face for the Map. That is the real constraint, not a harness gap.

/// A face a role can be set in. `resolvable == false` means the family has no bundled `.ttf`
/// (atlas-only), so SwiftUI/UIKit text must substitute — the preview labels it.
enum TypeFace: String {
    case sourceSerif4, fraunces, lato, lora, spaceGrotesk, sfPro, newYork

    /// PostScript name for the bundled families; nil for system faces + atlas-only families.
    private func postScript(bold: Bool, italic: Bool = false) -> String? {
        switch self {
        case .sourceSerif4: return bold ? "SourceSerif4-Bold" : "SourceSerif4-Regular"
        case .fraunces:     return bold ? "Fraunces72pt-Bold" : "Fraunces72pt-Regular"
        case .lato:         return bold ? "Lato-Bold" : "Lato-Regular"
        case .lora:         return bold ? "Lora-Bold" : "Lora-Regular"
        case .sfPro, .newYork, .spaceGrotesk: return nil
        }
    }

    /// True when the face can actually be set in SwiftUI/UIKit text today.
    var resolvable: Bool { self != .spaceGrotesk }

    /// The face used to STAND IN when this one can't be resolved (atlas-only families).
    var substitute: TypeFace { self == .spaceGrotesk ? .lato : self }

    /// `Font.Weight` is not `Comparable`, so "is this a bold cut?" is an explicit set.
    static func isBold(_ w: Font.Weight) -> Bool {
        [.semibold, .bold, .heavy, .black].contains(w)
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        let face = substitute
        let bold = TypeFace.isBold(weight)
        if let ps = face.postScript(bold: bold) { return .custom(ps, size: size) }
        switch face {
        case .newYork: return .system(size: size, weight: weight, design: .serif)
        default:       return .system(size: size, weight: weight)
        }
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let face = substitute
        let bold = weight.rawValue >= UIFont.Weight.semibold.rawValue
        if let ps = face.postScript(bold: bold), let f = UIFont(name: ps, size: size) { return f }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if face == .newYork, let d = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: d, size: size)
        }
        return base
    }
}

/// One candidate system: a face per role + the Map atlas for each orb-role variant.
struct TypeSystemSpec {
    let id: Int
    let name: String
    let display: TypeFace
    let title: TypeFace
    let body: TypeFace
    let label: TypeFace
    /// Atlas when orb titles wear the LABEL face (today's register).
    let orbAtlasLabel: String
    /// Atlas when orb titles wear the TITLE face (orb + card as siblings).
    let orbAtlasTitle: String
    /// Caveat shown in the preview caption — borrowed Map face, or a stand-in body face.
    let caveat: String?

    static let all: [TypeSystemSpec] = [
        .init(id: 1, name: "Editorial (today)",
              display: .fraunces, title: .sourceSerif4, body: .sourceSerif4, label: .spaceGrotesk,
              orbAtlasLabel: "spacegroteskbold_msdf", orbAtlasTitle: "sourceserif_msdf",
              caveat: nil),
        .init(id: 2, name: "One-Voice Serif",
              display: .sourceSerif4, title: .sourceSerif4, body: .sourceSerif4, label: .sourceSerif4,
              orbAtlasLabel: "sourceserifblack_msdf", orbAtlasTitle: "sourceserif_msdf",
              caveat: nil),
        .init(id: 3, name: "System (SF Pro)",
              display: .sfPro, title: .sfPro, body: .sfPro, label: .sfPro,
              orbAtlasLabel: "spacegroteskbold_msdf", orbAtlasTitle: "lato_msdf",
              caveat: "Map BORROWS a bundled face — SF Pro can't be baked into an atlas (Apple license)."),
        .init(id: 4, name: "New York",
              display: .newYork, title: .newYork, body: .newYork, label: .newYork,
              orbAtlasLabel: "spacegroteskbold_msdf", orbAtlasTitle: "sourceserif_msdf",
              caveat: "Map BORROWS a bundled face — New York can't be baked into an atlas (Apple license)."),
        .init(id: 5, name: "Grotesk (Space Grotesk)",
              display: .spaceGrotesk, title: .spaceGrotesk, body: .spaceGrotesk, label: .spaceGrotesk,
              orbAtlasLabel: "spacegroteskbold_msdf", orbAtlasTitle: "spacegroteskbold_msdf",
              caveat: "Map is REAL Space Grotesk; card/entry stand in with Lato — the family ships as an atlas only (no .ttf, ~200KB to add)."),
        .init(id: 6, name: "Humanist (Lato)",
              display: .lato, title: .lato, body: .lato, label: .lato,
              orbAtlasLabel: "latoblack_msdf", orbAtlasTitle: "lato_msdf",
              caveat: nil),
    ]
}

enum TypeSystemPreview {

    /// The active system, or nil when the app launched normally (→ every override no-ops).
    static let active: TypeSystemSpec? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-TypeSystem"), i + 1 < args.count,
              let n = Int(args[i + 1]),
              let spec = TypeSystemSpec.all.first(where: { $0.id == n }) else {
            NSLog("[TypeSystemPreview] no system active")
            return nil
        }
        NSLog("[TypeSystemPreview] ACTIVE = %d %@", spec.id, spec.name)
        return spec
    }()

    /// `-OrbRole title` → orb titles wear the system's TITLE face instead of its LABEL face.
    static let orbUsesTitleFace: Bool = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OrbRole"), i + 1 < args.count else { return false }
        return args[i + 1].lowercased() == "title"
    }()

    /// Atlas name the Map should render orb titles from, or nil to keep the shipping face.
    static var orbAtlasName: String? {
        guard let s = active else { return nil }
        return orbUsesTitleFace ? s.orbAtlasTitle : s.orbAtlasLabel
    }

    // MARK: Per-role overrides — each returns nil when no system is active.

    /// Card view (all roles) — the card is one serif today, so weight carries the role.
    ///
    /// ⚠ **KNOWN-UNRESOLVED (Brief BB4).** This is wired into `NodeCardView.cardFont` at all
    /// 11 of the card's font sites, and `active` is confirmed non-nil in a `-OpenCardView
    /// -TypeSystem n` launch, yet the rendered card type does NOT change — it still shows the
    /// shipping `.system(design: .serif)` (New York). Cause not isolated; a card-render
    /// caching path is the leading suspect, not this function. The Map previews are
    /// unaffected and verified. Do not trust card captures from this harness until fixed.
    static func cardFont(size: CGFloat, weight: Font.Weight) -> Font? {
        guard let s = active else { return nil }
        // Card title is the Title role; the small tracked caps are Label; the rest is Body.
        let face: TypeFace = TypeFace.isBold(weight) ? s.title : (size <= 11 ? s.label : s.body)
        return face.substitute.font(size: size, weight: weight)
    }

    /// Entry + item TITLE role (SwiftUI): entry title, collapsed item rows.
    static func titleFont(size: CGFloat) -> Font? {
        guard let s = active else { return nil }
        return (size >= 28 ? s.display : s.title).substitute.font(size: size, weight: .bold)
    }

    /// Territory pill (Label role).
    static func pillFont(size: CGFloat) -> Font? {
        guard let s = active else { return nil }
        return s.label.substitute.font(size: size, weight: .bold)
    }

    /// Note body + the entry-title run inside the editor (UIKit).
    static func bodyUIFont(size: CGFloat, weight: UIFont.Weight, italic: Bool) -> UIFont? {
        guard let s = active else { return nil }
        let f = s.body.substitute.uiFont(size: size, weight: weight)
        return italic ? NoteTypographyHelper.italicized(f) : f
    }

    /// The entry-title run inside the live editor (UIKit) — the Title role, bold.
    static func titleUIFont(size: CGFloat, italic: Bool) -> UIFont? {
        guard let s = active else { return nil }
        let f = s.title.substitute.uiFont(size: size, weight: .bold)
        return italic ? NoteTypographyHelper.italicized(f) : f
    }

    /// One-line caption stamped onto a capture so a frame is never ambiguous.
    static var caption: String? {
        guard let s = active else { return nil }
        let orb = orbUsesTitleFace ? "orb=TITLE face" : "orb=LABEL face"
        return "\(s.id). \(s.name) · \(orb)" + (s.caveat.map { " · ⚠ \($0)" } ?? "")
    }
}
#endif
