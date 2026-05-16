import SwiftUI
import UIKit

/// View modifier that dismisses the keyboard when the user taps outside any
/// editable surface within the modified view. Wires a SwiftUI `.onTapGesture`
/// against a `.contentShape(Rectangle())` filling the available width, which
/// makes the surrounding chrome (padding, gaps between fields, dividers)
/// tap-targetable.
///
/// SwiftUI's `.onTapGesture` is exclusive — `TextField`, `Button`, and
/// `UITextView` (e.g. `RichTextEditor`'s underlying view) consume their own
/// taps first. So this only fires for taps that genuinely land outside any
/// editable surface, mirroring the behavior of the keyboard toolbar's
/// "Done" button.
///
/// Apply to the content container inside a `ScrollView` (or any view that
/// wraps text inputs). Do NOT apply to the `ScrollView` itself — the
/// `.frame(maxWidth: .infinity, alignment: .leading)` expansion below
/// would collapse scroll content width.
struct KeyboardDismissOnTapOutside: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
    }
}

extension View {
    /// Dismisses the keyboard when the user taps non-editable chrome inside
    /// this view. See `KeyboardDismissOnTapOutside` for the contract.
    func dismissKeyboardOnTapOutside() -> some View {
        modifier(KeyboardDismissOnTapOutside())
    }
}
