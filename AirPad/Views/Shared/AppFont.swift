import SwiftUI
import UIKit

// Brief BF — the app-wide TYPE REGISTRY.
//
// One family — the user's chosen `EntryBodyFont` (Settings → Appearance → Font) — drives
// every CONTENT text surface: Display / Title / Body / Label / Meta. Two roles stay
// platform-native and are NOT resolved here: Mono = SF Mono, and UI chrome (nav, toolbars,
// buttons, menus, search fields, Settings rows, SF Symbols) = SF Pro. Map orb titles are a
// SEPARATE choice (`MapOrbFont`, resolved through the MSDF atlas path), independent of Font.
//
// The resolver PRESERVES each call site's existing size + weight + Dynamic Type behaviour
// (Brief BF: "Preserve today's Dynamic Type behaviour site by site — no sweep"). It swaps
// only the FACE to follow the chosen family. Pass `relativeTo:` at the sites that already
// scaled with Dynamic Type (Librarian, first-run callouts, semantic-style sites); omit it to
// keep the fixed point sizes the audit recorded.

extension EntryBodyFont {

    /// The registry core: a `UIFont` in this family at `size` / `weight` / `italic`. Reuses
    /// the AZ4 rendering resolver (`NoteFontChoice.resolveFont`); the four app faces always
    /// resolve (the system fallback covers a missing bundled cut, e.g. Lato has no italic
    /// face — it is synthesised), so this never falls back to the WRONG family.
    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        if let f = noteFontChoice.resolveFont(size: size, weight: weight.rawValue, italic: italic) {
            return f
        }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return italic ? NoteTypographyHelper.italicized(base) : base
    }

    /// A SwiftUI `Font` in this family at `size` / `weight` / `italic`. When `relativeTo:` is
    /// given the font rides Dynamic Type through `UIFontMetrics` (the same mechanism
    /// `Font.custom(_:size:relativeTo:)` uses, applied uniformly to bundled AND system
    /// faces); omit it for a fixed-size site. Italic is baked into the resolved `UIFont`
    /// (the reliable `withSymbolicTraits` path), not applied as a Text modifier.
    func font(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false,
              relativeTo textStyle: UIFont.TextStyle? = nil) -> Font {
        let base = uiFont(size: size, weight: weight, italic: italic)
        if let ts = textStyle {
            return Font(UIFontMetrics(forTextStyle: ts).scaledFont(for: base))
        }
        return Font(base)
    }
}

// MARK: - Environment plumbing (live switching)

private struct AppBodyFontKey: EnvironmentKey {
    static let defaultValue: EntryBodyFont = .fallback
}

extension EnvironmentValues {
    /// The app-wide chosen content face. Injected once near the root from a single
    /// `@AppStorage` read (see `provideAppBodyFont()`), so content views read it cheaply
    /// from the environment and re-render LIVE when the choice changes — without each view
    /// re-reading UserDefaults every `body` pass (the `@AppStorage`-per-frame cost).
    ///
    /// Entry DETAIL still resolves `perEntryBodyFont ?? default` (the per-entry override,
    /// AZ4/BA). Browse surfaces — Dashboard, List, Card, grid tiles, Librarian, callouts,
    /// territory pills — follow THIS global value.
    var appBodyFont: EntryBodyFont {
        get { self[AppBodyFontKey.self] }
        set { self[AppBodyFontKey.self] = newValue }
    }
}

private struct AppBodyFontProvider: ViewModifier {
    @AppStorage(EntryBodyFont.defaultStorageKey) private var raw = EntryBodyFont.fallback.rawValue
    func body(content: Content) -> some View {
        content.environment(\.appBodyFont, EntryBodyFont(rawValue: raw) ?? .fallback)
    }
}

extension View {
    /// Inject the app-wide content face into the environment (one `@AppStorage` read). Apply
    /// once, high in the tree; content views then read `@Environment(\.appBodyFont)`.
    func provideAppBodyFont() -> some View { modifier(AppBodyFontProvider()) }
}
