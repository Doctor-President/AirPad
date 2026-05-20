import SwiftUI
import UIKit

/// Stage 4.4 — dev-only runtime settings for `EntryCard` + `NodeDetailView`
/// visual exploration.
///
/// **Self-deleting infrastructure.** Commit 1 shipped the panel; addendum
/// 1a-i expands to a 4-role type scale (Node Title / Summary / Section
/// Title / Section Timestamp) plus iOS 26 glass variants; 1a-iii adds the
/// outline stroke. Commit 2 will migrate locked values to permanent
/// `AirPadTypeScale` + `EntryCardMetrics` structs. Commit 3 deletes this
/// file outright. Body-role typography deferred to Stage 2.3 (the editor's
/// font management has its own regression surface).
///
/// Singleton because the dev panel (mounted at `ContentView` root) and the
/// cards (deep inside `NodeDetailView`) live in different view trees, and
/// threading an `@Environment` value through every container in between is
/// noise for a throwaway. UserDefaults-only persistence — no schema
/// additions, no model changes, nothing corpus-side.
@Observable
@MainActor
final class EntryVisualSettings {

    static let shared = EntryVisualSettings()

    // MARK: - Body treatment

    /// Background fill style applied behind every `EntryCard`. iOS 26
    /// glass variants render via `.glassEffect()`; on iOS 18-25 they fall
    /// back to `.regularMaterial` so the picker still produces a
    /// recognisable result on older devices.
    enum BodyTreatment: String, CaseIterable, Identifiable {
        case semiOpacity       = "Semi-opacity"
        case thinMaterial      = "Thin material"
        case glassRegular      = "Glass: Regular"
        case glassClear        = "Glass: Clear"
        case glassKleinBlue    = "Glass: Klein Blue"
        case glassMango        = "Glass: Mango"
        case glassElectricCyan = "Glass: Electric Cyan"

        var id: String { rawValue }
    }

    // MARK: - Typography family

    enum TypographyChoice: String, Codable, CaseIterable, Identifiable {
        case sfPro    = "SF Pro"
        case newYork  = "New York"
        case lato     = "Lato"
        case fraunces = "Fraunces"
        case lora     = "Lora"

        var id: String { rawValue }

        /// PostScript name for the bundled `.ttf`. We only bundled Regular
        /// + Bold per custom family, so the weight picker collapses to a
        /// binary file choice for Lato/Fraunces/Lora (see
        /// `FontWeightChoice.clampsToBoldFile`). System families return
        /// `nil` so callers route to `.system(...)` with a real weight.
        func postScriptName(boldFile: Bool) -> String? {
            switch self {
            case .sfPro, .newYork:
                return nil
            case .lato:
                return boldFile ? "Lato-Bold" : "Lato-Regular"
            case .fraunces:
                // PostScript name unverified on device. The runtime debug
                // log in `logFontFamilyOnceIfNeeded(...)` resolves the
                // actual name on first selection so T can correct here.
                return boldFile ? "Fraunces72pt-Bold" : "Fraunces72pt-Regular"
            case .lora:
                return boldFile ? "Lora-Bold" : "Lora-Regular"
            }
        }
    }

    // MARK: - Font weight

    /// Local Codable mirror of `Font.Weight` (the SwiftUI type isn't
    /// Codable so it can't survive a JSON UserDefaults round-trip).
    enum FontWeightChoice: String, Codable, CaseIterable, Identifiable {
        case regular  = "Regular"
        case medium   = "Medium"
        case semibold = "Semibold"
        case bold     = "Bold"

        var id: String { rawValue }

        var swiftUI: Font.Weight {
            switch self {
            case .regular:  return .regular
            case .medium:   return .medium
            case .semibold: return .semibold
            case .bold:     return .bold
            }
        }

        /// For bundled custom fonts (Lato/Fraunces/Lora) only Regular and
        /// Bold .ttf files are shipped. The 4-option weight picker clamps:
        /// regular/medium → Regular file, semibold/bold → Bold file. The
        /// dev panel surfaces this as a caveat under the type-scale
        /// section so T isn't surprised during iteration.
        var clampsToBoldFile: Bool {
            switch self {
            case .regular, .medium:   return false
            case .semibold, .bold:    return true
            }
        }
    }

    // MARK: - Type role

    /// One slot in the type scale. Holds the three independent dimensions
    /// (family / size / weight). Codable so each role serialises as a
    /// single JSON blob in UserDefaults — cleaner than 15 scalar keys and
    /// tolerant to adding a 6th role later without migration.
    struct TypeRoleSettings: Codable, Equatable {
        var family: TypographyChoice
        var size: CGFloat
        var weight: FontWeightChoice

        func resolvedFont() -> Font {
            if let postScript = family.postScriptName(boldFile: weight.clampsToBoldFile) {
                // Custom fonts encode weight in the file name; the
                // `.weight()` modifier on top of `.custom(...)` is a no-op
                // and would only mislead, so we don't apply it.
                return .custom(postScript, size: size)
            }
            let design: Font.Design = (family == .newYork) ? .serif : .default
            return .system(size: size, weight: weight.swiftUI, design: design)
        }
    }

    /// Four type-scale roles that the dev panel exposes. The Body role
    /// (text rendered inside `RichTextEditor`) is intentionally absent —
    /// deferred to Stage 2.3 where the editor's font management gets its
    /// dedicated regression window.
    enum Role: String, CaseIterable, Identifiable {
        case nodeTitle
        case nodeSummary
        case sectionTitle
        case sectionTimestamp

        var id: String { rawValue }

        var label: String {
            switch self {
            case .nodeTitle:        return "Node title"
            case .nodeSummary:      return "Node summary"
            case .sectionTitle:     return "Section title"
            case .sectionTimestamp: return "Section timestamp"
            }
        }

        /// Slider bounds (pt) — defaults sit comfortably in range. Step
        /// 0.5pt per the addendum brief.
        var sizeRange: ClosedRange<CGFloat> {
            switch self {
            case .nodeTitle:        return 22...36
            case .nodeSummary:      return 13...22
            case .sectionTitle:     return 13...20
            case .sectionTimestamp: return 9...14
            }
        }

        /// Defaults reproduce the pre-1a-i production look: the panel
        /// opens at "no change" so toggling between roles is the only way
        /// to introduce drift.
        var defaultSettings: TypeRoleSettings {
            switch self {
            case .nodeTitle:
                // `NodeDetailView.swift:205` — `.title2.weight(.bold)`
                // ≈ 22pt bold.
                return TypeRoleSettings(family: .sfPro, size: 22, weight: .bold)
            case .nodeSummary:
                // `NodeDetailView.swift:213` — `.body` = 17pt regular.
                return TypeRoleSettings(family: .sfPro, size: 17, weight: .regular)
            case .sectionTitle:
                // `EntryCard.swift:361` — `.subheadline.weight(.semibold)`
                // = 15pt semibold.
                return TypeRoleSettings(family: .sfPro, size: 15, weight: .semibold)
            case .sectionTimestamp:
                // `EntryCard.swift:403` — `.caption2` = 11pt regular.
                return TypeRoleSettings(family: .sfPro, size: 11, weight: .regular)
            }
        }
    }

    // MARK: - Stroke

    /// Outline stroke applied around each `EntryCard`. Orthogonal to the
    /// body fill — stacks on top of whichever `BodyTreatment` is active.
    /// Stored as a single JSON blob so the persistence pattern matches
    /// the type-role storage above (one Codable struct per concept, not
    /// five scalar keys for a single visual element).
    struct StrokeSettings: Codable, Equatable {
        /// 6-digit sRGB hex (no `#`). White starting point so colour
        /// shows immediately on first enable; T dials from there.
        var colorHex: String
        /// 0.0 — 1.0. Applied on top of the picked colour so the picker
        /// stays full-alpha and the slider owns the visibility dimension.
        var opacity: Double
        /// 0pt — 4pt. Default 0 means no stroke is rendered, so the panel
        /// opens with "no change from production" (same baseline contract
        /// as the type-scale defaults).
        var width: CGFloat
    }

    static let defaultStroke = StrokeSettings(colorHex: "FFFFFF", opacity: 1.0, width: 0)
    static let strokeOpacityRange: ClosedRange<Double> = 0...1
    static let strokeWidthRange: ClosedRange<CGFloat> = 0...4

    // MARK: - Live values

    var bodyTreatment: BodyTreatment { didSet { persistShared() } }
    var cornerRadius: CGFloat { didSet { persistShared() } }
    var interCardSpacing: CGFloat { didSet { persistShared() } }
    var stroke: StrokeSettings { didSet { persistStroke() } }
    /// Floating summon button visibility. Toggled off via the hide-eye
    /// inside the panel; only restored by uninstall/reinstall.
    var buttonVisible: Bool {
        didSet { UserDefaults.standard.set(buttonVisible, forKey: Keys.buttonVisible) }
    }

    var nodeTitle: TypeRoleSettings        { didSet { persistRole(.nodeTitle) } }
    var nodeSummary: TypeRoleSettings      { didSet { persistRole(.nodeSummary) } }
    var sectionTitle: TypeRoleSettings     { didSet { persistRole(.sectionTitle) } }
    var sectionTimestamp: TypeRoleSettings { didSet { persistRole(.sectionTimestamp) } }

    func settings(for role: Role) -> TypeRoleSettings {
        switch role {
        case .nodeTitle:        return nodeTitle
        case .nodeSummary:      return nodeSummary
        case .sectionTitle:     return sectionTitle
        case .sectionTimestamp: return sectionTimestamp
        }
    }

    // MARK: - Production defaults (mirrored from current code)

    static let defaultBodyTreatment: BodyTreatment = .semiOpacity
    /// Matches `EntryCard.swift:148` — `cornerRadius: 12`.
    static let defaultCornerRadius: CGFloat = 12
    /// Stage 4.4 commit 1 nested cards in their own VStack so this slider
    /// only affects card-to-card distance.
    static let defaultInterCardSpacing: CGFloat = 24

    // MARK: - Slider ranges (locked with T on 2026-05-19)

    static let cornerRadiusRange: ClosedRange<CGFloat> = 12...32
    static let interCardSpacingRange: ClosedRange<CGFloat> = 4...32

    // MARK: - Persistence

    private enum Keys {
        static let bodyTreatment    = "entryVisualDevPanel.bodyTreatment"
        static let cornerRadius     = "entryVisualDevPanel.cornerRadius"
        static let interCardSpacing = "entryVisualDevPanel.interCardSpacing"
        static let buttonVisible    = "entryVisualDevPanel.buttonVisible"
        static let stroke           = "entryVisualDevPanel.stroke"
        static func role(_ r: Role) -> String { "entryVisualDevPanel.role.\(r.rawValue)" }
    }

    private init() {
        let d = UserDefaults.standard

        // BodyTreatment: legacy "Liquid glass" raw value from commit 1 no
        // longer matches any case after the glass-variant expansion, so
        // it falls through to the default. That's fine — T's locked
        // pre-1a-i selection was the placeholder, not the real glass.
        bodyTreatment = BodyTreatment(rawValue: d.string(forKey: Keys.bodyTreatment) ?? "")
            ?? Self.defaultBodyTreatment

        let storedRadius = d.double(forKey: Keys.cornerRadius)
        cornerRadius = storedRadius > 0 ? CGFloat(storedRadius) : Self.defaultCornerRadius

        let storedSpacing = d.double(forKey: Keys.interCardSpacing)
        interCardSpacing = storedSpacing > 0 ? CGFloat(storedSpacing) : Self.defaultInterCardSpacing

        // Default visible. Object-typed read so the absence of the key
        // (first launch) defaults to `true` rather than `false`.
        buttonVisible = (d.object(forKey: Keys.buttonVisible) as? Bool) ?? true

        // Per-role JSON blobs. Each falls through to the role's
        // production-mirroring default if absent or unparseable.
        nodeTitle        = Self.loadRole(.nodeTitle,        defaults: d) ?? Role.nodeTitle.defaultSettings
        nodeSummary      = Self.loadRole(.nodeSummary,      defaults: d) ?? Role.nodeSummary.defaultSettings
        sectionTitle     = Self.loadRole(.sectionTitle,     defaults: d) ?? Role.sectionTitle.defaultSettings
        sectionTimestamp = Self.loadRole(.sectionTimestamp, defaults: d) ?? Role.sectionTimestamp.defaultSettings

        // Stroke: single JSON blob. Falls through to "width: 0" default
        // so the card edge is untouched until T explicitly enables it.
        if let data = d.data(forKey: Keys.stroke),
           let decoded = try? JSONDecoder().decode(StrokeSettings.self, from: data) {
            stroke = decoded
        } else {
            stroke = Self.defaultStroke
        }
    }

    private static func loadRole(_ role: Role, defaults d: UserDefaults) -> TypeRoleSettings? {
        guard let data = d.data(forKey: Keys.role(role)) else { return nil }
        return try? JSONDecoder().decode(TypeRoleSettings.self, from: data)
    }

    private func persistShared() {
        let d = UserDefaults.standard
        d.set(bodyTreatment.rawValue,    forKey: Keys.bodyTreatment)
        d.set(Double(cornerRadius),      forKey: Keys.cornerRadius)
        d.set(Double(interCardSpacing),  forKey: Keys.interCardSpacing)
    }

    private func persistRole(_ role: Role) {
        let s = self.settings(for: role)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Keys.role(role))
        }
        logFontFamilyOnceIfNeeded(for: s.family)
    }

    private func persistStroke() {
        if let data = try? JSONEncoder().encode(stroke) {
            UserDefaults.standard.set(data, forKey: Keys.stroke)
        }
    }

    // MARK: - Font diagnostic

    /// Stage 4.4 dev-panel diagnostic: prints the PostScript names that
    /// UIKit registered for each custom-font family the first time that
    /// typography choice is selected. Lets T verify the
    /// `postScriptName(boldFile:)` mappings on device without launching
    /// Font Book. Removed in commit 3 with the rest of the dev panel.
    @ObservationIgnored private var loggedFamilies: Set<String> = []
    private func logFontFamilyOnceIfNeeded(for choice: TypographyChoice) {
        let family: String?
        switch choice {
        case .lato:     family = "Lato"
        case .fraunces: family = "Fraunces 72pt"
        case .lora:     family = "Lora"
        case .sfPro, .newYork: family = nil
        }
        guard let family, !loggedFamilies.contains(family) else { return }
        loggedFamilies.insert(family)
        let names = UIFont.fontNames(forFamilyName: family)
        print("[EntryVisualSettings] PostScript names for family '\(family)': \(names.isEmpty ? "<none — not registered>" : names.joined(separator: ", "))")
    }
}

// MARK: - Body treatment view

/// Renders the active body treatment as a SwiftUI view, ready to drop into
/// `EntryCard`'s background slot. Branches at the iOS 26 boundary for the
/// glass variants so the codebase still builds against an iOS 18
/// deployment target.
struct EntryCardBackground: View {

    let treatment: EntryVisualSettings.BodyTreatment

    var body: some View {
        switch treatment {
        case .semiOpacity:
            Color(.secondarySystemBackground)
                .opacity(0.85)

        case .thinMaterial:
            Rectangle()
                .fill(.ultraThinMaterial)

        case .glassRegular, .glassClear,
             .glassKleinBlue, .glassMango, .glassElectricCyan:
            glassBackground
        }
    }

    /// Glass branch. iOS 26 calls `.glassEffect()` with the appropriate
    /// `Glass` value; pre-iOS 26 falls back to `.regularMaterial` so
    /// older devices still render something visually distinct from
    /// `.ultraThinMaterial`. Tint hex values match the brief
    /// (Klein Blue #1B59C2, Mango #E8820A, Electric Cyan #00BFFF).
    @ViewBuilder
    private var glassBackground: some View {
        if #available(iOS 26.0, *) {
            glassEffectView
        } else {
            Rectangle()
                .fill(.regularMaterial)
        }
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private var glassEffectView: some View {
        switch treatment {
        case .glassRegular:
            Color.clear.glassEffect(.regular, in: Rectangle())
        case .glassClear:
            Color.clear.glassEffect(.clear, in: Rectangle())
        case .glassKleinBlue:
            Color.clear.glassEffect(.regular.tint(Color(hexString: "1B59C2")), in: Rectangle())
        case .glassMango:
            Color.clear.glassEffect(.regular.tint(Color(hexString: "E8820A")), in: Rectangle())
        case .glassElectricCyan:
            Color.clear.glassEffect(.regular.tint(Color(hexString: "00BFFF")), in: Rectangle())
        case .semiOpacity, .thinMaterial:
            // Unreachable: outer switch handles these before this view
            // is consulted. Present so the compiler is satisfied.
            Color.clear
        }
    }
}

// MARK: - Hex extraction (stroke ColorPicker round-trip)

/// Extracts a 6-digit sRGB hex string from a UIColor. Stroke storage in
/// `EntryVisualSettings.StrokeSettings.colorHex` round-trips through this:
/// the dev panel's ColorPicker outputs a SwiftUI Color, we wrap it as
/// `UIColor(color).sRGBHexString` for persistence, then rebuild on read
/// via `Color(hexString:)`. Wide-gamut → sRGB conversion is `getRed`'s
/// job; alpha is dropped on purpose (the panel exposes opacity as its
/// own slider so the picker stays full-alpha).
///
/// Deleted in commit 3 with the rest of the dev-panel scaffolding.
extension UIColor {
    var sRGBHexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((max(0, min(1, r)) * 255).rounded())
        let gi = Int((max(0, min(1, g)) * 255).rounded())
        let bi = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "%02X%02X%02X", ri, gi, bi)
    }
}
