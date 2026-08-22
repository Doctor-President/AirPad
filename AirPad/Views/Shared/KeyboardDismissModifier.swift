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
            // SPIKE v3.1 F3 — the dismiss recognizer moved to a BACKGROUND UIView so
            // it can NEVER swallow a tap destined for a foreground control. The prior
            // SwiftUI `.contentShape + .onTapGesture` on the content was documented as
            // "superseded by buttons," but that supersession is unreliable when a
            // first responder is up — and Model C makes the note's first line
            // tap-to-edit, so the keyboard is up far more often, surfacing the swallow
            // on the Related Nodes NavigationLinks below. A background recognizer with
            // `cancelsTouchesInView = false` only receives taps that fall THROUGH the
            // content (empty chrome / gaps), leaving controls to handle their own.
            .background(KeyboardDismissTapCatcher())
    }
}

/// Background tap catcher — dismisses the keyboard on taps that reach it (empty
/// chrome), without stealing touches from foreground controls.
private struct KeyboardDismissTapCatcher: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.dismiss))
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    final class Coordinator: NSObject {
        @objc func dismiss() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
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
