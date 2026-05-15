import SwiftUI
import UIKit

/// Reusable rich-text editor for AirPad. Wraps `UITextView` via `UIViewRepresentable`.
///
/// API surface is intentionally minimal so the component can be dropped into any
/// text-capture surface (NodeDetailView text items now, QuikCapture later, etc.):
///
/// - `text`: `Binding<String>` carrying the markdown content. Plain text is valid markdown,
///   so existing plain-text items pass through unchanged.
/// - `placeholder`: optional dim text shown when the editor is empty.
/// - `minHeight`: minimum vertical size; the editor grows past this with content.
/// - `onBeginEditing` / `onEndEditing`: lifecycle hooks the consumer can use to drive
///   save-on-defocus or other side effects. Persistence is the consumer's responsibility.
///
/// Height grows inline with content (via `sizeThatFits` + `isScrollEnabled = false`),
/// so the editor lives inside an outer `ScrollView` without its own inner scroll.
/// This is the Stage 2.1 inline-growth contract; Stage 2.2 must not regress it.
///
/// The keyboard toolbar is wired internally in Stage 2.2 step 2+; consumers get it for
/// free by adopting this component.
struct RichTextEditor: UIViewRepresentable {

    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 44
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RichTextUIView {
        let textView = RichTextUIView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .white
        textView.tintColor = .white
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.placeholderText = placeholder
        textView.minHeight = minHeight
        textView.text = text
        context.coordinator.attachToolbar(to: textView)
        return textView
    }

    func updateUIView(_ uiView: RichTextUIView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            let previousRange = uiView.selectedRange
            uiView.text = text
            // Clamp the previous selection into the new text length so the cursor
            // doesn't jump when an external write shortens the string.
            let length = (uiView.text as NSString).length
            let clampedLocation = min(previousRange.location, length)
            let clampedLength = min(previousRange.length, length - clampedLocation)
            uiView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
        }
        uiView.placeholderText = placeholder
        uiView.minHeight = minHeight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichTextUIView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        guard width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, minHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        let state = RichTextEditorState()
        private weak var textView: UITextView?
        private var toolbarHost: UIHostingController<RichTextToolbar>?

        init(parent: RichTextEditor) {
            self.parent = parent
            super.init()
            wireStateCommands()
        }

        // MARK: Toolbar wiring

        func attachToolbar(to textView: UITextView) {
            self.textView = textView
            let host = UIHostingController(rootView: RichTextToolbar(state: state))
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear

            let container = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            container.autoresizingMask = .flexibleWidth
            container.backgroundColor = UIColor(white: 0.12, alpha: 1.0)
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            textView.inputAccessoryView = container
            self.toolbarHost = host
        }

        private func wireStateCommands() {
            state.dismissKeyboard = { [weak self] in
                self?.textView?.resignFirstResponder()
            }
            state.toggleBold = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleFontTrait(.traitBold, in: tv)
            }
            state.toggleItalic = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleFontTrait(.traitItalic, in: tv)
            }
            state.toggleInlineCode = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleInlineCode(in: tv)
            }
            state.toggleUnderline = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleSimpleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: tv)
            }
            state.toggleStrikethrough = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleSimpleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, in: tv)
            }
            // Bullet list / numbered list / indent / outdent / link / undo / redo wire in
            // later steps. Their closures stay no-op until then.
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            refreshActiveState(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            refreshActiveState(in: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            refreshActiveState(in: textView)
            parent.onBeginEditing?()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEndEditing?()
        }

        // MARK: Active-state derivation

        /// Reads `typingAttributes` (UITextView keeps these in sync with the cursor /
        /// start of the current selection) to populate the toolbar's active-state flags.
        private func refreshActiveState(in textView: UITextView) {
            let typing = textView.typingAttributes
            let font = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let traits = font.fontDescriptor.symbolicTraits
            state.isBold = traits.contains(.traitBold)
            state.isItalic = traits.contains(.traitItalic)
            // Inline-code state is tracked via custom marker because `.traitMonoSpace`
            // doesn't always round-trip cleanly through `withSymbolicTraits` on monospaced
            // system fonts; the marker is the source of truth.
            state.isInlineCode = (typing[.airpadInlineCode] as? Bool) == true
                || traits.contains(.traitMonoSpace)
            state.isUnderline = (typing[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            state.isStrikethrough = (typing[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false
        }

        // MARK: Inline attribute toggles (step 3)

        /// Toggles a font symbolic trait (bold / italic) across the current selection,
        /// or on `typingAttributes` when there's no selection. Notes' "if uniform, invert;
        /// else set" semantics.
        fileprivate func toggleFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in textView: UITextView) {
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()

            if range.length == 0 {
                var typing = textView.typingAttributes
                let font = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let hasTrait = font.fontDescriptor.symbolicTraits.contains(trait)
                let isCode = (typing[.airpadInlineCode] as? Bool) == true
                typing[.font] = composeFont(togglingTrait: trait, currentlyOn: hasTrait, code: isCode, base: font)
                textView.typingAttributes = typing
            } else {
                let uniformOn = isTraitUniformlyApplied(trait, in: attrText, range: range)
                let target = !uniformOn

                let mutable = NSMutableAttributedString(attributedString: attrText)
                mutable.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                    let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                    let isCode = (attrs[.airpadInlineCode] as? Bool) == true
                    let newFont = composeFont(togglingTrait: trait, currentlyOn: !target, code: isCode, base: font)
                    mutable.addAttribute(.font, value: newFont, range: subRange)
                }
                let preservedSelection = range
                textView.attributedText = mutable
                textView.selectedRange = preservedSelection

                var typing = textView.typingAttributes
                let typingFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let typingIsCode = (typing[.airpadInlineCode] as? Bool) == true
                typing[.font] = composeFont(togglingTrait: trait, currentlyOn: !target, code: typingIsCode, base: typingFont)
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            // attributedText assignment doesn't fire textViewDidChange — push the new
            // string out to the binding manually.
            parent.text = textView.text
        }

        /// Inline code is a font-family swap plus a marker attribute. The marker is the
        /// detection source of truth (independent of font introspection quirks); the
        /// monospaced font is for rendering.
        fileprivate func toggleInlineCode(in textView: UITextView) {
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()
            let markerKey = NSAttributedString.Key.airpadInlineCode

            if range.length == 0 {
                var typing = textView.typingAttributes
                let isOn = (typing[markerKey] as? Bool) == true
                let baseFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let traits = baseFont.fontDescriptor.symbolicTraits
                if isOn {
                    typing.removeValue(forKey: markerKey)
                    typing[.font] = buildBodyFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                } else {
                    typing[markerKey] = true
                    typing[.font] = buildMonoFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                }
                textView.typingAttributes = typing
            } else {
                let uniformOn = isMarkerUniformlyApplied(markerKey, in: attrText, range: range)
                let target = !uniformOn
                let mutable = NSMutableAttributedString(attributedString: attrText)
                mutable.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                    let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                    let traits = font.fontDescriptor.symbolicTraits
                    let bold = traits.contains(.traitBold)
                    let italic = traits.contains(.traitItalic)
                    if target {
                        mutable.addAttribute(markerKey, value: true, range: subRange)
                        mutable.addAttribute(.font, value: buildMonoFont(bold: bold, italic: italic), range: subRange)
                    } else {
                        mutable.removeAttribute(markerKey, range: subRange)
                        mutable.addAttribute(.font, value: buildBodyFont(bold: bold, italic: italic), range: subRange)
                    }
                }
                textView.attributedText = mutable
                textView.selectedRange = range

                var typing = textView.typingAttributes
                let typingFont = (typing[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                let traits = typingFont.fontDescriptor.symbolicTraits
                if target {
                    typing[markerKey] = true
                    typing[.font] = buildMonoFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                } else {
                    typing.removeValue(forKey: markerKey)
                    typing[.font] = buildBodyFont(bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                }
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            parent.text = textView.text
        }

        /// Toggles a simple attribute (underline / strikethrough) that doesn't require font
        /// recomposition.
        fileprivate func toggleSimpleAttribute(_ key: NSAttributedString.Key, value: Any, in textView: UITextView) {
            let range = textView.selectedRange
            let attrText = textView.attributedText ?? NSAttributedString()

            if range.length == 0 {
                var typing = textView.typingAttributes
                if typing[key] != nil {
                    typing.removeValue(forKey: key)
                } else {
                    typing[key] = value
                }
                textView.typingAttributes = typing
            } else {
                let uniformOn = isAttributeUniformlyApplied(key, in: attrText, range: range)
                let mutable = NSMutableAttributedString(attributedString: attrText)
                if uniformOn {
                    mutable.removeAttribute(key, range: range)
                } else {
                    mutable.addAttribute(key, value: value, range: range)
                }
                textView.attributedText = mutable
                textView.selectedRange = range

                var typing = textView.typingAttributes
                if uniformOn {
                    typing.removeValue(forKey: key)
                } else {
                    typing[key] = value
                }
                textView.typingAttributes = typing
            }
            refreshActiveState(in: textView)
            parent.text = textView.text
        }

        // MARK: Uniformity checks

        private func isTraitUniformlyApplied(
            _ trait: UIFontDescriptor.SymbolicTraits,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
                if !font.fontDescriptor.symbolicTraits.contains(trait) {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        private func isAttributeUniformlyApplied(
            _ key: NSAttributedString.Key,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if value == nil {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        private func isMarkerUniformlyApplied(
            _ key: NSAttributedString.Key,
            in attrText: NSAttributedString,
            range: NSRange
        ) -> Bool {
            var uniform = true
            attrText.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if (value as? Bool) != true {
                    uniform = false
                    stop.pointee = true
                }
            }
            return uniform
        }

        // MARK: Font composition

        /// Returns a font that has `trait` toggled relative to `currentlyOn`, preserving
        /// the other bold/italic trait and the code/non-code family.
        private func composeFont(
            togglingTrait trait: UIFontDescriptor.SymbolicTraits,
            currentlyOn: Bool,
            code: Bool,
            base: UIFont
        ) -> UIFont {
            let traits = base.fontDescriptor.symbolicTraits
            let bold = trait == .traitBold ? !currentlyOn : traits.contains(.traitBold)
            let italic = trait == .traitItalic ? !currentlyOn : traits.contains(.traitItalic)
            return code
                ? buildMonoFont(bold: bold, italic: italic)
                : buildBodyFont(bold: bold, italic: italic)
        }

        private func buildBodyFont(bold: Bool, italic: Bool) -> UIFont {
            let body = UIFont.preferredFont(forTextStyle: .body)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            guard !traits.isEmpty else { return body }
            if let desc = body.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: desc, size: body.pointSize)
            }
            return body
        }

        private func buildMonoFont(bold: Bool, italic: Bool) -> UIFont {
            let size = UIFont.preferredFont(forTextStyle: .body).pointSize
            let mono = UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic, let desc = mono.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: desc, size: size)
            }
            return mono
        }
    }
}

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Marker for inline-code spans. Detection source of truth (independent of font
    /// introspection quirks); the corresponding monospaced font is for rendering.
    static let airpadInlineCode = NSAttributedString.Key("airpadInlineCode")
}

// MARK: - Toolbar state

/// Observable bag of formatting state and command closures the toolbar reads and invokes.
/// The `Coordinator` owns this and rewires the closures as commands are implemented in
/// subsequent stage-2.2 steps.
@MainActor
@Observable
final class RichTextEditorState {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var isInlineCode = false
    var isBulletList = false
    var isNumberedList = false
    var canUndo = false
    var canRedo = false

    var toggleBold: () -> Void = {}
    var toggleItalic: () -> Void = {}
    var toggleUnderline: () -> Void = {}
    var toggleStrikethrough: () -> Void = {}
    var toggleInlineCode: () -> Void = {}
    var toggleBulletList: () -> Void = {}
    var toggleNumberedList: () -> Void = {}
    var indent: () -> Void = {}
    var outdent: () -> Void = {}
    var insertLink: () -> Void = {}
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var dismissKeyboard: () -> Void = {}
}

// MARK: - Toolbar view

/// Keyboard-attached formatting toolbar. Hosted via `UIHostingController` inside the
/// `UITextView`'s `inputAccessoryView`. Buttons read active-state from `RichTextEditorState`
/// and invoke the matching command closure.
struct RichTextToolbar: View {
    @Bindable var state: RichTextEditorState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                button(icon: "bold", active: state.isBold, action: state.toggleBold)
                button(icon: "italic", active: state.isItalic, action: state.toggleItalic)
                button(icon: "underline", active: state.isUnderline, action: state.toggleUnderline)
                button(icon: "strikethrough", active: state.isStrikethrough, action: state.toggleStrikethrough)
                separator
                button(icon: "list.bullet", active: state.isBulletList, action: state.toggleBulletList)
                button(icon: "list.number", active: state.isNumberedList, action: state.toggleNumberedList)
                button(icon: "decrease.indent", active: false, action: state.outdent)
                button(icon: "increase.indent", active: false, action: state.indent)
                separator
                button(icon: "chevron.left.forwardslash.chevron.right", active: state.isInlineCode, action: state.toggleInlineCode)
                button(icon: "link", active: false, action: state.insertLink)
                separator
                button(icon: "arrow.uturn.backward", active: false, enabled: state.canUndo, action: state.undo)
                button(icon: "arrow.uturn.forward", active: false, enabled: state.canRedo, action: state.redo)
                separator
                button(icon: "keyboard.chevron.compact.down", active: false, action: state.dismissKeyboard)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .background(Color(white: 0.12))
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func button(
        icon: String,
        active: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(enabled ? (active ? Color.white : Color.white.opacity(0.75)) : Color.white.opacity(0.3))
                .background(active ? Color.white.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!enabled)
    }
}

/// `UITextView` subclass providing:
/// - placeholder rendering via an overlay `UILabel` that hides when text is non-empty,
/// - `intrinsicContentSize` and a `minHeight` floor so SwiftUI sizing can drive inline growth.
///
/// Subclassing rather than composing because we need to observe `text` / `attributedText`
/// changes and update the placeholder visibility from a single source of truth.
final class RichTextUIView: UITextView {

    private let placeholderLabel = UILabel()

    var placeholderText: String = "" {
        didSet {
            placeholderLabel.text = placeholderText
            updatePlaceholderVisibility()
        }
    }

    var minHeight: CGFloat = 44 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChangeNotification),
            name: UITextView.textDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var text: String! {
        didSet { updatePlaceholderVisibility() }
    }

    override var attributedText: NSAttributedString! {
        didSet { updatePlaceholderVisibility() }
    }

    override var intrinsicContentSize: CGSize {
        let proposedWidth = bounds.width > 0 ? bounds.width : UIView.layoutFittingExpandedSize.width
        let fitted = sizeThatFits(CGSize(width: proposedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(fitted.height, minHeight))
    }

    private func setupPlaceholder() {
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = font
        placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.35)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: textContainerInset.top),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: textContainerInset.left + textContainer.lineFragmentPadding
            ),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(textContainerInset.right + textContainer.lineFragmentPadding)
            )
        ])
    }

    @objc private func textDidChangeNotification() {
        updatePlaceholderVisibility()
        invalidateIntrinsicContentSize()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.font = font
        placeholderLabel.isHidden = !(text?.isEmpty ?? true)
    }
}
