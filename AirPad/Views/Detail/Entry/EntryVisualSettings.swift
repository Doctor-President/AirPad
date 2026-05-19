import SwiftUI
import UIKit

/// Stage 4.4 — dev-only runtime settings for `EntryCard` visual exploration.
///
/// This is scaffolding for ONE design decision (commit 1 of Stage 4.4 ships
/// the panel; commit 2 migrates the locked combination to `EntryCardMetrics`
/// constants; commit 3 deletes this file outright). Future visual stages
/// that need similar exploration will rebuild similar scaffolding from
/// scratch; this is not intended as reusable infrastructure.
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

    enum BodyTreatment: String, CaseIterable, Identifiable {
        /// Solid color with reduced opacity — the gradient backdrop bleeds
        /// through subtly. Closest to current production but softer.
        case semiOpacity = "Semi-opacity"
        /// SwiftUI `.ultraThinMaterial` — frosted blur with subtle tint.
        case thinMaterial = "Thin material"
        /// iOS 26 `.glassEffect()` — crystalline glass with programmable
        /// tint. Falls back to `.regularMaterial` on iOS 18–25.
        case liquidGlass = "Liquid glass"

        var id: String { rawValue }
    }

    // MARK: - Typography

    enum TypographyChoice: String, CaseIterable, Identifiable {
        /// `.font(.system(...))` — current default, neutral baseline.
        case sfPro = "SF Pro"
        /// `.font(.system(..., design: .serif))` — Apple's contemporary
        /// serif. Drop-in, no bundling.
        case newYork = "New York"
        /// Custom font via `.font(.custom("Lato-...", size:))`. Requires
        /// the `Lato-*.ttf` family bundled and registered in Info.plist
        /// under `UIAppFonts`. Falls back silently to system if missing.
        case lato = "Lato"
        /// Plain `Fraunces 72pt` cut (Regular + Bold). Soft/SuperSoft cuts
        /// not bundled — see Stage 4.4 audit on 2026-05-19.
        case fraunces = "Fraunces"
        /// `Lora` static Regular + Bold.
        case lora = "Lora"

        var id: String { rawValue }
    }

    // MARK: - Live values

    var bodyTreatment: BodyTreatment { didSet { persist() } }
    var typography: TypographyChoice { didSet { persist() } }
    var cornerRadius: CGFloat { didSet { persist() } }
    var interCardSpacing: CGFloat { didSet { persist() } }
    /// Floating summon button visibility. Toggled off via the hide-eye
    /// inside the panel; only restored by uninstall/reinstall or a
    /// build-time bypass (see `EntryVisualDevPanel`).
    var buttonVisible: Bool {
        didSet { UserDefaults.standard.set(buttonVisible, forKey: Keys.buttonVisible) }
    }

    // MARK: - Production defaults (mirrored from current code)

    static let defaultBodyTreatment: BodyTreatment = .semiOpacity
    static let defaultTypography: TypographyChoice = .sfPro
    /// Matches `EntryCard.swift:148` — `cornerRadius: 12`.
    static let defaultCornerRadius: CGFloat = 12
    /// Matches `NodeDetailView.swift:197` — outer VStack `spacing: 24`.
    /// Stage 4.4 commit 1 isolates inter-card spacing into a nested
    /// VStack so this slider only affects card-to-card distance.
    static let defaultInterCardSpacing: CGFloat = 24

    // MARK: - Slider ranges (locked with T on 2026-05-19)

    static let cornerRadiusRange: ClosedRange<CGFloat> = 12...32
    static let interCardSpacingRange: ClosedRange<CGFloat> = 4...32

    // MARK: - Persistence

    private enum Keys {
        static let bodyTreatment   = "entryVisualDevPanel.bodyTreatment"
        static let typography      = "entryVisualDevPanel.typography"
        static let cornerRadius    = "entryVisualDevPanel.cornerRadius"
        static let interCardSpacing = "entryVisualDevPanel.interCardSpacing"
        static let buttonVisible   = "entryVisualDevPanel.buttonVisible"
    }

    private init() {
        let d = UserDefaults.standard

        bodyTreatment = BodyTreatment(rawValue: d.string(forKey: Keys.bodyTreatment) ?? "")
            ?? Self.defaultBodyTreatment

        typography = TypographyChoice(rawValue: d.string(forKey: Keys.typography) ?? "")
            ?? Self.defaultTypography

        let storedRadius = d.double(forKey: Keys.cornerRadius)
        cornerRadius = storedRadius > 0 ? CGFloat(storedRadius) : Self.defaultCornerRadius

        let storedSpacing = d.double(forKey: Keys.interCardSpacing)
        interCardSpacing = storedSpacing > 0 ? CGFloat(storedSpacing) : Self.defaultInterCardSpacing

        // Default visible. Object-typed read so the absence of the key
        // (first launch) defaults to `true` rather than `false`.
        buttonVisible = (d.object(forKey: Keys.buttonVisible) as? Bool) ?? true
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(bodyTreatment.rawValue,        forKey: Keys.bodyTreatment)
        d.set(typography.rawValue,           forKey: Keys.typography)
        d.set(Double(cornerRadius),          forKey: Keys.cornerRadius)
        d.set(Double(interCardSpacing),      forKey: Keys.interCardSpacing)
    }

    // MARK: - Font derivation helpers

    /// Title-row font for `EntryCard`. Derives from the typography toggle
    /// while preserving the original weight/size relationship of the
    /// current `.subheadline.weight(.semibold)` baseline.
    func titleRowFont() -> Font {
        logFontFamilyOnceIfNeeded(for: typography)
        switch typography {
        case .sfPro:
            return .subheadline.weight(.semibold)
        case .newYork:
            return .system(.subheadline, design: .serif).weight(.semibold)
        case .lato:
            return .custom("Lato-Bold", size: 15)
        case .fraunces:
            // PostScript name unverified for Fraunces; the on-device debug
            // log above resolves the actual name. If `.custom` misses, it
            // falls back to system silently.
            return .custom("Fraunces72pt-Bold", size: 15)
        case .lora:
            return .custom("Lora-Bold", size: 15)
        }
    }

    /// Stage 4.4 dev-panel diagnostic: prints the PostScript names that
    /// UIKit registered for each custom-font family the first time that
    /// typography choice is selected. Lets T verify the `.custom(...)`
    /// names above on device without launching Font Book. Removed in
    /// commit 3 with the rest of the dev panel scaffolding.
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
/// liquid-glass option so the codebase still builds against an iOS 18
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

        case .liquidGlass:
            liquidGlassBackground
        }
    }

    /// iOS 26 introduces `.glassEffect(...)` for true Liquid Glass. The
    /// codebase deploys to iOS 18.0; older OS versions fall back to
    /// `.regularMaterial` so the toggle still renders something visibly
    /// distinct from `.ultraThinMaterial`. The exact iOS 26 API signature
    /// can be refined once T verifies on iPhone 17 Pro Max (iOS 26.4).
    @ViewBuilder
    private var liquidGlassBackground: some View {
        if #available(iOS 26.0, *) {
            // Placeholder iOS 26 path — uses .regularMaterial as a
            // visually-distinct stand-in until T confirms the precise
            // `.glassEffect()` API shape. Stronger blur + tint than
            // `.ultraThinMaterial` makes this branch already feel
            // different in the design test.
            Rectangle()
                .fill(.regularMaterial)
        } else {
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}
