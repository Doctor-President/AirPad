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

        /// Baked from T's device-verified panel values (2026-07-17). These are
        /// what Release renders (panel is DEBUG-only; reads gated at 725a646).
        var defaultSettings: TypeRoleSettings {
            switch self {
            case .nodeTitle:
                return TypeRoleSettings(family: .fraunces, size: 35, weight: .bold)
            case .nodeSummary:
                return TypeRoleSettings(family: .fraunces, size: 17, weight: .regular)
            case .sectionTitle:
                // T picked Fraunces + "Semibold", but Fraunces ships Regular +
                // Bold only, so semibold clamps to the Bold file → it RENDERS
                // Bold (the weight T approved). Baked as `.bold` to encode the
                // actual render; `.semibold` is identical for Fraunces.
                return TypeRoleSettings(family: .fraunces, size: 20, weight: .bold)
            case .sectionTimestamp:
                // Unchanged from production: SF Pro 11 Regular.
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
    var titleRowHeight: CGFloat { didSet { persistShared() } }
    var heroMaxHeight: CGFloat { didSet { persistShared() } }
    var cardVerticalPadding: CGFloat { didSet { persistShared() } }
    var noteVerticalPadding: CGFloat { didSet { persistShared() } }
    var titleToSummary: CGFloat { didSet { persistShared() } }
    var summaryToChips: CGFloat { didSet { persistShared() } }
    var chipRowGap: CGFloat { didSet { persistShared() } }
    var chipsToDivider: CGFloat { didSet { persistShared() } }
    var dividerToEntries: CGFloat { didSet { persistShared() } }
    var entriesToRelated: CGFloat { didSet { persistShared() } }
    var stroke: StrokeSettings { didSet { persistStroke() } }
    /// Floating summon button visibility. Toggled off via the hide-eye
    /// inside the panel; only restored by uninstall/reinstall.
    var buttonVisible: Bool {
        didSet {
            #if DEBUG
            UserDefaults.standard.set(buttonVisible, forKey: Keys.buttonVisible)
            #endif
        }
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
    /// Baked from T's device (2026-07-17): 32 (was 12, `EntryCard.swift:148`).
    static let defaultCornerRadius: CGFloat = 32
    /// Card-to-card distance. Baked from T's device (2026-07-17): 4 (was 24).
    static let defaultInterCardSpacing: CGFloat = 4

    // MARK: - Slider ranges (locked with T on 2026-05-19)

    static let cornerRadiusRange: ClosedRange<CGFloat> = 12...32
    static let interCardSpacingRange: ClosedRange<CGFloat> = 4...32

    // Detail-View pass (2026-07) — title-zone + hero levers. Defaults == the
    // current hardcoded literals, so each dial is a no-op until T moves it.
    /// EntryTitleRow's fixed non-note row height (`:632`/`:682`) — the dominant
    /// title-zone-height lever per that row's own comment. Notes keep 34pt.
    static let defaultTitleRowHeight: CGFloat = 39   // baked from T's device (was 44)
    static let titleRowHeightRange: ClosedRange<CGFloat> = 28...56
    /// HeroImageBanner visible-height CAP (`:2721`, was a hardcoded 420). The
    /// image hero cover-crops to `max(200, min(cap, width/aspect))`; portraits
    /// fill to the cap, so lowering it is the lever for "the hero is too large."
    static let defaultHeroMaxHeight: CGFloat = 240   // baked (was 420); == range floor — T wants smaller, see report
    static let heroMaxHeightRange: ClosedRange<CGFloat> = 240...560
    /// EntryCard title-zone vertical padding (`EntryCard:184`), two branches:
    /// card (non-note) + note. T UNIFIED them on device (2026-07-17): both 12
    /// (note was 4). The type-conditional split at EntryCard:184 is now 12/12.
    static let defaultCardVerticalPadding: CGFloat = 12
    static let defaultNoteVerticalPadding: CGFloat = 12
    static let cardVerticalPaddingRange: ClosedRange<CGFloat> = 4...24
    static let noteVerticalPaddingRange: ClosedRange<CGFloat> = 0...24

    /// Detail-View outer rhythm (NodeDetailView content VStack) — SIX per-gap
    /// dials that replaced the single `spacing: 24`. Baked from T's device
    /// (2026-07-17); divider→entries + entries→related kept 24 deliberately.
    /// Range includes 0 → read via object-presence.
    static let defaultTitleToSummary: CGFloat = 4   // #3 — tightened 2pt from the detail view's 6 (shared, both surfaces)
    static let defaultSummaryToChips: CGFloat = 15
    static let defaultChipRowGap: CGFloat = 11
    static let defaultChipsToDivider: CGFloat = 12   // breathing room so the ATTRIBUTES hairline doesn't kiss the feather button / chips
    static let defaultDividerToEntries: CGFloat = 24
    static let defaultEntriesToRelated: CGFloat = 24
    static let metadataGapRange: ClosedRange<CGFloat> = 0...48

    // MARK: - Persistence

    private enum Keys {
        static let bodyTreatment    = "entryVisualDevPanel.bodyTreatment"
        static let cornerRadius     = "entryVisualDevPanel.cornerRadius"
        static let interCardSpacing = "entryVisualDevPanel.interCardSpacing"
        static let titleRowHeight   = "entryVisualDevPanel.titleRowHeight"
        static let heroMaxHeight    = "entryVisualDevPanel.heroMaxHeight"
        static let cardVerticalPadding = "entryVisualDevPanel.cardVerticalPadding"
        static let noteVerticalPadding = "entryVisualDevPanel.noteVerticalPadding"
        static let titleToSummary   = "entryVisualDevPanel.gap.titleToSummary"
        static let summaryToChips   = "entryVisualDevPanel.gap.summaryToChips"
        static let chipRowGap       = "entryVisualDevPanel.gap.chipRowGap"
        static let chipsToDivider   = "entryVisualDevPanel.gap.chipsToDivider"
        static let dividerToEntries = "entryVisualDevPanel.gap.dividerToEntries"
        static let entriesToRelated = "entryVisualDevPanel.gap.entriesToRelated"
        static let buttonVisible    = "entryVisualDevPanel.buttonVisible"
        static let stroke           = "entryVisualDevPanel.stroke"
        static func role(_ r: Role) -> String { "entryVisualDevPanel.role.\(r.rawValue)" }
    }

    private init() {
        #if DEBUG
        // DEBUG: the dev panel exists, so pull T's dialed values from
        // UserDefaults (each falls through to the in-code default when absent).
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

        let storedTitleRow = d.double(forKey: Keys.titleRowHeight)
        titleRowHeight = storedTitleRow > 0 ? CGFloat(storedTitleRow) : Self.defaultTitleRowHeight

        let storedHeroMax = d.double(forKey: Keys.heroMaxHeight)
        heroMaxHeight = storedHeroMax > 0 ? CGFloat(storedHeroMax) : Self.defaultHeroMaxHeight

        // Object-presence (not `> 0`) so a dialed 0 persists — noteVerticalPadding's
        // range includes 0.
        cardVerticalPadding = d.object(forKey: Keys.cardVerticalPadding) != nil
            ? CGFloat(d.double(forKey: Keys.cardVerticalPadding)) : Self.defaultCardVerticalPadding
        noteVerticalPadding = d.object(forKey: Keys.noteVerticalPadding) != nil
            ? CGFloat(d.double(forKey: Keys.noteVerticalPadding)) : Self.defaultNoteVerticalPadding

        // Detail-View outer rhythm — object-presence (range includes 0).
        func gap(_ key: String, _ def: CGFloat) -> CGFloat {
            d.object(forKey: key) != nil ? CGFloat(d.double(forKey: key)) : def
        }
        titleToSummary   = gap(Keys.titleToSummary,   Self.defaultTitleToSummary)
        summaryToChips   = gap(Keys.summaryToChips,   Self.defaultSummaryToChips)
        chipRowGap       = gap(Keys.chipRowGap,       Self.defaultChipRowGap)
        chipsToDivider   = gap(Keys.chipsToDivider,   Self.defaultChipsToDivider)
        dividerToEntries = gap(Keys.dividerToEntries, Self.defaultDividerToEntries)
        entriesToRelated = gap(Keys.entriesToRelated, Self.defaultEntriesToRelated)

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
        #else
        // RELEASE: no panel ships (mount is #if DEBUG), so ignore UserDefaults
        // entirely and render from the in-code defaults with ZERO UserDefaults
        // access (ws-chat-lane / MapTuning.isOn scar). The Detail View then
        // renders identically every launch — this is what kills T's reinstall
        // drift, even before the bake to AirPadTypeScale / EntryCardMetrics.
        bodyTreatment    = Self.defaultBodyTreatment
        cornerRadius     = Self.defaultCornerRadius
        interCardSpacing = Self.defaultInterCardSpacing
        titleRowHeight   = Self.defaultTitleRowHeight
        heroMaxHeight    = Self.defaultHeroMaxHeight
        cardVerticalPadding = Self.defaultCardVerticalPadding
        noteVerticalPadding = Self.defaultNoteVerticalPadding
        titleToSummary   = Self.defaultTitleToSummary
        summaryToChips   = Self.defaultSummaryToChips
        chipRowGap       = Self.defaultChipRowGap
        chipsToDivider   = Self.defaultChipsToDivider
        dividerToEntries = Self.defaultDividerToEntries
        entriesToRelated = Self.defaultEntriesToRelated
        buttonVisible    = false
        nodeTitle        = Role.nodeTitle.defaultSettings
        nodeSummary      = Role.nodeSummary.defaultSettings
        sectionTitle     = Role.sectionTitle.defaultSettings
        sectionTimestamp = Role.sectionTimestamp.defaultSettings
        stroke           = Self.defaultStroke
        #endif
    }

    private static func loadRole(_ role: Role, defaults d: UserDefaults) -> TypeRoleSettings? {
        guard let data = d.data(forKey: Keys.role(role)) else { return nil }
        return try? JSONDecoder().decode(TypeRoleSettings.self, from: data)
    }

    // All writes are #if DEBUG — in Release the setters are only reachable
    // from the (DEBUG-only) panel, but gating the bodies too makes the
    // "zero UserDefaults access in Release" guarantee airtight.
    private func persistShared() {
        #if DEBUG
        let d = UserDefaults.standard
        d.set(bodyTreatment.rawValue,    forKey: Keys.bodyTreatment)
        d.set(Double(cornerRadius),      forKey: Keys.cornerRadius)
        d.set(Double(interCardSpacing),  forKey: Keys.interCardSpacing)
        d.set(Double(titleRowHeight),    forKey: Keys.titleRowHeight)
        d.set(Double(heroMaxHeight),     forKey: Keys.heroMaxHeight)
        d.set(Double(cardVerticalPadding), forKey: Keys.cardVerticalPadding)
        d.set(Double(noteVerticalPadding), forKey: Keys.noteVerticalPadding)
        d.set(Double(titleToSummary),   forKey: Keys.titleToSummary)
        d.set(Double(summaryToChips),   forKey: Keys.summaryToChips)
        d.set(Double(chipRowGap),       forKey: Keys.chipRowGap)
        d.set(Double(chipsToDivider),   forKey: Keys.chipsToDivider)
        d.set(Double(dividerToEntries), forKey: Keys.dividerToEntries)
        d.set(Double(entriesToRelated), forKey: Keys.entriesToRelated)
        #endif
    }

    private func persistRole(_ role: Role) {
        #if DEBUG
        let s = self.settings(for: role)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Keys.role(role))
        }
        logFontFamilyOnceIfNeeded(for: s.family)
        #endif
    }

    private func persistStroke() {
        #if DEBUG
        if let data = try? JSONEncoder().encode(stroke) {
            UserDefaults.standard.set(data, forKey: Keys.stroke)
        }
        #endif
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
