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
    /// Fired when a checklist glyph is toggled by a direct tap. A tap is not a
    /// focus event, so it never reaches `onEndEditing` — the only other save
    /// trigger — which is why a checkbox tick could be lost if the app was
    /// closed before the field defocused. Consumers wire this to persist
    /// immediately. See `Coordinator.toggleChecklistChecked`.
    var onChecklistMutated: (() -> Void)? = nil
    /// When true, the editor calls `becomeFirstResponder` once on first appearance.
    /// Used by the in-node "+" → Text path so a newly appended empty entry lands
    /// the user directly in the editor with the keyboard up. Consumers should
    /// clear the upstream trigger (e.g. `store.pendingAutoFocusItemID`) on
    /// `.onAppear` so subsequent renders don't re-focus.
    var autoFocusOnAppear: Bool = false
    /// When true, applies the Note document typography (line height, paragraph
    /// spacing, list hanging indent) and system-aware colors. Opt-in so other
    /// consumers of this editor render exactly as before. See `NoteTypography`.
    var documentStyle: Bool = false
    /// Serif feel-test typeface (SB121 scaffold). Only applied when
    /// `documentStyle` is on. `.system` keeps the default system font.
    var documentFont: NoteFontChoice = .system
    /// Inline-image resolver: item id (from an `![](airpad-image:<id>)` token) →
    /// loaded image. Provided by the note (TextEntryBody) so the editor stays
    /// generic. Nil = this consumer doesn't render inline images.
    var resolveImage: ((String) async -> UIImage?)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> RichTextUIView {
        let textView = RichTextUIView()
        textView.delegate = context.coordinator
        if CaretTrace.enabled { textView.accessibilityIdentifier = "noteEditor" }
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        // documentStyle uses semantic `.label` (adaptive) so text is legible in
        // both light and dark; the legacy path keeps its hardcoded white.
        textView.textColor = documentStyle ? .label : .white
        textView.tintColor = documentStyle ? .label : .white
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.placeholderText = placeholder
        textView.minHeight = minHeight
        textView.attributedText = decodedAttributedText(text)
        // Record the markdown now reflected in the view so the first updateUIView
        // (and every benign re-render after) is a no-op — see `lastAppliedMarkdown`.
        context.coordinator.lastAppliedMarkdown = text
        // Seed typingAttributes so the first keystroke into an empty editor renders
        // legibly. UIKit derives typingAttributes from the surrounding character on
        // each cursor move, but with no characters it falls back to system defaults.
        // Set them explicitly here and re-apply whenever attributedText is replaced.
        textView.typingAttributes = documentStyle ? NoteTypography.typingAttributes : Self.defaultTypingAttributes
        context.coordinator.attachToolbar(to: textView)
        if autoFocusOnAppear {
            // Dispatch so the view is in the window/responder chain before we
            // try to become first responder. Without the hop, becomeFirstResponder
            // is called during view construction and silently fails.
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        }
        return textView
    }

    func updateUIView(_ uiView: RichTextUIView, context: Context) {
        context.coordinator.parent = self
        CaretTrace.log("updateUIView ENTER \(CaretTrace.sel(uiView)) bindingLen=\((text as NSString).length) lastAppliedLen=\((context.coordinator.lastAppliedMarkdown as NSString?)?.length ?? -1) willReassign=\(text != context.coordinator.lastAppliedMarkdown)")
        // Only re-decode when the incoming binding differs from the markdown we last
        // reflected in the view (`lastAppliedMarkdown`). This is a plain string compare,
        // NOT `encode(attributedText) != text`: `encode ∘ decode` is not the identity for
        // links / checklists / nested bullets / escaped specials / serif bold-italic, so
        // that form was permanently true and would re-decode (clobbering caret/attributes)
        // on every render. Typing keeps the two in sync: `pushBinding` sets
        // `lastAppliedMarkdown` to the value it writes, so the next render is a no-op.
        if text != context.coordinator.lastAppliedMarkdown {
            let previousRange = uiView.selectedRange
            uiView.attributedText = decodedAttributedText(text)
            context.coordinator.lastAppliedMarkdown = text
            let length = uiView.attributedText.length
            let clampedLocation = min(previousRange.location, length)
            let clampedLength = min(previousRange.length, length - clampedLocation)
            uiView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            CaretTrace.log("updateUIView REASSIGNED attributedText, restored \(CaretTrace.sel(uiView)) (prev=\(NSStringFromRange(previousRange)))")
            // After replacing attributedText, typingAttributes inherit from the new
            // surrounding character — or default to system attrs if the text is empty.
            // Re-seed for the empty case so the next keystroke stays legible.
            if length == 0 {
                uiView.typingAttributes = documentStyle ? NoteTypography.typingAttributes : Self.defaultTypingAttributes
            }
        }
        // Inline images: async-load any placeholder attachments (from decoded
        // `![](airpad-image:<id>)` tokens) that don't yet have an image.
        if resolveImage != nil {
            context.coordinator.resolvePendingImages(in: uiView)
        }
        uiView.placeholderText = placeholder
        uiView.minHeight = minHeight
    }

    /// Default typing attributes for an empty editor — body font, white foreground.
    /// Used as a floor so the first keystroke into a freshly created entry is legible
    /// against the app's dark chrome.
    private static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NoteTypographyHelper.bodyFont,
            .foregroundColor: UIColor.white
        ]
    }

    /// Decodes the markdown binding, applying Note document typography when
    /// `documentStyle` is set. The styling is display-only, so `encode` still
    /// recovers the identical markdown.
    private func decodedAttributedText(_ markdown: String) -> NSAttributedString {
        let decoded = MarkdownCodec.decode(markdown)
        return documentStyle ? NoteTypography.styled(decoded, font: documentFont) : decoded
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
        /// The markdown currently reflected in the text view's `attributedText`.
        /// This is the no-op signal for `updateUIView`: it re-decodes only when the
        /// incoming binding differs from what we last put into (or read out of) the
        /// view. It must NOT be derived from `MarkdownCodec.encode(attributedText)`,
        /// because `encode ∘ decode` is not the identity for several ordinary
        /// constructs (links gain a `<u>` span, checklists/nested bullets/escaped
        /// specials re-serialize differently, and — for serif notes — a bold+italic
        /// run collapses to bold since the face has no bold-italic variant). Any of
        /// those made the old `encode(attributedText) != text` guard permanently
        /// true, so every render reassigned `attributedText` and re-anchored the
        /// caret to `previousRange` — which on the keyboard/focus render after a tap
        /// is still the end-of-text default, jumping the caret to the end (MD14).
        /// Set in `makeUIView`, `updateUIView` (external change), and `pushBinding`.
        var lastAppliedMarkdown: String?
        /// Guards against re-entrancy when `applyInPlace` restyles storage from
        /// within `refreshActiveState` (a programmatic selection nudge could
        /// otherwise re-trigger the delegate and recurse).
        private var isRestyling = false
        private weak var textView: UITextView?
        private var toolbarHost: UIHostingController<RichTextToolbar>?
        /// Tap recognizer that fires only when the tap lands on a checklist
        /// glyph. Installed in `attachToolbar`; its delegate filters out other
        /// taps so the textView's built-in cursor-placement tap still wins.
        private var checklistTapRecognizer: UITapGestureRecognizer?

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

            let container = ToolbarContainerView(frame: CGRect(x: 0, y: 0, width: 0, height: NoteEditorToolbar.designHeight))
            container.autoresizingMask = .flexibleWidth
            container.backgroundColor = .clear
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            textView.inputAccessoryView = container
            self.toolbarHost = host

            // Tap-to-toggle for checklist glyphs. The delegate's
            // `shouldReceive` returns true only when the touch lands inside
            // a glyph's drawing rect, so the textView's own tap recognizer
            // continues to handle every other tap (cursor placement, etc).
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleChecklistTap(_:)))
            tap.delegate = self
            textView.addGestureRecognizer(tap)
            self.checklistTapRecognizer = tap
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
            state.toggleBulletList = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.toggleKind(.bullet), in: tv)
            }
            state.toggleNumberedList = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.applyListMutation(.toggleKind(.numbered), in: tv)
            }
            state.indent = { [weak self] in
                guard let self, let tv = self.textView else { return }
                // Checklist paragraphs aren't recognized by parseLine (the SF
                // Symbol attachment isn't a list marker); handle them directly
                // before falling through to bullet/numbered indent logic.
                if self.adjustChecklistIndent(by: +1, in: tv) { return }
                self.applyListMutation(.indent, in: tv)
            }
            state.outdent = { [weak self] in
                guard let self, let tv = self.textView else { return }
                if self.adjustChecklistIndent(by: -1, in: tv) { return }
                self.applyListMutation(.outdent, in: tv)
            }
            state.insertLink = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.beginLinkEntry(in: tv)
            }
            state.undo = { [weak self] in
                guard let self, let tv = self.textView else { return }
                tv.undoManager?.undo()
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
            state.redo = { [weak self] in
                guard let self, let tv = self.textView else { return }
                tv.undoManager?.redo()
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
            state.applyHeading = { [weak self] level in
                guard let self, let tv = self.textView else { return }
                self.applyHeading(level: level, in: tv)
            }
            state.toggleChecklist = { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.toggleChecklist(in: tv)
            }
        }

        // MARK: Undo registration (step 7)

        /// Registers an undo step that restores the textView to its current state.
        /// Call this BEFORE applying a custom mutation (formatting toggle, list mutation,
        /// link insertion). NSUndoManager handles redo automatically by re-registering
        /// the inverse when this closure runs during an undo operation.
        ///
        /// UITextView's built-in typing undo is independent of this and works out of the box;
        /// this helper covers our `attributedText`-assignment mutations which bypass it.
        private func captureUndoSnapshot(in textView: UITextView) {
            let before = (textView.attributedText.copy() as? NSAttributedString) ?? NSAttributedString()
            let beforeSel = textView.selectedRange
            textView.undoManager?.registerUndo(withTarget: textView) { [weak self] tv in
                guard let self else { return }
                self.captureUndoSnapshot(in: tv)  // chain for redo
                tv.attributedText = before
                let clamped = min(beforeSel.location, before.length)
                tv.selectedRange = NSRange(location: clamped, length: 0)
                self.refreshActiveState(in: tv)
                self.pushBinding(from: tv)
            }
        }

        /// Encodes the textView's attributed string to markdown and pushes it through the
        /// binding. Use this instead of `parent.text = textView.text` to keep the binding
        /// authoritative as markdown rather than raw display text.
        private func pushBinding(from textView: UITextView) {
            let markdown = MarkdownCodec.encode(textView.attributedText ?? NSAttributedString())
            parent.text = markdown
            // The view already holds exactly this markdown, so mark it applied: the
            // updateUIView SwiftUI schedules from this binding write is then a no-op
            // and won't re-decode over the user's caret (MD14).
            lastAppliedMarkdown = markdown
        }

        // MARK: Inline images

        /// Finds image attachments whose image hasn't loaded yet and resolves
        /// each via the parent's `resolveImage`, swapping the loaded image in
        /// (sized to text width) when it arrives.
        func resolvePendingImages(in textView: UITextView) {
            guard let resolveImage = parent.resolveImage else { return }
            let attr = textView.attributedText ?? NSAttributedString()
            guard attr.length > 0 else { return }
            var pending: [String] = []
            attr.enumerateAttribute(.airpadImageItemID, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
                guard let id = value as? String else { return }
                let att = attr.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                if att?.image == nil { pending.append(id) }
            }
            guard !pending.isEmpty else { return }
            for id in pending {
                Task { @MainActor [weak textView] in
                    guard let image = await resolveImage(id), let textView else { return }
                    self.applyImage(image, forItemID: id, in: textView)
                }
            }
        }

        /// Replaces the placeholder attachment tagged `id` with one carrying the
        /// loaded image, scaled to the available text width.
        private func applyImage(_ image: UIImage, forItemID id: String, in textView: UITextView) {
            let current = textView.attributedText ?? NSAttributedString()
            var target: NSRange?
            current.enumerateAttribute(.airpadImageItemID, in: NSRange(location: 0, length: current.length)) { value, range, stop in
                if (value as? String) == id { target = range; stop.pointee = true }
            }
            guard let range = target else { return }

            let available = max(1, textView.bounds.width
                - textView.textContainerInset.left - textView.textContainerInset.right
                - 2 * textView.textContainer.lineFragmentPadding)
            let scale = image.size.width > available ? available / image.size.width : 1
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: size)
            let replacement = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            let full = NSRange(location: 0, length: replacement.length)
            replacement.addAttribute(.airpadImageItemID, value: id, range: full)
            replacement.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: full)

            let selected = textView.selectedRange
            let mut = NSMutableAttributedString(attributedString: current)
            mut.replaceCharacters(in: range, with: replacement)
            // Loaded image encodes to the same token, so the markdown binding is
            // unchanged — don't push it (avoids a needless re-decode).
            textView.attributedText = mut
            textView.selectedRange = NSRange(location: min(selected.location, mut.length), length: 0)
        }

        // MARK: UITextViewDelegate

        func textViewDidChange(_ textView: UITextView) {
            pushBinding(from: textView)
            refreshActiveState(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            CaretTrace.log("didChangeSelection ENTER \(CaretTrace.sel(textView))")
            // restyle: false — a selection change is not a content change; the storage
            // is already styled. Restyling here would mutate storage mid-gesture and
            // cancel tap-to-position (MD14). See `refreshActiveState`.
            refreshActiveState(in: textView, restyle: false)
            CaretTrace.log("didChangeSelection EXIT  \(CaretTrace.sel(textView))")
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            CaretTrace.log("didBeginEditing ENTER \(CaretTrace.sel(textView))")
            // MD14 M2 geometry gate: where does the XCUITest tap point (0.35, 0.06) map?
            CaretTrace.geomLog(textView)
            // restyle: false — focusing is not a content change; restyling here mutates
            // storage synchronously inside the focus/tap gesture and cancels
            // tap-to-position, snapping the caret to the end (MD14 root cause).
            refreshActiveState(in: textView, restyle: false)
            parent.onBeginEditing?()
            CaretTrace.log("didBeginEditing EXIT  \(CaretTrace.sel(textView))")
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEndEditing?()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                return !handleReturnKey(in: textView, range: range)
            }
            return true
        }

        // MARK: Active-state derivation

        /// Reads `typingAttributes` (UITextView keeps these in sync with the cursor /
        /// start of the current selection) to populate the toolbar's active-state flags.
        /// List state is derived from the current paragraph's prefix in the raw text.
        /// Updates the toolbar's active-state flags from the cursor, and — when
        /// `restyle` is true — re-applies document typography via `applyInPlace`.
        ///
        /// `restyle` MUST be false for focus / selection changes. `applyInPlace`
        /// mutates the text storage (`beginEditing`/`endEditing`); performing that
        /// synchronously inside `textViewDidBeginEditing` / `textViewDidChangeSelection`
        /// cancels the in-flight `UITextInteraction` tap-to-position gesture, so the
        /// caret never lands where you tapped and snaps to the end (MD14 root cause).
        /// On focus/selection nothing changed, so the storage is already styled and
        /// skipping the restyle is a pure no-op for appearance. Content changes
        /// (typing → `textViewDidChange`, toolbar mutations, undo/redo) keep
        /// `restyle: true` so new/edited text still gets the serif + paragraph styling.
        private func refreshActiveState(in textView: UITextView, restyle: Bool = true) {
            CaretTrace.log("  refreshActiveState ENTER \(CaretTrace.sel(textView)) restyle=\(restyle)")
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

            // Heading detection: read the paragraph-level attribute off typingAttributes
            // (UITextView keeps these in sync with the cursor's surrounding char).
            if let raw = typing[.airpadHeadingLevel] as? Int,
               let level = RichTextHeadingLevel(rawValue: raw) {
                state.currentHeadingLevel = level
            } else {
                state.currentHeadingLevel = nil
            }

            // List detection: parse the paragraph containing the cursor.
            let info = currentParagraphInfo(in: textView)
            switch info.kind {
            case .bullet:
                state.isBulletList = true
                state.isNumberedList = false
            case .numbered:
                state.isBulletList = false
                state.isNumberedList = true
            case nil:
                state.isBulletList = false
                state.isNumberedList = false
            }

            // Checklist detection: read paragraph prefix on the cursor's paragraph.
            // (Independent of bullet/numbered list parsing — the checklist glyph is
            // a display-form substitution; the original paragraph parser doesn't
            // recognize it as a list marker, which is fine for commit 4.)
            state.isChecklist = paragraphStartsWithChecklistGlyph(in: textView)

            // Undo / redo availability — bridged from UITextView's undoManager,
            // which covers built-in typing and our explicit captureUndoSnapshot calls.
            state.canUndo = textView.undoManager?.canUndo ?? false
            state.canRedo = textView.undoManager?.canRedo ?? false

            // typingAttributes inherit from the preceding char. If that char is a `•`
            // carrying `.airpadBulletGlyph`, freshly typed content would silently inherit
            // the marker — which the encoder would later rewrite to `-`. Strip it so the
            // marker stays scoped to the actual bullet glyph chars. Same logic for the
            // checklist glyph marker, which would otherwise leak into typed-after content
            // and encode-corrupt it on the next pass.
            if textView.typingAttributes[.airpadBulletGlyph] != nil {
                var typing = textView.typingAttributes
                typing.removeValue(forKey: .airpadBulletGlyph)
                textView.typingAttributes = typing
            }
            if textView.typingAttributes[.airpadChecklistGlyph] != nil {
                var typing = textView.typingAttributes
                typing.removeValue(forKey: .airpadChecklistGlyph)
                textView.typingAttributes = typing
            }
            // typingAttributes inherits `.attachment` from the preceding char if
            // it was an NSTextAttachment (the checklist glyph). Without this
            // scrub, the next typed char would carry the attachment attribute
            // (benign since it's not U+FFFC, but tidier to strip).
            if textView.typingAttributes[.attachment] != nil {
                var typing = textView.typingAttributes
                typing.removeValue(forKey: .attachment)
                textView.typingAttributes = typing
            }

            // Keep Note document typography (line height, paragraph spacing, list
            // hanging indent, adaptive color) applied as the text changes. This is
            // the single choke point every mutation and keystroke passes through.
            // Guarded against re-entrancy since it touches storage/selection.
            if restyle, parent.documentStyle, !isRestyling {
                CaretTrace.log("  refreshActiveState pre-applyInPlace  \(CaretTrace.sel(textView))")
                isRestyling = true
                NoteTypography.applyInPlace(to: textView, font: parent.documentFont)
                isRestyling = false
                CaretTrace.log("  refreshActiveState post-applyInPlace \(CaretTrace.sel(textView))")
            }
            CaretTrace.log("  refreshActiveState EXIT  \(CaretTrace.sel(textView))")
        }

        /// Returns true when the paragraph containing the cursor starts with a
        /// marker-tagged checklist glyph (attachment or legacy Unicode), via
        /// `MarkdownCodec.checklistPrefixRange`. Drives `state.isChecklist`.
        private func paragraphStartsWithChecklistGlyph(in textView: UITextView) -> Bool {
            guard let text = textView.attributedText else { return false }
            let ns = text.string as NSString
            guard ns.length > 0 else { return false }
            let loc = min(max(textView.selectedRange.location, 0), ns.length)
            let paraRange = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            return MarkdownCodec.checklistPrefixRange(in: text, paragraph: paraRange) != nil
        }

        // MARK: List parsing (step 5)

        fileprivate enum ListKind: Equatable {
            case bullet
            case numbered(Int)

            var isNumbered: Bool {
                if case .numbered = self { return true }
                return false
            }
        }

        fileprivate struct LineInfo {
            let indent: Int        // count of leading "  " groups (0 = top level)
            let kind: ListKind?    // nil = not a list line
            let prefixLength: Int  // total chars consumed by indent + marker (0 if no marker)
        }

        /// Parses a single line (without its trailing newline) for indent + list marker.
        fileprivate static func parseLine(_ line: String) -> LineInfo {
            var work = Substring(line)
            var indent = 0
            while work.hasPrefix("  "), indent < 5 {
                work = work.dropFirst(2)
                indent += 1
            }
            let indentChars = indent * 2

            // `▪\u{FE0E} ` is 3 UTF-16 code units (glyph + VS + space); the other
            // bullet forms are 2. Check the VS-bearing form first so it doesn't get
            // shadowed by a more-permissive prefix.
            if work.hasPrefix("▪\u{FE0E} ") {
                return LineInfo(indent: indent, kind: .bullet, prefixLength: indentChars + 3)
            }
            if work.hasPrefix("- ")
                || work.hasPrefix("• ")
                || work.hasPrefix("◦ ")
                || work.hasPrefix("▪ ")
            {
                return LineInfo(indent: indent, kind: .bullet, prefixLength: indentChars + 2)
            }

            // Numbered: digits + ". " + space
            var digitCount = 0
            var iter = work.startIndex
            while iter < work.endIndex, work[iter].isASCII, work[iter].isNumber, digitCount < 6 {
                digitCount += 1
                iter = work.index(after: iter)
            }
            if digitCount > 0, iter < work.endIndex, work[iter] == "." {
                let afterDot = work.index(after: iter)
                if afterDot < work.endIndex, work[afterDot] == " " {
                    if let n = Int(work.prefix(digitCount)) {
                        return LineInfo(indent: indent, kind: .numbered(n), prefixLength: indentChars + digitCount + 2)
                    }
                }
            }

            return LineInfo(indent: indent, kind: nil, prefixLength: 0)
        }

        private func currentParagraphInfo(in textView: UITextView) -> LineInfo {
            let text = textView.text ?? ""
            let nsText = text as NSString
            let cursorRange = NSRange(location: min(textView.selectedRange.location, nsText.length), length: 0)
            let pRange = nsText.paragraphRange(for: cursorRange)
            // Strip trailing newline if present (paragraphRange includes the \n)
            var line = nsText.substring(with: pRange)
            if line.hasSuffix("\n") { line.removeLast() }
            return Self.parseLine(line)
        }

        // MARK: List mutation (step 5)

        fileprivate enum ListMutationMode {
            case toggleKind(TargetKind)  // toggle bullet/numbered on/off
            case indent
            case outdent

            enum TargetKind { case bullet, numbered }
        }

        /// Single entry point for list-affecting toolbar commands. Mutates every paragraph
        /// in the expanded selection range, runs a renumbering pass over the full document,
        /// and writes the result back to the text view (preserving selection where possible).
        fileprivate func applyListMutation(_ mode: ListMutationMode, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let attrText = textView.attributedText ?? NSAttributedString()
            let text = textView.text ?? ""
            let nsText = text as NSString
            let selRange = textView.selectedRange
            guard nsText.length >= 0 else { return }
            let workingRange = nsText.paragraphRange(for: selRange)

            // Gather paragraphs (range without trailing newline, line text, parsed info).
            var paragraphs: [(range: NSRange, line: String, info: LineInfo)] = []
            nsText.enumerateSubstrings(in: workingRange, options: .byParagraphs) { substring, substringRange, _, _ in
                let line = substring ?? ""
                paragraphs.append((substringRange, line, Self.parseLine(line)))
            }
            // Empty workingRange — cursor sits on a trailing empty line (or the whole
            // document is empty). `enumerateSubstrings` emits nothing in that case, so
            // synthesize a zero-length paragraph so the mutation still inserts the prefix
            // at the cursor location.
            if paragraphs.isEmpty {
                let emptyInfo = LineInfo(indent: 0, kind: nil, prefixLength: 0)
                paragraphs.append((NSRange(location: workingRange.location, length: 0), "", emptyInfo))
            }

            // Decide direction for toggleKind: if every paragraph already matches the target
            // kind, the toggle removes; else it applies.
            let removeAll: Bool = {
                if case .toggleKind(let target) = mode {
                    return paragraphs.allSatisfy { p in
                        switch (target, p.info.kind) {
                        case (.bullet, .bullet): return true
                        case (.numbered, .numbered(_)): return true
                        default: return false
                        }
                    }
                }
                return false
            }()

            // Build new mutable text. Process paragraphs in order; track offset delta so
            // we can re-anchor the cursor afterwards.
            let mutable = NSMutableAttributedString(attributedString: attrText)
            var runningDelta = 0

            for paragraph in paragraphs {
                let shifted = NSRange(location: paragraph.range.location + runningDelta, length: paragraph.range.length)
                let info = paragraph.info

                // Compute new prefix
                let (newIndent, newKind): (Int, ListKind?) = {
                    switch mode {
                    case .toggleKind(let target):
                        if removeAll {
                            return (0, nil)
                        }
                        // Apply target kind at existing indent (or 0 if not a list yet).
                        let baseIndent = info.indent
                        switch target {
                        case .bullet: return (baseIndent, .bullet)
                        case .numbered: return (baseIndent, .numbered(1))
                        }
                    case .indent:
                        guard info.kind != nil else { return (info.indent, info.kind) }  // only indent list items
                        return (min(info.indent + 1, 5), info.kind)
                    case .outdent:
                        guard info.kind != nil else { return (info.indent, info.kind) }
                        if info.indent == 0 {
                            return (0, nil)  // exit list at top
                        }
                        return (info.indent - 1, info.kind)
                    }
                }()

                let newPrefix: String
                switch newKind {
                case .bullet:
                    // Display-form bullet glyph. The `airpadBulletGlyph` marker is added
                    // below so the markdown encoder substitutes it back to `-` for storage.
                    let glyph = MarkdownCodec.bulletGlyph(forIndent: newIndent)
                    newPrefix = String(repeating: "  ", count: newIndent) + glyph + " "
                case .numbered:
                    // Placeholder "1." — the renumbering pass fixes the actual number afterward.
                    newPrefix = String(repeating: "  ", count: newIndent) + "1. "
                case nil:
                    newPrefix = ""
                }

                // Replace old prefix with new prefix on this paragraph.
                let oldPrefixRange = NSRange(location: shifted.location, length: info.prefixLength)
                mutable.replaceCharacters(in: oldPrefixRange, with: newPrefix)

                // `replaceCharacters(in:with: String)` inherits attributes from the surrounding
                // text, which can carry a stale bullet marker onto the new prefix. Scrub the
                // whole new-prefix range first, then tag only the `•` glyph (if present).
                let newPrefixLength = (newPrefix as NSString).length
                let newPrefixRange = NSRange(location: shifted.location, length: newPrefixLength)
                if newPrefixLength > 0 {
                    mutable.removeAttribute(.airpadBulletGlyph, range: newPrefixRange)
                }
                if case .bullet = newKind {
                    let glyphLen = MarkdownCodec.bulletGlyphUTF16Length(forIndent: newIndent)
                    let bulletLocation = shifted.location + newIndent * 2
                    let bulletRange = NSRange(location: bulletLocation, length: glyphLen)
                    if bulletRange.upperBound <= mutable.length {
                        mutable.addAttribute(.airpadBulletGlyph, value: true, range: bulletRange)
                    }
                }

                runningDelta += newPrefixLength - info.prefixLength
            }

            // Run the document-wide renumbering pass so numbered blocks are 1, 2, 3...
            let renumberedDelta = renumberLists(in: mutable)

            textView.attributedText = mutable
            // Re-anchor cursor: original location + delta from list mutation +
            // delta contributed by renumbering that occurred at or before the cursor.
            let newLength = mutable.length
            let proposedLocation = selRange.location + runningDelta + renumberedDelta.deltaBeforeOrAt(selRange.location + runningDelta)
            let clampedLocation = max(0, min(proposedLocation, newLength))
            textView.selectedRange = NSRange(location: clampedLocation, length: 0)

            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        /// Walks the whole document, finds contiguous numbered list paragraphs at the same
        /// indent level, and rewrites their numeric prefix to 1, 2, 3, ... A counter is
        /// kept per indent level and reset when the contiguous run breaks (non-numbered
        /// paragraph at that level encountered).
        ///
        /// Returns a `DeltaMap` recording offset shifts so callers can re-anchor selection.
        @discardableResult
        private func renumberLists(in attrString: NSMutableAttributedString) -> DeltaMap {
            let nsText = attrString.string as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            // Collect paragraph metadata in document order.
            struct ParaMeta {
                let range: NSRange
                let info: LineInfo
            }
            var paragraphs: [ParaMeta] = []
            nsText.enumerateSubstrings(in: fullRange, options: .byParagraphs) { substring, substringRange, _, _ in
                let line = substring ?? ""
                paragraphs.append(ParaMeta(range: substringRange, info: Self.parseLine(line)))
            }

            // Walk, computing the desired prefix for numbered lines. Track counter per indent.
            var counter: [Int: Int] = [:]
            var lastWasNumberedAtIndent: [Int: Bool] = [:]

            var mutations: [(range: NSRange, newPrefix: String, oldPrefixLength: Int)] = []

            for p in paragraphs {
                switch p.info.kind {
                case .numbered(_):
                    let indent = p.info.indent
                    if !(lastWasNumberedAtIndent[indent] ?? false) {
                        counter[indent] = 1
                    }
                    let n = counter[indent] ?? 1
                    let newPrefix = "\(String(repeating: "  ", count: indent))\(n). "
                    let prefixRange = NSRange(location: p.range.location, length: p.info.prefixLength)
                    mutations.append((prefixRange, newPrefix, p.info.prefixLength))
                    counter[indent] = n + 1
                    lastWasNumberedAtIndent[indent] = true
                    // Numbered runs at deeper indents are interrupted by a parent line.
                    for key in lastWasNumberedAtIndent.keys where key > indent {
                        lastWasNumberedAtIndent[key] = false
                    }
                default:
                    // Non-list (or bullet) line breaks the numbered streak at every indent
                    // level shallower than or equal to this paragraph's indent.
                    for key in lastWasNumberedAtIndent.keys where key >= p.info.indent {
                        lastWasNumberedAtIndent[key] = false
                    }
                }
            }

            // Apply mutations from end to start so earlier ranges aren't invalidated.
            var deltaMap = DeltaMap()
            for m in mutations.reversed() {
                let oldLength = m.range.length
                let newLength = (m.newPrefix as NSString).length
                attrString.replaceCharacters(in: m.range, with: m.newPrefix)
                let delta = newLength - oldLength
                if delta != 0 {
                    deltaMap.add(at: m.range.location, delta: delta)
                }
            }
            return deltaMap
        }

        /// Sparse map of offset deltas: for a location, sum all deltas applied at or
        /// before that location (so callers can re-anchor a cursor that lived past
        /// some renumbered prefixes).
        private struct DeltaMap {
            private var entries: [(location: Int, delta: Int)] = []
            mutating func add(at location: Int, delta: Int) {
                entries.append((location, delta))
            }
            func deltaBeforeOrAt(_ location: Int) -> Int {
                entries.reduce(0) { acc, entry in
                    entry.location <= location ? acc + entry.delta : acc
                }
            }
        }

        // MARK: Return-key list continuation (step 5)

        /// Called from `textView(_:shouldChangeTextIn:replacementText:)`. If the user is
        /// pressing Return inside a list line, continue the list on the new line (Notes
        /// behavior). If the current line is an empty list item (just the marker), Return
        /// exits the list instead.
        ///
        /// Returns true if the change was handled here and the default insertion should be
        /// suppressed; returns false to let UITextView handle the change normally.
        fileprivate func handleReturnKey(in textView: UITextView, range: NSRange) -> Bool {
            let text = textView.text ?? ""
            let nsText = text as NSString
            let cursorParagraph = nsText.paragraphRange(for: NSRange(location: range.location, length: 0))
            var line = nsText.substring(with: cursorParagraph)
            if line.hasSuffix("\n") { line.removeLast() }

            // Checklist continuation takes precedence over `parseLine` because the
            // display-form glyph (`☐` / `☑`) isn't a recognized bullet marker.
            if handleReturnInChecklist(line: line, cursorParagraph: cursorParagraph, in: textView, range: range) {
                return true
            }

            let info = Self.parseLine(line)
            guard info.kind != nil else { return false }

            // Use UTF-16 length for parity with `info.prefixLength`. `Character.count`
            // groups `▪\u{FE0E}` as one grapheme; UTF-16 length is the right unit here.
            let isEmptyListLine = ((line as NSString).length == info.prefixLength)
            if isEmptyListLine {
                captureUndoSnapshot(in: textView)
                // Empty list item + Enter → strip the prefix, exit the list, no new line.
                let prefixRange = NSRange(location: cursorParagraph.location, length: info.prefixLength)
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
                mutable.deleteCharacters(in: prefixRange)
                renumberLists(in: mutable)
                textView.attributedText = mutable
                let newLoc = max(0, cursorParagraph.location)
                textView.selectedRange = NSRange(location: newLoc, length: 0)
                refreshActiveState(in: textView)
                pushBinding(from: textView)
                return true
            }

            captureUndoSnapshot(in: textView)
            // Otherwise: insert \n + same-indent marker (number gets renumbered after).
            let indentStr = String(repeating: "  ", count: info.indent)
            let isBulletContinuation: Bool
            let markerStr: String
            switch info.kind! {
            case .bullet:
                markerStr = MarkdownCodec.bulletGlyph(forIndent: info.indent) + " "
                isBulletContinuation = true
            case .numbered:
                markerStr = "1. "  // renumber pass corrects
                isBulletContinuation = false
            }
            let insertion = "\n" + indentStr + markerStr

            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            mutable.replaceCharacters(in: range, with: insertion)

            // Scrub any stale bullet marker inherited from surrounding text, then tag the
            // `•` glyph (if this is a bullet continuation) so the encoder maps it to `-`.
            let insertedLength = (insertion as NSString).length
            let insertedRange = NSRange(location: range.location, length: insertedLength)
            if insertedLength > 0 {
                mutable.removeAttribute(.airpadBulletGlyph, range: insertedRange)
            }
            if isBulletContinuation {
                let glyphLen = MarkdownCodec.bulletGlyphUTF16Length(forIndent: info.indent)
                let bulletLocation = range.location + 1 + info.indent * 2  // \n + indent
                let bulletRange = NSRange(location: bulletLocation, length: glyphLen)
                if bulletRange.upperBound <= mutable.length {
                    mutable.addAttribute(.airpadBulletGlyph, value: true, range: bulletRange)
                }
            }

            renumberLists(in: mutable)
            textView.attributedText = mutable
            let newCursor = range.location + (insertion as NSString).length
            textView.selectedRange = NSRange(location: min(newCursor, mutable.length), length: 0)
            refreshActiveState(in: textView)
            pushBinding(from: textView)
            return true
        }

        /// Checklist-paragraph return handling. Mirrors `handleReturnKey`'s
        /// list-continuation contract for the SF-Symbol attachment glyph:
        /// empty checklist line + Enter strips the prefix and exits; non-empty
        /// line + Enter inserts `\n` + same-indent + attachment + space (new
        /// items always start unchecked). Detection is marker-based via
        /// `MarkdownCodec.checklistPrefixRange`, so it works on attachment
        /// chars (U+FFFC) without depending on a specific visible glyph.
        /// Returns true when handled.
        private func handleReturnInChecklist(
            line: String,
            cursorParagraph: NSRange,
            in textView: UITextView,
            range: NSRange
        ) -> Bool {
            guard let attrText = textView.attributedText else { return false }
            guard let prefixRange = MarkdownCodec.checklistPrefixRange(in: attrText, paragraph: cursorParagraph) else {
                return false
            }
            // Indent depth = chars between paragraph start and the glyph location.
            let indentChars = prefixRange.location - cursorParagraph.location
            let prefixLen = indentChars + 2  // indent spaces + glyph + space
            let lineLen = (line as NSString).length

            // Empty checklist item + Enter → strip prefix, exit checklist mode.
            if lineLen == prefixLen {
                captureUndoSnapshot(in: textView)
                let stripRange = NSRange(location: cursorParagraph.location, length: prefixLen)
                let mutable = NSMutableAttributedString(attributedString: attrText)
                mutable.deleteCharacters(in: stripRange)
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: max(0, cursorParagraph.location), length: 0)
                refreshActiveState(in: textView)
                pushBinding(from: textView)
                return true
            }

            captureUndoSnapshot(in: textView)
            // Otherwise: \n + same-indent + attachment + space. Build as an
            // attributed string so the attachment + marker + body styling land
            // in one shot, with no risk of stale list markers bleeding into
            // the inserted run from typingAttributes.
            let indentStr = String(repeating: "  ", count: indentChars / 2)
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.white,
            ]
            let insertion = NSMutableAttributedString(string: "\n" + indentStr, attributes: bodyAttrs)
            insertion.append(MarkdownCodec.checklistAttachmentString(checked: false))
            insertion.append(NSAttributedString(string: " ", attributes: bodyAttrs))
            let insertionLen = insertion.length

            let mutable = NSMutableAttributedString(attributedString: attrText)
            mutable.replaceCharacters(in: range, with: insertion)

            textView.attributedText = mutable
            let newCursor = range.location + insertionLen
            textView.selectedRange = NSRange(location: min(newCursor, mutable.length), length: 0)
            refreshActiveState(in: textView)
            pushBinding(from: textView)
            return true
        }

        // MARK: Link entry (step 6)

        /// Presents a `UIAlertController` for link entry — pragmatic Notes-shaped UX.
        /// Putting an editable field inside `inputAccessoryView` would steal first-responder
        /// and dismiss the keyboard mid-entry; the alert keeps things clean and we restore
        /// the textView's first-responder afterwards so editing continues seamlessly.
        ///
        /// - If a selection exists, only the URL field is shown; the selection becomes link text.
        /// - If no selection, both Title and URL fields are shown; the title text is inserted.
        fileprivate func beginLinkEntry(in textView: UITextView) {
            let range = textView.selectedRange
            let nsText = (textView.text ?? "") as NSString
            let hasSelection = (range.length > 0)
            let selectedText: String? = hasSelection ? nsText.substring(with: range) : nil
            let savedRange = NSRange(location: range.location, length: range.length)

            let alert = UIAlertController(title: "Add Link", message: nil, preferredStyle: .alert)
            if !hasSelection {
                alert.addTextField { tf in
                    tf.placeholder = "Title"
                    tf.autocapitalizationType = .sentences
                }
            }
            alert.addTextField { tf in
                tf.placeholder = "https://..."
                tf.keyboardType = .URL
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak textView] _ in
                textView?.becomeFirstResponder()
            })
            alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                let title: String
                let urlString: String
                if hasSelection {
                    title = selectedText ?? ""
                    urlString = alert.textFields?.first?.text ?? ""
                } else {
                    title = alert.textFields?.first?.text ?? ""
                    urlString = alert.textFields?.last?.text ?? ""
                }
                self.commitLinkEntry(
                    savedRange: savedRange,
                    title: title,
                    urlString: urlString,
                    hasSelection: hasSelection,
                    in: textView
                )
                textView.becomeFirstResponder()
            })

            guard var presenter = textView.window?.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(alert, animated: true)
        }

        private func commitLinkEntry(
            savedRange: NSRange,
            title: String,
            urlString: String,
            hasSelection: Bool,
            in textView: UITextView
        ) {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let url = URL(string: normalized) else { return }

            captureUndoSnapshot(in: textView)
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            if hasSelection {
                mutable.addAttribute(.link, value: url, range: savedRange)
                mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: savedRange)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: savedRange)
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: savedRange.location + savedRange.length, length: 0)
            } else {
                let visible = title.isEmpty ? normalized : title
                let attrs: [NSAttributedString.Key: Any] = [
                    .link: url,
                    .foregroundColor: UIColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: UIFont.preferredFont(forTextStyle: .body)
                ]
                let inserted = NSAttributedString(string: visible, attributes: attrs)
                mutable.replaceCharacters(in: savedRange, with: inserted)
                textView.attributedText = mutable
                let endLoc = savedRange.location + (visible as NSString).length
                textView.selectedRange = NSRange(location: endLoc, length: 0)
            }
            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        // MARK: Inline attribute toggles (step 3)

        /// Toggles a font symbolic trait (bold / italic) across the current selection,
        /// or on `typingAttributes` when there's no selection. Notes' "if uniform, invert;
        /// else set" semantics.
        fileprivate func toggleFontTrait(_ trait: UIFontDescriptor.SymbolicTraits, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
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
            pushBinding(from: textView)
        }

        /// Inline code is a font-family swap plus a marker attribute. The marker is the
        /// detection source of truth (independent of font introspection quirks); the
        /// monospaced font is for rendering.
        fileprivate func toggleInlineCode(in textView: UITextView) {
            captureUndoSnapshot(in: textView)
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
            pushBinding(from: textView)
        }

        /// Toggles a simple attribute (underline / strikethrough) that doesn't require font
        /// recomposition.
        fileprivate func toggleSimpleAttribute(_ key: NSAttributedString.Key, value: Any, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
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
            pushBinding(from: textView)
        }

        // MARK: Heading style (Stage 2.3)

        /// Applies (or clears, when `level` is nil) the heading style on every
        /// paragraph touched by the current selection. Body resets fonts to
        /// the body baseline, preserving italic. typingAttributes are updated
        /// so subsequent keystrokes inherit the new style at the cursor.
        fileprivate func applyHeading(level: RichTextHeadingLevel?, in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let selRange = textView.selectedRange
            let mut = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            MarkdownCodec.setHeadingLevel(level, on: mut, paragraphsTouchedBy: selRange)
            textView.attributedText = mut

            // Re-seat selection inside the (possibly mutated) text. `setHeadingLevel`
            // doesn't change length, so we can pass the original range back through —
            // clamp defensively in case future logic does mutate length.
            let length = mut.length
            let clampedLoc = min(selRange.location, length)
            let clampedLen = min(selRange.length, length - clampedLoc)
            textView.selectedRange = NSRange(location: clampedLoc, length: clampedLen)

            // Update typingAttributes so the next keystroke inherits the new style.
            var typing = textView.typingAttributes
            let existingFont = (typing[.font] as? UIFont) ?? NoteTypographyHelper.bodyFont
            let italic = existingFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
            if let level {
                typing[.airpadHeadingLevel] = level.rawValue
                typing[.font] = NoteTypographyHelper.headingFont(level: level, italic: italic)
            } else {
                typing.removeValue(forKey: .airpadHeadingLevel)
                let body = NoteTypographyHelper.bodyFont
                if italic, let desc = body.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    typing[.font] = UIFont(descriptor: desc, size: body.pointSize)
                } else {
                    typing[.font] = body
                }
            }
            textView.typingAttributes = typing

            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        // MARK: Checklist toggle (Stage 2.3)

        /// Toggles checklist state for every paragraph touched by the current
        /// selection. Direction is derived from the first touched paragraph:
        /// if it already starts with `☐ ` / `☑ `, the operation strips the
        /// glyph; otherwise it prepends `☐ ` to each paragraph that doesn't
        /// already have one.
        ///
        /// Caret shift: each modified paragraph's start grows or shrinks by 2
        /// chars (`☐` + space). We adjust the caret by the total length delta —
        /// exact for single-paragraph toggles (the common case) and
        /// approximately right for multi-paragraph selections.
        fileprivate func toggleChecklist(in textView: UITextView) {
            captureUndoSnapshot(in: textView)
            let selRange = textView.selectedRange
            let mut = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
            let ns = mut.string as NSString

            let safeLoc = min(max(selRange.location, 0), ns.length)
            // Empty-doc case: `paragraphRange(for:)` can be unhappy with zero-length
            // receivers — treat empty as "no checklist prefix" so we go insert-mode.
            let alreadyChecklist: Bool
            if ns.length == 0 {
                alreadyChecklist = false
            } else {
                let firstParaRange = ns.paragraphRange(for: NSRange(location: safeLoc, length: 0))
                alreadyChecklist = MarkdownCodec.checklistPrefixRange(in: mut, paragraph: firstParaRange) != nil
            }

            let lengthBefore = mut.length
            MarkdownCodec.setChecklist(!alreadyChecklist, on: mut, paragraphsTouchedBy: selRange)
            let delta = mut.length - lengthBefore

            textView.attributedText = mut

            let newLength = mut.length
            let newLoc = max(0, min(selRange.location + delta, newLength))
            let newLen = max(0, min(selRange.length, newLength - newLoc))
            textView.selectedRange = NSRange(location: newLoc, length: newLen)

            // Ensure the marker + attachment don't leak into typingAttributes
            // after the mutation (next typed char would otherwise inherit them).
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .airpadChecklistGlyph)
            typing.removeValue(forKey: .attachment)
            textView.typingAttributes = typing

            refreshActiveState(in: textView)
            pushBinding(from: textView)
        }

        // MARK: Checklist tap-to-toggle (Stage 2.3 commit 5)

        /// Tap handler installed in `attachToolbar`. The delegate's
        /// `shouldReceive` already filtered to taps inside a glyph's draw
        /// rect, so we just re-resolve the glyph and flip its state.
        @objc fileprivate func handleChecklistTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = self.textView else { return }
            let point = recognizer.location(in: textView)
            guard let prefixRange = hitTestChecklistGlyph(at: point, in: textView) else { return }
            toggleChecklistChecked(at: prefixRange, in: textView)
        }

        /// Returns the 2-char checklist prefix range (glyph + space) when
        /// `point` lands inside the glyph's drawing rect; nil otherwise.
        /// Strict — a tap that's merely "near" the glyph (e.g. in the
        /// trailing space or text) does not toggle. This is used both by
        /// the tap handler and by `shouldReceive` so the recognizer
        /// effectively only fires on glyph hits.
        fileprivate func hitTestChecklistGlyph(at point: CGPoint, in textView: UITextView) -> NSRange? {
            guard let attrText = textView.attributedText else { return nil }
            let ns = attrText.string as NSString
            guard ns.length > 0 else { return nil }
            guard let position = textView.closestPosition(to: point) else { return nil }
            let charIdx = textView.offset(from: textView.beginningOfDocument, to: position)
            // closestPosition can sit one past the glyph if the tap lands
            // at its trailing edge; clamp inside string bounds before
            // computing the paragraph so we don't read past the end.
            let probeIdx = min(max(charIdx, 0), ns.length - 1)
            let paraRange = ns.paragraphRange(for: NSRange(location: probeIdx, length: 0))
            guard let prefixRange = MarkdownCodec.checklistPrefixRange(in: attrText, paragraph: paraRange) else {
                return nil
            }
            let glyphLoc = prefixRange.location
            guard let start = textView.position(from: textView.beginningOfDocument, offset: glyphLoc),
                  let end = textView.position(from: textView.beginningOfDocument, offset: glyphLoc + 1),
                  let range = textView.textRange(from: start, to: end) else {
                return nil
            }
            let rects = textView.selectionRects(for: range)
            for selRect in rects {
                if selRect.rect.contains(point) { return prefixRange }
            }
            return nil
        }

        /// Replaces the 1-char attachment glyph at `prefixRange.location`
        /// with a freshly-built attachment in the opposite checked state.
        /// Length-preserving so selection / typingAttributes stay valid.
        private func toggleChecklistChecked(at prefixRange: NSRange, in textView: UITextView) {
            let attrText = textView.attributedText ?? NSAttributedString()
            let glyphLoc = prefixRange.location
            guard glyphLoc < attrText.length else { return }
            let attrs = attrText.attributes(at: glyphLoc, effectiveRange: nil)
            let currentChecked = ((attrs[.airpadChecklistGlyph] as? Int) ?? 0) == 1
            let newChecked = !currentChecked

            captureUndoSnapshot(in: textView)
            // BUG 13 — save the selection: reassigning `attributedText` below
            // resets the caret to the document END, and UITextView then scrolls
            // to it, so every checkbox tick shot the view to the bottom of the
            // entry. `adjustChecklistIndent` restores the selection after the
            // same reassignment and never jumps — mirror it here.
            let savedSelection = textView.selectedRange
            let mut = NSMutableAttributedString(attributedString: attrText)
            let replacement = MarkdownCodec.checklistAttachmentString(checked: newChecked)
            mut.replaceCharacters(in: NSRange(location: glyphLoc, length: 1), with: replacement)
            textView.attributedText = mut
            // The replace is length-preserving, so the saved range is still
            // valid (clamped defensively).
            let loc = min(savedSelection.location, mut.length)
            textView.selectedRange = NSRange(location: loc,
                                             length: min(savedSelection.length, mut.length - loc))
            // restyle:false — only the glyph attachment swapped (checked↔unchecked);
            // paragraph typography is unchanged, so the storage-mutating
            // `applyInPlace` (the MD14 caret-jump root cause, a second scroll
            // disruptor) must NOT run on a mere toggle.
            refreshActiveState(in: textView, restyle: false)
            pushBinding(from: textView)
            // A tap toggle never fires onEndEditing (no focus change), so drive
            // persistence explicitly — otherwise the tick is lost on relaunch if
            // the app closes before the field defocuses.
            parent.onChecklistMutated?()
        }

        // MARK: Checklist indent / outdent (Stage 2.3 commit 5)

        /// Indents or outdents every checklist paragraph touched by the
        /// current selection. Returns true if at least one checklist
        /// paragraph was found and mutated; false otherwise so the caller
        /// can fall through to bullet/numbered list logic.
        ///
        /// - Indent (+1): inserts `"  "` at paragraph start, capped at 5 levels.
        /// - Outdent (-1): removes one leading `"  "`; if the line was
        ///   already at indent 0, strips the glyph + space entirely
        ///   (mirrors bullet/numbered outdent-exit behavior).
        fileprivate func adjustChecklistIndent(by direction: Int, in textView: UITextView) -> Bool {
            guard direction == 1 || direction == -1 else { return false }
            let attrText = textView.attributedText ?? NSAttributedString()
            let ns = attrText.string as NSString
            guard ns.length > 0 else { return false }
            let selRange = textView.selectedRange
            let safeLoc = min(max(selRange.location, 0), ns.length)
            let safeLen = min(selRange.length, ns.length - safeLoc)
            let enclosing = ns.paragraphRange(for: NSRange(location: safeLoc, length: safeLen))

            var paragraphRanges: [NSRange] = []
            ns.enumerateSubstrings(in: enclosing, options: .byParagraphs) { _, subRange, _, _ in
                paragraphRanges.append(subRange)
            }
            let checklistParas = paragraphRanges.filter {
                MarkdownCodec.checklistPrefixRange(in: attrText, paragraph: $0) != nil
            }
            guard !checklistParas.isEmpty else { return false }

            captureUndoSnapshot(in: textView)
            let mut = NSMutableAttributedString(attributedString: attrText)
            let bodyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.white,
            ]

            // Reverse-order so earlier ranges aren't invalidated.
            var caretDelta = 0
            for paraRange in checklistParas.reversed() {
                guard let prefixRange = MarkdownCodec.checklistPrefixRange(in: mut, paragraph: paraRange) else { continue }
                let indentChars = prefixRange.location - paraRange.location

                if direction == 1 {
                    guard indentChars < 10 else { continue }  // cap at 5 levels
                    let twoSpaces = NSAttributedString(string: "  ", attributes: bodyAttrs)
                    mut.insert(twoSpaces, at: paraRange.location)
                    if paraRange.location <= safeLoc { caretDelta += 2 }
                } else {
                    if indentChars >= 2 {
                        let delRange = NSRange(location: paraRange.location, length: 2)
                        mut.deleteCharacters(in: delRange)
                        if paraRange.location <= safeLoc { caretDelta -= 2 }
                    } else {
                        mut.deleteCharacters(in: prefixRange)
                        if prefixRange.location <= safeLoc { caretDelta -= prefixRange.length }
                    }
                }
            }

            textView.attributedText = mut
            let newLoc = max(0, min(safeLoc + caretDelta, mut.length))
            textView.selectedRange = NSRange(location: newLoc, length: 0)
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .airpadChecklistGlyph)
            typing.removeValue(forKey: .attachment)
            textView.typingAttributes = typing
            refreshActiveState(in: textView)
            pushBinding(from: textView)
            return true
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
            let body = NoteTypographyHelper.bodyFont
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

// MARK: - Formatting-toolbar metrics + live-height measurement (caret-clearance)

/// The editor's formatting toolbar is the `UITextView`'s `inputAccessoryView`
/// (see `Coordinator.attachToolbar`). It floats ABOVE the keyboard, and the
/// scroll view's `adjustedContentInset` accounts only for the keyboard — so the
/// caret, kept just above the keyboard, otherwise sits UNDER the toolbar. The
/// keyboard-up bottom inset in `NodeDetailView` reserves this toolbar's height
/// (+ breathing room) so the caret clears it in normal viewing.
enum NoteEditorToolbar {
    /// Designed container height — the single source of truth read by both
    /// `attachToolbar` (the container frame) and the inset's pre-measurement
    /// fallback. The inset prefers the LIVE laid-out height once known.
    static let designHeight: CGFloat = 56
}

extension Notification.Name {
    /// Posted by `ToolbarContainerView` with the toolbar's ACTUAL laid-out height
    /// (`userInfo["height"]: Double`) once it is presented in the window (keyboard
    /// up) — so the inset reserves the real on-screen height, not the coded value.
    static let noteEditorToolbarHeightMeasured = Notification.Name("noteEditorToolbarHeightMeasured")
}

/// `inputAccessoryView` container for the formatting toolbar. Posts its real
/// laid-out height once presented (window-attached + laid out = keyboard up), so
/// the caret-clearance inset reserves exactly the toolbar's on-screen height
/// rather than trusting the coded design value (which is the container's initial
/// frame, not a guaranteed laid-out height).
final class ToolbarContainerView: UIView {
    private var lastPostedHeight: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil else { return }          // only once actually presented
        let h = bounds.height
        guard h > 0, h != lastPostedHeight else { return }
        lastPostedHeight = h
        NotificationCenter.default.post(
            name: .noteEditorToolbarHeightMeasured, object: nil, userInfo: ["height": Double(h)]
        )
    }
}

// MARK: - Custom attribute keys

extension NSAttributedString.Key {
    /// Marker for inline-code spans. Detection source of truth (independent of font
    /// introspection quirks); the corresponding monospaced font is for rendering.
    static let airpadInlineCode = NSAttributedString.Key("airpadInlineCode")

    /// Marker placed on a `•` character that represents a markdown `-` bullet in storage.
    /// The textView always displays `• `; the `MarkdownCodec` strips the marker and
    /// substitutes `-` back when encoding so the on-disk JSON remains pure markdown.
    /// User-typed literal `•` chars (no marker) are preserved as-is — only marker-bearing
    /// glyphs are mapped to hyphens.
    static let airpadBulletGlyph = NSAttributedString.Key("airpadBulletGlyph")

    /// Stage 2.3 — paragraph-level heading marker. Raw value matches
    /// `RichTextHeadingLevel`. Set on every char in a paragraph styled as
    /// title/heading/subheading/monospaced; absence means body (default).
    static let airpadHeadingLevel = NSAttributedString.Key("airpadHeadingLevel")

    /// Stage 2.3 — marker on the single display-form checklist glyph char.
    /// In the current SF Symbol path the glyph is an NSTextAttachment
    /// (`NSAttachmentCharacter` U+FFFC); legacy sessions may have left
    /// Unicode `☐` / `☑` chars in place — either way the marker is the
    /// source of truth. Value is Int (0 = unchecked, 1 = checked). Encode
    /// reads the marker + value to emit the canonical markdown prefix
    /// `- [ ] ` / `- [x] `.
    static let airpadChecklistGlyph = NSAttributedString.Key("airpadChecklistGlyph")

    /// Tags the single attachment character of an inline image with its
    /// `.imageVideo` item id. Storage form: `![](airpad-image:<id>)`. The image
    /// bytes live in the referenced item (ws-note-primitive inline images).
    static let airpadImageItemID = NSAttributedString.Key("airpadImageItemID")
}

// MARK: - Gesture recognizer delegate (Stage 2.3 commit 5)

extension RichTextEditor.Coordinator: UIGestureRecognizerDelegate {
    /// Only fires the checklist tap recognizer when the touch lands inside
    /// a glyph's drawing rect. For every other touch we return false so
    /// the textView's own tap gesture handles cursor placement normally.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let textView = gestureRecognizer.view as? UITextView else { return true }
        let point = touch.location(in: textView)
        return hitTestChecklistGlyph(at: point, in: textView) != nil
    }
}

// MARK: - Heading levels

/// Paragraph-level heading roles for the editor. Stored in the attributed
/// string via `.airpadHeadingLevel` (raw value); persisted in markdown via
/// leading `# `/`## `/`### ` prefix or, for `.monospaced`, by wrapping the
/// entire paragraph contents in single backticks (markdown's atomic code-span
/// — nested inline formatting is intentionally dropped by spec).
enum RichTextHeadingLevel: Int {
    case title       = 1
    case heading     = 2
    case subheading  = 3
    case monospaced  = 4

    /// Locked Stage 2.3 sizes relative to the 17pt body baseline:
    /// Title 26 / Heading 21 / Subheading 18 / Body 17 / Monospaced 16.
    var font: UIFont {
        switch self {
        case .title:       return UIFont.systemFont(ofSize: 26, weight: .bold)
        case .heading:     return UIFont.systemFont(ofSize: 21, weight: .semibold)
        case .subheading:  return UIFont.systemFont(ofSize: 18, weight: .semibold)
        case .monospaced:  return UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        }
    }
}

// MARK: - Note font construction

/// One source of truth for the fonts the note editor builds. Body font was
/// previously constructed independently in four places (editor default typing
/// attrs, decode-path `currentAttrs`, toggle-path `buildBodyFont`, and
/// `NoteTypography.typingAttributes`); heading-with-italic in two
/// (`Coordinator.applyHeading` + `MarkdownCodec.applyHeading`). Centralising
/// both removes the drift (freshly-typed vs loaded text differing) and fixes a
/// silent italic-on-heading failure — see `headingFont`.
enum NoteTypographyHelper {

    /// Body font for the editor and decoded text.
    static var bodyFont: UIFont {
        UIFont.preferredFont(forTextStyle: .body)
    }

    /// Heading font at `level`, optionally italic.
    ///
    /// The obvious `base.fontDescriptor.withSymbolicTraits(.traitItalic)` — which
    /// both `applyHeading` sites used — frequently returns `nil` for the non-regular
    /// system weights headings use (Title `.bold`, Heading/Subheading `.semibold`),
    /// because the numeric weight isn't carried by the symbolic-trait bitmask. The
    /// call then silently drops italic. Rebuild the descriptor's `.traits`
    /// dictionary instead, preserving the concrete weight alongside the italic bit.
    /// If the platform still can't synthesise the face, `UIFont(descriptor:size:)`
    /// falls back to the closest match — i.e. the non-italic base, the prior
    /// behaviour, so this never regresses.
    static func headingFont(level: RichTextHeadingLevel, italic: Bool) -> UIFont {
        let base = level.font
        guard italic else { return base }
        let descriptor = base.fontDescriptor
        var symbolic = descriptor.symbolicTraits
        symbolic.insert(.traitItalic)
        var traits = (descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]) ?? [:]
        traits[.symbolic] = symbolic.rawValue
        let italicDescriptor = descriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: italicDescriptor, size: base.pointSize)
    }
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
    /// True when the cursor sits in a paragraph that begins with a checklist
    /// glyph (SF Symbol attachment tagged with `.airpadChecklistGlyph`).
    /// Drives the toolbar button's active state.
    var isChecklist = false
    var canUndo = false
    var canRedo = false
    /// Heading style of the paragraph the cursor sits in. `nil` = Body.
    var currentHeadingLevel: RichTextHeadingLevel? = nil

    var toggleBold: () -> Void = {}
    var toggleItalic: () -> Void = {}
    var toggleUnderline: () -> Void = {}
    var toggleStrikethrough: () -> Void = {}
    var toggleInlineCode: () -> Void = {}
    var toggleBulletList: () -> Void = {}
    var toggleNumberedList: () -> Void = {}
    /// Adds or strips an unchecked checklist glyph for every paragraph
    /// touched by the current selection. Direction (insert vs. strip) is
    /// derived from the first touched paragraph.
    var toggleChecklist: () -> Void = {}
    var indent: () -> Void = {}
    var outdent: () -> Void = {}
    var insertLink: () -> Void = {}
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var dismissKeyboard: () -> Void = {}
    /// Sets the heading style for every paragraph touched by the current
    /// selection. `nil` resets to Body.
    var applyHeading: (RichTextHeadingLevel?) -> Void = { _ in }
}

// MARK: - Toolbar view

/// Keyboard-attached formatting toolbar. Hosted via `UIHostingController` inside the
/// `UITextView`'s `inputAccessoryView`. Buttons read active-state from `RichTextEditorState`
/// and invoke the matching command closure.
struct RichTextToolbar: View {
    @Bindable var state: RichTextEditorState

    /// ws-dark-light-mode — the formatting toolbar is a UIKit
    /// `inputAccessoryView` (SwiftUI hosted in a `UIHostingController`), so it
    /// sits OUTSIDE the SwiftUI render tree and every render-tree/directory
    /// sweep missed it. The capsule adapts: dark = the prior `Color(white:
    /// 0.12)` (byte-identical), light = a soft light pill so the bar reads on
    /// cream. Buttons/separators use `.primary` (adaptive; dark = white =
    /// identical). System color, not `AppearancePalette` — this is a Shared view.
    private static let toolbarFill = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.12, alpha: 1)
            : UIColor(white: 0.90, alpha: 1)
    })

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    headingMenu
                    separator
                    button(icon: "bold", active: state.isBold, action: state.toggleBold)
                    button(icon: "italic", active: state.isItalic, action: state.toggleItalic)
                    button(icon: "underline", active: state.isUnderline, action: state.toggleUnderline)
                    button(icon: "strikethrough", active: state.isStrikethrough, action: state.toggleStrikethrough)
                    separator
                    button(icon: "list.bullet", active: state.isBulletList, action: state.toggleBulletList)
                    button(icon: "list.number", active: state.isNumberedList, action: state.toggleNumberedList)
                    button(icon: "checklist", active: state.isChecklist, action: state.toggleChecklist)
                    button(icon: "decrease.indent", active: false, action: state.outdent)
                    button(icon: "increase.indent", active: false, action: state.indent)
                    separator
                    button(icon: "chevron.left.forwardslash.chevron.right", active: state.isInlineCode, action: state.toggleInlineCode)
                    button(icon: "link", active: false, action: state.insertLink)
                    separator
                    button(icon: "arrow.uturn.backward", active: false, enabled: state.canUndo, action: state.undo)
                    button(icon: "arrow.uturn.forward", active: false, enabled: state.canRedo, action: state.redo)
                }
                .padding(.horizontal, 10)
            }
            separator
            button(icon: "keyboard.chevron.compact.down", active: false, action: state.dismissKeyboard)
                .padding(.trailing, 6)
        }
        .frame(height: 48)
        .background(
            Capsule(style: .continuous).fill(Self.toolbarFill)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    /// Heading-style picker. Inline Picker inside a Menu gives the iOS native
    /// checkmark affordance on the active style; the trigger button lights up
    /// whenever the cursor sits in any non-Body paragraph.
    private var headingMenu: some View {
        let active = state.currentHeadingLevel != nil
        let binding = Binding<RichTextHeadingLevel?>(
            get: { state.currentHeadingLevel },
            set: { state.applyHeading($0) }
        )
        return Menu {
            Picker("Style", selection: binding) {
                Text("Title").tag(Optional(RichTextHeadingLevel.title))
                Text("Heading").tag(Optional(RichTextHeadingLevel.heading))
                Text("Subheading").tag(Optional(RichTextHeadingLevel.subheading))
                Text("Body").tag(Optional<RichTextHeadingLevel>.none)
                Text("Monospaced").tag(Optional(RichTextHeadingLevel.monospaced))
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.75))
                .background(active ? Color.primary.opacity(0.18) : Color.clear)
                .clipShape(Capsule(style: .continuous))
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
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
                .foregroundStyle(enabled ? (active ? Color.primary : Color.primary.opacity(0.75)) : Color.primary.opacity(0.3))
                .background(active ? Color.primary.opacity(0.18) : Color.clear)
                .clipShape(Capsule(style: .continuous))
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
        placeholderLabel.textColor = UIColor.label.withAlphaComponent(0.35)
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

// MARK: - Markdown codec

/// Lossless markdown encode/decode for the editor's attributed-text representation.
///
/// **Encode** walks every attribute run in the attributed string and emits markdown
/// markers around runs that carry our tracked attributes:
/// - `**…**` bold (font with `.traitBold`)
/// - `*…*` italic (font with `.traitItalic`)
/// - `~~…~~` strikethrough (`.strikethroughStyle`)
/// - `<u>…</u>` underline (`.underlineStyle`) — markdown has no native underline
/// - `` `…` `` inline code (`.airpadInlineCode` marker; other formats don't nest in code)
/// - `[…](url)` link (`.link` attribute)
/// - List markers (`- ` / `N. `) round-trip as literal text since the editor stores them
///   as plain characters at line start; no special handling needed.
///
/// **Decode** parses the same markers back into attributes. Special characters in literal
/// text are escaped on encode (`\*`, `` \` ``, `\~`, `\[`, `\<`, `\\`) so plain text containing
/// markdown-reserved chars round-trips correctly.
///
/// Plain text → encode → plain text is the lossless invariant: text without attributes
/// has no markers emitted, only escapes for reserved chars, which decode back to the
/// original characters.
///
/// **Bullet glyph substitution (Stage 2.2.1):** the editor displays `• ` at the start of
/// bulleted lines while the storage form stays `- `. The substitution is driven by the
/// `.airpadBulletGlyph` marker attribute placed on the `•` char: encode rewrites
/// marker-bearing `•` → `-`; decode walks paragraphs and substitutes `- ` → `• ` (adding
/// the marker) at line start, with optional leading indent. Literal `•` chars typed by
/// the user (no marker) are preserved as-is.
///
/// **Heading levels (Stage 2.3):** paragraphs styled as Title / Heading / Subheading
/// persist as leading `# ` / `## ` / `### ` markers; Monospaced wraps the entire
/// paragraph content in single backticks. The display form carries
/// `.airpadHeadingLevel` on every char of a styled paragraph plus the corresponding
/// heading font; encode reads the first-char attribute to emit the right prefix and
/// subtracts heading-inherent font traits so a plain Title round-trips as `# Hello`
/// (not `# **Hello**`). Decode runs a post-pass after the char-by-char inline
/// decoder to strip prefixes / detect whole-paragraph code spans.
@MainActor
enum MarkdownCodec {

    // MARK: Bullet glyph depth cascade
    //
    // Notes-style depth cascade — `•` at level 0, `◦` at level 1, `▪` at level 2+.
    // `•` (U+2022) and `◦` (U+25E6) render as text by default. `▪` (U+25AA) has
    // emoji-presentation-default on iOS — without the U+FE0E text variation selector
    // it paints as a color emoji square rather than a plain glyph. The VS makes the
    // depth-2 glyph 2 UTF-16 code units; consumers must use `bulletGlyphUTF16Length`
    // rather than assuming 1.
    static func bulletGlyph(forIndent depth: Int) -> String {
        switch depth {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪\u{FE0E}"
        }
    }

    static func bulletGlyphUTF16Length(forIndent depth: Int) -> Int {
        return (bulletGlyph(forIndent: depth) as NSString).length
    }

    // MARK: Checklist glyphs (Stage 2.3)
    //
    // Display form is an NSTextAttachment wrapping an SF Symbol (`circle` /
    // `checkmark.circle.fill`), tinted to the body text color. Storage form is
    // markdown `- [ ] ` / `- [x] ` (5 chars + trailing space). The attachment
    // occupies one `NSAttachmentCharacter` (U+FFFC) in the attributed string and
    // is tagged with `.airpadChecklistGlyph` (Int: 0 unchecked / 1 checked) so
    // the encoder and detection paths can find it without depending on the
    // underlying char.

    /// Symbol point-size for the inline checkbox. 22pt against a 17pt body
    /// matches Notes' visual scale — large enough to feel tappable, not so
    /// large that it overpowers the line.
    private static let checklistSymbolPointSize: CGFloat = 22

    /// Vertical-baseline nudge for the attachment so the circle's center
    /// aligns roughly with the lowercase x-height of the body font. Negative
    /// pulls the glyph down from the text top. Tuned for 22pt symbol / 17pt body.
    private static let checklistAttachmentYOffset: CGFloat = -5

    /// Builds the SF-Symbol-backed `NSTextAttachment` for a checklist item.
    /// Tinted with `.label` (the body text color) via `.alwaysOriginal`, so the
    /// glyph matches the note text in both themes — white in dark (identical to
    /// before), near-black on cream (ws-dark-light-mode). NOTE: `.alwaysOriginal`
    /// bakes the resolved color at build time, so the glyph re-resolves on the
    /// next decode/appear, not live on an in-place appearance flip (acceptable:
    /// set the mode, then open the note).
    static func makeChecklistAttachment(checked: Bool) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let symbolName = checked ? "checkmark.circle.fill" : "circle"
        let config = UIImage.SymbolConfiguration(
            pointSize: checklistSymbolPointSize,
            weight: .regular,
            scale: .medium
        )
        let image = UIImage(systemName: symbolName, withConfiguration: config)?
            .withTintColor(.label, renderingMode: .alwaysOriginal)
        attachment.image = image
        if let size = image?.size {
            attachment.bounds = CGRect(
                x: 0,
                y: checklistAttachmentYOffset,
                width: size.width,
                height: size.height
            )
        }
        return attachment
    }

    /// Single-char attributed string carrying: the attachment, the marker
    /// (`.airpadChecklistGlyph` with the state), body font, and the body text
    /// color. Use this as the display-form replacement for the markdown prefix.
    static func checklistAttachmentString(checked: Bool) -> NSAttributedString {
        let attachment = makeChecklistAttachment(checked: checked)
        let mut = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let range = NSRange(location: 0, length: mut.length)
        mut.addAttribute(.airpadChecklistGlyph, value: checked ? 1 : 0, range: range)
        mut.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
        mut.addAttribute(.foregroundColor, value: UIColor.label, range: range)
        return mut
    }

    /// Marker-based prefix detection. Returns the NSRange covering the
    /// attachment char + trailing space (2 chars) at the start of `paragraph`,
    /// accounting for `"  "` indent groups before it. `nil` when the paragraph
    /// doesn't start with a marker-tagged glyph (so user-typed literal `☐` /
    /// `○` chars without the marker are correctly rejected — only checklist
    /// items the codec/toolbar produced count).
    static func checklistPrefixRange(in attr: NSAttributedString, paragraph: NSRange) -> NSRange? {
        let ns = attr.string as NSString
        guard paragraph.length > 0,
              paragraph.upperBound <= ns.length,
              paragraph.location >= 0 else { return nil }
        let paraText = ns.substring(with: paragraph)
        let chars = Array(paraText)
        var idx = 0
        while idx + 1 < chars.count, chars[idx] == " ", chars[idx + 1] == " " {
            idx += 2
        }
        // Need at least: glyph + space.
        guard idx + 1 < chars.count else { return nil }
        let glyphLoc = paragraph.location + idx
        guard glyphLoc < attr.length else { return nil }
        let attrs = attr.attributes(at: glyphLoc, effectiveRange: nil)
        guard attrs[.airpadChecklistGlyph] != nil else { return nil }
        // Trailing space sanity.
        let spaceLoc = glyphLoc + 1
        guard spaceLoc < ns.length else { return nil }
        let next = ns.substring(with: NSRange(location: spaceLoc, length: 1))
        guard next == " " else { return nil }
        return NSRange(location: glyphLoc, length: 2)
    }

    // MARK: Inline images (ws-note-primitive)
    //
    // Display form: an NSTextAttachment occupying one `NSAttachmentCharacter`
    // (U+FFFC), tagged `.airpadImageItemID` with the `.imageVideo` item id.
    // Storage form: markdown `![](airpad-image:<id>)`. The image bytes live in
    // the referenced item (no schema change) — the token only points to it. The
    // attachment starts as a placeholder; `RichTextEditor` async-loads the real
    // image via its `resolveImage` hook and swaps it in, sized to text width.

    static let imageTokenPrefix = "![](airpad-image:"

    /// The storage token for an inline image referencing `itemID`.
    static func imageToken(itemID: String) -> String { "\(imageTokenPrefix)\(itemID))" }

    /// Single attachment-char string for an inline image, tagged with `itemID`.
    /// The image is nil until the editor resolves it (placeholder bounds keep
    /// layout stable meanwhile).
    static func imageAttachmentString(itemID: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let mut = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let range = NSRange(location: 0, length: mut.length)
        mut.addAttribute(.airpadImageItemID, value: itemID, range: range)
        mut.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
        return mut
    }

    /// All item ids referenced by `![](airpad-image:<id>)` tokens in `markdown`,
    /// in order. Used by the note renderer and by NodeDetailView (to hide
    /// inline images from the standalone payload list).
    static func referencedImageItemIDs(in markdown: String) -> [String] {
        guard markdown.contains(imageTokenPrefix) else { return [] }
        var ids: [String] = []
        var rest = Substring(markdown)
        while let start = rest.range(of: imageTokenPrefix) {
            let after = rest[start.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            ids.append(String(after[after.startIndex..<close]))
            rest = after[after.index(after: close)...]
        }
        return ids
    }

    // MARK: Encoding

    private static let escapeChars: Set<Character> = ["*", "`", "~", "[", "<", "\\"]

    static func encode(_ attr: NSAttributedString) -> String {
        guard attr.length > 0 else { return "" }
        // Pre-pass: strip the display-only bullet glyph substitution so the markdown
        // we emit uses the canonical `-` storage form.
        let normalized = substituteBulletGlyphsForStorage(attr)
        let nsString = normalized.string as NSString
        let fullRange = NSRange(location: 0, length: normalized.length)
        var result = ""
        result.reserveCapacity(normalized.length + 16)

        // Paragraph-aware emission so heading prefixes (`# ` / `## ` / `### `) and
        // full-line monospaced wrap (whole-paragraph backtick span) land at line
        // start. Inside each paragraph, fall through to per-attribute-run encoding
        // for inline markers (bold/italic/etc).
        var lastEnd = 0
        nsString.enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, subRange, enclosingRange, _ in
            // Defensive: emit any inter-paragraph gap as literal text (typically empty).
            if subRange.location > lastEnd {
                result += nsString.substring(with: NSRange(location: lastEnd, length: subRange.location - lastEnd))
            }

            switch paragraphHeadingLevel(normalized, range: subRange) {
            case .monospaced:
                // Whole-paragraph monospaced: emit raw content wrapped in backticks
                // with `\` and `` ` `` escaped. Per-char inline formatting is dropped
                // — markdown code spans are atomic and don't nest other markers.
                let raw = nsString.substring(with: subRange)
                var body = raw.replacingOccurrences(of: "\\", with: "\\\\")
                body = body.replacingOccurrences(of: "`", with: "\\`")
                result += "`" + body + "`"
            case .title:
                result += "# " + encodeRuns(normalized, range: subRange, headingLevel: .title)
            case .heading:
                result += "## " + encodeRuns(normalized, range: subRange, headingLevel: .heading)
            case .subheading:
                result += "### " + encodeRuns(normalized, range: subRange, headingLevel: .subheading)
            case .none:
                result += encodeRuns(normalized, range: subRange, headingLevel: nil)
            }

            // Re-emit the paragraph separator (typically a single `\n`) if the
            // enclosing range extends past the substring range.
            if NSMaxRange(enclosingRange) > NSMaxRange(subRange) {
                let sepRange = NSRange(
                    location: NSMaxRange(subRange),
                    length: NSMaxRange(enclosingRange) - NSMaxRange(subRange)
                )
                result += nsString.substring(with: sepRange)
            }
            lastEnd = NSMaxRange(enclosingRange)
        }
        // Tail content (defensive — `.byParagraphs` covers all chars, but guard
        // against an enumeration that stops short of `length`).
        if lastEnd < normalized.length {
            result += nsString.substring(with: NSRange(location: lastEnd, length: normalized.length - lastEnd))
        }
        return result
    }

    /// Reads the paragraph's first char to determine its heading level (if any).
    /// Headings are stored as a per-char attribute on every char of the paragraph;
    /// inspecting the first char is sufficient because the post-pass / apply
    /// helpers always set the attribute paragraph-wide.
    private static func paragraphHeadingLevel(_ attr: NSAttributedString, range: NSRange) -> RichTextHeadingLevel? {
        guard range.length > 0 else { return nil }
        let attrs = attr.attributes(at: range.location, effectiveRange: nil)
        if let raw = attrs[.airpadHeadingLevel] as? Int,
           let level = RichTextHeadingLevel(rawValue: raw) {
            return level
        }
        return nil
    }

    /// Per-attribute-run encoder for the body of a single paragraph. Splits out
    /// from `encode` so paragraph-level concerns (heading prefix, monospaced
    /// wrap) own the outer loop; inline-marker emission stays here.
    ///
    /// `headingLevel` lets the run encoder subtract the heading-inherent font
    /// traits (e.g., title's `.traitBold`) so a plain Title round-trips as
    /// `# Hello` rather than `# **Hello**`.
    private static func encodeRuns(_ attr: NSAttributedString, range: NSRange, headingLevel: RichTextHeadingLevel?) -> String {
        guard range.length > 0 else { return "" }
        let nsString = attr.string as NSString
        let headingTraits: UIFontDescriptor.SymbolicTraits =
            headingLevel?.font.fontDescriptor.symbolicTraits ?? []
        var result = ""
        result.reserveCapacity(range.length)

        attr.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            // Inline image: emit the storage token, skip normal text encoding
            // (the run's char is the U+FFFC attachment placeholder).
            if let itemID = attrs[.airpadImageItemID] as? String {
                result += imageToken(itemID: itemID)
                return
            }
            let runText = nsString.substring(with: runRange)
            let escaped = escape(runText)

            let isCode = (attrs[.airpadInlineCode] as? Bool) == true
            let linkURL = attrs[.link] as? URL
            let font = (attrs[.font] as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let userTraits = font.fontDescriptor.symbolicTraits.subtracting(headingTraits)
            let isBold = userTraits.contains(.traitBold)
            let isItalic = userTraits.contains(.traitItalic)
            let isUnderline = (attrs[.underlineStyle] as? Int).map { $0 != 0 } ?? false
            let isStrike = (attrs[.strikethroughStyle] as? Int).map { $0 != 0 } ?? false

            let middle: String
            if isCode {
                var body = runText.replacingOccurrences(of: "\\", with: "\\\\")
                body = body.replacingOccurrences(of: "`", with: "\\`")
                middle = "`" + body + "`"
            } else {
                var open = ""
                var close = ""
                if isBold { open += "**"; close = "**" + close }
                if isItalic { open += "*"; close = "*" + close }
                if isUnderline { open += "<u>"; close = "</u>" + close }
                if isStrike { open += "~~"; close = "~~" + close }
                middle = open + escaped + close
            }

            if let url = linkURL {
                result += "[\(middle)](\(url.absoluteString))"
            } else {
                result += middle
            }
        }
        return result
    }

    private static func escape(_ s: String) -> String {
        guard s.contains(where: { escapeChars.contains($0) }) else { return s }
        var out = ""
        out.reserveCapacity(s.count + 4)
        for ch in s {
            if escapeChars.contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    // MARK: Decoding

    static func decode(_ markdown: String) -> NSAttributedString {
        // Inline images: split on `![](airpad-image:<id>)` tokens, decode each
        // surrounding text segment through the normal pipeline, and splice image
        // attachments between them. This keeps the (dense) inline markdown parser
        // untouched — an image token is handled at the top level, never inside it.
        guard markdown.contains(imageTokenPrefix) else { return decodeText(markdown) }
        let out = NSMutableAttributedString()
        var rest = Substring(markdown)
        while let tokenStart = rest.range(of: imageTokenPrefix) {
            let before = rest[rest.startIndex..<tokenStart.lowerBound]
            if !before.isEmpty { out.append(decodeText(String(before))) }
            let after = rest[tokenStart.upperBound...]
            guard let close = after.firstIndex(of: ")") else {
                // Malformed token — emit the remainder literally and stop.
                out.append(decodeText(String(rest)))
                return out
            }
            let itemID = String(after[after.startIndex..<close])
            out.append(imageAttachmentString(itemID: itemID))
            rest = after[after.index(after: close)...]
        }
        if !rest.isEmpty { out.append(decodeText(String(rest))) }
        return out
    }

    /// The text-only decode pipeline (no image tokens). `decode` splits image
    /// tokens out and feeds each surrounding text segment through this.
    private static func decodeText(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var state = DecoderState()
        decode(markdown, into: result, state: &state, linkURL: nil)
        // Post-pass 1: apply the display-only bullet glyph substitution so the user sees
        // `• ` instead of literal `- ` at the start of bulleted lines.
        let withBullets = substituteBulletGlyphsForDisplay(result)
        // Post-pass 2: promote `# `/`## `/`### ` prefixes and whole-paragraph inline-code
        // spans to paragraph-level heading attributes (Stage 2.3).
        return detectHeadingParagraphs(withBullets)
    }

    // MARK: Heading paragraph detection (Stage 2.3)

    /// Walks each paragraph and promotes:
    /// - Leading `# `/`## `/`### ` → title/heading/subheading (prefix stripped from
    ///   display text; `.airpadHeadingLevel` + heading font applied to remainder).
    /// - Whole-paragraph inline-code span (every char carries `.airpadInlineCode`)
    ///   → monospaced paragraph (per-char marker stripped; paragraph-level attribute
    ///   + monospaced font applied).
    ///
    /// Runs in reverse paragraph order so prefix-strip mutations earlier in the
    /// string don't invalidate later ranges.
    private static func detectHeadingParagraphs(_ attr: NSAttributedString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        let ns = mut.string as NSString
        guard ns.length > 0 else { return mut }

        var paragraphRanges: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byParagraphs
        ) { _, subRange, _, _ in
            paragraphRanges.append(subRange)
        }

        for paraRange in paragraphRanges.reversed() {
            let paraText = (mut.string as NSString).substring(with: paraRange)

            if let (level, prefixLen) = headingPrefixMatch(paraText) {
                let prefixRange = NSRange(location: paraRange.location, length: prefixLen)
                mut.replaceCharacters(in: prefixRange, with: "")
                let newParaRange = NSRange(
                    location: paraRange.location,
                    length: paraRange.length - prefixLen
                )
                applyHeading(level: level, in: mut, range: newParaRange)
                continue
            }

            if paraRange.length > 0, isAllInlineCode(mut, range: paraRange) {
                mut.removeAttribute(.airpadInlineCode, range: paraRange)
                applyHeading(level: .monospaced, in: mut, range: paraRange)
            }
        }

        return mut
    }

    private static func headingPrefixMatch(_ s: String) -> (RichTextHeadingLevel, Int)? {
        if s.hasPrefix("### ") { return (.subheading, 4) }
        if s.hasPrefix("## ")  { return (.heading, 3) }
        if s.hasPrefix("# ")   { return (.title, 2) }
        return nil
    }

    private static func isAllInlineCode(_ attr: NSAttributedString, range: NSRange) -> Bool {
        var allCode = true
        attr.enumerateAttributes(in: range, options: []) { attrs, _, stop in
            if (attrs[.airpadInlineCode] as? Bool) != true {
                allCode = false
                stop.pointee = true
            }
        }
        return allCode
    }

    /// Public toolbar entry point: sets or clears the heading style for every
    /// paragraph touched by `range` on `attr`. Pass `nil` to reset to Body
    /// (strips `.airpadHeadingLevel` and resets fonts to body, preserving italic).
    /// Caller owns undo / selection / typing-attribute housekeeping.
    ///
    /// Applies per-paragraph **excluding the trailing `\n`** — if the `\n`
    /// carries the heading attribute, the cursor positioned at the start of the
    /// next paragraph inherits heading-styled typingAttributes from it, causing
    /// new text in a Body paragraph to render as Heading.
    static func setHeadingLevel(
        _ level: RichTextHeadingLevel?,
        on attr: NSMutableAttributedString,
        paragraphsTouchedBy range: NSRange
    ) {
        let ns = attr.string as NSString
        guard ns.length > 0 else { return }
        let safeLocation = min(max(range.location, 0), ns.length)
        let safeLength = min(range.length, ns.length - safeLocation)
        let enclosing = ns.paragraphRange(for: NSRange(location: safeLocation, length: safeLength))

        // Enumerate by paragraph — each `subRange` is the content WITHOUT the
        // terminator, which is exactly the range we want to style.
        ns.enumerateSubstrings(in: enclosing, options: .byParagraphs) { _, subRange, _, _ in
            if let level = level {
                attr.removeAttribute(.airpadHeadingLevel, range: subRange)
                applyHeading(level: level, in: attr, range: subRange)
            } else {
                removeHeading(in: attr, range: subRange)
            }
        }
    }

    /// Strips `.airpadHeadingLevel` and rewrites every font run back to body,
    /// preserving italic. Used by `setHeadingLevel(nil, ...)` (Body case).
    private static func removeHeading(in attr: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        attr.removeAttribute(.airpadHeadingLevel, range: range)
        let body = UIFont.preferredFont(forTextStyle: .body)
        attr.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            let existing = (value as? UIFont) ?? body
            let italic = existing.fontDescriptor.symbolicTraits.contains(.traitItalic)
            let final: UIFont
            if italic, let desc = body.fontDescriptor.withSymbolicTraits(.traitItalic) {
                final = UIFont(descriptor: desc, size: body.pointSize)
            } else {
                final = body
            }
            attr.addAttribute(.font, value: final, range: runRange)
        }
    }

    /// Applies the heading attribute paragraph-wide and overrides each font run
    /// with the heading's font, preserving any per-run italic trait. Bold and
    /// other weight traits are dropped because the heading font carries its own
    /// weight (titles are inherently bold, subheadings semibold, etc).
    private static func applyHeading(
        level: RichTextHeadingLevel,
        in attr: NSMutableAttributedString,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        attr.addAttribute(.airpadHeadingLevel, value: level.rawValue, range: range)
        attr.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            let existing = (value as? UIFont) ?? NoteTypographyHelper.bodyFont
            let italic = existing.fontDescriptor.symbolicTraits.contains(.traitItalic)
            attr.addAttribute(.font,
                              value: NoteTypographyHelper.headingFont(level: level, italic: italic),
                              range: runRange)
        }
    }

    // MARK: Checklist toggle (Stage 2.3)

    /// Public toolbar entry: for every paragraph touched by `range`, either
    /// prepends an SF-Symbol checklist glyph (unchecked) if `active == true`
    /// and the paragraph doesn't already start with one, or strips the leading
    /// glyph+space pair if `active == false`. Indented paragraphs (`"  "`
    /// groups before the glyph) are recognized when stripping, but new
    /// insertions always happen at paragraph-start offset 0 — bullet/checklist
    /// coexistence on the same paragraph is undefined for commit 4.
    ///
    /// Length-changing op: caller must adjust selection / typing afterward
    /// based on the post-op `attr.length` delta.
    static func setChecklist(
        _ active: Bool,
        on attr: NSMutableAttributedString,
        paragraphsTouchedBy range: NSRange
    ) {
        let ns = attr.string as NSString
        guard ns.length > 0 || active else { return }
        let safeLocation = min(max(range.location, 0), ns.length)
        let safeLength = min(range.length, ns.length - safeLocation)
        let enclosing: NSRange
        if ns.length == 0 {
            enclosing = NSRange(location: 0, length: 0)
        } else {
            enclosing = ns.paragraphRange(for: NSRange(location: safeLocation, length: safeLength))
        }

        // Collect paragraph ranges (content-only, no terminator). Apply in
        // reverse so mutations earlier don't shift later locations.
        var paragraphRanges: [NSRange] = []
        if ns.length == 0 {
            paragraphRanges.append(NSRange(location: 0, length: 0))
        } else {
            ns.enumerateSubstrings(in: enclosing, options: .byParagraphs) { _, subRange, _, _ in
                paragraphRanges.append(subRange)
            }
        }

        for paraRange in paragraphRanges.reversed() {
            // Marker-based prefix check — works for both the current SF Symbol
            // attachment glyph and any legacy Unicode-char glyphs from older
            // sessions. The position-and-char-shape check the previous version
            // used would miss attachment chars (which are U+FFFC, not `☐`).
            let prefix = checklistPrefixRange(in: attr, paragraph: paraRange)

            if active {
                if prefix != nil { continue }
                // Build attachment + space as a single attributed insertion.
                // The attachment string already carries marker + body font +
                // white color; the trailing space mirrors those attrs so the
                // caret following the glyph types in body / white by default.
                let insertion = NSMutableAttributedString()
                insertion.append(checklistAttachmentString(checked: false))
                insertion.append(NSAttributedString(string: " ", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.white,
                ]))
                attr.insert(insertion, at: paraRange.location)
            } else {
                guard let prefix else { continue }
                attr.replaceCharacters(in: prefix, with: "")
            }
        }
    }

    // MARK: Bullet glyph substitution (Stage 2.2.1)

    /// Display-form: walk paragraphs and substitute markdown list prefixes for
    /// their display glyphs. Two prefix shapes are recognized (after consuming
    /// any leading `"  "` indent groups):
    ///
    /// 1. `- [ ] ` / `- [x] ` (checklist) → replace the 5-char `- [ ]` /
    ///    `- [x]` portion with a single-char SF Symbol attachment (built via
    ///    `checklistAttachmentString`), marker-tagged with the state (0/1).
    ///    The trailing space is preserved as-is.
    /// 2. `- ` (bullet) → replace `-` with `•` / `◦` / `▪\u{FE0E}` by depth;
    ///    mark the glyph chars with `.airpadBulletGlyph`.
    ///
    /// Checklist takes precedence — a paragraph matching the checklist shape
    /// never falls through to bullet substitution. Mutations applied
    /// reverse-order so earlier ranges stay valid; the checklist substitution
    /// shrinks the string (5 → 1), bullet substitution at depth 2+ grows it
    /// (1 → 2).
    private static func substituteBulletGlyphsForDisplay(_ attr: NSAttributedString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        let ns = mut.string as NSString
        guard ns.length > 0 else { return mut }

        enum DisplaySub {
            case checklist(state: Int)  // range covers 5 chars `- [ ]` or `- [x]`
            case bullet(indent: Int)    // range covers 1 char `-`
        }
        var hits: [(range: NSRange, sub: DisplaySub)] = []

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byParagraphs
        ) { sub, range, _, _ in
            guard let s = sub else { return }
            let chars = Array(s)
            var idx = 0
            while idx + 1 < chars.count, chars[idx] == " ", chars[idx + 1] == " " {
                idx += 2
            }
            // Checklist takes precedence: `- [ ] ` or `- [x] ` (6 chars total)
            if idx + 5 < chars.count,
               chars[idx] == "-", chars[idx + 1] == " ",
               chars[idx + 2] == "[",
               (chars[idx + 3] == " " || chars[idx + 3] == "x"),
               chars[idx + 4] == "]", chars[idx + 5] == " " {
                let state = (chars[idx + 3] == "x") ? 1 : 0
                hits.append((NSRange(location: range.location + idx, length: 5), .checklist(state: state)))
                return
            }
            if idx + 1 < chars.count, chars[idx] == "-", chars[idx + 1] == " " {
                let depth = idx / 2
                hits.append((NSRange(location: range.location + idx, length: 1), .bullet(indent: depth)))
            }
        }

        for hit in hits.reversed() {
            switch hit.sub {
            case .checklist(let state):
                // Replace the 5-char `- [ ]` / `- [x]` portion with a 1-char
                // attachment string (NSAttachmentCharacter + attributes). The
                // trailing space stays as-is, picking up surrounding attributes.
                let replacement = checklistAttachmentString(checked: state == 1)
                mut.replaceCharacters(in: hit.range, with: replacement)
            case .bullet(let indent):
                let glyph = bulletGlyph(forIndent: indent)
                let glyphLen = (glyph as NSString).length
                mut.mutableString.replaceCharacters(in: hit.range, with: glyph)
                let glyphRange = NSRange(location: hit.range.location, length: glyphLen)
                mut.addAttribute(.airpadBulletGlyph, value: true, range: glyphRange)
            }
        }
        return mut
    }

    /// Storage-form: find chars carrying `.airpadBulletGlyph` or
    /// `.airpadChecklistGlyph` markers and rewrite them back to their markdown
    /// storage form (`-` for bullets, `- [ ]` / `- [x]` for checklists).
    ///
    /// Both marker types are collected up front and applied in document-reverse
    /// order so the shrink/grow doesn't shift earlier ranges. The two marker
    /// types are mutually exclusive within a paragraph (the display-form
    /// substitution emits only one shape per paragraph), so we don't need to
    /// worry about overlap.
    private static func substituteBulletGlyphsForStorage(_ attr: NSAttributedString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        let fullRange = NSRange(location: 0, length: mut.length)

        enum StorageSub {
            case checklist(state: Int)  // emit `- [ ]` or `- [x]` (5 chars)
            case bullet                  // emit `-` (1 char)
        }
        var hits: [(range: NSRange, sub: StorageSub)] = []

        mut.enumerateAttribute(.airpadChecklistGlyph, in: fullRange, options: []) { value, range, _ in
            if let state = value as? Int {
                hits.append((range, .checklist(state: state)))
            }
        }
        mut.enumerateAttribute(.airpadBulletGlyph, in: fullRange, options: []) { value, range, _ in
            if (value as? Bool) == true {
                hits.append((range, .bullet))
            }
        }
        hits.sort { $0.range.location > $1.range.location }

        for hit in hits {
            switch hit.sub {
            case .checklist(let state):
                // Marker is the source of truth — the glyph might be an
                // NSAttachmentCharacter (current SF Symbol path) or a legacy
                // Unicode `☐` / `☑` from an older session. Either way: replace
                // the marker-bearing range with the markdown form, then scrub
                // any residual marker/attachment attribute on the new chars.
                let replacement = (state == 1) ? "- [x]" : "- [ ]"
                mut.mutableString.replaceCharacters(in: hit.range, with: replacement)
                let newRange = NSRange(location: hit.range.location, length: (replacement as NSString).length)
                mut.removeAttribute(.airpadChecklistGlyph, range: newRange)
                mut.removeAttribute(.attachment, range: newRange)
            case .bullet:
                let chunk = (mut.string as NSString).substring(with: hit.range)
                let first = chunk.first
                if first == "•" || first == "◦" || first == "▪" {
                    mut.mutableString.replaceCharacters(in: hit.range, with: "-")
                }
                mut.removeAttribute(.airpadBulletGlyph, range: hit.range)
            }
        }
        return mut
    }

    private struct DecoderState {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
    }

    private static func decode(
        _ source: String,
        into out: NSMutableAttributedString,
        state: inout DecoderState,
        linkURL: URL?
    ) {
        let scalars = Array(source)
        var i = 0
        let count = scalars.count

        while i < count {
            let ch = scalars[i]

            // Escape sequence: \<char> is literal char
            if ch == "\\", i + 1 < count {
                let next = scalars[i + 1]
                out.append(NSAttributedString(string: String(next), attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 2
                continue
            }

            // Bold: **
            if ch == "*", i + 1 < count, scalars[i + 1] == "*" {
                state.bold.toggle()
                i += 2
                continue
            }

            // Strikethrough: ~~
            if ch == "~", i + 1 < count, scalars[i + 1] == "~" {
                state.strike.toggle()
                i += 2
                continue
            }

            // Underline open/close
            if ch == "<", let close = matchTag(scalars, at: i) {
                switch close {
                case .openUnderline: state.underline = true
                case .closeUnderline: state.underline = false
                }
                i += close.length
                continue
            }

            // Italic: *
            if ch == "*" {
                state.italic.toggle()
                i += 1
                continue
            }

            // Inline code: `…`
            if ch == "`" {
                let codeStart = i + 1
                var j = codeStart
                while j < count {
                    if scalars[j] == "\\", j + 1 < count {
                        j += 2
                        continue
                    }
                    if scalars[j] == "`" { break }
                    j += 1
                }
                if j < count {
                    // Extract code body, un-escape any \` inside
                    var body = ""
                    var k = codeStart
                    while k < j {
                        if scalars[k] == "\\", k + 1 < count {
                            body.append(scalars[k + 1])
                            k += 2
                        } else {
                            body.append(scalars[k])
                            k += 1
                        }
                    }
                    out.append(NSAttributedString(string: body, attributes: currentAttrs(state: state, code: true, linkURL: linkURL)))
                    i = j + 1
                    continue
                }
                // Unmatched backtick: treat literally
                out.append(NSAttributedString(string: "`", attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 1
                continue
            }

            // Link: [text](url)
            if ch == "[" {
                if let parsed = parseLink(scalars, from: i) {
                    var innerState = state  // inherit current inline state
                    decode(parsed.text, into: out, state: &innerState, linkURL: parsed.url)
                    i = parsed.endIndex
                    continue
                }
                // Not a link; treat literal
                out.append(NSAttributedString(string: "[", attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
                i += 1
                continue
            }

            // Literal character
            out.append(NSAttributedString(string: String(ch), attributes: currentAttrs(state: state, code: false, linkURL: linkURL)))
            i += 1
        }
    }

    private enum TagMatch {
        case openUnderline
        case closeUnderline
        var length: Int {
            switch self {
            case .openUnderline: return 3
            case .closeUnderline: return 4
            }
        }
    }

    private static func matchTag(_ scalars: [Character], at i: Int) -> TagMatch? {
        let count = scalars.count
        if i + 2 < count, scalars[i] == "<", scalars[i + 1] == "u", scalars[i + 2] == ">" {
            return .openUnderline
        }
        if i + 3 < count, scalars[i] == "<", scalars[i + 1] == "/", scalars[i + 2] == "u", scalars[i + 3] == ">" {
            return .closeUnderline
        }
        return nil
    }

    private struct LinkParse {
        let text: String
        let url: URL
        let endIndex: Int  // first index after the closing `)`
    }

    private static func parseLink(_ scalars: [Character], from start: Int) -> LinkParse? {
        let count = scalars.count
        // Find matching `]` accounting for escape sequences
        var j = start + 1
        var textChars: [Character] = []
        while j < count {
            if scalars[j] == "\\", j + 1 < count {
                textChars.append(scalars[j])
                textChars.append(scalars[j + 1])
                j += 2
                continue
            }
            if scalars[j] == "]" { break }
            textChars.append(scalars[j])
            j += 1
        }
        guard j < count, scalars[j] == "]" else { return nil }
        let urlOpen = j + 1
        guard urlOpen < count, scalars[urlOpen] == "(" else { return nil }
        let urlStart = urlOpen + 1
        var k = urlStart
        while k < count, scalars[k] != ")" {
            k += 1
        }
        guard k < count, scalars[k] == ")" else { return nil }
        let urlString = String(scalars[urlStart..<k])
        guard let url = URL(string: urlString) else { return nil }
        return LinkParse(text: String(textChars), url: url, endIndex: k + 1)
    }

    private static func currentAttrs(state: DecoderState, code: Bool, linkURL: URL?) -> [NSAttributedString.Key: Any] {
        let body = NoteTypographyHelper.bodyFont
        let font: UIFont
        if code {
            let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize, weight: state.bold ? .bold : .regular)
            if state.italic, let desc = mono.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: desc, size: body.pointSize)
            } else {
                font = mono
            }
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if state.bold { traits.insert(.traitBold) }
            if state.italic { traits.insert(.traitItalic) }
            if !traits.isEmpty, let desc = body.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: desc, size: body.pointSize)
            } else {
                font = body
            }
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        if state.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if state.strike {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if code {
            attrs[.airpadInlineCode] = true
        }
        if let url = linkURL {
            attrs[.link] = url
            attrs[.foregroundColor] = UIColor.systemBlue
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }
}

// MARK: - Note serif feel-test (SB121)

/// Scaffold font options for the Note serif feel-test. This is throwaway
/// plumbing — it will be replaced by the real font-picker setting. `.system`
/// keeps the decoded system font (existing behavior); the serif cases swap the
/// typeface while preserving each run's size + bold/italic.
enum NoteFontChoice {
    case system
    case lora
    case sourceSerif4

    /// Bundled serif PostScript face name for a run's NUMERIC `weight` + `italic`,
    /// or nil to keep the system font. `weight` is the UIFontWeight-axis value read
    /// from the descriptor's `.traits[.weight]` (see `UIFont.airpadWeightValue`) —
    /// **not** the `.traitBold` symbolic bit, which is unset for `.semibold` and so
    /// silently dropped a semibold heading's weight (the headings-italic defect).
    /// Resolves to the NEAREST vendored weight, so runs at weights we don't ship a
    /// face for still render at the closest one.
    ///
    /// SourceSerif4 vendors the full core family — Regular / Semibold / Bold, each
    /// upright + italic — so every (weight, italic) a note run can reach renders,
    /// keeping weight AND italic. `.lora` is dead scaffold: nothing sets
    /// `documentFont: .lora`, the picker that would expose it isn't built, and only
    /// Regular / Italic / Bold are vendored — so it can't honour weight or compose
    /// bold-italic; give it the same family + weight treatment if the picker ever
    /// makes it reachable. (The `.lora` in `EntryVisualSettings` / `CorpusPhysicsScene`
    /// is a separate, family-based path — not this PostScript-name one.)
    func faceName(weight: CGFloat, italic: Bool) -> String? {
        switch self {
        case .system:
            return nil
        case .sourceSerif4:
            // (axis weight, upright stem, italic stem) per vendored face. PS names
            // read from the files — `-It`/`-SemiboldIt`/`-BoldIt`, NOT `-Italic`.
            let faces: [(w: CGFloat, up: String, it: String)] = [
                (UIFont.Weight.regular.rawValue,  "Regular",  "It"),
                (UIFont.Weight.semibold.rawValue, "Semibold", "SemiboldIt"),
                (UIFont.Weight.bold.rawValue,     "Bold",     "BoldIt"),
            ]
            let nearest = faces.min { abs($0.w - weight) < abs($1.w - weight) }!
            return "SourceSerif4-" + (italic ? nearest.it : nearest.up)
        case .lora:
            // Dead scaffold — only Regular/Bold/Italic vendored (no semibold /
            // bold-italic), so weight collapses to a bold threshold and bold+italic
            // can't compose. Same family + weight fix if ever reachable.
            let bold = weight >= UIFont.Weight.semibold.rawValue
            if bold { return "Lora-Bold" }
            return italic ? "Lora-Italic" : "Lora-Regular"
        }
    }
}

extension UIFont {
    /// The run's NUMERIC weight — the UIFontWeight-axis value from the descriptor's
    /// `.traits[.weight]` — independent of the `.traitBold` symbolic bit, which is
    /// unset for `.semibold`. Defaults to `.regular` (0) when absent.
    var airpadWeightValue: CGFloat {
        let traits = fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        if let n = traits?[.weight] as? NSNumber { return CGFloat(n.doubleValue) }
        if let d = traits?[.weight] as? CGFloat { return d }
        return 0
    }
}

// MARK: - Note document typography (SB121 #3)

/// Reading/editing typography for the Note (`.text`) entry surface: line height,
/// paragraph spacing, and hanging indentation for bulleted / numbered / checklist
/// lines, plus system-aware (light/dark) colors.
///
/// Opt-in via `RichTextEditor.documentStyle` so the only other consumer of the
/// editor (`TextCaptureSheet`) is unaffected.
///
/// Storage is untouched: `.paragraphStyle` and `.foregroundColor` are display-only
/// attributes that `MarkdownCodec.encode` never reads, so markdown round-trips
/// byte-for-byte. This is a pure rendering layer.
@MainActor
enum NoteTypography {

    // Layout constants in points (not colors — safe as literals). Tuned so body
    // text reads at roughly 1.5x font-size line height with comfortable gaps,
    // and list items hang under their text like Apple Notes.
    private static let bodyLineSpacing: CGFloat = 3
    private static let bodyParagraphSpacing: CGFloat = 7
    private static let listLineSpacing: CGFloat = 4
    private static let listParagraphSpacing: CGFloat = 6
    private static let indentUnit: CGFloat = 22     // horizontal step per nesting level
    private static let markerHang: CGFloat = 20     // wrapped lines hang past the marker

    /// Text foreground — black in light, white in dark. Semantic + adaptive.
    static let foreground = UIColor.label

    /// Note base background — clean white in light; warm near-black `#1A1A1A` in
    /// dark. Deliberately NOT `systemBackground`, whose dark value is pure black;
    /// the brief calls for near-black-with-warmth, not `#000000`.
    static let background = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: CGFloat(0x1A) / 255.0,
                      green: CGFloat(0x1A) / 255.0,
                      blue: CGFloat(0x1A) / 255.0,
                      alpha: 1)
            : .systemBackground
    }

    static var bodyParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = bodyLineSpacing
        p.paragraphSpacing = bodyParagraphSpacing
        return p
    }

    private static func listParagraphStyle(indent: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = listLineSpacing
        p.paragraphSpacing = listParagraphSpacing
        let base = CGFloat(indent) * indentUnit
        p.firstLineHeadIndent = base
        p.headIndent = base + markerHang
        p.tabStops = [NSTextTab(textAlignment: .left, location: base + markerHang)]
        return p
    }

    /// Typing attributes seeded for an empty / freshly-focused editor so the first
    /// keystrokes render body-styled and in the adaptive foreground.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NoteTypographyHelper.bodyFont,
            .foregroundColor: foreground,
            .paragraphStyle: bodyParagraphStyle
        ]
    }

    /// Returns a styled copy for initial render (decode-time).
    static func styled(_ attr: NSAttributedString, font: NoteFontChoice = .system) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: attr)
        apply(to: mut, font: font)
        return mut
    }

    /// Restyles a live text view's storage in place. Attribute-only and
    /// length-preserving, so the cursor is untouched (selection restored only if
    /// it somehow shifted, to avoid a redundant delegate callback).
    static func applyInPlace(to textView: UITextView, font: NoteFontChoice = .system) {
        let sel = textView.selectedRange
        CaretTrace.log("    applyInPlace ENTER captured-sel=\(NSStringFromRange(sel)) live=\(CaretTrace.sel(textView))")
        let storage = textView.textStorage
        storage.beginEditing()
        apply(to: storage, font: font)
        storage.endEditing()
        CaretTrace.log("    applyInPlace post-endEditing live=\(CaretTrace.sel(textView))")
        if textView.selectedRange != sel { textView.selectedRange = sel }
        CaretTrace.log("    applyInPlace EXIT live=\(CaretTrace.sel(textView)) (restored-to captured-sel if drifted)")
    }

    /// Core pass: per-paragraph paragraph style + white→label color normalization,
    /// plus an optional typeface swap (serif feel-test).
    private static func apply(to mut: NSMutableAttributedString, font: NoteFontChoice) {
        let ns = mut.string as NSString
        guard ns.length > 0 else { return }
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byParagraphs
        ) { sub, subRange, enclosing, _ in
            let line = sub ?? ""
            let style = paragraphStyle(forLine: line, paragraph: subRange, in: mut)
            mut.addAttribute(.paragraphStyle, value: style, range: enclosing)

            // Normalize legacy hardcoded white → adaptive label. Leave links
            // (systemBlue) and any other explicit color intact. Collect first,
            // then apply, to avoid mutating during enumeration.
            var whiteRanges: [NSRange] = []
            mut.enumerateAttribute(.foregroundColor, in: enclosing, options: []) { value, r, _ in
                let c = value as? UIColor
                if c == nil || c == .white { whiteRanges.append(r) }
            }
            for r in whiteRanges {
                mut.addAttribute(.foregroundColor, value: foreground, range: r)
            }
        }
        if font != .system { applyFont(font, to: mut) }
    }

    /// Swaps every text run's typeface to `choice`, preserving point size and
    /// bold/italic. Inline-code (monospaced) runs are left alone. Scaffold only.
    private static func applyFont(_ choice: NoteFontChoice, to mut: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: mut.length)
        var runs: [(NSRange, UIFont)] = []
        mut.enumerateAttribute(.font, in: full, options: []) { value, r, _ in
            let current = (value as? UIFont) ?? UIFont.preferredFont(forTextStyle: .body)
            let symbolic = current.fontDescriptor.symbolicTraits
            if symbolic.contains(.traitMonoSpace) { return }   // keep inline code monospaced
            // Resolve by NUMERIC weight, not the .traitBold bit — semibold headings
            // don't set .traitBold, so the bit path drops their weight. Italic stays
            // the symbolic trait (its correct source).
            guard let name = choice.faceName(weight: current.airpadWeightValue,
                                             italic: symbolic.contains(.traitItalic)),
                  let swapped = UIFont(name: name, size: current.pointSize) else { return }
            runs.append((r, swapped))
        }
        for (r, f) in runs { mut.addAttribute(.font, value: f, range: r) }
    }

    private static func paragraphStyle(
        forLine line: String,
        paragraph: NSRange,
        in attr: NSAttributedString
    ) -> NSParagraphStyle {
        let info = RichTextEditor.Coordinator.parseLine(line)
        if info.kind != nil {
            return listParagraphStyle(indent: info.indent)
        }
        // Checklist paragraphs use an attachment glyph parseLine doesn't recognize.
        if MarkdownCodec.checklistPrefixRange(in: attr, paragraph: paragraph) != nil {
            return listParagraphStyle(indent: leadingIndentDepth(line))
        }
        return bodyParagraphStyle
    }

    private static func leadingIndentDepth(_ line: String) -> Int {
        var work = Substring(line)
        var depth = 0
        while work.hasPrefix("  "), depth < 5 { work = work.dropFirst(2); depth += 1 }
        return depth
    }
}
